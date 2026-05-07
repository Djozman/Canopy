public enum FilePriority: Int, CaseIterable {
    case dontDownload = 0
    case low          = 1
    case normal       = 4
    case high         = 7

    public var label: String {
        switch self {
        case .dontDownload: return "Skip"
        case .low:          return "Low"
        case .normal:       return "Normal"
        case .high:         return "High"
        }
    }
}
