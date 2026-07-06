//
//  EpisodeGrouping.swift
//  MultiSub
//
//  Shared "group by series+season" rule used by the cache-management (G4)
//  and vocabulary (G5) episode lists — extracted during G6 consolidation
//  since both views had implemented the identical bucket/group/flatten logic
//  independently. Presentation (Table vs List) stays with each view; this
//  just produces the grouped/flat row structure, mirroring the original
//  AppKit `GroupedRow`/`buildGroupedRows`'s rule: 2+ items sharing a group
//  key get a labeled group, a lone item renders flat with no label.
//

import Foundation

enum RowGroup<Row: Identifiable>: Identifiable {
    case grouped(label: String, rows: [Row])
    case flat(Row)

    var id: String {
        switch self {
        case .grouped(let label, _): return "group:\(label)"
        case .flat(let row): return "flat:\(row.id)"
        }
    }
}

/// Groups `items` by `groupKey`, preserving each group's position at its
/// first-seen item and each item's relative order within its group. A group
/// of exactly one item renders `.flat` (no header); `makeRow` receives
/// whether its item ended up in a `.grouped` bucket, since both current
/// callers show a shorter label for grouped rows (the header already states
/// the series) and the full title for flat ones.
func buildRowGroups<T, Row: Identifiable>(
    _ items: [T],
    groupKey: (T) -> String,
    groupLabel: (T) -> String,
    makeRow: (T, _ grouped: Bool) -> Row
) -> [RowGroup<Row>] {
    var order: [String] = []
    var buckets: [String: [T]] = [:]
    for item in items {
        let key = groupKey(item)
        if buckets[key] == nil {
            order.append(key)
            buckets[key] = []
        }
        buckets[key]?.append(item)
    }
    var groups: [RowGroup<Row>] = []
    for key in order {
        guard let bucket = buckets[key], let first = bucket.first else { continue }
        if bucket.count > 1 {
            groups.append(.grouped(label: groupLabel(first), rows: bucket.map { makeRow($0, true) }))
        } else {
            groups.append(.flat(makeRow(first, false)))
        }
    }
    return groups
}

/// e.g. "Stranger Things 第2季", or just the series title when there's no
/// season number (a movie, or the private-API season lookup failed).
func seriesGroupLabel(_ seriesTitle: String, seasonNumber: Int?) -> String {
    guard let seasonNumber else { return seriesTitle }
    return "\(seriesTitle) 第\(seasonNumber)季"
}
