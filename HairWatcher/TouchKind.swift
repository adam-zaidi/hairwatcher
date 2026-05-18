import Foundation

enum TouchKind: String, Codable, CaseIterable {
    case hair
    case face
}

enum WatchTarget: String, CaseIterable, Codable, Identifiable {
    case hair
    case face
    case both

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hair: return "Hair"
        case .face: return "Face"
        case .both: return "Both"
        }
    }

    var watchesHair: Bool { self == .hair || self == .both }
    var watchesFace: Bool { self == .face || self == .both }
}
