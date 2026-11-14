import Cocoa
import WebKit
import ServiceManagement

// Match Day: live cricket and football on your desktop.
// The window and menu bar live here; widget.html fetches the scores and draws the widget.

// MARK: - Settings

let fm = FileManager.default
let baseDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Match Day")
let configURL = baseDir.appendingPathComponent("config.json")

/// Everything in config.json is passed to the widget as-is; these are the defaults.
let defaultConfig: [String: Any] = [
    "size": "small",                       // small | medium
    "view": "auto",                        // auto | live | idle
    "scale": 1.0,                          // 1.0 = the design's size
    "accent": "#BFF04E",
    "demo": false,
    "keepOnDesktop": true,
    "cricketTeams": ["PAK"],
    "internationalCricket": true,
    "footballLeagues": ["eng.1", "uefa.champions"],
    "favoriteTeam": ["league": "eng.1", "id": "364"],
    "timeZoneLabel": "",
]

let sizes: [(key: String, title: String, size: NSSize)] = [
    ("small", "Small  (340 × 340)", NSSize(width: 340, height: 340)),
    ("medium", "Medium  (728 × 340)", NSSize(width: 728, height: 340)),
]
let views: [(key: String, title: String)] = [
    ("auto", "Automatic"),
    ("live", "Live match"),
    ("idle", "Next up / Next 3 days"),
]
let scales: [Double] = [1.0, 0.75, 0.5]

final class Config {
    private(set) var values: [String: Any] = defaultConfig

    init() { load() }

    func load() {
        values = defaultConfig
        var missing = true
        if let data = try? Data(contentsOf: configURL),
           let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (k, v) in d { values[k] = v }
            missing = defaultConfig.keys.contains { d[$0] == nil }
        }
        if missing { save() }
    }

    func save() {
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? fm.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try? data.write(to: configURL)
    }

    subscript(key: String) -> Any? {
        get { values[key] }
        set { values[key] = newValue; save() }
    }

    var size: String { (values["size"] as? String).flatMap { s in sizes.contains { $0.key == s } ? s : nil } ?? "small" }
    var view: String { values["view"] as? String ?? "auto" }
    var scale: Double { min(2, max(0.25, values["scale"] as? Double ?? 1)) }
    var demo: Bool { values["demo"] as? Bool ?? false }
    var keepOnDesktop: Bool { values["keepOnDesktop"] as? Bool ?? true }
    var pixelSize: NSSize {
        let s = sizes.first { $0.key == size }!.size
        return NSSize(width: (s.width * scale).rounded(), height: (s.height * scale).rounded())
    }
}

// MARK: - Web view plumbing

/// Serves widget.html from the app bundle at app://widget/widget.html.
final class SchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, !url.path.contains(".."),
              let file = Bundle.main.resourceURL?.appendingPathComponent(String(url.path.dropFirst())),
              let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "text/html; charset=utf-8", "Content-Length": String(data.count)])!
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

final class WidgetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class WidgetWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler {
    let config = Config()
    var window: WidgetWindow!
    var web: WidgetWebView!
    var status: NSStatusItem!
    var ready = false

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildWindow()
        buildMenu()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.web.evaluateJavaScript("window.matchday && matchday.refresh()")
        }
    }

    func buildWindow() {
        let size = config.pixelSize
        window = WidgetWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        applyLevel()

        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(SchemeHandler(), forURLScheme: "app")
        cfg.userContentController.add(self, name: "native")
        web = WidgetWebView(frame: NSRect(origin: .zero, size: size), configuration: cfg)
        web.autoresizingMask = [.width, .height]
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = .clear
        web.pageZoom = config.scale
        window.contentView = web
        web.load(URLRequest(url: URL(string: "app://widget/widget.html")!))

        if window.setFrameUsingName("MatchDay") {
            let f = window.frame   // keep the saved top-left corner at the current size
            window.setFrame(NSRect(x: f.minX, y: f.maxY - size.height, width: size.width, height: size.height), display: false)
        } else if let v = NSScreen.main?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: v.maxX - size.width - 24, y: v.maxY - size.height - 24))
        }
        window.setFrameAutosaveName("MatchDay")
        window.orderFrontRegardless()
    }

    func applyLevel() {
        window.level = config.keepOnDesktop
            ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            : .floating
    }

    func applySize() {
        let s = config.pixelSize
        let f = window.frame
        var r = NSRect(x: f.minX, y: f.maxY - s.height, width: s.width, height: s.height)
        if let v = (window.screen ?? NSScreen.main)?.visibleFrame {
            r.origin.x = min(max(r.minX, v.minX), v.maxX - r.width)
            r.origin.y = min(max(r.minY, v.minY), v.maxY - r.height)
        }
        window.setFrame(r, display: true)
        web.pageZoom = config.scale
        pushConfig()
    }

    func pushConfig() {
        guard ready,
              let data = try? JSONSerialization.data(withJSONObject: config.values, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.matchday && matchday.setConfig(\(json))")
    }

    // MARK: Menu bar

    func buildMenu() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "sportscourt", accessibilityDescription: "Match Day")
        rebuildMenu()
    }

    func rebuildMenu() {
        let menu = NSMenu()
        menu.addItem(item("Refresh", #selector(refresh)))
        menu.addItem(.separator())

        menu.addItem(submenu("Size", sizes.map { ($0.title, $0.key, $0.key == config.size) }, #selector(pickSize(_:))))
        menu.addItem(submenu("Show", views.map { ($0.title, $0.key, $0.key == config.view) }, #selector(pickView(_:))))
        menu.addItem(submenu("Scale", scales.map { ("\(Int($0 * 100))%", String($0), abs($0 - config.scale) < 0.001) }, #selector(pickScale(_:))))

        let demo = item("Demo data", #selector(toggleDemo))
        demo.state = config.demo ? .on : .off
        menu.addItem(demo)
        menu.addItem(.separator())

        let desk = item("Keep on desktop", #selector(toggleDesktop))
        desk.state = config.keepOnDesktop ? .on : .off
        menu.addItem(desk)
        let login = item("Open at login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Reset position", #selector(resetPosition)))
        menu.addItem(.separator())
        menu.addItem(item("Edit settings…", #selector(openSettings)))
        menu.addItem(item("Reload settings", #selector(reloadSettings)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Match Day", #selector(quit)))
        status.menu = menu
    }

    func item(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }

    func submenu(_ title: String, _ options: [(String, String, Bool)], _ sel: Selector) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let m = NSMenu()
        for (label, key, on) in options {
            let i = item(label, sel)
            i.representedObject = key
            i.state = on ? .on : .off
            m.addItem(i)
        }
        parent.submenu = m
        return parent
    }

    @objc func refresh() { web.evaluateJavaScript("window.matchday && matchday.refresh()") }

    @objc func pickSize(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        config["size"] = key
        applySize()
        rebuildMenu()
    }

    @objc func pickView(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        config["view"] = key
        pushConfig()
        rebuildMenu()
    }

    @objc func pickScale(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let v = Double(key) else { return }
        config["scale"] = v
        applySize()
        rebuildMenu()
    }

    @objc func toggleDemo() {
        config["demo"] = !config.demo
        pushConfig()
        rebuildMenu()
    }

    @objc func toggleDesktop() {
        config["keepOnDesktop"] = !config.keepOnDesktop
        applyLevel()
        rebuildMenu()
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn't change Open at login"
            a.informativeText = error.localizedDescription
            a.runModal()
        }
        rebuildMenu()
    }

    @objc func resetPosition() {
        guard let v = NSScreen.main?.visibleFrame else { return }
        window.setFrameOrigin(NSPoint(x: v.maxX - window.frame.width - 24, y: v.maxY - window.frame.height - 24))
    }

    @objc func openSettings() { config.save(); NSWorkspace.shared.open(configURL) }

    @objc func reloadSettings() {
        config.load()
        applyLevel()
        applySize()
        rebuildMenu()
        refresh()
    }

    @objc func quit() { NSApp.terminate(nil) }

    // MARK: Messages from the widget

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true
            pushConfig()
        case "drag":
            if let e = NSApp.currentEvent, e.type == .leftMouseDown || e.type == .leftMouseDragged {
                window.performDrag(with: e)
            }
        default: break
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
