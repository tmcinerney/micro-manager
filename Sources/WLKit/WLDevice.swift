import Foundation
import CoreFoundation
import IOKit
import IOKit.hid

/// Raw-HID JSON-RPC transport for Work Louder devices.
///
/// Framing, on 64-byte reports carried by the vendor collection
/// (usage page 0xFF00 / usage 1):
///
///     byte 0      report id, always 0x06
///     byte 1      channel: 1 = firmware debug log, 2 = JSON-RPC
///     byte 2      payload length in this report, max 61
///     bytes 3..   UTF-8 fragment of the JSON message
///
/// Messages are split across as many reports as needed and reassembled by
/// scanning for balanced top-level braces.
///
/// The device must be opened **non-exclusively**. Its vendor collection shares
/// an IOHIDDevice with a keyboard collection, and macOS refuses to let anything
/// seize a keyboard — a seizing open fails with 0xE00002C1, which looks exactly
/// like a missing Input Monitoring grant and is not.
public final class WLDevice {

    public static let vendorID = 0x303A
    public static let reportID: UInt8 = 0x06
    public static let channelDebug: UInt8 = 1
    public static let channelRPC: UInt8 = 2
    public static let maxChunk = 61
    public static let reportSize = 64

    public struct Info {
        public var product: String
        public var productID: Int
        public var transport: String
        public var serial: String
        public var usagePage: Int
        public var interfaceCount: Int
    }

    public static let vendorUsagePage = 0xFF00
    public static let vendorUsage = 0x01

    public enum Failure: LocalizedError {
        case notFound
        case noVendorCollection
        case openFailed(IOReturn)
        case notConnected
        case writeFailed(IOReturn)
        case timeout(String)
        case rpc(String, String, Int? = nil)

        public var errorDescription: String? {
            switch self {
            case .notFound:
                return "No Work Louder device on the HID bus. If it is a Bluetooth pad it may have gone to sleep — press a key to wake it."
            case .noVendorCollection:
                return "Found the device, but not its vendor collection (usage page 0xFF00). Nothing to talk to."
            case .openFailed(let r):
                if r == kIOReturnNotPrivileged || UInt32(bitPattern: r) == 0xE00002C1 {
                    return "Open refused (0xE00002C1). Grant Input Monitoring to the process running this app, under System Settings → Privacy & Security → Input Monitoring."
                }
                return String(format: "IOHIDDeviceOpen failed (0x%08X)", UInt32(bitPattern: r))
            case .notConnected:
                return "Not connected."
            case .writeFailed(let r):
                let code = UInt32(bitPattern: r)
                let name: String
                switch code {
                case 0xE00002CD: name = " — kIOReturnNotOpen, the device handle is no longer open"
                case 0xE00002C0: name = " — kIOReturnNoDevice"
                case 0xE00002C5: name = " — kIOReturnExclusiveAccess"
                case 0xE00002C1: name = " — kIOReturnNotPrivileged"
                case 0xE00002C7: name = " — kIOReturnUnsupported, wrong report id or interface"
                default: name = ""
                }
                return String(format: "IOHIDDeviceSetReport failed (0x%08X)", code) + name
            case .timeout(let m):
                return "Timed out waiting for \(m)."
            case .rpc(let method, let message, let code):
                return "\(method): \(message)" + (code.map {"; rpcCode=\($0)"} ?? "; rpcCode=unavailable")
            }
        }
    }

    // Callbacks, always delivered on the main queue.
    public var onTX: ((String, Any?, Int) -> Void)?          // method, params, id
    public var pilotBudgetState:PilotRequestBudget.State? {pilotBudget?.state}
    public func configureSingleKeyMutationBeforeFirstRequest() throws {
        guard let pilotBudget else {throw NSError(domain:"WLKit.PilotBudget",code:2,userInfo:[NSLocalizedDescriptionKey:"Pilot device required"])}
        try pilotBudget.configureSingleKeyMutationBeforeFirstRequest()
    }
    public var onResponse: ((Int, Any?, String?) -> Void)?   // id, result, errorMessage
    public var onNotification: ((String, Any?) -> Void)?     // method, params
    public var onDeviceLog: ((String) -> Void)?
    public var onWriteError: ((String, String) -> Void)?
    /// Every input report, before framing. Reports that do not match the
    /// channel framing are otherwise dropped, which hides any other traffic
    /// the device emits - key presses included.
    public var onRawReport: ((UInt32, [UInt8]) -> Void)?
    public var onDisconnect: ((String) -> Void)?

    public private(set) var info: Info?
    /// When set, every call is answered by this instead of by the HID bus, and
    /// nothing touches IOKit. See `PadEmulator`.
    public let emulator: PadEmulator?
    private var emulatedConnected = false
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private final class ConnectionContext {
        weak var owner:WLDevice?
        let generation:UInt64
        let buffer=UnsafeMutablePointer<UInt8>.allocate(capacity:WLDevice.reportSize)
        init(_ owner:WLDevice,_ generation:UInt64) {self.owner=owner;self.generation=generation}
        deinit {buffer.deallocate()}
    }
    // Keep callback contexts alive until this transport is destroyed; queued work captures its generation.
    private var contexts:[ConnectionContext]=[]
    private let generationLock=NSLock()
    private var generationValue:UInt64=0
    public var connectionGeneration:UInt64 {generationLock.lock();defer {generationLock.unlock()};return generationValue}
    private let selector:PilotDeviceSelector?
    private let pilotBudget:PilotRequestBudget?
    private struct Pending {let generation:UInt64;let ticket:UUID;let done:(Any?,String?)->Void;let rpcErrorCode:((Int?)->Void)?}
    private var rpcAccumulator = ""
    private var debugAccumulator = ""
    private var pending: [Int: Pending] = [:]
    private var nextID = 1

    public var isConnected: Bool { device != nil || emulatedConnected }

    public init(emulator: PadEmulator? = nil) {self.emulator=emulator;selector=nil;pilotBudget=nil}
    /// Pilot IDs are process-wide and never reset by reconnecting or replacing a WLDevice.
    public init(pilotSelector: PilotDeviceSelector) {emulator=nil;selector=pilotSelector;pilotBudget = .process}
    init(emulator:PadEmulator,budget:PilotRequestBudget) {self.emulator=emulator;selector=nil;pilotBudget=budget}

    deinit {
        if let device {IOHIDDeviceUnscheduleFromRunLoop(device,CFRunLoopGetMain(),CFRunLoopMode.defaultMode.rawValue);IOHIDDeviceClose(device,0)}
        if let manager {IOHIDManagerClose(manager,0)}
    }

    // MARK: - Connect

    public func connect() throws {
        disconnect(reason: nil)
        let generation=connectionGeneration

        if let emulator {
            emulatedConnected = true
            info = Info(
                product: "Creator Micro 2 (emulated)",
                productID: 0x8297,
                transport: "emulated",
                serial: "EMULATOR",
                usagePage: WLDevice.vendorUsagePage,
                interfaceCount: 1
            )
            emulator.onNotify = { [weak self] method, params in
                guard let self else { return }
                DispatchQueue.main.async {
                    guard self.isConnected,self.connectionGeneration==generation else {return}
                    self.onNotification?(method,params)
                }
            }
            return
        }

        // Must be held for the lifetime of the connection: releasing the
        // manager tears down the devices it opened, and every later SetReport
        // then fails with kIOReturnNotOpen.
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        // Match on vendor only: over Bluetooth the pad presents a single
        // IOHIDDevice whose *primary* usage is keyboard, with the vendor
        // collection alongside it in DeviceUsagePairs.
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: WLDevice.vendorID] as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !set.isEmpty else {
            disconnect(reason:nil);throw Failure.notFound
        }
        // Over Bluetooth the pad is a single IOHIDDevice whose primary usage is
        // keyboard, with the vendor collection alongside it in DeviceUsagePairs.
        // Over USB each interface is its own IOHIDDevice, so picking the first
        // match lands on the keyboard and every report id 6 write is dropped.
        // Select the one that actually carries the vendor collection.
        let dev:IOHIDDevice
        if let selector {
            let devices=Array(set)
            let candidates=devices.map {d in
                PilotDeviceSelector.Candidate(vendorID:number(d,kIOHIDVendorIDKey) ?? 0,
                    productID:number(d,kIOHIDProductIDKey) ?? 0,usagePage:hasExactVendorCollection(d) ? WLDevice.vendorUsagePage : 0,
                    usage:hasExactVendorCollection(d) ? WLDevice.vendorUsage : 0,
                    serial:string(d,kIOHIDSerialNumberKey) ?? "",transport:string(d,kIOHIDTransportKey) ?? "")
            }
            do {dev=devices[try selector.index(in:candidates)]}
            catch {disconnect(reason:nil);throw error}
        } else if let selected=set.first(where:{primaryUsagePage($0)==WLDevice.vendorUsagePage}) ?? set.first(where:{hasVendorCollection($0)}) {dev=selected}
        else {disconnect(reason:nil);throw Failure.noVendorCollection}

        let result = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {disconnect(reason:nil);throw Failure.openFailed(result)}

        device = dev
        info = Info(
            product: string(dev, kIOHIDProductKey) ?? "Work Louder device",
            productID: number(dev, kIOHIDProductIDKey) ?? 0,
            transport: string(dev, kIOHIDTransportKey) ?? "?",
            serial: string(dev, kIOHIDSerialNumberKey) ?? "",
            usagePage: primaryUsagePage(dev) ?? 0,
            interfaceCount: set.count
        )

        let connection=ConnectionContext(self,generation)
        contexts.append(connection)
        let context=Unmanaged.passUnretained(connection).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(dev,connection.buffer,WLDevice.reportSize,{ctx,_,_,_,reportID,report,length in
            guard let ctx,length>0 else {return}
            let connection=Unmanaged<ConnectionContext>.fromOpaque(ctx).takeUnretainedValue()
            let bytes=Array(UnsafeBufferPointer(start:report,count:Int(length)))
            connection.owner?.enqueueReport(bytes,reportID:reportID,generation:connection.generation)
        },context)
        IOHIDDeviceRegisterRemovalCallback(dev,{ctx,_,_ in
            guard let ctx else {return}
            let connection=Unmanaged<ConnectionContext>.fromOpaque(ctx).takeUnretainedValue()
            connection.owner?.enqueueRemoval(generation:connection.generation)
        },context)

        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    public func disconnect(reason: String?) {
        generationLock.lock();generationValue &+= 1;generationLock.unlock()
        let wasConnected=isConnected
        emulatedConnected=false;emulator?.onNotify=nil
        if let dev=device {
            IOHIDDeviceUnscheduleFromRunLoop(dev,CFRunLoopGetMain(),CFRunLoopMode.defaultMode.rawValue)
            IOHIDDeviceClose(dev,IOOptionBits(kIOHIDOptionsTypeNone))
        }
        device=nil
        if let mgr=manager {IOHIDManagerClose(mgr,IOOptionBits(kIOHIDOptionsTypeNone))}
        manager=nil;info=nil;rpcAccumulator="";debugAccumulator=""
        let retired=Array(pending.values);pending.removeAll()
        for waiting in retired {waiting.done(nil,"disconnected")}
        if wasConnected,let reason {onDisconnect?(reason)}
    }
    func enqueueReport(_ bytes:[UInt8],reportID:UInt32,generation:UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self,self.isConnected,self.connectionGeneration==generation else {return}
            self.handleReport(bytes,reportID:reportID,generation:generation)
        }
    }
    func enqueueRemoval(generation:UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self,self.isConnected,self.connectionGeneration==generation else {return}
            self.disconnect(reason:"device removed")
        }
    }
    func requestTicket(_ id:Int)->UUID? {pending[id]?.ticket}
    func expireRequest(_ id:Int,ticket:UUID,generation:UInt64,method:String) {
        guard connectionGeneration==generation,let waiting=pending[id],waiting.ticket==ticket else {return}
        pending.removeValue(forKey:id)
        waiting.done(nil,Failure.timeout(method).errorDescription)
        if pilotBudget != nil {disconnect(reason:"pilot reply timeout; request retired")}
    }

    // MARK: - Send

    @discardableResult
    public func call(_ method:String,params:Any?,completion:((Any?,String?)->Void)?=nil) -> Int? {
        callReportingRPCError(method,params:params,rpcErrorCode:nil,completion:completion)
    }

    @discardableResult
    public func callReportingRPCError(_ method: String, params: Any?, rpcErrorCode: ((Int?)->Void)?, reserving:Int=0, completion: ((Any?, String?) -> Void)? = nil) -> Int? {
        guard emulatedConnected || device != nil else {
            completion?(nil, Failure.notConnected.errorDescription)
            return nil
        }

        // Firmware only accepts call ids below 1000.
        let generation=connectionGeneration,ticket=UUID()
        let id:Int
        if let pilotBudget {
            guard let allocated=pilotBudget.allocate(reserving:reserving) else {
                if reserving>0 {completion?(nil,"pilot cleanup reserve reached");return nil}
                completion?(nil,"pilot request budget exhausted");disconnect(reason:"pilot request budget exhausted");return nil
            }
            id=allocated
        } else {id=nextID;nextID=nextID % 998 + 1}
        let done=completion ?? {_,_ in}
        pending[id]=Pending(generation:generation,ticket:ticket,done:done,rpcErrorCode:rpcErrorCode)
        DispatchQueue.main.asyncAfter(deadline:.now()+(pilotBudget == nil ? 8:2)) { [weak self] in
            self?.expireRequest(id,ticket:ticket,generation:generation,method:method)
        }

        if let emulator {
            onTX?(method, params, id)
            // Answer on the next turn of the run loop rather than inline: a
            // real call is never synchronous, and callers that assume it is
            // would work here and deadlock on hardware.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.isConnected,self.connectionGeneration==generation,
                    let waiting=self.pending[id],waiting.ticket==ticket else {return}
                let (result,error)=emulator.handle(method,params:params)
                guard self.connectionGeneration==generation else {return}
                self.pending.removeValue(forKey:id)
                self.onResponse?(id,result,error)
                waiting.done(result,error)
            }
            return id
        }

        guard let dev = device else {
            completion?(nil, Failure.notConnected.errorDescription)
            return nil
        }

        var message: [String: Any] = ["method": method, "id": id]
        message["params"] = params ?? NSNull()

        guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]) else {
            pending.removeValue(forKey:id)
            completion?(nil, "could not encode params")
            return nil
        }

        let payload = [UInt8](data)
        var offset = 0
        while offset < payload.count {
            let n = min(WLDevice.maxChunk, payload.count - offset)
            var report = [UInt8](repeating: 0, count: WLDevice.reportSize)
            report[0] = WLDevice.reportID
            report[1] = WLDevice.channelRPC
            report[2] = UInt8(n)
            report.replaceSubrange(3..<(3 + n), with: payload[offset..<(offset + n)])

            let rc = report.withUnsafeBufferPointer { buf in
                IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, CFIndex(WLDevice.reportID), buf.baseAddress!, buf.count)
            }
            guard rc == kIOReturnSuccess else {
                // Surface the failure rather than dropping it: a silent write
                // error is indistinguishable from a device that ignores you.
                let message = Failure.writeFailed(rc).errorDescription ?? "write failed"
                pending.removeValue(forKey:id)
                onWriteError?(method,message)
                completion?(nil,message)
                if pilotBudget != nil {disconnect(reason:"pilot write failed")}
                return nil
            }
            offset += n
        }

        onTX?(method, params, id)

        return id
    }

    // MARK: - Receive

    private func handleReport(_ bytes: [UInt8], reportID: UInt32, generation:UInt64) {
        onRawReport?(reportID,bytes)
        guard isConnected,connectionGeneration==generation else {return}
        // The input callback delivers the report id out-of-band, so the
        // payload normally starts at index 0 — but be tolerant of stacks that
        // include it, and try the shifted alignment too.
        if !parse(bytes, at: 0) { _ = parse(bytes, at: 1) }
    }

    private func parse(_ bytes: [UInt8], at offset: Int) -> Bool {
        guard bytes.count > offset + 2 else { return false }
        let channel = bytes[offset]
        let length = Int(bytes[offset + 1])
        guard channel == WLDevice.channelRPC || channel == WLDevice.channelDebug else { return false }
        guard length > 0, length <= WLDevice.maxChunk, bytes.count >= offset + 2 + length else { return false }

        let slice = Array(bytes[(offset + 2)..<(offset + 2 + length)])
        guard let text = String(bytes: slice, encoding: .utf8) else { return false }

        if channel == WLDevice.channelDebug {
            debugAccumulator += text
            while let idx = debugAccumulator.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                let line = String(debugAccumulator[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
                debugAccumulator = String(debugAccumulator[debugAccumulator.index(after: idx)...])
                if !line.isEmpty { onDeviceLog?(line) }
            }
            if debugAccumulator.count > 4096 { debugAccumulator = "" }
            return true
        }

        rpcAccumulator += text
        let cap=pilotBudget == nil ? 8192:262_144
        guard rpcAccumulator.utf8.count<=cap else {
            rpcAccumulator=""
            if pilotBudget != nil {disconnect(reason:"pilot response exceeds 256 KiB")}
            return true
        }
        drainRPC()
        return true
    }

    /// Pulls complete top-level JSON objects out of the accumulator.
    static func matchedRPCErrorCode(_ decoded:[String:Any]) -> Int? {
        guard let n=(decoded["error"] as? [String:Any])?["code"] as? NSNumber,
              CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite,
              n.doubleValue>=Double(Int32.min),n.doubleValue<=Double(Int32.max),
              n.doubleValue==Double(n.intValue) else {return nil}
        return n.intValue
    }

    private func drainRPC() {
        let generation=connectionGeneration
        while isConnected,connectionGeneration==generation,let object = nextJSONObject() {
            guard
                let data = object.data(using: .utf8),
                let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let id = decoded["id"] as? Int {
                let error = (decoded["error"] as? [String: Any])?["message"] as? String
                let result = decoded["result"]
                if let waiting=pending.removeValue(forKey:id),waiting.generation==generation {
                    onResponse?(id,result,error)
                    if error != nil {waiting.rpcErrorCode?(Self.matchedRPCErrorCode(decoded))}
                    waiting.done(result,error)
                } else if pilotBudget == nil {
                    // Preserve the inspector's raw response diagnostics outside the bounded pilot.
                    onResponse?(id,result,error)
                }
            } else if let method = (decoded["m"] as? String) ?? (decoded["method"] as? String) {
                // Device-pushed notification. Note the envelope is abbreviated
                // here - {"m": method, "p": params} - while responses use the
                // full "method". Matching only on "method" drops every one.
                let params = decoded["m"] != nil ? decoded["p"] : decoded["params"]
                onNotification?(method, params)
            }
        }
    }

    private func nextJSONObject() -> String? {
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false
        var index = rpcAccumulator.startIndex

        while index < rpcAccumulator.endIndex {
            let ch = rpcAccumulator[index]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else if ch == "\"" {
                inString = true
            } else if ch == "{" {
                if depth == 0 { start = index }
                depth += 1
            } else if ch == "}" {
                if depth > 0 {
                    depth -= 1
                    if depth == 0, let s = start {
                        let end = rpcAccumulator.index(after: index)
                        let object = String(rpcAccumulator[s..<end])
                        rpcAccumulator = String(rpcAccumulator[end...])
                        return object
                    }
                }
            }
            index = rpcAccumulator.index(after: index)
        }
        return nil
    }

    // MARK: - Properties

    private func string(_ dev: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(dev, key as CFString) as? String
    }

    private func number(_ dev: IOHIDDevice, _ key: String) -> Int? {
        IOHIDDeviceGetProperty(dev, key as CFString) as? Int
    }

    private func primaryUsagePage(_ dev: IOHIDDevice) -> Int? {
        number(dev, kIOHIDPrimaryUsagePageKey)
    }

    private func hasExactVendorCollection(_ dev:IOHIDDevice)->Bool {
        if primaryUsagePage(dev)==WLDevice.vendorUsagePage && number(dev,kIOHIDPrimaryUsageKey)==WLDevice.vendorUsage {return true}
        guard let pairs=IOHIDDeviceGetProperty(dev,kIOHIDDeviceUsagePairsKey as CFString) as? [[String:Any]] else {return false}
        return pairs.contains {($0[kIOHIDDeviceUsagePageKey] as? Int)==WLDevice.vendorUsagePage && ($0[kIOHIDDeviceUsageKey] as? Int)==WLDevice.vendorUsage}
    }

    /// True when this IOHIDDevice exposes the vendor collection, either as its
    /// primary usage or as one of its DeviceUsagePairs.
    private func hasVendorCollection(_ dev: IOHIDDevice) -> Bool {
        if primaryUsagePage(dev) == WLDevice.vendorUsagePage { return true }
        guard let pairs = IOHIDDeviceGetProperty(dev, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Any]]
        else { return false }
        return pairs.contains { ($0[kIOHIDDeviceUsagePageKey] as? Int) == WLDevice.vendorUsagePage }
    }
}
