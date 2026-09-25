import Foundation

enum CGMType: String, JSON, CaseIterable, Identifiable {
    var id: String { rawValue }
    case none
    case nightscout
    case xdrip
    case appleHealth
    case simulator
    case plugin

    var displayName: String {
        switch self {
        case .none:
            return "None"
        case .nightscout:
            return "Nightscout as CGM"
        case .xdrip:
            return "xDrip4iOS"
        case .appleHealth:
            return "Apple Health"
        case .simulator:
            return String(localized: "Glucose Simulator", comment: "Glucose Simulator CGM type")
        case .plugin:
            return "Plugin CGM"
        }
    }

    var appURL: URL? {
        switch self {
        case .appleHealth,
             .nightscout,
             .none:
            return nil
        case .xdrip:
            return URL(string: "xdripswift://")!
        case .simulator:
            return nil
        case .plugin:
            return nil
        }
    }

    var externalLink: URL? {
        switch self {
        case .xdrip:
            return URL(string: "https://xdrip4ios.readthedocs.io/")!
        default: return nil
        }
    }

    var subtitle: String {
        switch self {
        case .none:
            return String(localized: "None", comment: "No CGM selected")
        case .nightscout:
            return String(localized: "Uses your Nightscout as CGM", comment: "Online or internal server")
        case .xdrip:
            return String(
                localized:
                "Using shared app group with external CGM app xDrip4iOS",
                comment: "Shared app group xDrip4iOS"
            )
        case .appleHealth:
            return String(
                localized: "Reads glucose that a CGM app such as Instara (Perlanova) writes to Apple Health",
                comment: "Apple Health CGM source subtitle"
            )
        case .simulator:
            return String(localized: "Glucose Simulator for Demo Only", comment: "Simple simulator")
        case .plugin:
            return String(localized: "Plugin CGM", comment: "Plugin CGM")
        }
    }
}

enum GlucoseDataError: Error {
    case noData
    case unreliableData
}
