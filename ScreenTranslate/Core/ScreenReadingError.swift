import Foundation

nonisolated enum ScreenReadingError: LocalizedError {
    case invalidImage
    case noText

    var errorDescription: String? {
        switch self {
        case .invalidImage: "This image couldn’t be opened."
        case .noText: "No text found on this screen."
        }
    }
}

