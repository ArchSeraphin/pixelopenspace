import Foundation

/// What a prompt template is filled with: a card, plus the name and path of its project.
public struct PromptSubject: Equatable, Sendable {
    public var title: String
    public var details: String
    public var projectName: String?
    public var projectPath: String?
    public var tags: [String]
    public var priority: Priority

    public init(title: String, details: String = "", projectName: String? = nil, projectPath: String? = nil,
                tags: [String] = [], priority: Priority = .normal) {
        self.title = title
        self.details = details
        self.projectName = projectName
        self.projectPath = projectPath
        self.tags = tags
        self.priority = priority
    }

    public init(card: TaskCard, projectName: String?, projectPath: String?) {
        self.init(title: card.title, details: card.details, projectName: projectName, projectPath: projectPath,
                  tags: card.tags, priority: card.priority)
    }
}

/// Builds the text of a card's prompt from its template (proposal 3.5, "Modèles de prompt"). Pure. The result
/// still goes through `PromptSanitizer`, for the editor's preview as for the delivery: the preview is exactly
/// what will be typed (mockup 6(l)).
public enum PromptComposer {
    /// The variables a template body may use, in the order the template manager lists them (mockup 6(l)).
    public static let variables = ["{titre}", "{description}", "{projet}", "{chemin}", "{tags}", "{priorite}"]

    /// Template resolution: card.templateID, else projectDefault, else none. Unknown ids count as none.
    public static func resolveTemplate(card: TaskCard, projectDefault: PromptTemplateID?,
                                       in board: TaskBoardState) -> PromptTemplate? {
        [card.templateID, projectDefault].lazy.compactMap { $0.flatMap(board.template) }.first
    }

    /// With a template: its body with {titre} {description} {projet} {chemin} {tags} {priorite} replaced
    /// ({tags} = "#a #b", {priorite} = Priority.title, missing values = ""); unknown {x} kept verbatim.
    /// Without: the title, then a line break and the description when it is not blank.
    /// Title and description are trimmed; a substituted value is never expanded again.
    public static func compose(_ subject: PromptSubject, template: PromptTemplate?) -> String {
        let title = subject.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let details = subject.details.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let template else {
            return [title, details].filter { !$0.isEmpty }.joined(separator: "\n")
        }
        return substitute(template.body, values: [
            "titre": title,
            "description": details,
            "projet": subject.projectName ?? "",
            "chemin": subject.projectPath ?? "",
            "tags": hashtags(subject.tags),
            "priorite": subject.priority.title,
        ])
    }

    /// One pass over `body`: each "{name}" with a known name becomes its value, anything else is copied as is.
    static func substitute(_ body: String, values: [String: String]) -> String {
        var result = ""
        var rest = body[...]
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            let nameStart = rest.index(after: open)
            if let close = rest[nameStart...].firstIndex(where: { $0 == "}" || $0 == "{" }), rest[close] == "}",
               let value = values[String(rest[nameStart..<close])] {
                result += value
                rest = rest[rest.index(after: close)...]
            } else {
                result += "{"
                rest = rest[nameStart...]
            }
        }
        result += rest
        return result
    }

    /// "#api #backend": blank tags skipped, a tag already starting with "#" not hashed twice.
    static func hashtags(_ tags: [String]) -> String {
        tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0.hasPrefix("#") ? $0 : "#" + $0 }
            .joined(separator: " ")
    }
}
