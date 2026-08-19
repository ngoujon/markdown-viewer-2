import Cocoa
import WebKit
import Darwin

extension WKWebView {
    @objc func zoomIn(_ sender: Any?) {
        pageZoom = min(pageZoom + 0.1, 3.0)
    }

    @objc func zoomOut(_ sender: Any?) {
        pageZoom = max(pageZoom - 0.1, 0.3)
    }

    @objc func actualSize(_ sender: Any?) {
        pageZoom = 1.0
    }
}

final class DragRegionView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

final class MarkdownWindowController: NSWindowController, NSWindowDelegate {
    private let webView: WKWebView
    private var fileURL: URL?
    private var fileMonitor: DispatchSourceFileSystemObject?

    convenience init() {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 720), configuration: config)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.title = "Markdown Viewer"
        window.center()
        window.isMovableByWindowBackground = true

        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        let dragRegion = DragRegionView(frame: NSRect(x: 0, y: container.bounds.height - 28, width: container.bounds.width, height: 28))
        dragRegion.autoresizingMask = [.width, .minYMargin]
        container.addSubview(dragRegion)

        window.contentView = container
        window.appearance = NSAppearance(named: .darkAqua)
        self.init(window: window, webView: webView)
    }

    private init(window: NSWindow?, webView: WKWebView) {
        self.webView = webView
        super.init(window: window)
        window?.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func open(url: URL) {
        self.fileURL = url
        window?.title = url.lastPathComponent
        render()
        watchFile(url)
    }

    private func render() {
        guard let url = fileURL else { return }
        let markdown = (try? String(contentsOf: url, encoding: .utf8)) ?? "*(Impossible de lire le fichier)*"
        let html = MarkdownRenderer.renderHTML(fromMarkdown: markdown, title: url.lastPathComponent)
        webView.loadHTMLString(html, baseURL: url.deletingLastPathComponent())
    }

    private func watchFile(_ url: URL) {
        fileMonitor?.cancel()
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            self?.render()
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        fileMonitor = source
    }

    func windowWillClose(_ notification: Notification) {
        fileMonitor?.cancel()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controllers: [MarkdownWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        buildMainMenu()
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quitter Markdown Viewer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "Fichier")
        let closeItem = NSMenuItem(title: "Fermer", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeItem.keyEquivalentModifierMask = .command
        fileMenu.addItem(closeItem)
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "Présentation")
        viewMenu.addItem(withTitle: "Zoom avant", action: #selector(WKWebView.zoomIn(_:)), keyEquivalent: "+")
        viewMenu.addItem(withTitle: "Zoom arrière", action: #selector(WKWebView.zoomOut(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Taille réelle", action: #selector(WKWebView.actualSize(_:)), keyEquivalent: "0")
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        NSApp.mainMenu = mainMenu
    }

    /// Called by AppKit when launched via Finder double-click, `open -a`
    /// with a file, or drag-onto-dock-icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { openFile(url) }
    }

    /// Called by AppKit when launched with no document to open (e.g. the
    /// app icon itself was double-clicked).
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        openWindow(withMarkdown: "# Markdown Viewer\n\nOuvrez un fichier `.md` avec cette application (double-clic dans le Finder, ou glissez-déposez un fichier ici).", title: "Markdown Viewer")
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func openFile(_ url: URL) {
        let controller = MarkdownWindowController()
        controller.open(url: url)
        controller.window?.makeKeyAndOrderFront(nil)
        controllers.append(controller)
    }

    private func openWindow(withMarkdown markdown: String, title: String) {
        let controller = MarkdownWindowController()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("welcome.md")
        try? markdown.write(to: tmp, atomically: true, encoding: .utf8)
        controller.open(url: tmp)
        controller.window?.title = title
        controller.window?.makeKeyAndOrderFront(nil)
        controllers.append(controller)
    }
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()
