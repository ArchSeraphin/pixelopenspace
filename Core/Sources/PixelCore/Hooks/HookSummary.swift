import Foundation

/// One-line descriptions of a tool call, shown in the agent list, the waiting tray and notifications.
enum HookSummary {
    static let maxLength = 200

    /// Summary of `tool_input` for `tool`: the Bash command, file path, URL, query or pattern;
    /// the tool name for MCP tools; otherwise the first string value of `tool_input`, or "".
    static func tool(_ tool: String, input: HookJSON?) -> String {
        let object = input?.objectValue
        func field(_ key: String) -> String? { object?[key]?.stringValue.flatMap(nonBlank) }

        let specific: String?
        switch tool {
        case "Bash", "PowerShell":
            specific = field("command")
        case "Read", "Edit", "Write", "MultiEdit":
            specific = field("file_path")
        case "NotebookEdit":
            specific = field("notebook_path")
        case "WebFetch":
            specific = field("url")
        case "WebSearch":
            specific = field("query")
        case "Grep", "Glob":
            specific = field("pattern").map { pattern in field("path").map { "\(pattern) in \($0)" } ?? pattern }
        case "Agent", "Task":
            specific = field("description")
        case "AskUserQuestion":
            specific = object?["questions"]?.arrayValue?.first?["question"]?.stringValue.flatMap(nonBlank)
        default:
            specific = tool.hasPrefix("mcp__") ? tool : nil
        }
        return singleLine(specific ?? firstString(in: object) ?? "")
    }

    /// First line of `text`, trimmed, at most `maxLength` characters. " …" marks anything left out:
    /// further lines or the end of a long line.
    static func singleLine(_ text: String, maxLength: Int = maxLength) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstBreak = trimmed.firstIndex(where: \.isNewline)
        var line = firstBreak.map { String(trimmed[..<$0]) } ?? trimmed
        line = line.trimmingCharacters(in: .whitespaces)
        var elided = firstBreak != nil
        let marker = " …"
        if line.count + (elided ? marker.count : 0) > maxLength {
            line = String(line.prefix(max(0, maxLength - marker.count))).trimmingCharacters(in: .whitespaces)
            elided = true
        }
        return elided ? line + marker : line
    }

    /// First `maxLength` characters of `text`, unchanged otherwise.
    static func head(_ text: String, maxLength: Int = maxLength) -> String {
        String(text.prefix(maxLength))
    }

    private static func firstString(in object: HookJSONObject?) -> String? {
        object?.values.lazy.compactMap { $0.stringValue.flatMap(nonBlank) }.first
    }

    private static func nonBlank(_ text: String) -> String? {
        text.allSatisfy(\.isWhitespace) ? nil : text
    }
}
