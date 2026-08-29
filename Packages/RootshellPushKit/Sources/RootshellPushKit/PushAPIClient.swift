//
//  PushAPIClient.swift
//  RootshellPushKit
//
//  Device-side calls to the stateless relay. See push/PROTOCOL.md.
//

import Foundation

public struct PushAPIError: Error, Equatable {
    public let status: Int
    public let code: String
    public let message: String?

    public init(status: Int, code: String, message: String?) {
        self.status = status; self.code = code; self.message = message
    }
}

public struct PushAPIClient: Sendable {
    public let server: URL
    let session: URLSession

    public init(server: URL, session: URLSession = .shared) {
        self.server = server
        self.session = session
    }

    public struct Registration: Decodable, Sendable {
        public let deviceID: String
        public let deviceCred: String
        enum CodingKeys: String, CodingKey { case deviceID = "device_id", deviceCred = "device_cred" }
    }

    public struct NewSender: Decodable, Sendable {
        public let senderID: String
        public let senderCred: String
        enum CodingKeys: String, CodingKey { case senderID = "sender_id", senderCred = "sender_cred" }
    }

    public func registerDevice(apnsToken: Data, topic: String, environment: String, platform: String) async throws -> Registration {
        let body: [String: Any] = ["apns_token": apnsToken.map { String(format: "%02x", $0) }.joined(),
                                   "topic": topic, "environment": environment, "platform": platform]
        return try await request("POST", "/v1/devices", token: nil, json: body)
    }

    public func createSender(credentials: PushCredentials, label: String) async throws -> NewSender {
        try await request("POST", "/v1/senders", token: credentials.deviceCred, json: ["label": label])
    }

    private func request<T: Decodable>(_ method: String, _ path: String, token: String?, json: [String: Any]?) async throws -> T {
        var req = URLRequest(url: server.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let err = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw PushAPIError(status: http.statusCode,
                               code: err?["error"] as? String ?? "http_\(http.statusCode)",
                               message: err?["message"] as? String)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
