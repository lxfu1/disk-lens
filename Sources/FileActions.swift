import AppKit
import UniformTypeIdentifiers

// Shared by the table and the map; application discovery runs only when a menu opens.
enum FileActions {
    static func applications(for url: URL) -> [URL] {
        let preferred = NSWorkspace.shared.urlForApplication(toOpen: url)
        return Array(Set(NSWorkspace.shared.urlsForApplications(toOpen: url))).sorted {
            if ($0 == preferred) != ($1 == preferred) { return $0 == preferred }
            return $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }
    static func applicationName(_ app: URL, for file: URL) -> String {
        FileManager.default.displayName(atPath: app.path)
            + (NSWorkspace.shared.urlForApplication(toOpen: file) == app ? "（默认）" : "")
    }
    static func open(_ file: URL, with application: URL? = nil, failure: @escaping (String) -> Void) {
        if let application {
            NSWorkspace.shared.open([file], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { DispatchQueue.main.async { failure("无法打开文件：\(error.localizedDescription)") } }
            }
        } else if !NSWorkspace.shared.open(file) { failure("无法打开文件：\(file.path)") }
    }
    static func chooseApplication(for file: URL, failure: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "选择打开应用"; panel.prompt = "打开"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let app = panel.url { open(file, with: app, failure: failure) }
        }
    }
    @discardableResult static func copyPath(_ path: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(path, forType: .string)
    }
}
