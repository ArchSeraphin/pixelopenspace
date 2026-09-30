import Foundation

/// A UUID-backed identifier that encodes as a bare UUID string.
/// Distinct types keep an `AgentID` from being passed where a `ProjectID` is expected.
public protocol TypedUUID: Hashable, Codable, Sendable, CustomStringConvertible, Comparable {
    var raw: UUID { get }
    init(_ raw: UUID)
}

extension TypedUUID {
    public init() { self.init(UUID()) }

    public init?(string: String) {
        guard let uuid = UUID(uuidString: string) else { return nil }
        self.init(uuid)
    }

    public init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(UUID.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }

    public var description: String { raw.uuidString }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.raw.uuidString < rhs.raw.uuidString }
}

public struct ProjectID: TypedUUID {
    public let raw: UUID
    public init(_ raw: UUID) { self.raw = raw }
}

/// Stable app-side identity of an agent (a desk). Never equal to Claude Code's `session_id`,
/// which changes on `/clear`, `/resume` or a fork.
public struct AgentID: TypedUUID {
    public let raw: UUID
    public init(_ raw: UUID) { self.raw = raw }
}

public struct TaskCardID: TypedUUID {
    public let raw: UUID
    public init(_ raw: UUID) { self.raw = raw }
}

public struct PromptTemplateID: TypedUUID {
    public let raw: UUID
    public init(_ raw: UUID) { self.raw = raw }
}

public struct InstructionID: TypedUUID {
    public let raw: UUID
    public init(_ raw: UUID) { self.raw = raw }
}
