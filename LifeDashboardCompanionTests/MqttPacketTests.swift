import XCTest
@testable import LifeDashboardCompanion

final class MqttPacketTests: XCTestCase {

    func testRemainingLengthEncoding() {
        XCTAssertEqual([UInt8](MqttPacket.encodeRemainingLength(0)), [0x00])
        XCTAssertEqual([UInt8](MqttPacket.encodeRemainingLength(127)), [0x7F])
        XCTAssertEqual([UInt8](MqttPacket.encodeRemainingLength(128)), [0x80, 0x01])
        XCTAssertEqual([UInt8](MqttPacket.encodeRemainingLength(321)), [0xC1, 0x02])
    }

    func testConnectPacketMatchesSpecExample() {
        let packet = [UInt8](MqttPacket.connect(clientId: "abc", keepAliveSeconds: 30))
        let expected: [UInt8] = [
            0x10, 0x0F,                                // CONNECT, remaining length 15
            0x00, 0x04, 0x4D, 0x51, 0x54, 0x54,        // "MQTT"
            0x04,                                      // protocol level 3.1.1
            0x02,                                      // clean session
            0x00, 0x1E,                                // keep alive 30
            0x00, 0x03, 0x61, 0x62, 0x63               // client id "abc"
        ]
        XCTAssertEqual(packet, expected)
    }

    func testConnectPacketSetsAuthFlags() {
        let packet = [UInt8](MqttPacket.connect(clientId: "c", username: "u", password: "p"))
        XCTAssertEqual(packet[9], 0x02 | 0x80 | 0x40)  // clean session + username + password
        XCTAssertEqual(Array(packet.suffix(6)), [0x00, 0x01, 0x75, 0x00, 0x01, 0x70])  // "u", "p"
    }

    func testRetainedPublishPacket() {
        let packet = [UInt8](MqttPacket.publish(topic: "a/b", payload: Data("1".utf8), retain: true))
        XCTAssertEqual(packet, [0x31, 0x06, 0x00, 0x03, 0x61, 0x2F, 0x62, 0x31])
    }

    func testConnackParsing() {
        XCTAssertEqual(MqttPacket.parseConnack(Data([0x20, 0x02, 0x00, 0x00])), true)
        XCTAssertEqual(MqttPacket.parseConnack(Data([0x20, 0x02, 0x00, 0x05])), false)
        XCTAssertNil(MqttPacket.parseConnack(Data([0x20, 0x02])))
    }

    func testDisconnectPacket() {
        XCTAssertEqual([UInt8](MqttPacket.disconnect()), [0xE0, 0x00])
    }
}
