import Foundation

/// The active left-sidebar filter. Combines status, category, and tag filters
/// into a single selectable value.
enum TransferFilter: Hashable {
    case status(StatusFilter)
    case category(String)   // a named category
    case uncategorized
    case tag(String)
    case untagged

    func matches(_ t: Torrent) -> Bool {
        switch self {
        case .status(let s):    return s.matches(t)
        case .category(let c):  return t.category == c
        case .uncategorized:    return t.category.isEmpty
        case .tag(let tag):     return t.tags.contains(tag)
        case .untagged:         return t.tags.isEmpty
        }
    }
}
