import Foundation

/// Explicit USB identity. No first-device or Bluetooth fallback in pilot mode.
public struct PilotDeviceSelector: Equatable {
    public let serial: String
    public let productID: Int
    public init(serial: String, productID: Int = 0x8297) throws {
        guard !serial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              serial.utf8.count <= 128, !serial.unicodeScalars.contains(where: {CharacterSet.controlCharacters.contains($0)}) else {
            throw WLDevice.Failure.rpc("selector", "An exact nonempty serial is required")
        }
        self.serial=serial;self.productID=productID
    }
    public struct Candidate {
        public let vendorID: Int, productID: Int, usagePage: Int, usage: Int
        public let serial: String, transport: String
        public init(vendorID:Int,productID:Int,usagePage:Int,usage:Int,serial:String,transport:String) {
            self.vendorID=vendorID;self.productID=productID;self.usagePage=usagePage;self.usage=usage
            self.serial=serial;self.transport=transport
        }
    }
    public func index(in candidates:[Candidate]) throws -> Int {
        let matches=candidates.indices.filter {i in
            let c=candidates[i]
            return c.vendorID==WLDevice.vendorID && c.productID==productID && c.serial==serial
                && c.transport=="USB" && c.usagePage==WLDevice.vendorUsagePage && c.usage==WLDevice.vendorUsage
        }
        guard matches.count==1 else {throw WLDevice.Failure.rpc("selector","Exact USB vendor collection absent or ambiguous")}
        return matches[0]
    }
}
/// Numeric firmware replies have no generation. Never reuse their IDs in this process.
public final class PilotRequestBudget {
    public static let process = PilotRequestBudget()
    private var next=1
    private var limit:Int, lifetime:Double
    private var started:Double?
    private let clock:()->Double
    public convenience init() {self.init(limit:256,lifetime:60,clock:{ProcessInfo.processInfo.systemUptime})}
    init(limit:Int,lifetime:Double,clock:@escaping ()->Double) {self.limit=min(limit,998);self.lifetime=lifetime;self.clock=clock}
    /// Explicit configuration mode, only before this process has sent any pilot request.
    /// Does not reset IDs, extend an active lifetime or permit a second configuration.
    public func configureSingleKeyMutationBeforeFirstRequest() throws {
        lock.lock();defer {lock.unlock()}
        guard started==nil,next==1,limit==256,lifetime==60 else {
            throw NSError(domain:"WLKit.PilotBudget",code:1,userInfo:[NSLocalizedDescriptionKey:"Configuration budget must be selected before first request"])
        }
        limit=768;lifetime=120
    }
    public struct State {public let deadline:Double,remainingRequests:Int}
    /// Read-only process budget; reconnecting never resets IDs or lifetime.
    public var state:State {
        lock.lock();defer {lock.unlock()}
        let now=clock(),start=started ?? now
        let valid=now.isFinite && start.isFinite && now>=start && now-start<lifetime
        return State(deadline:start+lifetime,remainingRequests:valid ? max(0,limit-next+1):0)
    }
    private let lock=NSLock()
    func allocate(reserving:Int=0) -> Int? {
        lock.lock();defer {lock.unlock()}
        let now=clock();if started==nil {started=now}
        guard reserving>=0,now>=started!, now-started!<lifetime, next<=limit-reserving else {return nil}
        defer {next+=1};return next
    }
}
