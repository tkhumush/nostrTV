import Foundation
import Network

/// A loopback-only media server owned by the UI test runner, including byte-range support.
final class PhoneMediaServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "cove.phone.fixture")
    private let media: Data
    private var connections: [NWConnection] = []

    init() throws {
        guard let url = Bundle(for: PhoneMediaServer.self).url(forResource: "cove", withExtension: "mp4") else {
            throw NSError(domain: "CoveTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Phone media fixture is missing"])
        }
        media = try Data(contentsOf: url)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(self.listener.port!.rawValue)/cove.mp4")!)
                case .failed(let error):
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.connections.append(connection)
                connection.start(queue: self.queue)
                self.receive(connection, header: Data())
            }
            listener.start(queue: queue)
        }
    }

    private func receive(_ connection: NWConnection, header: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] bytes, _, done, error in
            guard let self, error == nil, let bytes else { connection.cancel(); return }
            let header = header + bytes
            guard let request = String(data: header, encoding: .utf8), request.contains("\r\n\r\n") else {
                if !done && header.count < 65_536 { self.receive(connection, header: header) }
                else { connection.cancel() }
                return
            }
            let range = request.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("range: bytes=") }
            let limits = range?.split(separator: "=").last?.split(separator: "-", omittingEmptySubsequences: false)
            let lower = max(0, min(self.media.count - 1, limits?.first.flatMap { Int($0) } ?? 0))
            let upper = max(lower, min(self.media.count - 1, limits?.last.flatMap { Int($0) } ?? self.media.count - 1))
            let payload = self.media.subdata(in: lower..<(upper + 1))
            let status = range == nil ? "200 OK" : "206 Partial Content"
            var response = "HTTP/1.1 \(status)\r\nContent-Type: video/mp4\r\nAccept-Ranges: bytes\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n"
            if range != nil { response += "Content-Range: bytes \(lower)-\(upper)/\(self.media.count)\r\n" }
            let body = request.hasPrefix("HEAD ") ? Data() : payload
            connection.send(content: Data((response + "\r\n").utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    func stop() {
        listener.cancel()
        queue.async { [self] in connections.forEach { $0.cancel() }; connections.removeAll() }
    }
}
