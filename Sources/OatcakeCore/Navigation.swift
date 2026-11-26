// Where you are among the meetings: following a folder or meeting that has moved, falling back when
// one has gone, the row that's next after some go to the Trash, and Back and Forward.

import Foundation

/// `path` after the folder or meeting at `from` has moved to `to`: it, or anything inside it,
/// follows; anything else (a sibling whose name only starts the same, say) stays where it is.
public func remapped(_ path: String, from: String, to: String) -> String {
    path == from ? to : path.hasPrefix(from + "/") ? to + path.dropFirst(from.count) : path
}

/// The folder at `path` if the tree still has it, or else the nearest folder above it that it has
/// ("", the Meetings folder itself, at worst).
public func nearestFolder(_ path: String, in tree: TreeNode) -> String {
    var path = path
    while !path.isEmpty, tree.find(path)?.kind != .folder { path = (path as NSString).deletingLastPathComponent }
    return path
}

/// The row to show once `removed` have left `list`, as Mail chooses after a delete: the first row
/// after the last one removed, or else the nearest before it. nil when nothing is left, or when
/// none of `removed` was in the list.
public func rowAfterRemoving(_ removed: Set<String>, from list: [String]) -> String? {
    guard let last = list.lastIndex(where: removed.contains) else { return nil }
    return list[(last + 1)...].first { !removed.contains($0) } ?? list[..<last].last { !removed.contains($0) }
}

/// Back and Forward through the places a link took you from, as a browser keeps them. A place that
/// has gone since (a meeting moved to the Trash) is skipped over.
public struct History<Place: Equatable> {
    private var back: [Place] = []
    private var forward: [Place] = []

    public init() {}

    /// Leaving `current` by following a link: it can be gone back to, and what was ahead is dropped.
    public mutating func leave(_ current: Place) {
        if back.last != current { back.append(current) }
        forward = []
    }

    /// Where Back goes from `current`: the latest place left that `exists` still, or nil.
    public mutating func goBack(from current: Place, where exists: (Place) -> Bool) -> Place? {
        while let place = back.popLast() {
            guard place != current, exists(place) else { continue }
            forward.append(current)
            return place
        }
        return nil
    }

    /// Where Forward goes from `current`, after going back: the place gone back from, or nil.
    public mutating func goForward(from current: Place, where exists: (Place) -> Bool) -> Place? {
        while let place = forward.popLast() {
            guard place != current, exists(place) else { continue }
            back.append(current)
            return place
        }
        return nil
    }

    public func canGoBack(from current: Place, where exists: (Place) -> Bool) -> Bool { back.contains { $0 != current && exists($0) } }
    public func canGoForward(from current: Place, where exists: (Place) -> Bool) -> Bool { forward.contains { $0 != current && exists($0) } }
}
