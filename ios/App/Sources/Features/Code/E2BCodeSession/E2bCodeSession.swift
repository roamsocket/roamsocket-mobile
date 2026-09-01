import Foundation
import AnyProvCore

/// A long-lived "code session" running on an E2B sandbox. The
/// sandbox stays alive across multiple operations (file reads,
/// shell commands, edits) so the user can run a series of
/// commands against the same working tree — closer to the
/// desktop's chat-driven code sessions, just driven directly
/// from the phone over e2b.dev's REST API.
///
/// The `sandboxId` + `accessToken` identify the live sandbox.
/// `transcript` is the list of human + tool messages so the
/// user can see what happened. `status` mirrors the desktop
/// session status (working / readyForReview / completed /
/// failed / killed) so the row in the Code home can render
/// the same status icons.
///
/// The agent loop itself (LLM calls, tool dispatch) is a
/// separate piece — see the upcoming `E2bSessionRunner`. This
/// struct is the *data model* the runner mutates and that
/// `E2bSessionStore` persists.
public struct E2bCodeSession: Codable, Identifiable, Hashable, Sendable {
    public enum Status: String, Codable, Hashable, Sendable {
        /// Sandbox is being provisioned.
        case provisioning
        /// Sandbox is alive and ready; no agent turn in flight.
        case idle
        /// Agent is mid-turn (LLM call + tool dispatch).
        case working
        /// Last agent turn finished with a non-error completion.
        case readyForReview
        /// Last agent turn errored.
        case failed
        /// User manually killed the sandbox.
        case killed
    }

    public let id: UUID
    public var title: String
    public var repoFullName: String
    public var branch: String
    public var sandboxId: String?
    public var sandboxDomain: String
    public var sandboxAccessToken: String?
    public var sandboxUrl: String?
    public var status: Status
    public var createdAt: Date
    public var updatedAt: Date
    public var transcript: [E2bCodeMessage]
    public var agentActive: Bool
    /// Running total of input tokens billed by the agent loop.
    /// Surfaced in the chat footer so the user sees running cost.
    public var totalInputTokens: Int
    /// Running total of output tokens billed by the agent loop.
    public var totalOutputTokens: Int
    /// The model id the user is talking to. Captured at session
    /// open time so the cost estimate stays consistent even if
    /// the user later changes the selected model.
    public var modelID: String

    public init(
        id: UUID = UUID(),
        title: String,
        repoFullName: String,
        branch: String,
        sandboxId: String? = nil,
        sandboxDomain: String = "e2b.dev",
        sandboxAccessToken: String? = nil,
        sandboxUrl: String? = nil,
        status: Status = .provisioning,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        transcript: [E2bCodeMessage] = [],
        agentActive: Bool = false,
        totalInputTokens: Int = 0,
        totalOutputTokens: Int = 0,
        modelID: String = "claude-sonnet-4-5",
    ) {
        self.id = id
        self.title = title
        self.repoFullName = repoFullName
        self.branch = branch
        self.sandboxId = sandboxId
        self.sandboxDomain = sandboxDomain
        self.sandboxAccessToken = sandboxAccessToken
        self.sandboxUrl = sandboxUrl
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.transcript = transcript
        self.agentActive = agentActive
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.modelID = modelID
    }

    /// Convenience: returns the e2b sandbox URL for "open in
    /// browser" deep links, or nil while the sandbox is still
    /// provisioning.
    public var liveSandboxURL: String? {
        guard let id = sandboxId else { return nil }
        return "https://\(id).\(sandboxDomain)"
    }

    public var isLive: Bool {
        sandboxId != nil && status != .killed
    }
}

/// One entry in a session's transcript. Mirrors the desktop
/// session's `SessionTranscriptLine` kinds so the phone UI can
/// share rendering with the chat-driven path.
public struct E2bCodeMessage: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case user
        case assistant
        case tool
        case diff
        case notice
    }

    public let id: String
    public var kind: Kind
    public var text: String
    public var tool: String?
    public var ok: Bool?
    public var path: String?
    public var added: Int?
    public var removed: Int?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        kind: Kind,
        text: String,
        tool: String? = nil,
        ok: Bool? = nil,
        path: String? = nil,
        added: Int? = nil,
        removed: Int? = nil,
        createdAt: Date = Date(),
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.tool = tool
        self.ok = ok
        self.path = path
        self.added = added
        self.removed = removed
        self.createdAt = createdAt
    }
}
