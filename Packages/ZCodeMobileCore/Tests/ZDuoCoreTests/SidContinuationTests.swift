import XCTest
@testable import ZCodeMobileCore

final class SidContinuationTests: XCTestCase {

    func device(_ sid: String, mid: String, online: Bool, name: String? = nil) -> V2AccountApi.RemoteDevice {
        var dict: [String: Any] = ["device_sid": sid, "device_mid": mid, "online": online]
        if let name { dict["meta"] = ["name": name, "platform": "darwin", "version": "3.18.2"] }
        return V2AccountApi.RemoteDevice(dict: dict)
    }

    func testKeepCurrentWhenOldSidStillOnline() {
        let outcome = SidContinuation.resolve(
            failedSid: "d_1", failedMid: "mid-1",
            devices: [device("d_1", mid: "mid-1", online: true)])
        XCTAssertEqual(outcome, .keepCurrent)
    }

    func testSwitchToSoleOnlineSibling() {
        let outcome = SidContinuation.resolve(
            failedSid: "d_old", failedMid: "mid-1",
            devices: [
                device("d_old", mid: "mid-1", online: false),   // 旧 sid 已离线(桌面重启)
                device("d_new", mid: "mid-1", online: true, name: "Demo Mac"),
            ])
        XCTAssertEqual(outcome, .switchTo(deviceSid: "d_new", deviceName: "Demo Mac"))
    }

    func testNoneWhenTwoOnlineSiblings() {
        let outcome = SidContinuation.resolve(
            failedSid: "d_old", failedMid: "mid-1",
            devices: [
                device("d_a", mid: "mid-1", online: true),
                device("d_b", mid: "mid-1", online: true),
            ])
        XCTAssertEqual(outcome, .none)
    }

    func testNoneWhenMidMissing() {
        let outcome = SidContinuation.resolve(
            failedSid: "d_1", failedMid: nil,
            devices: [device("d_1", mid: "mid-1", online: true)])
        XCTAssertEqual(outcome, .none)
    }

    func testNoneWhenAllOffline() {
        let outcome = SidContinuation.resolve(
            failedSid: "d_old", failedMid: "mid-1",
            devices: [device("d_old", mid: "mid-1", online: false)])
        XCTAssertEqual(outcome, .none)
    }

    func testIgnoresOtherMids() {
        let outcome = SidContinuation.resolve(
            failedSid: "d_old", failedMid: "mid-1",
            devices: [
                device("d_x", mid: "mid-2", online: true),     // 别的机器
                device("d_old", mid: "mid-1", online: false),
            ])
        XCTAssertEqual(outcome, .none)
    }
}
