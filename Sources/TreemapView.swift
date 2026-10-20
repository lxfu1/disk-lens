import AppKit
import SwiftUI

struct TreemapView: View {
    let result: ScanResult
    let selection: String?
    let select: (String?) -> Void
    let navigate: (URL) -> Void
    let showList: () -> Void
    let failure: (String) -> Void
    @State private var hovered: TreemapItem?
    private var chartTotal: Double { max(Double(result.total), result.entries.reduce(0) { $0 + Double(max(0, $1.bytes)) }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("目录占用地图").font(.headline)
                Spacer()
                Text("双击打开 · 右键更多操作").font(.caption).foregroundStyle(.secondary)
            }
            if chartTotal > 0 {
                TreemapCanvas(items: TreemapItem.items(entries: result.entries, total: result.total),
                              total: result.total, selection: selection,
                              hover: { hovered = $0 }, select: { select($0?.entry?.path) },
                              enter: { item in
                                  if let entry = item.entry {
                                      if entry.isDirectory { navigate(URL(fileURLWithPath: entry.path)) }
                                      else { FileActions.open(URL(fileURLWithPath: entry.path), failure: failure) }
                                  } else { showList() }
                              }, failure: failure)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(minHeight: 100)
            } else {
                Text("当前目录暂无已计入的磁盘占用").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            VStack(alignment: .leading, spacing: 3) {
                if let item = hovered {
                    Text("\(item.name) · \(formatBytes(item.displayBytes)) · \(percentage(item.bytes, total: chartTotal))")
                        .font(.callout.weight(.medium)).lineLimit(1)
                    Text(item.entry?.path ?? "未单独绘制的项目及目录自身占用；双击切回列表查看。")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                } else {
                    Text("移入方块查看名称、占用、比例及完整路径").font(.callout)
                    Text("最多展示 200 项，其余合并；方向键选择，回车打开，零占用项目见列表。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(height: 40, alignment: .leading)
        }
        .onChange(of: result.root) { _ in hovered = nil }
        .onChange(of: result.entries) { _ in hovered = nil }
        .onChange(of: result.total) { _ in hovered = nil }
    }
}

private func percentage(_ bytes: Double, total: Double) -> String {
    let value = bytes / max(1, total) * 100
    return value > 0 && value < 0.1 ? "<0.1%" : String(format: "%.1f%%", value)
}

private struct TreemapCanvas: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    let items: [TreemapItem]
    let total: Int64
    let selection: String?
    let hover: (TreemapItem?) -> Void
    let select: (TreemapItem?) -> Void
    let enter: (TreemapItem) -> Void
    let failure: (String) -> Void

    func makeNSView(context: Context) -> TreemapNSView { TreemapNSView() }
    func updateNSView(_ view: TreemapNSView, context: Context) {
        let layoutChanged = view.items != items || view.total != total
        view.items = items; view.total = total; view.selection = selection
        view.isInteractive = isEnabled
        view.hover = hover; view.select = select; view.enter = enter; view.failure = failure
        view.needsDisplay = true
        if layoutChanged { view.needsLayout = true }
    }
}

final class TreemapNSView: NSView {
    var items: [TreemapItem] = [] {
        didSet { if items != oldValue { hoveredID = nil; toolTip = nil; layoutBounds = .null; needsLayout = true } }
    }
    var total: Int64 = 0
    var isInteractive = true
    var selection: String?
    var hover: (TreemapItem?) -> Void = { _ in }
    var select: (TreemapItem?) -> Void = { _ in }
    var enter: (TreemapItem) -> Void = { _ in }
    var failure: (String) -> Void = { _ in }
    private var hoveredID: String?
    private var actions: [() -> Void] = []
    override var isFlipped: Bool { true }
    private var layoutBounds = CGRect.null
    private var cachedTiles: [TreemapTile] = []
    private var chartTotal: Double { max(Double(total), items.reduce(0) { $0 + $1.bytes }) }
    private var tiles: [TreemapTile] {
        if layoutBounds != bounds {
            cachedTiles = TreemapLayout.tiles(items: items, in: bounds)
            layoutBounds = bounds
        }
        return cachedTiles
    }
    override var acceptsFirstResponder: Bool { isInteractive && !items.isEmpty }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("目录占用地图")
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    override func layout() {
        super.layout()
        let elements = tiles.map { tile -> MapAccessibilityElement in
            let element = MapAccessibilityElement()
            element.setAccessibilityRole(.button)
            element.setAccessibilityParent(self)
            element.setAccessibilityLabel("\(tile.item.name)，\(formatBytes(tile.item.displayBytes))，\(percentage(tile.item.bytes, total: chartTotal))")
            let screen = window?.convertToScreen(convert(tile.rect, to: nil)) ?? .zero
            element.setAccessibilityFrame(screen)
            element.press = { [weak self] in
                guard let self, self.isInteractive else { return }
                self.choose(tile.item); self.enter(tile.item)
            }
            return element
        }
        setAccessibilityChildren(elements)
    }
    private func choose(_ item: TreemapItem?) {
        selection = item?.entry?.path
        hoveredID = item?.id
        select(item); hover(item); needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        guard isInteractive else { return }
        if event.keyCode == 53 { choose(nil); return }
        let candidates = tiles
        guard !candidates.isEmpty else { return }
        let current = candidates.first { selection != nil && $0.item.entry?.path == selection }
            ?? candidates.first { $0.item.id == hoveredID }
        if event.keyCode == 36 || event.keyCode == 76 {
            if let current { enter(current.item) }
            return
        }
        guard [123, 124, 125, 126].contains(event.keyCode) else { super.keyDown(with: event); return }
        guard let current else { choose(candidates[0].item); return }
        let next = candidates.filter { tile in
            switch event.keyCode {
            case 123: return tile.rect.midX < current.rect.midX - 0.1
            case 124: return tile.rect.midX > current.rect.midX + 0.1
            case 125: return tile.rect.midY > current.rect.midY + 0.1
            default: return tile.rect.midY < current.rect.midY - 0.1
            }
        }.min { a, b in
            hypot(a.rect.midX - current.rect.midX, a.rect.midY - current.rect.midY)
                < hypot(b.rect.midX - current.rect.midX, b.rect.midY - current.rect.midY)
        }
        if let next { choose(next.item) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    private func item(at event: NSEvent) -> TreemapItem? {
        let point = convert(event.locationInWindow, from: nil)
        return tiles.first { $0.rect.contains(point) }?.item
    }
    override func mouseMoved(with event: NSEvent) {
        let item = item(at: event)
        guard hoveredID != item?.id else { return }
        hoveredID = item?.id
        hover(item); needsDisplay = true
        toolTip = item.map { "\($0.name)\n\(formatBytes($0.displayBytes)) · \(percentage($0.bytes, total: chartTotal))\n\($0.entry?.path ?? "其他项目及目录自身占用")" }
    }
    override func mouseExited(with event: NSEvent) {
        hoveredID = nil; hover(nil); toolTip = nil; needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        guard isInteractive else { return }
        if event.modifierFlags.contains(.control) { rightMouseDown(with: event); return }
        window?.makeFirstResponder(self)
        let item = item(at: event)
        choose(item)
        if event.clickCount == 2, let item { enter(item) }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); bounds.fill()
        for tile in tiles {
            let rect = tile.rect.insetBy(dx: min(1, tile.rect.width / 4), dy: min(1, tile.rect.height / 4))
            let hash = tile.item.id.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
            let color = tile.item.entry == nil ? NSColor.systemGray : NSColor(calibratedHue: CGFloat(hash % 360) / 360, saturation: 0.52, brightness: 0.61, alpha: 1)
            let isHighlighted = tile.item.id == hoveredID || (selection != nil && tile.item.entry?.path == selection)
            color.withAlphaComponent(isHighlighted ? 0.8 : 1).setFill()
            rect.fill()
            guard rect.width > 48, rect.height > 25 else { continue }
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white, .paragraphStyle: paragraph]
            let name = (tile.item.entry?.isDirectory == true ? "▸ " : "") + tile.item.name
            (name as NSString).draw(in: CGRect(x: rect.minX + 7, y: rect.minY + 6, width: max(0, rect.width - 14), height: 17), withAttributes: attributes)
            if rect.height > 46 {
                ("\(formatBytes(tile.item.displayBytes)) · \(percentage(tile.item.bytes, total: chartTotal))" as NSString)
                    .draw(in: CGRect(x: rect.minX + 7, y: rect.minY + 25, width: max(0, rect.width - 14), height: 17), withAttributes: attributes)
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menu(for: event) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard isInteractive else { return nil }
        guard let item = item(at: event), let entry = item.entry else { return nil }
        window?.makeFirstResponder(self)
        choose(item)
        return contextMenu(for: entry)
    }
    func contextMenu(for entry: DiskEntry) -> NSMenu {
        let url = URL(fileURLWithPath: entry.path)
        actions.removeAll()
        let menu = NSMenu()
        if entry.isDirectory {
            add("打开此文件夹", to: menu) { [weak self] in self?.enter(TreemapItem(entry: entry, bytes: Double(entry.bytes))) }
        } else {
            add("打开", to: menu) { [weak self] in
                FileActions.open(url) { self?.failure($0) }
            }
            let openWith = NSMenu()
            let apps = FileActions.applications(for: url)
            for app in apps {
                add(FileActions.applicationName(app, for: url), to: openWith) { [weak self] in
                    FileActions.open(url, with: app) { self?.failure($0) }
                }
            }
            if !apps.isEmpty { openWith.addItem(.separator()) }
            add("其他应用…", to: openWith) { [weak self] in
                FileActions.chooseApplication(for: url) { self?.failure($0) }
            }
            let submenu = NSMenuItem(title: "打开方式", action: nil, keyEquivalent: "")
            submenu.submenu = openWith; menu.addItem(submenu)
        }
        menu.addItem(.separator())
        add("在 Finder 中显示", to: menu) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        add("复制路径", to: menu) { FileActions.copyPath(entry.path) }
        return menu
    }
    private func add(_ title: String, to menu: NSMenu, action: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(performMenuAction(_:)), keyEquivalent: "")
        item.target = self; item.tag = actions.count; actions.append(action); menu.addItem(item)
    }
    @objc private func performMenuAction(_ item: NSMenuItem) {
        guard actions.indices.contains(item.tag) else { return }; actions[item.tag]()
    }
}

private final class MapAccessibilityElement: NSAccessibilityElement {
    var press: () -> Void = {}
    override func accessibilityPerformPress() -> Bool { press(); return true }
}
