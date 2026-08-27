import Foundation

/// Minimal MQTT 3.1.1 packet encoding, implemented in-process so the app stays free of
/// third-party dependencies. Only what the publisher needs: CONNECT, CONNACK parsing,
/// retained QoS 0 PUBLISH, and DISCONNECT. Pure functions over Data, unit tested with
/// golden byte vectors.
enum MqttPacket {

    /// MQTT "remaining length" variable-length encoding (spec 2.2.3).
    static func encodeRemainingLength(_ length: Int) -> Data {
        var value = length
        var bytes = Data()
        repeat {
            var byte = UInt8(value % 128)
            value /= 128
            if value > 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value > 0
        return bytes
    }

    private static func encodeString(_ string: String) -> Data {
        let utf8 = Data(string.utf8)
        var data = Data()
        data.append(UInt8(utf8.count >> 8))
        data.append(UInt8(utf8.count & 0xFF))
        data.append(utf8)
        return data
    }

    static func connect(
        clientId: String,
        username: String? = nil,
        password: String? = nil,
        keepAliveSeconds: UInt16 = 30
    ) -> Data {
        var variableHeader = Data()
        variableHeader.append(encodeString("MQTT"))
        variableHeader.append(0x04)  // protocol level 3.1.1

        var connectFlags: UInt8 = 0x02  // clean session
        if username != nil { connectFlags |= 0x80 }
        if password != nil { connectFlags |= 0x40 }
        variableHeader.append(connectFlags)
        variableHeader.append(UInt8(keepAliveSeconds >> 8))
        variableHeader.append(UInt8(keepAliveSeconds & 0xFF))

        var payload = Data()
        payload.append(encodeString(clientId))
        if let username { payload.append(encodeString(username)) }
        if let password { payload.append(encodeString(password)) }

        var packet = Data([0x10])
        packet.append(encodeRemainingLength(variableHeader.count + payload.count))
        packet.append(variableHeader)
        packet.append(payload)
        return packet
    }

    /// Retained QoS 0 publish: fire-and-forget over the acknowledged TCP/TLS connection.
    /// Retained delivery is what makes Home Assistant see the last value after restarts.
    static func publish(topic: String, payload: Data, retain: Bool = true) -> Data {
        var fixedHeaderByte: UInt8 = 0x30
        if retain { fixedHeaderByte |= 0x01 }
        var variable = encodeString(topic)
        variable.append(payload)
        var packet = Data([fixedHeaderByte])
        packet.append(encodeRemainingLength(variable.count))
        packet.append(variable)
        return packet
    }

    static func disconnect() -> Data {
        Data([0xE0, 0x00])
    }

    /// Returns nil while more bytes are needed; otherwise whether the broker accepted us.
    static func parseConnack(_ data: Data) -> Bool? {
        guard data.count >= 4 else { return nil }
        let bytes = [UInt8](data.prefix(4))
        return bytes[0] == 0x20 && bytes[1] == 0x02 && bytes[3] == 0x00
    }
}
