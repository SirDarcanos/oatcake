import Foundation

/// The shared People and Calendars palette. Keep the order: People settings store palette indices.
public enum SwatchColour: String, Codable, CaseIterable, Sendable {
    case indigo, red, green, magenta, sky, orange, purple, leaf, blue, raspberry, mustard, teal

    public var title: String { rawValue.capitalized }

    public var hue: Double {
        switch self {
        case .indigo: 265
        case .red: 25
        case .green: 160
        case .magenta: 330
        case .sky: 200
        case .orange: 60
        case .purple: 295
        case .leaf: 130
        case .blue: 230
        case .raspberry: 0
        case .mustard: 95
        case .teal: 180
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let name = try container.decode(String.self)
        // Calendar test builds used two colours outside the shared palette.
        switch name {
        case "pink": self = .raspberry
        case "brown": self = .mustard
        default:
            // One this version doesn't know (from a newer version, or edited by hand) mustn't stop every
            // calendar from loading: it shows as the first colour until another is picked.
            self = Self(rawValue: name) ?? .indigo
        }
    }
}
