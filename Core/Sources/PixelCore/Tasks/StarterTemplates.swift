import Foundation

/// Prompt templates of a fresh board (first launch). Editable and deletable like any other.
public enum StarterTemplates {
    /// (name, body), in the order of the template manager (mockup 6(l)).
    static let definitions: [(name: String, body: String)] = [
        ("Corriger un bug", "Corrige le bug suivant et ajoute un test qui le reproduit : {titre}. {description}"),
        ("Ajouter une fonctionnalité", "Ajoute la fonctionnalité suivante, avec ses tests : {titre}. {description}"),
        ("Écrire la documentation", "Écris la documentation suivante, claire et concise : {titre}. {description}"),
    ]

    /// "Corriger un bug", "Ajouter une fonctionnalité", "Écrire la documentation", with these ids (3 expected;
    /// fewer ids give fewer templates, extra ids are ignored).
    public static func make(ids: [PromptTemplateID]) -> [PromptTemplate] {
        zip(ids, definitions).map { id, definition in
            PromptTemplate(id: id, name: definition.name, body: definition.body)
        }
    }
}
