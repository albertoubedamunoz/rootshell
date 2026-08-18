#if targetEnvironment(macCatalyst) && STANDALONE

import Foundation

struct LocalAgentApprovalRequest: Identifiable, Sendable {
    enum Subject: Sendable, Equatable {
        case client
        case signature(keyName: String, fingerprint: String)
        case addIdentity(comment: String)
    }

    enum Decision: Sendable, Equatable {
        case deny
        case allowOnce
        case allowSession
        case alwaysAllow
        case timeout
    }

    let id: UUID
    let subject: Subject
    let clientName: String
    let clientPath: String
    let identityLine: String
    let destination: String?
    let canPersist: Bool
    let createdAt: Date
    let completion: @Sendable (Decision) -> Void

    init(
        id: UUID = UUID(),
        subject: Subject,
        clientName: String,
        clientPath: String,
        identityLine: String,
        destination: String?,
        canPersist: Bool,
        createdAt: Date = Date(),
        completion: @escaping @Sendable (Decision) -> Void
    ) {
        self.id = id
        self.subject = subject
        self.clientName = clientName
        self.clientPath = clientPath
        self.identityLine = identityLine
        self.destination = destination
        self.canPersist = canPersist
        self.createdAt = createdAt
        self.completion = completion
    }
}

#endif
