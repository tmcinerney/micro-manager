import XCTest
@testable import WLKit
final class PilotTransportTests:XCTestCase {
    func candidate(_ serial:String="exact",_ transport:String="USB")->PilotDeviceSelector.Candidate {
        .init(vendorID:WLDevice.vendorID,productID:0x8297,usagePage:0xff00,usage:1,serial:serial,transport:transport)
    }
    func testSelectorRefusesAmbiguityBluetoothAndMissingSerial() throws {
        let s=try PilotDeviceSelector(serial:"exact")
        XCTAssertEqual(try s.index(in:[candidate("other"),candidate()]),1)
        XCTAssertThrowsError(try s.index(in:[candidate(),candidate()]))
        XCTAssertThrowsError(try s.index(in:[candidate("exact","Bluetooth")]))
        XCTAssertThrowsError(try PilotDeviceSelector(serial:""))
    }
    func testIDsNeverReuseAcrossConsumersAndStopAtBudgetOrDeadline() {
        var now=0.0
        let budget=PilotRequestBudget(limit:2,lifetime:60,clock:{now})
        XCTAssertEqual(budget.allocate(),1)
        XCTAssertEqual(budget.allocate(),2)
        XCTAssertNil(budget.allocate())
        let deadline=PilotRequestBudget(limit:998,lifetime:60,clock:{now})
        XCTAssertEqual(deadline.allocate(),1);now=60;XCTAssertNil(deadline.allocate())
    }
    @MainActor func testQueuedEmulatorResponseCannotSucceedAfterReconnect() async throws {
        let device=WLDevice(emulator:PadEmulator())
        try device.connect()
        var outcomes:[String?]=[]
        device.call("sys.version",params:nil) {_,error in outcomes.append(error)}
        device.disconnect(reason:nil);try device.connect()
        await withCheckedContinuation {c in DispatchQueue.main.async {c.resume()}}
        XCTAssertEqual(outcomes.count,1)
        XCTAssertEqual(outcomes.first!,"disconnected")
        device.disconnect(reason:nil)
    }
    @MainActor func testOldEmulatorNotificationCannotEnterNewConnection() async throws {
        let emulator=PadEmulator(),device=WLDevice(emulator:PadEmulator())
        let observed=WLDevice(emulator:emulator)
        try observed.connect();let old=emulator.onNotify
        observed.disconnect(reason:nil);try observed.connect()
        var receipts=0;observed.onNotification={_,_ in receipts+=1}
        old?("v.oai.hid",["k":"AG03","act":1])
        await withCheckedContinuation {c in DispatchQueue.main.async {c.resume()}}
        XCTAssertEqual(receipts,0)
        observed.disconnect(reason:nil);device.disconnect(reason:nil)
    }

    func report(_ text:String)->[UInt8] {let bytes=Array(text.utf8);return [2,UInt8(bytes.count)]+bytes}
    @MainActor func testQueuedRawReportsRemovalAndPartialFramesAreRetired() async throws {
        let d=WLDevice(emulator:PadEmulator());try d.connect();let old=d.connectionGeneration
        var raw=0,notes=0;d.onRawReport={_,_ in raw+=1};d.onNotification={_,_ in notes+=1}
        d.enqueueReport(report("{\"m\":\"v.oai.hid\",\"p\":"),reportID:6,generation:old)
        d.enqueueRemoval(generation:old)
        d.disconnect(reason:nil);try d.connect();let fresh=d.connectionGeneration
        await withCheckedContinuation {c in DispatchQueue.main.async {c.resume()}}
        XCTAssertTrue(d.isConnected);XCTAssertEqual(raw,0);XCTAssertEqual(notes,0)
        d.enqueueReport(report("{\"m\":\"v.oai.hid\",\"p\":{\"k\":\"AG03\",\"act\":1}}"),reportID:6,generation:fresh)
        await withCheckedContinuation {c in DispatchQueue.main.async {c.resume()}}
        XCTAssertEqual(raw,1);XCTAssertEqual(notes,1);d.disconnect(reason:nil)
    }
    @MainActor func testTimeoutRetiresRequestAndCannotResetBudgetWithNewDevice() async throws {
        let budget=PilotRequestBudget(limit:1,lifetime:60,clock:{0})
        let a=WLDevice(emulator:PadEmulator(),budget:budget);try a.connect()
        var errors:[String?]=[]
        let id=try XCTUnwrap(a.call("sys.version",params:nil) {_,e in errors.append(e)})
        let ticket=try XCTUnwrap(a.requestTicket(id));let generation=a.connectionGeneration
        a.expireRequest(id,ticket:ticket,generation:generation,method:"sys.version")
        XCTAssertFalse(a.isConnected);XCTAssertEqual(errors.count,1)
        let b=WLDevice(emulator:PadEmulator(),budget:budget);try b.connect()
        XCTAssertNil(b.call("sys.version",params:nil))
        // An old numeric-only reply is not a new request, even after reconnect.
        try a.connect();var responses=0;a.onResponse={_,_,_ in responses+=1}
        a.enqueueReport(report("{\"id\":1,\"result\":\"late A\"}"),reportID:6,generation:a.connectionGeneration)
        a.expireRequest(id,ticket:ticket,generation:generation,method:"sys.version")
        await withCheckedContinuation {c in DispatchQueue.main.async {c.resume()}}
        XCTAssertEqual(responses,0);XCTAssertEqual(errors.count,1);a.disconnect(reason:nil)
    }

    @MainActor func testPilotAssemblesFullKeymapSizedNotificationWithoutEightKiBTruncation() async throws {
        let d=WLDevice(emulator:PadEmulator(),budget:PilotRequestBudget(limit:256,lifetime:60,clock:{0}));try d.connect()
        let generation=d.connectionGeneration
        var payloadLength=0
        d.onNotification={_,p in payloadLength=((p as? [String:Any])?["padding"] as? String)?.count ?? 0}
        let wire=Array(("{\"m\":\"test\",\"p\":{\"padding\":\""+String(repeating:"x",count:13_298)+"\"}}").utf8)
        for i in stride(from:0,to:wire.count,by:61) {
            let chunk=Array(wire[i..<min(i+61,wire.count)])
            d.enqueueReport([2,UInt8(chunk.count)]+chunk,reportID:6,generation:generation)
        }
        await withCheckedContinuation {c in DispatchQueue.main.async {c.resume()}}
        XCTAssertEqual(payloadLength,13_298);d.disconnect(reason:nil)
    }

    @MainActor func testMatchedDeviceErrorCodeSurvivesAsync() async throws {
        let d=WLDevice(emulator:PadEmulator());try d.connect()
        d.onTX={_,_,id in
            let wire=Array("{\"id\":\(id),\"error\":{\"code\":-32000,\"message\":\"json pool overflow\"}}".utf8)
            for i in stride(from:0,to:wire.count,by:61) {
                let chunk=Array(wire[i..<min(i+61,wire.count)])
                d.enqueueReport([2,UInt8(chunk.count)]+chunk,reportID:6,generation:d.connectionGeneration)
            }
        }
        do {_ = try await d.callAsync("fs.readbin",params:["len":192]);XCTFail("Expected device error")}
        catch let e as WLDevice.Failure {
            guard case .rpc(let method,let message,let code)=e else {return XCTFail("Wrong failure")}
            XCTAssertEqual(method,"fs.readbin");XCTAssertEqual(message,"json pool overflow");XCTAssertEqual(code,-32000)
        }
        for code:Any in [true,1.5,"-32000",Double.infinity] {XCTAssertNil(WLDevice.matchedRPCErrorCode(["error":["code":code]]))}
        d.disconnect(reason:nil)
    }

}
