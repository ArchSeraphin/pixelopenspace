import Foundation

public enum HookDecodingError: Error, Equatable, Sendable {
    case notJSONObject
    case missingField(String)
    case tooLarge(Int)
}

/// Tolerant decoder for hook JSON and `pixel-hook` envelopes: unknown events decode to `.other`,
/// unknown fields are ignored, missing optional fields become `nil`.
public enum HookDecoder {
    /// Decodes one envelope line written by `pixel-hook` (wire format: `HookWire`).
    public static func decodeEnvelope(_ data: Data) throws -> HookEnvelope {
        throw HookDecodingError.notJSONObject // Implemented by the hooks work package.
    }

    /// Decodes the raw JSON Claude Code writes on a hook's stdin.
    public static func decodeHook(_ data: Data) throws -> HookEvent {
        throw HookDecodingError.notJSONObject // Implemented by the hooks work package.
    }
}
