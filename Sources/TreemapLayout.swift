import Foundation

struct TreemapItem: Identifiable, Equatable {
    let entry: DiskEntry?
    let bytes: Double
    var id: String { entry?.path ?? "remainder" }
    var name: String { entry?.name ?? "其他占用" }
    var displayBytes: Int64 { entry?.bytes ?? Int64(min(max(0, bytes), Double(Int64.max).nextDown)) }

    static func items(entries: [DiskEntry], total: Int64) -> [TreemapItem] {
        let visible = entries.filter { $0.bytes > 0 }.map { TreemapItem(entry: $0, bytes: Double($0.bytes)) }
        let remainder = max(0, Double(total) - visible.reduce(0) { $0 + $1.bytes })
        return (visible + (remainder > 0 ? [TreemapItem(entry: nil, bytes: remainder)] : []))
            .sorted { $0.bytes == $1.bytes ? $0.id < $1.id : $0.bytes > $1.bytes }
    }
}

struct TreemapTile {
    let item: TreemapItem
    let rect: CGRect
}

// Squarified rows preserve area while avoiding long, thin strips where possible.
enum TreemapLayout {
    static func tiles(items: [TreemapItem], in bounds: CGRect) -> [TreemapTile] {
        let items = items.filter { $0.bytes.isFinite && $0.bytes > 0 }
        let total = items.reduce(0) { $0 + $1.bytes }
        guard total.isFinite, total > 0, bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return [] }
        let scale = bounds.width * bounds.height / total
        var remaining = bounds
        var output: [TreemapTile] = []
        var row: [TreemapItem] = []
        func worst(_ values: [TreemapItem], side: CGFloat) -> Double {
            guard !values.isEmpty, side > 0 else { return .infinity }
            let areas = values.map { $0.bytes * scale }
            let sum = areas.reduce(0, +)
            let squared = side * side
            return max(squared * areas.max()! / (sum * sum), sum * sum / (squared * areas.min()!))
        }
        func place(_ values: [TreemapItem]) {
            let area = values.reduce(0) { $0 + $1.bytes * scale }
            let vertical = remaining.width >= remaining.height
            let side = vertical ? remaining.height : remaining.width
            guard side > 0 else { return }
            let thickness = min(vertical ? remaining.width : remaining.height, area / side)
            guard thickness > 0 else { return }
            var offset: CGFloat = 0
            for (index, item) in values.enumerated() {
                let length = index == values.count - 1 ? max(0, side - offset) : item.bytes * scale / thickness
                let rect = vertical
                    ? CGRect(x: remaining.minX, y: remaining.minY + offset, width: thickness, height: length)
                    : CGRect(x: remaining.minX + offset, y: remaining.minY, width: length, height: thickness)
                output.append(TreemapTile(item: item, rect: rect))
                offset += length
            }
            if vertical { remaining.origin.x += thickness; remaining.size.width -= thickness }
            else { remaining.origin.y += thickness; remaining.size.height -= thickness }
        }
        for item in items {
            let side = min(remaining.width, remaining.height)
            if !row.isEmpty && worst(row + [item], side: side) > worst(row, side: side) {
                place(row); row.removeAll()
            }
            row.append(item)
        }
        if !row.isEmpty { place(row) }
        return output
    }
}
