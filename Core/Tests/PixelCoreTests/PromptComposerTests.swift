import Foundation
import Testing
@testable import PixelCore

/// Template resolution and prompt composition (proposal 3.5 "Modèles de prompt", mockup 6(l)).
@Suite struct PromptComposerTests {
    typealias S = TaskBoardSamples

    private static let pagination = "Pagination /users"
    private static let perPage = "20 par page, paramètres page et per_page."

    private func card(title: String = PromptComposerTests.pagination, details: String = PromptComposerTests.perPage,
                      priority: Priority = .high, tags: [String] = ["api", "backend"],
                      templateID: PromptTemplateID? = nil) -> TaskCard {
        TaskCard(id: S.card(1), title: title, details: details, projectID: S.project(1), rank: "i", priority: priority,
                 tags: tags, templateID: templateID, createdAt: S.t0)
    }

    private func subject(_ card: TaskCard, projectName: String? = "API",
                         projectPath: String? = "/Users/nicolas/Code/api") -> PromptSubject {
        PromptSubject(card: card, projectName: projectName, projectPath: projectPath)
    }

    private func template(_ body: String) -> PromptTemplate {
        PromptTemplate(id: S.template(9), name: "Essai", body: body)
    }

    // MARK: - Subject

    @Test func subjectCopiesTheCard() {
        let subject = subject(card())
        #expect(subject.title == "Pagination /users")
        #expect(subject.details == "20 par page, paramètres page et per_page.")
        #expect(subject.projectName == "API")
        #expect(subject.projectPath == "/Users/nicolas/Code/api")
        #expect(subject.tags == ["api", "backend"])
        #expect(subject.priority == .high)
    }

    // MARK: - With a template

    @Test func everyVariableIsReplaced() {
        let body = "T={titre} D={description} P={projet} C={chemin} G={tags} R={priorite}"
        #expect(PromptComposer.compose(subject(card()), template: template(body))
            == "T=Pagination /users D=20 par page, paramètres page et per_page. P=API C=/Users/nicolas/Code/api "
            + "G=#api #backend R=haute")
    }

    @Test(arguments: [(Priority.low, "basse"), (.normal, "normale"), (.high, "haute")])
    func priorityIsWrittenOut(_ priority: Priority, _ title: String) {
        #expect(PromptComposer.compose(subject(card(priority: priority)), template: template("Priorité {priorite}"))
            == "Priorité " + title)
    }

    @Test func aVariableCanAppearTwice() {
        #expect(PromptComposer.compose(subject(card()), template: template("{titre} / {titre}"))
            == "Pagination /users / Pagination /users")
    }

    @Test func missingValuesAreEmpty() {
        let bare = subject(card(details: "", tags: []), projectName: nil, projectPath: nil)
        #expect(PromptComposer.compose(bare, template: template("[{projet}][{chemin}][{tags}][{description}]"))
            == "[][][][]")
    }

    @Test func unknownVariablesAreKeptVerbatim() {
        let body = "{titre} {inconnu} {Titre} {priorité} {titre {} { titre } {"
        #expect(PromptComposer.compose(subject(card()), template: template(body))
            == "Pagination /users {inconnu} {Titre} {priorité} {titre {} { titre } {")
    }

    @Test func extraBracesAroundAVariableAreKept() {
        #expect(PromptComposer.compose(subject(card()), template: template("{{titre}}")) == "{Pagination /users}")
    }

    @Test func substitutedValuesAreNotExpandedAgain() {
        let tricky = subject(card(title: "{description}", details: "{titre} {projet}"))
        #expect(PromptComposer.compose(tricky, template: template("{titre}|{description}"))
            == "{description}|{titre} {projet}")
    }

    @Test func tagsAreHashedOnceAndBlankOnesSkipped() {
        let tagged = subject(card(tags: ["#api", "backend", "", "  "]))
        #expect(PromptComposer.compose(tagged, template: template("{tags}")) == "#api #backend")
    }

    @Test func titleAndDescriptionAreTrimmed() {
        let padded = subject(card(title: "  Pagination  ", details: "\n20 par page.\n"))
        #expect(PromptComposer.compose(padded, template: template("<{titre}|{description}>"))
            == "<Pagination|20 par page.>")
    }

    @Test func aMultilineDescriptionKeepsItsLines() {
        let multiline = subject(card(details: "Étape 1\nÉtape 2"))
        #expect(PromptComposer.compose(multiline, template: template("{titre} :\n{description}"))
            == "Pagination /users :\nÉtape 1\nÉtape 2")
    }

    // MARK: - Without a template

    @Test func withoutTemplateTitleThenDescription() {
        #expect(PromptComposer.compose(subject(card()), template: nil)
            == "Pagination /users\n20 par page, paramètres page et per_page.")
    }

    @Test func withoutTemplateABlankDescriptionIsLeftOut() {
        #expect(PromptComposer.compose(subject(card(details: "")), template: nil) == "Pagination /users")
        #expect(PromptComposer.compose(subject(card(details: "  \n\t ")), template: nil) == "Pagination /users")
    }

    // MARK: - Resolution: card, then project, then none

    @Test func theCardTemplateWinsOverTheProjectDefault() {
        let board = TaskBoardState.initial(templateIDs: S.templateIDs)
        let resolved = PromptComposer.resolveTemplate(card: card(templateID: S.template(2)),
                                                      projectDefault: S.template(1), in: board)
        #expect(resolved?.id == S.template(2))
    }

    @Test func theProjectDefaultWhenTheCardHasNone() {
        let board = TaskBoardState.initial(templateIDs: S.templateIDs)
        let resolved = PromptComposer.resolveTemplate(card: card(), projectDefault: S.template(3), in: board)
        #expect(resolved?.id == S.template(3))
    }

    @Test func noTemplateWhenNeitherIsSet() {
        let board = TaskBoardState.initial(templateIDs: S.templateIDs)
        #expect(PromptComposer.resolveTemplate(card: card(), projectDefault: nil, in: board) == nil)
    }

    @Test func anUnknownCardTemplateFallsBackToTheProjectDefault() {
        let board = TaskBoardState.initial(templateIDs: S.templateIDs)
        let resolved = PromptComposer.resolveTemplate(card: card(templateID: S.template(42)),
                                                      projectDefault: S.template(1), in: board)
        #expect(resolved?.id == S.template(1))
    }

    @Test func anUnknownProjectDefaultMeansNoTemplate() {
        let board = TaskBoardState.initial(templateIDs: S.templateIDs)
        #expect(PromptComposer.resolveTemplate(card: card(), projectDefault: S.template(42), in: board) == nil)
        #expect(PromptComposer.resolveTemplate(card: card(templateID: S.template(41)), projectDefault: S.template(42),
                                               in: board) == nil)
    }

    // MARK: - Composer, then sanitizer: the editor's preview

    @Test func thePreviewOfMockup6lReads112Characters() {
        let board = TaskBoardState.initial(templateIDs: S.templateIDs)
        let featureCard = card(tags: ["api"], templateID: S.template(2))
        let resolved = PromptComposer.resolveTemplate(card: featureCard, projectDefault: S.template(1), in: board)
        #expect(resolved?.name == "Ajouter une fonctionnalité")
        let prompt = PromptSanitizer.sanitize(PromptComposer.compose(subject(featureCard), template: resolved))
        #expect(prompt.text == "Ajoute la fonctionnalité suivante, avec ses tests : Pagination /users. "
            + "20 par page, paramètres page et per_page.")
        #expect(PromptSanitizer.summary(prompt) == "112 caractères · saisie courte · aucun caractère retiré")
    }

    @Test func aStarterTemplateWithoutDescriptionLeavesNoTrailingSpace() {
        let board = TaskBoardState.initial(templateIDs: S.templateIDs)
        let bugCard = card(title: "Crash au login", details: "", templateID: S.template(1))
        let resolved = PromptComposer.resolveTemplate(card: bugCard, projectDefault: nil, in: board)
        let prompt = PromptSanitizer.sanitize(PromptComposer.compose(subject(bugCard), template: resolved))
        #expect(prompt.text == "Corrige le bug suivant et ajoute un test qui le reproduit : Crash au login.")
    }

    @Test func aTitleStartingWithASlashIsPrefixedWithoutTemplate() {
        let slashCard = card(title: "/clear puis relance", details: "")
        let prompt = PromptSanitizer.sanitize(PromptComposer.compose(subject(slashCard), template: nil))
        #expect(prompt.text == "Tâche : /clear puis relance")
        #expect(prompt.prefixed)
    }
}
