import CoreTransferable
import PixelCore
import UniformTypeIdentifiers

extension UTType {
    /// A post-it being dragged (declared in `project.yml`, `UTExportedTypeDeclarations`). A type of its own, not
    /// plain text: a folder dragged from the Finder also carries its name as text, and must still reach the
    /// window's folder drop (mockup 6(m)) when it passes over an agent card or the board.
    static let pixelTaskCard = UTType(exportedAs: "fr.vv2.pixelopenspace.task-card", conformingTo: .data)
}

/// What a dragged post-it carries: its id, the UUID as UTF-8 text. Dropped on a section of the board it moves
/// (`.move`), on an agent card it is assigned (`.assign`).
struct CardDragPayload: Transferable, Equatable, Sendable {
    enum DecodingError: Error {
        case notACard
    }

    let cardID: TaskCardID

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .pixelTaskCard) { payload in
            Data(payload.cardID.description.utf8)
        } importing: { data in
            guard let text = String(data: data, encoding: .utf8),
                  let cardID = TaskCardID(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw DecodingError.notACard
            }
            return CardDragPayload(cardID: cardID)
        }
    }
}
