import Foundation
import Darwin

enum OSC {
    static func validate(_ endpoint: Endpoint) throws {
        var address = in_addr()
        guard inet_pton(AF_INET, endpoint.host, &address) == 1, (1...65535).contains(endpoint.port), !endpoint.name.isEmpty else {
            throw CueError.message("送信先 \(endpoint.name): IPv4と1〜65535のポートを入力してください。")
        }
    }
    static func string(_ value: String) -> Data {
        var data = Data(value.utf8); data.append(0)
        while data.count % 4 != 0 { data.append(0) }
        return data
    }
    static func encode(_ message: OSCMessage) throws -> Data {
        let address = message.address
        guard address.hasPrefix("/"), !address.contains(where: {$0.isWhitespace}), address.utf8.allSatisfy({$0 >= 33 && $0 < 127}), !address.contains(where: {"#*,?[]{}".contains($0)}) else {
            throw CueError.message("OSCアドレスは / で始まるASCII文字列で指定してください（空白やパターン文字不可）。")
        }
        guard message.arguments.count <= 100 else { throw CueError.message("OSC引数が多すぎます。") }
        var payload = Data()
        for arg in message.arguments {
            switch arg.type {
            case "i":
                guard let value = Int32(arg.value) else { throw CueError.message("OSC int32 が不正です: \(arg.value)") }
                var n = value.bigEndian; withUnsafeBytes(of: &n) { payload.append(contentsOf:$0) }
            case "f":
                guard let value = Float(arg.value), value.isFinite else { throw CueError.message("OSC float32 が不正です: \(arg.value)") }
                var n = value.bitPattern.bigEndian; withUnsafeBytes(of: &n) { payload.append(contentsOf:$0) }
            case "s":
                guard arg.value.utf8.allSatisfy({$0 > 0 && $0 < 128}) else { throw CueError.message("OSC文字列はASCIIで指定してください。") }
                payload.append(string(arg.value))
            default: throw CueError.message("OSC型は i / f / s のいずれかです。")
            }
        }
        var data = string(address); data.append(string("," + message.arguments.map(\.type).joined())); data.append(payload)
        guard data.count <= 60000 else { throw CueError.message("OSCパケットが大きすぎます。") }
        return data
    }
    /// A successful return means local UDP submission only, never receiver acknowledgement.
    static func send(_ message: OSCMessage, to endpoint: Endpoint) throws {
        try validate(endpoint)
        let packet = try encode(message)
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw CueError.message("UDP socket: \(String(cString:strerror(errno)))") }
        defer { close(fd) }
        var flags = fcntl(fd,F_GETFL,0); flags |= O_NONBLOCK; _ = fcntl(fd,F_SETFL,flags)
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = UInt16(endpoint.port).bigEndian
        inet_pton(AF_INET,endpoint.host,&destination.sin_addr)
        let result = withUnsafePointer(to:&destination) { pointer in
            pointer.withMemoryRebound(to:sockaddr.self,capacity:1) { address in
                packet.withUnsafeBytes { bytes in sendto(fd,bytes.baseAddress,bytes.count,0,address,socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        guard result == packet.count else { throw CueError.message("UDP送信失敗 \(endpoint.name): \(String(cString:strerror(errno)))") }
    }
}
