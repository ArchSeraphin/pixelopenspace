import Foundation
import Testing
@testable import PixelCore

/// A pasted list becomes post-its (proposal 3.5, "Import collé").
@Suite struct PasteImporterTests {
    private func titles(_ text: String) -> [String] {
        PasteImporter.cards(from: text).map(\.title)
    }

    @Test func oneCardPerLine() {
        #expect(PasteImporter.cards(from: "Pagination\nLogin\nDoc de l'API") == [
            PastedCard(title: "Pagination", details: ""),
            PastedCard(title: "Login", details: ""),
            PastedCard(title: "Doc de l'API", details: ""),
        ])
    }

    @Test func blankLinesAreIgnored() {
        #expect(titles("\n\nA\n\n   \n\t\nB\n\n") == ["A", "B"])
    }

    @Test func nothingToImport() {
        #expect(PasteImporter.cards(from: "").isEmpty)
        #expect(PasteImporter.cards(from: "  \n\n\t\r\n").isEmpty)
    }

    @Test func bulletsAreRemoved() {
        #expect(titles("- A\n* B\n• C") == ["A", "B", "C"])
        #expect(titles("-\tA\n•\tB") == ["A", "B"])
        #expect(titles("-    A") == ["A"])
    }

    @Test func numberedListsWithADotOrAParenthesis() {
        #expect(titles("1. A\n2) B\n10. C\n11) D\n3.\tE") == ["A", "B", "C", "D", "E"])
    }

    @Test func checkboxesAreRemoved() {
        #expect(titles("[ ] A\n[x] B\n[X] C\n- [ ] D\n- [x] E\n* [ ] F\n1. [ ] G") == ["A", "B", "C", "D", "E", "F", "G"])
    }

    @Test func aMarkerMustBeFollowedByABlank() {
        #expect(titles("-v pour verbeux\n1.5 kg de farine\n*important*\n2)x\n[x]y\n#12 crash") == [
            "-v pour verbeux", "1.5 kg de farine", "*important*", "2)x", "[x]y", "#12 crash",
        ])
    }

    @Test func aLoneMarkerIsIgnored() {
        #expect(titles("-\n1.\n[ ]\n- [ ]\nA\n*") == ["A"])
    }

    @Test func titlesAreTrimmed() {
        #expect(titles("- A   \n B \t") == ["A", "B"])
    }

    @Test func indentedLinesGoToTheDetailsOfTheCardAbove() {
        let text = "- A\n  détail 1\n\tdétail 2\n- B\n    détail B"
        #expect(PasteImporter.cards(from: text) == [
            PastedCard(title: "A", details: "détail 1\ndétail 2"),
            PastedCard(title: "B", details: "détail B"),
        ])
    }

    @Test func indentedDetailsKeepTheirOwnBullets() {
        let text = "1. Pagination\n   - 20 par page\n   - paramètres page et per_page\n2. Login"
        #expect(PasteImporter.cards(from: text) == [
            PastedCard(title: "Pagination", details: "- 20 par page\n- paramètres page et per_page"),
            PastedCard(title: "Login", details: ""),
        ])
    }

    @Test func aSingleSpaceIsNotAnIndentation() {
        #expect(titles("A\n B") == ["A", "B"])
    }

    @Test func anIndentedFirstLineIsACard() {
        #expect(PasteImporter.cards(from: "A\n  détail\n") == [PastedCard(title: "A", details: "détail")])
        #expect(PasteImporter.cards(from: "  - A\nB") == [
            PastedCard(title: "A", details: ""),
            PastedCard(title: "B", details: ""),
        ])
    }

    @Test func aUniformlyIndentedListIsReadAsIfItWereNot() {
        let text = "    - A\n    - B\n      détail de B\n    - C"
        #expect(PasteImporter.cards(from: text) == [
            PastedCard(title: "A", details: ""),
            PastedCard(title: "B", details: "détail de B"),
            PastedCard(title: "C", details: ""),
        ])
    }

    @Test func tabsAndSpacesAreComparedByWidth() {
        // A tab moves to the next multiple of 4 columns: a list mixing both reads by how it looks.
        #expect(PasteImporter.cards(from: "\t- A\n    - B\n\t  détail de B") == [
            PastedCard(title: "A", details: ""),
            PastedCard(title: "B", details: "détail de B"),
        ])
        #expect(PasteImporter.cards(from: "  - A\n\t- détail") == [PastedCard(title: "A", details: "- détail")])
        #expect(PasteImporter.cards(from: "- A\n \tdétail") == [PastedCard(title: "A", details: "détail")])
    }

    @Test func indentationIsMeasuredFromTheLeastIndentedLine() {
        // One column deeper than the shallowest line is not an indentation, as flush left ("A\n B").
        #expect(titles(" A\n  B") == ["A", "B"])
        #expect(titles("\tA\n\tB") == ["A", "B"])
        #expect(PasteImporter.cards(from: " A\n   détail") == [PastedCard(title: "A", details: "détail")])
    }

    @Test func aCopyStartingAtTheFirstBulletOfAnIndentedBlockNestsTheRest() {
        // The first bullet lost its indentation, the others kept it: this reads as a nested list, which it cannot
        // be told apart from ("- Pagination" then "    - 20 par page").
        #expect(PasteImporter.cards(from: "- A\n    - B\n    - C") == [PastedCard(title: "A", details: "- B\n- C")])
    }

    @Test func invisibleCharactersDoNotHideAMarker() {
        #expect(titles("\u{FEFF}- A\n\u{200B}- B\n\u{2060}1. [ ] C\n- \u{FEFF}D\u{200B}\n-\u{200B} E") == [
            "A", "B", "C", "D", "E",
        ])
        // Glued to a word, invisible characters aside: still as written.
        #expect(titles("-\u{200B}v pour verbeux") == ["-\u{200B}v pour verbeux"])
    }

    @Test func aLineOfInvisibleCharactersIsBlank() {
        #expect(titles("A\n\u{FEFF}\n\u{200B} \u{2060}\nB") == ["A", "B"])
    }

    @Test func anInvisibleCharacterTakesNoColumn() {
        #expect(PasteImporter.cards(from: "\u{FEFF}- A\n\u{200B}  détail\n\u{FEFF}- B") == [
            PastedCard(title: "A", details: "détail"),
            PastedCard(title: "B", details: ""),
        ])
    }

    @Test func aBlankLineDoesNotDetachTheDetails() {
        #expect(PasteImporter.cards(from: "A\n\n  détail\nB") == [
            PastedCard(title: "A", details: "détail"),
            PastedCard(title: "B", details: ""),
        ])
    }

    @Test func textWithOrWithoutAFinalLineBreak() {
        #expect(PasteImporter.cards(from: "- A\n- B") == PasteImporter.cards(from: "- A\n- B\n"))
        #expect(titles("- A\n- B") == ["A", "B"])
    }

    @Test func carriageReturnsSplitLinesToo() {
        #expect(PasteImporter.cards(from: "- A\r\n  détail\r\n- B\rC") == [
            PastedCard(title: "A", details: "détail"),
            PastedCard(title: "B", details: ""),
            PastedCard(title: "C", details: ""),
        ])
    }

    @Test func accentsAndEmojiAreKept() {
        #expect(titles("- Écrire la doc 📚\n• Ça déploie 🚀") == ["Écrire la doc 📚", "Ça déploie 🚀"])
    }
}
