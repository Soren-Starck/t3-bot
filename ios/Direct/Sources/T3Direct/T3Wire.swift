import Foundation

// T3 Code's data as it comes over the wire (packages/contracts in t3code, orchestration protocol 2), reduced to
// what T3 Bot reads. Every field but the id is optional and unknown fields are ignored, so a newer T3 Code that adds
// or drops a field does not break the app.

struct T3Shell: Decodable {
    var snapshotSequence: Int?
    var threads: [T3ThreadSummary]
    var projects: [T3Project]

    enum CodingKeys: String, CodingKey { case snapshotSequence, threads, projects }

    init(snapshotSequence: Int? = nil, threads: [T3ThreadSummary] = [], projects: [T3Project] = []) {
        self.snapshotSequence = snapshotSequence
        self.threads = threads
        self.projects = projects
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        snapshotSequence = (try? c.decodeIfPresent(T3Scalar.self, forKey: .snapshotSequence))?.int
        threads = (try? c.decodeIfPresent(Lenient<T3ThreadSummary>.self, forKey: .threads))?.items ?? []
        projects = (try? c.decodeIfPresent(Lenient<T3Project>.self, forKey: .projects))?.items ?? []
    }
}

enum T3JSON {
    /// A value from the wire as JSON data, or nil when it is not a list or an object (null, a text, a number):
    /// JSONSerialization raises an exception on those, which no `try?` catches and which would take the app down.
    static func data(_ x: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject(x) else { return nil }
        return try? JSONSerialization.data(withJSONObject: x)
    }
}

/// A list that skips the items it cannot read instead of failing whole.
struct Lenient<T: Decodable>: Decodable {
    var items: [T]
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var out: [T] = []
        while !c.isAtEnd {
            if let v = try? c.decode(T.self) { out.append(v) } else { _ = try? c.decode(Skip.self) }
        }
        items = out
    }
    private struct Skip: Decodable {}
}

/// An optional field that reads as nil when a newer T3 Code sends it in a form this app does not know (a string
/// that became an object, a new shape), instead of failing the whole thread, message or item it sits in.
@propertyWrapper
struct Soft<T: Codable & Equatable>: Codable, Equatable {
    var wrappedValue: T?
    init(wrappedValue: T?) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws { wrappedValue = try? decoder.singleValueContainer().decode(T.self) }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(wrappedValue) }
}

/// The same for a list: the items it cannot read are skipped, the rest stays.
@propertyWrapper
struct SoftList<T: Codable & Equatable>: Codable, Equatable {
    var wrappedValue: [T]?
    init(wrappedValue: [T]?) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws { wrappedValue = (try? Lenient<T>(from: decoder))?.items }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(wrappedValue) }
}

extension KeyedDecodingContainer {
    func decode<T>(_ type: Soft<T>.Type, forKey key: Key) throws -> Soft<T> {
        (try? decodeIfPresent(type, forKey: key)) ?? Soft(wrappedValue: nil)
    }
    func decode<T>(_ type: SoftList<T>.Type, forKey key: Key) throws -> SoftList<T> {
        (try? decodeIfPresent(type, forKey: key)) ?? SoftList(wrappedValue: nil)
    }
}

extension KeyedEncodingContainer {
    mutating func encode<T>(_ value: Soft<T>, forKey key: Key) throws {
        if let v = value.wrappedValue { try encode(v, forKey: key) }
    }
    mutating func encode<T>(_ value: SoftList<T>, forKey key: Key) throws {
        if let v = value.wrappedValue { try encode(v, forKey: key) }
    }
}

struct T3PendingRequest: Codable, Equatable {
    var id: String
    @Soft var kind: String? = nil
    @Soft var createdAt: String? = nil
    @Soft var blocking: Bool? = nil
}

struct T3VisibleMessage: Codable, Equatable {
    @Soft var id: String? = nil
    @Soft var role: String? = nil
    @Soft var text: String? = nil
    @Soft var updatedAt: String? = nil
    @Soft var createdAt: String? = nil
}

struct T3ThreadSummary: Codable, Equatable, Identifiable {
    var id: String
    @Soft var projectId: String? = nil
    @Soft var title: String? = nil
    @Soft var status: String? = nil
    @Soft var activityRunStatus: String? = nil
    @Soft var pendingRuntimeRequest: T3PendingRequest? = nil
    @Soft var latestVisibleMessage: T3VisibleMessage? = nil
    @Soft var latestRunId: String? = nil
    @Soft var latestRunRequestedAt: String? = nil
    @Soft var latestRunStartedAt: String? = nil
    @Soft var latestRunCompletedAt: String? = nil
    @Soft var activeRunId: String? = nil
    @Soft var createdBy: String? = nil
    @Soft var creationSource: String? = nil
    @Soft var createdAt: String? = nil
    @Soft var updatedAt: String? = nil
    @Soft var archivedAt: String? = nil
    @Soft var deletedAt: String? = nil
    @Soft var settledOverride: String? = nil
    @Soft var settledAt: String? = nil
    @Soft var pinnedAt: String? = nil
    @Soft var autoSettleDisabledAt: String? = nil
    @Soft var runtimeMode: String? = nil
    @Soft var latestUserMessageAt: String? = nil
    @Soft var lastError: String? = nil
    @Soft var lineage: Lineage? = nil
    @Soft var modelSelection: ModelSelection? = nil

    struct Lineage: Codable, Equatable {
        @Soft var parentThreadId: String? = nil
        @Soft var relationshipToParent: String? = nil
        @Soft var rootThreadId: String? = nil
    }

    var isGone: Bool { archivedAt != nil || deletedAt != nil }
    var isSubagent: Bool { lineage?.relationshipToParent == "subagent" }
}

struct ModelSelection: Codable, Equatable {
    @Soft var instanceId: String? = nil
    @Soft var model: String? = nil
    @SoftList var options: [Option]? = nil
    struct Option: Codable, Equatable { var id: String; var value: T3Scalar? }
}

/// A value that may be a string, a number or a bool on the wire.
enum T3Scalar: Codable, Equatable {
    case string(String), number(Double), bool(Bool)
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) } else if let n = try? c.decode(Double.self) { self = .number(n) } else { self = .string((try? c.decode(String.self)) ?? "") }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case let .string(s): try c.encode(s); case let .number(n): try c.encode(n); case let .bool(b): try c.encode(b) }
    }
    /// A whole number, also when it came as "12" or 12.0.
    var int: Int? {
        switch self {
        case let .string(s): return Int(s)
        case let .number(n): return n.isFinite && abs(n) < 1e15 ? Int(n) : nil
        case .bool: return nil
        }
    }
    var string: String {
        switch self { case let .string(s): return s; case let .number(n): return n == n.rounded() ? String(Int(n)) : String(n); case let .bool(b): return b ? "true" : "false" }
    }
}

struct T3Project: Codable, Equatable, Identifiable {
    var id: String
    @Soft var title: String? = nil
    @Soft var workspaceRoot: String? = nil
    @Soft var defaultModelSelection: ModelSelection? = nil
    @Soft var archivedAt: String? = nil
    @Soft var pinnedAt: String? = nil
    @Soft var createdAt: String? = nil
}

// MARK: - One thread

struct T3ThreadSnapshot: Decodable {
    var snapshotSequence: Int?
    var projection: T3Projection
    var hasMoreHistory: Bool?

    enum CodingKeys: String, CodingKey { case snapshotSequence, projection, hasMoreHistory }

    init(snapshotSequence: Int? = nil, projection: T3Projection = T3Projection(), hasMoreHistory: Bool? = nil) {
        self.snapshotSequence = snapshotSequence; self.projection = projection; self.hasMoreHistory = hasMoreHistory
    }

    /// Only the projection must be there; a sequence or a flag in a form this app does not read is left out.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        snapshotSequence = (try? c.decodeIfPresent(T3Scalar.self, forKey: .snapshotSequence))?.int
        projection = try c.decode(T3Projection.self, forKey: .projection)
        hasMoreHistory = try? c.decodeIfPresent(Bool.self, forKey: .hasMoreHistory)
    }
}

struct T3Projection: Decodable {
    var thread: T3ThreadSummary?
    var runs: [T3Run]
    var messages: [T3Message]
    var runtimeRequests: [T3RuntimeRequest]
    var turnItems: [T3TurnItem]

    enum CodingKeys: String, CodingKey { case thread, runs, messages, runtimeRequests, turnItems }

    init(thread: T3ThreadSummary? = nil, runs: [T3Run] = [], messages: [T3Message] = [], runtimeRequests: [T3RuntimeRequest] = [], turnItems: [T3TurnItem] = []) {
        self.thread = thread; self.runs = runs; self.messages = messages; self.runtimeRequests = runtimeRequests; self.turnItems = turnItems
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        thread = try? c.decodeIfPresent(T3ThreadSummary.self, forKey: .thread)
        runs = (try? c.decodeIfPresent(Lenient<T3Run>.self, forKey: .runs))?.items ?? []
        messages = (try? c.decodeIfPresent(Lenient<T3Message>.self, forKey: .messages))?.items ?? []
        runtimeRequests = (try? c.decodeIfPresent(Lenient<T3RuntimeRequest>.self, forKey: .runtimeRequests))?.items ?? []
        turnItems = (try? c.decodeIfPresent(Lenient<T3TurnItem>.self, forKey: .turnItems))?.items ?? []
    }
}

struct T3Run: Codable, Equatable, Identifiable {
    var id: String
    @Soft var ordinal: Int? = nil
    @Soft var status: String? = nil
    @Soft var userMessageId: String? = nil
    @Soft var requestedAt: String? = nil
    @Soft var startedAt: String? = nil
    @Soft var completedAt: String? = nil
}

struct T3Attachment: Codable, Equatable {
    @Soft var id: String? = nil
    @Soft var type: String? = nil
    @Soft var name: String? = nil
    @Soft var mimeType: String? = nil
    @Soft var sizeBytes: Int? = nil
}

struct T3Message: Codable, Equatable, Identifiable {
    var id: String
    @Soft var role: String? = nil
    @Soft var text: String? = nil
    @Soft var runId: String? = nil
    @Soft var createdBy: String? = nil
    @Soft var creationSource: String? = nil
    @Soft var streaming: Bool? = nil
    @Soft var createdAt: String? = nil
    @Soft var updatedAt: String? = nil
    @SoftList var attachments: [T3Attachment]? = nil
}

struct T3RuntimeRequest: Codable, Equatable, Identifiable {
    var id: String
    @Soft var kind: String? = nil
    @Soft var status: String? = nil
    @Soft var createdAt: String? = nil
    @Soft var resolvedAt: String? = nil
    @Soft var responseCapability: Capability? = nil
    struct Capability: Codable, Equatable { var type: String?; var supportsFeedback: Bool? }
}

struct T3QuestionOption: Codable, Equatable { var label: String; var description: String?; var value: String? }

struct T3Question: Codable, Equatable {
    @Soft var id: String? = nil
    @Soft var header: String? = nil
    @Soft var question: String? = nil
    @SoftList var options: [T3QuestionOption]? = nil
    @Soft var multiSelect: Bool? = nil
    @Soft var allowCustomAnswer: Bool? = nil
}

struct T3TurnItem: Codable, Equatable, Identifiable {
    var id: String
    @Soft var runId: String? = nil
    @Soft var type: String? = nil
    @Soft var status: String? = nil
    @Soft var title: String? = nil
    @Soft var startedAt: String? = nil
    @Soft var completedAt: String? = nil
    @Soft var updatedAt: String? = nil
    // command_execution
    @Soft var input: String? = nil
    // dynamic_tool
    @Soft var toolName: String? = nil
    // user_input_request / approval requests
    @Soft var requestId: String? = nil
    @SoftList var questions: [T3Question]? = nil
    @Soft var command: String? = nil
    @Soft var detail: String? = nil
    @Soft var text: String? = nil
    // approval_request: the command (prompt) and why the agent wants it (reason).
    @Soft var prompt: String? = nil
    @Soft var reason: String? = nil
}
