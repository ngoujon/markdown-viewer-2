import Cocoa
import WebKit
import Darwin
import UniformTypeIdentifiers

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

/// Sends clicked links to Google Chrome (falling back to the system default
/// browser when Chrome is not installed).
enum ExternalLinkOpener {
    private static let chromeBundleIDs = [
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.google.Chrome.canary",
    ]

    private static var chromeURL: URL? {
        for id in chromeBundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return url
            }
        }
        return nil
    }

    static func open(_ url: URL) {
        guard let chrome = chromeURL else {
            NSWorkspace.shared.open(url)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration: configuration) { _, error in
            if error != nil {
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            }
        }
    }
}

/// Content-area backdrop: dragging anywhere on it moves the window, which
/// complements the standard title bar.
final class DragRegionView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

final class MarkdownWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private let webView: WKWebView
    private(set) var fileURL: URL?
    private var fileMonitor: DispatchSourceFileSystemObject?

    /// True for the placeholder window shown when the app is launched without
    /// a document; it gets recycled as soon as a real file arrives.
    var isPlaceholder = false

    /// Called when the window closes, so the app delegate can forget us.
    var onClose: ((MarkdownWindowController) -> Void)?

    convenience init() {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 720), configuration: config)
        // A plain titled window: the real macOS title bar carries the
        // red/yellow/green buttons and is draggable everywhere along its
        // width, including the middle where the file name is shown.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Markdown Viewer"
        window.center()
        window.isMovableByWindowBackground = true
        // Lets macOS group several documents as tabs of a single window when
        // the user's "Prefer tabs" setting asks for it.
        window.tabbingIdentifier = "MarkdownDocument"

        let container = DragRegionView(frame: window.contentRect(forFrameRect: window.frame))
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        window.contentView = container
        window.appearance = NSAppearance(named: .darkAqua)
        self.init(window: window, webView: webView)
    }

    private init(window: NSWindow?, webView: WKWebView) {
        self.webView = webView
        super.init(window: window)
        window?.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func open(url: URL) {
        self.fileURL = url
        isPlaceholder = false
        window?.title = url.lastPathComponent
        window?.representedURL = url
        render()
        watchFile(url)
    }

    func showPlaceholder(markdown: String, title: String) {
        fileMonitor?.cancel()
        fileMonitor = nil
        fileURL = nil
        isPlaceholder = true
        window?.title = title
        window?.representedURL = nil
        let html = MarkdownRenderer.renderHTML(fromMarkdown: markdown, title: title)
        webView.loadHTMLString(html, baseURL: nil)
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

    // MARK: - Links

    /// Anything the user clicks leaves the viewer: web links go to Chrome,
    /// while local Markdown files open in a new viewer window. Only the
    /// document we load ourselves and in-page anchors stay put.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        // In-page anchors (#section) must keep scrolling the current document.
        if url.fragment != nil,
           let current = webView.url,
           url.scheme == current.scheme,
           url.host == current.host,
           url.path == current.path {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        handle(url)
    }

    /// Links with target="_blank" ask for a new web view instead of navigating.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { handle(url) }
        return nil
    }

    private func handle(_ url: URL) {
        if url.isFileURL {
            let markdownExtensions = ["md", "markdown", "mdown", "mkd"]
            if markdownExtensions.contains(url.pathExtension.lowercased()),
               let delegate = NSApp.delegate as? AppDelegate {
                delegate.application(NSApp, open: [url])
            } else {
                NSWorkspace.shared.open(url)
            }
            return
        }
        ExternalLinkOpener.open(url)
    }

    func windowWillClose(_ notification: Notification) {
        fileMonitor?.cancel()
        fileMonitor = nil
        onClose?(self)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controllers: [MarkdownWindowController] = []
    /// Top-left corner used to cascade each new window instead of stacking
    /// them all in the exact same centered spot.
    private var cascadePoint = NSPoint.zero

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
        let openItem = NSMenuItem(title: "Ouvrir…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        openItem.keyEquivalentModifierMask = .command
        openItem.target = self
        fileMenu.addItem(openItem)
        fileMenu.addItem(.separator())
        let closeItem = NSMenuItem(title: "Fermer", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        closeItem.keyEquivalentModifierMask = .command
        fileMenu.addItem(closeItem)
        let closeAllItem = NSMenuItem(title: "Tout fermer", action: #selector(closeAllDocuments(_:)), keyEquivalent: "w")
        closeAllItem.keyEquivalentModifierMask = [.command, .option]
        closeAllItem.target = self
        fileMenu.addItem(closeAllItem)
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "Présentation")
        viewMenu.addItem(withTitle: "Zoom avant", action: #selector(WKWebView.zoomIn(_:)), keyEquivalent: "+")
        viewMenu.addItem(withTitle: "Zoom arrière", action: #selector(WKWebView.zoomOut(_:)), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Taille réelle", action: #selector(WKWebView.actualSize(_:)), keyEquivalent: "0")
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // "Fenêtre" lists every open document, so several files can be read
        // side by side and switched between with Cmd+` or the menu.
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Fenêtre")
        windowMenu.addItem(withTitle: "Réduire", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Tout ramener au premier plan", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    /// Called by AppKit when launched via Finder double-click, `open -a`
    /// with a file, or drag-onto-dock-icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { openFile(url) }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Called by AppKit when launched with no document to open (e.g. the
    /// app icon itself was double-clicked).
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        // Re-opening the app while documents are already visible should just
        // bring them forward rather than add a placeholder window.
        if let existing = controllers.last {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return true
        }
        let controller = makeController()
        controller.showPlaceholder(
            markdown: "# Markdown Viewer\n\nOuvrez un fichier `.md` avec **Fichier ▸ Ouvrir…** (⌘O), par un double-clic dans le Finder, ou en le glissant sur l'icône de l'application.\n\nChaque fichier s'ouvre dans sa propre fenêtre : plusieurs documents peuvent être lus en même temps.",
            title: "Markdown Viewer"
        )
        controller.window?.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choisissez un ou plusieurs fichiers Markdown"
        var types: [UTType] = [.plainText, .text]
        for ext in ["md", "markdown", "mdown", "mkd", "txt"] {
            if let type = UTType(filenameExtension: ext) { types.insert(type, at: 0) }
        }
        panel.allowedContentTypes = types
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            for url in panel.urls { self?.openFile(url) }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc func closeAllDocuments(_ sender: Any?) {
        for controller in controllers { controller.window?.performClose(nil) }
    }

    private func openFile(_ url: URL) {
        let target = url.standardizedFileURL
        // Already open? Just bring that window forward instead of duplicating it.
        if let existing = controllers.first(where: { $0.fileURL?.standardizedFileURL == target }) {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        // Recycle the placeholder window the first time a real file shows up.
        if let placeholder = controllers.first(where: { $0.isPlaceholder }) {
            placeholder.open(url: target)
            placeholder.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = makeController()
        controller.open(url: target)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private func makeController() -> MarkdownWindowController {
        let controller = MarkdownWindowController()
        if let window = controller.window {
            if controllers.isEmpty {
                window.center()
                cascadePoint = NSPoint(x: window.frame.minX, y: window.frame.maxY)
            }
            cascadePoint = window.cascadeTopLeft(from: cascadePoint)
        }
        controller.onClose = { [weak self] closed in
            self?.controllers.removeAll { $0 === closed }
        }
        controllers.append(controller)
        return controller
    }
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()
