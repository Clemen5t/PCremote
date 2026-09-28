import Foundation
import CryptoKit
import Network

enum PCRemoteError: LocalizedError {
    case invalidURL
    case invalidResponse
    case unauthorized
    case server(Int)
    case invalidMAC
    case wakeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Adresse du PC invalide."
        case .invalidResponse:
            return "Réponse du PC invalide."
        case .unauthorized:
            return "Clé secrète incorrecte."
        case .server(let code):
            return "Erreur du PC (\(code))."
        case .invalidMAC:
            return "Adresse MAC invalide."
        case .wakeFailed(let message):
            return "Wake-on-LAN : \(message)"
        }
    }
}

struct PCClient {
    let host: String
    let port: Int
    let secret: String

    func status() async throws {
        _ = try await request(path: "/status", method: "GET")
    }

    func shutdown() async throws {
        _ = try await request(path: "/action/shutdown", method: "POST")
    }

    func restart() async throws {
        _ = try await request(path: "/action/restart", method: "POST")
    }

    private func request(path: String, method: String) async throws -> Data {
        guard let url = URL(string: "http://\(host):\(port)\(path)") else {
            throw PCRemoteError.invalidURL
        }

        let timestamp = String(Int(Date().timeIntervalSince1970))
        let payload = "\(timestamp)\n\(method)\n\(path)"

        let key = SymmetricKey(data: Data(secret.utf8))
        let digest = HMAC<SHA256>.authenticationCode(
            for: Data(payload.utf8),
            using: key
        )
        let signature = digest.map { String(format: "%02x", $0) }.joined()

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(timestamp, forHTTPHeaderField: "X-PC-Time")
        request.setValue(signature, forHTTPHeaderField: "X-PC-Signature")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw PCRemoteError.invalidResponse
        }

        if http.statusCode == 401 {
            throw PCRemoteError.unauthorized
        }

        guard (200...299).contains(http.statusCode) else {
            throw PCRemoteError.server(http.statusCode)
        }

        return data
    }
}

enum WakeOnLAN {
    static func send(mac: String, broadcast: String, port: UInt16 = 9) async throws {
        let packet = try makeMagicPacket(mac: mac)

        for attempt in 0..<3 {
            try await sendOnce(packet: packet, broadcast: broadcast, port: port)
            if attempt < 2 {
                try await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    private static func makeMagicPacket(mac: String) throws -> Data {
        let clean = mac
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ".", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard clean.count == 12 else {
            throw PCRemoteError.invalidMAC
        }

        var macBytes = [UInt8]()
        var index = clean.startIndex

        for _ in 0..<6 {
            let next = clean.index(index, offsetBy: 2)
            let pair = String(clean[index..<next])

            guard let value = UInt8(pair, radix: 16) else {
                throw PCRemoteError.invalidMAC
            }

            macBytes.append(value)
            index = next
        }

        var bytes = [UInt8](repeating: 0xFF, count: 6)

        for _ in 0..<16 {
            bytes.append(contentsOf: macBytes)
        }

        return Data(bytes)
    }

    private static func sendOnce(packet: Data, broadcast: String, port: UInt16) async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw PCRemoteError.wakeFailed("port UDP invalide")
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(broadcast),
            port: nwPort,
            using: .udp
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var completed = false

            func complete(_ result: Result<Void, Error>) {
                guard !completed else { return }
                completed = true
                connection.cancel()

                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(
                        content: packet,
                        completion: .contentProcessed { error in
                            if let error {
                                complete(.failure(PCRemoteError.wakeFailed(error.localizedDescription)))
                            } else {
                                complete(.success(()))
                            }
                        }
                    )

                case .failed(let error):
                    complete(.failure(PCRemoteError.wakeFailed(error.localizedDescription)))

                default:
                    break
                }
            }

            connection.start(queue: DispatchQueue.global(qos: .userInitiated))
        }
    }
}
