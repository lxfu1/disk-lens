import AppKit
import SwiftUI

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

@main struct TreemapSmoke {
    @MainActor static func main() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("DiskLens-map-" + UUID().uuidString)
        defer { try? fm.removeItem(at: fixture) }
        let root = fixture.appendingPathComponent("root")
        let folder = root.appendingPathComponent("模块目录")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for i in 0..<210 { try Data(repeating: 1, count: 4096).write(to: root.appendingPathComponent("file-\(i).txt")) }
        try Data(repeating: 2, count: 8192).write(to: folder.appendingPathComponent("nested.txt"))
        let index = try DiskIndex(url: fixture.appendingPathComponent("state/index.sqlite"))
        try index.rebuild(IndexIdentity.read(root), cursor: 1, cancellation: ScanCancellation())
        let result = try index.result(for: root.path, scope: root.path)!
        check(result.entries.count == 200 && result.next != nil, "fixture crosses one page")
        let items = TreemapItem.items(entries: result.entries, total: result.total)
        check(items.contains { $0.entry == nil && $0.bytes > 0 }, "rest of directory remains represented")
        check(items.reduce(0) { $0 + $1.bytes } == Double(result.total), "map uses whole directory denominator")
        let child = try index.result(for: folder.path, scope: root.path)!
        check(child.entries.count == 1 && child.entries[0].name == "nested.txt", "drill down direct children only")
        check(TreemapItem.items(entries: [DiskEntry(path: "/zero", isDirectory: false, bytes: 0)], total: 0).isEmpty, "zero bytes do not invent area")
        for size in [CGSize(width: 800, height: 360), CGSize(width: 80, height: 900), CGSize(width: 900, height: 80), CGSize(width: 1, height: 1)] {
            let bounds = CGRect(origin: CGPoint(x: 5, y: 8), size: size)
            let tiles = TreemapLayout.tiles(items: items, in: bounds)
            let area = size.width * size.height
            check(tiles.count == items.count, "no missing tile")
            for (i, tile) in tiles.enumerated() {
                check(tile.rect.width >= 0 && tile.rect.height >= 0, "nonnegative dimensions")
                check(tile.rect.minX >= bounds.minX - 1e-7 && tile.rect.maxX <= bounds.maxX + 1e-7 && tile.rect.minY >= bounds.minY - 1e-7 && tile.rect.maxY <= bounds.maxY + 1e-7, "within bounds")
                check(abs(tile.rect.width * tile.rect.height / area - tile.item.bytes / Double(result.total)) < 1e-8, "proportional area")
                for other in tiles.dropFirst(i + 1) {
                    let intersection = tile.rect.intersection(other.rect)
                    check(intersection.isNull || intersection.width * intersection.height < 1e-7, "no overlapping rectangles")
                }
            }
        }
        check(TreemapLayout.tiles(items: items, in: .zero).isEmpty, "zero-sized viewport")
        print("PASS: real index pagination/remainder, directory drilldown, area ratios, bounds, overlap, zero values")

        _ = NSApplication.shared
        let native = TreemapNSView(frame: CGRect(x: 0, y: 0, width: 800, height: 350))
        native.items = items; native.total = result.total
        let interactionWindow = NSWindow(contentRect: native.frame, styleMask: [.titled], backing: .buffered, defer: false)
        interactionWindow.contentView = native
        var hovered: String?; var selected: String?; var entered: String?
        native.hover = { hovered = $0?.entry?.path }
        native.select = { selected = $0?.entry?.path }
        native.enter = { entered = $0.entry?.path }
        let folderTile = TreemapLayout.tiles(items: items, in: native.bounds).first { $0.item.entry?.isDirectory == true }!
        let point = native.convert(CGPoint(x: folderTile.rect.midX, y: folderTile.rect.midY), to: nil)
        func event(_ type: NSEvent.EventType, clicks: Int) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                              windowNumber: interactionWindow.windowNumber, context: nil, eventNumber: 1,
                              clickCount: clicks, pressure: 0)!
        }
        native.mouseMoved(with: event(.mouseMoved, clicks: 0))
        check(hovered == folder.path && native.toolTip?.contains(folder.path) == true, "hover identifies path and tooltip")
        native.mouseDown(with: event(.leftMouseDown, clicks: 2))
        check(selected == folder.path && entered == folder.path, "double click selects and navigates correct directory")
        native.mouseExited(with: NSEvent.enterExitEvent(with: .mouseExited, location: point,
            modifierFlags: [], timestamp: 0, windowNumber: interactionWindow.windowNumber,
            context: nil, eventNumber: 2, trackingNumber: 0, userData: nil)!)
        check(hovered == nil && native.toolTip == nil, "exit clears hover")
        print("PASS: native pointer hit test, hover detail, selection, double-click navigation and exit")
        let file = result.entries.first { !$0.isDirectory }!
        let fileMenu = native.contextMenu(for: file)
        let openWith = fileMenu.items.first { $0.title == "打开方式" }!.submenu!
        check(openWith.items.contains { $0.title == "其他应用…" }, "application picker always present")
        check(fileMenu.items.contains { $0.title == "打开" }, "default open present")
        let directory = result.entries.first { $0.isDirectory }!
        let directoryMenu = native.contextMenu(for: directory)
        check(!directoryMenu.items.contains { $0.title == "打开方式" }, "directories navigate instead of application chooser")
        print("PASS: native file menu, recommended apps (\(openWith.items.count) items), other-app picker, directory menu")

        func key(_ code: UInt16) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: interactionWindow.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        }
        var selectedID: String?; var activatedID: String?
        native.select = { selectedID = $0?.id }
        native.enter = { activatedID = $0.id }
        native.keyDown(with: key(53))
        native.keyDown(with: key(124))
        precondition(selectedID == items[0].id, "arrow key selects first tile, including remainder")
        let firstSelection = selectedID
        native.keyDown(with: key(36))
        precondition(activatedID == firstSelection, "return activates selected tile")
        for direction: UInt16 in [124, 125, 123, 126] where selectedID == firstSelection { native.keyDown(with: key(direction)) }
        precondition(selectedID != firstSelection, "arrow keys move spatially")
        activatedID = nil
        native.isInteractive = false
        native.keyDown(with: key(36))
        precondition(activatedID == nil, "disabled map cannot activate stale entries with keyboard")
        native.isInteractive = true
        native.selection = file.path
        native.mouseMoved(with: event(.mouseMoved, clicks: 0))
        native.keyDown(with: key(36))
        precondition(activatedID == items.first { $0.entry?.path == file.path }?.id,
                     "return activates selection even when the pointer hovers over another tile")
        native.needsLayout = true
        native.layoutSubtreeIfNeeded()
        precondition((native.accessibilityChildren()?.count ?? 0) > 0, "map exposes accessibility children")
        let huge = TreemapItem(entry: nil, bytes: Double(Int64.max))
        precondition(huge.displayBytes > 0, "display conversion cannot overflow Int64")
        print("PASS: keyboard selection/navigation/activation, accessibility children, large byte values")

        guard ProcessInfo.processInfo.environment["DISKLENS_CAPTURE_UI"] == "1" else { return }
        let sample = [DiskEntry(path: "/项目/应用源码", isDirectory: true, bytes: 420_000_000),
                      DiskEntry(path: "/项目/依赖", isDirectory: true, bytes: 280_000_000),
                      DiskEntry(path: "/项目/设计稿.fig", isDirectory: false, bytes: 160_000_000),
                      DiskEntry(path: "/项目/预览视频.mov", isDirectory: false, bytes: 90_000_000),
                      DiskEntry(path: "/项目/说明.md", isDirectory: false, bytes: 30_000_000)]
        let preview = ScanResult(root: URL(fileURLWithPath: "/项目"), entries: sample, files: 2000, skipped: 0, issues: [], date: Date(), total: 1_000_000_000, incomplete: false, next: nil, pageReset: false)
        let host = NSHostingView(rootView: TreemapView(result: preview, selection: nil, select: { _ in }, navigate: { _ in }, showList: {}, failure: { _ in }).padding(20).frame(width: 820, height: 420).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/disklens-treemap-preview.png"))
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-l", String(window.windowNumber), "/tmp/disklens-treemap-window.png"]
        try capture.run(); capture.waitUntilExit()
        window.orderOut(nil)
        print("PASS: TreemapView snapshot; window capture exit \(capture.terminationStatus)")
    }
}
