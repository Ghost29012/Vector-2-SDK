import Foundation

// The preview compares drafts only. Applying a fix still uses the reviewed XML.
nonisolated enum XMLSolutionDiff {
    enum Kind: Sendable { case unchanged, removed, added }
    struct Line: Sendable { var kind: Kind; var text: String }

    static func lines(before: String, after: String) -> [Line] {
        let old = before.components(separatedBy: "\n")
        let new = after.components(separatedBy: "\n")
        let changes = new.difference(from: old)
        var removals: Set<Int> = [], additions: Set<Int> = []
        for change in changes {
            switch change {
            case .remove(let offset, _, _): removals.insert(offset)
            case .insert(let offset, _, _): additions.insert(offset)
            }
        }
        var result: [Line] = [], i = 0, j = 0
        while i < old.count || j < new.count {
            if i < old.count && removals.contains(i) {
                result.append(.init(kind: .removed, text: old[i])); i += 1
            } else if j < new.count && additions.contains(j) {
                result.append(.init(kind: .added, text: new[j])); j += 1
            } else if i < old.count && j < new.count {
                result.append(.init(kind: .unchanged, text: new[j])); i += 1; j += 1
            } else { break }
        }
        return result
    }
}
