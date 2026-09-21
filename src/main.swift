import Cocoa
import WebKit
import Carbon.HIToolbox

// MARK: - Logging

let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/ReelCorner.log")

func rcLog(_ s: String) {
    let stamp = DateFormatter()
    stamp.dateFormat = "HH:mm:ss"
    let line = stamp.string(from: Date()) + "  " + s + "\n"
    guard let d = line.data(using: .utf8) else { return }
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile(); h.write(d); try? h.close()
    } else {
        try? d.write(to: logURL)
    }
    FileHandle.standardError.write(d)
}

// MARK: - Panel

/// A non-activating floating panel: it can take keyboard focus (needed to log in)
/// without pulling the whole app to the front and stealing focus from your work.
final class ReelPanel: NSPanel {
    /// Off while the panel is the corner player. If the web view can take keyboard
    /// focus, clicking a reel routes bare F7/F8/F9 into the page instead of to the
    /// global hot key - which is what made presses seem to go missing. Turned on
    /// only for the wide login window, where typing is the point.
    var allowKey = false
    override var canBecomeKey: Bool { allowKey }
    override var canBecomeMain: Bool { false }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {

    static var shared: AppDelegate?

    var panel: ReelPanel!
    var web: WKWebView!
    var statusItem: NSStatusItem!
    var hotKeys: [EventHotKeyRef?] = []
    var config = Config.load()
    var shortcuts: [UInt32: Shortcut] = [:]
    var configStamp: Date?
    var signalSources: [DispatchSourceSignal] = []

    let reelsURL = URL(string: "https://www.instagram.com/reels/")!
    var muted = true
    var zoom: CGFloat = 0.75
    var corner = true   // false while the window is in "wide" login mode

    // MARK: launch

    func applicationDidFinishLaunching(_ n: Notification) {
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.accessory)

        // Two copies would fight over the F8/F9 hotkeys; the second would silently
        // lose the registration. Bail out instead.
        let me = ProcessInfo.processInfo.processIdentifier
        let twins = NSRunningApplication.runningApplications(withBundleIdentifier: "com.reelcorner.app")
            .filter { $0.processIdentifier != me }
        if !twins.isEmpty {
            rcLog("another ReelCorner is already running (pid \(twins[0].processIdentifier)); exiting")
            NSApp.terminate(nil)
            return
        }

        rcLog("=== ReelCorner launched ===")

        buildWebView()
        buildPanel()
        buildStatusItem()
        installHotKeys()
        installKeyMonitor()
        startWatchingConfig()
        installSignalHooks()

        web.load(URLRequest(url: reelsURL))

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    // MARK: web view

    func buildWebView() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()               // persists the Instagram login
        cfg.mediaTypesRequiringUserActionForPlayback = [] // let reels autoplay
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let ucc = WKUserContentController()
        ucc.add(self, name: "rc")
        ucc.addUserScript(WKUserScript(source: reelBridgeJS,
                                       injectionTime: .atDocumentEnd,
                                       forMainFrameOnly: true))
        cfg.userContentController = ucc

        web = WKWebView(frame: .zero, configuration: cfg)
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"
        web.allowsBackForwardNavigationGestures = false
        web.navigationDelegate = self
        web.uiDelegate = self
        zoom = config.zoom
        muted = config.startMuted
        web.pageZoom = zoom
        web.setValue(false, forKey: "drawsBackground")
    }

    // MARK: panel

    func buildPanel() {
        let style: NSWindow.StyleMask = [.titled, .closable, .resizable,
                                         .fullSizeContentView, .nonactivatingPanel, .utilityWindow]
        panel = ReelPanel(contentRect: NSRect(x: 0, y: 0, width: config.width, height: config.height),
                          styleMask: style, backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false   // drag by the title strip, click-through elsewhere
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.backgroundColor = .black
        panel.hasShadow = true

        web.frame = panel.contentView!.bounds
        web.autoresizingMask = [.width, .height]
        panel.contentView!.addSubview(web)

        snapToCorner()
        panel.orderFrontRegardless()
        let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        rcLog("screen visibleFrame \(NSStringFromRect(vf))  panel \(NSStringFromRect(panel.frame))  visible=\(panel.isVisible)")
    }

    func snapToCorner() {
        guard let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        let m: CGFloat = 14
        var f = panel.frame
        f.origin.x = vf.maxX - f.width - m
        f.origin.y = vf.minY + m
        panel.setFrame(f, display: true)
        corner = true
    }

    @objc func screensChanged() { if corner { snapToCorner() } }

    func resizePanel(w: CGFloat, h: CGFloat) {
        var f = panel.frame
        f.size = NSSize(width: w, height: h)
        panel.setFrame(f, display: true)
        snapToCorner()
    }

    // MARK: status-bar menu

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "play.rectangle.on.rectangle",
                              accessibilityDescription: "Reel Corner")
            b.image?.isTemplate = true
        }
        rebuildMenu()
    }

    /// Menu labels show whatever is actually bound right now, so the config file and
    /// the menu can never disagree.
    func key(_ action: String) -> String {
        guard let id = AppDelegate.actionIDs[action], let sc = shortcuts[id] else { return "unset" }
        return sc.text
    }

    func rebuildMenu() {
        guard statusItem != nil else { return }
        let m = NSMenu()
        func add(_ title: String, _ sel: Selector) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self
            m.addItem(i)
        }

        add(playerOn ? "Stop player   \(key("startStop"))" : "Start player   \(key("startStop"))",
            #selector(togglePlayer))
        m.addItem(.separator())
        add("Like reel   \(key("like"))", #selector(doLike))
        add("Save reel   \(key("save"))", #selector(doSave))
        add("Next reel   \(key("next"))", #selector(doNext))
        add("Saved reels / Feed   \(key("savedMode"))", #selector(toggleSaved))
        m.addItem(.separator())
        add("Open / Close panel   \(key("showHide"))", #selector(toggleVisible))
        add(chromeShown ? "Show only the reel" : "Show full Instagram page", #selector(toggleChrome))
        add(muted ? "Turn sound on" : "Mute", #selector(toggleSound))
        m.addItem(.separator())
        add("Change keys and size...", #selector(editConfig))
        add("Reload settings now", #selector(reloadConfig))
        m.addItem(.separator())

        let sizes = NSMenu()
        for (label, w, h) in [("Small  320 x 560", 320.0, 560.0),
                              ("Medium  380 x 660", 380.0, 660.0),
                              ("Large  460 x 800", 460.0, 800.0)] {
            let i = NSMenuItem(title: label, action: #selector(pickSize(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = NSValue(size: NSSize(width: w, height: h))
            sizes.addItem(i)
        }
        let sizeItem = NSMenuItem(title: "Panel size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizes
        m.addItem(sizeItem)
        add("Zoom in", #selector(zoomIn))
        add("Zoom out", #selector(zoomOut))
        m.addItem(.separator())
        add("Log in to Instagram (wide window)", #selector(wideMode))
        add("Back to corner", #selector(cornerMode))
        m.addItem(.separator())
        add("Reload Instagram", #selector(reload))
        add("Open log", #selector(openLog))
        add("Dump page labels to log", #selector(dumpLabels))
        m.addItem(.separator())
        add("Quit Reel Corner", #selector(quit))

        statusItem.menu = m
    }

    // MARK: actions

    @objc func doLike() { call("like()") }
    @objc func doNext() { call("next()") }
    @objc func doSave() { call("save()") }
    @objc func dumpLabels() { call("dump()") }
    @objc func dumpChain()  { call("chain()") }

    /// One entry point for every source of a shortcut. The Carbon hot key is global,
    /// but once the web view takes keyboard focus it can swallow a bare F-key before
    /// the hot key sees it - so a local monitor catches those too. Both can fire for
    /// one physical press, hence the dedupe window.
    var lastFire: [UInt32: TimeInterval] = [:]

    func trigger(_ id: UInt32, from source: String) {
        let now = Date().timeIntervalSince1970
        if let t = lastFire[id], now - t < 0.09 {
            rcLog("trigger \(id) from \(source): ignored, duplicate \(Int((now - t) * 1000))ms after \(source)")
            return
        }
        lastFire[id] = now
        if !playerOn && id != 5 {
            rcLog("trigger \(id) ignored: player is stopped (cmd-F9 to start)")
            return
        }
        switch id {
        case 1: doNext()
        case 2: doSave()
        case 3: doLike()
        case 4: toggleVisible()
        case 5: togglePlayer()
        case 6: call("toggleMode()")
        default: break
        }
    }

    func installKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self = self else { return ev }
            let flags = ev.modifierFlags.intersection([.command, .control, .option, .shift])
            for (id, sc) in self.shortcuts
            where UInt32(ev.keyCode) == sc.keyCode && flags == sc.nsFlags {
                self.trigger(id, from: "focus")
                return nil
            }
            return ev
        }
        rcLog("local key monitor installed (catches keys the web view would swallow)")
    }

    /// Calls into the page bridge. If the bridge is missing - a load where the
    /// script threw, so every shortcut would silently do nothing - reinject it and
    /// run the call again rather than losing the press.
    func call(_ expr: String) {
        let js = "(function(){ if (!window.__rc) return 'MISSING';"
               + " try { window.__rc.\(expr); return 'ok'; } catch (e) { return 'ERR ' + e; } })()"
        web.evaluateJavaScript(js) { [weak self] res, err in
            guard let self = self else { return }
            if let e = err { rcLog("JS error in \(expr): \(e.localizedDescription)"); return }
            guard let s = res as? String else { return }
            if s == "MISSING" {
                rcLog("bridge missing on \(self.web.url?.absoluteString ?? "?") - reinjecting, then \(expr)")
                self.web.evaluateJavaScript(reelBridgeJS) { _, e2 in
                    if let e2 = e2 { rcLog("reinject failed: \(e2.localizedDescription)") }
                    else { self.web.evaluateJavaScript("window.__rc && window.__rc.\(expr)") { _, _ in } }
                }
            } else if s.hasPrefix("ERR") {
                rcLog("JS threw in \(expr): \(s)")
            }
        }
    }

    /// cmd-F9: start and end the player.
    ///
    /// Stopping releases the web content entirely - panel hidden, page blanked - so
    /// nothing is decoded, fetched or buffered. The process itself stays resident,
    /// idle and tiny, because a hot key can only be delivered to a running app:
    /// quitting outright would leave nothing able to hear cmd-F9 to start again.
    /// A real quit is in the menu.
    var playerOn = true

    @objc func togglePlayer() {
        playerOn.toggle()
        if playerOn {
            panel.allowKey = false
            panel.orderFrontRegardless()
            if corner { snapToCorner() }
            web.load(URLRequest(url: reelsURL))
            rcLog("player STARTED (loading reels)")
        } else {
            call("active(false)")
            panel.orderOut(nil)
            web.load(URLRequest(url: URL(string: "about:blank")!))
            rcLog("player STOPPED (panel hidden, web content released)")
        }
        rebuildMenu()
    }

    @objc func toggleSaved() { call("toggleMode()") }

    @objc func toggleVisible() {
        if panel.isVisible {
            panel.orderOut(nil)
            call("active(false)")
        } else {
            panel.orderFrontRegardless()
            call("active(true)")
        }
        rcLog("toggle -> panel visible=\(panel.isVisible)")
    }

    @objc func toggleSound() {
        muted.toggle()
        rebuildMenu()
        run("window.__rc && window.__rc.mute(\(muted ? "true" : "false"))")
    }

    var chromeShown = false
    @objc func toggleChrome() {
        chromeShown.toggle()
        rebuildMenu()
        run("window.__rc && window.__rc.clean(\(chromeShown ? "false" : "true"))")
    }

    @objc func pickSize(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? NSValue else { return }
        resizePanel(w: v.sizeValue.width, h: v.sizeValue.height)
    }

    @objc func zoomIn()  { zoom = min(1.5, zoom + 0.05); web.pageZoom = zoom; rcLog("zoom \(zoom)") }
    @objc func zoomOut() { zoom = max(0.35, zoom - 0.05); web.pageZoom = zoom; rcLog("zoom \(zoom)") }

    @objc func wideMode() {
        corner = false
        var f = panel.frame
        f.size = NSSize(width: 1000, height: 760)
        panel.setFrame(f, display: true)
        panel.center()
        web.pageZoom = 1.0
        chromeShown = true
        run("window.__rc && window.__rc.clean(false)")
        panel.allowKey = true
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc func cornerMode() {
        panel.allowKey = false
        // resignKey() only posts the notification; the window stays key. Cycling it
        // is what actually drops focus, so returning from the login window really
        // does hand bare F-keys back to the global hot key.
        if panel.isKeyWindow { panel.orderOut(nil); panel.orderFrontRegardless() }
        chromeShown = false
        run("window.__rc && window.__rc.clean(true)")
        web.pageZoom = zoom
        resizePanel(w: 380, h: 660)
    }

    @objc func reload() { web.load(URLRequest(url: reelsURL)) }

    @objc func openLog() { NSWorkspace.shared.open(logURL) }

    @objc func quit() { NSApp.terminate(nil) }

    func run(_ js: String) {
        web.evaluateJavaScript(js) { _, err in
            if let e = err { rcLog("JS error: \(e.localizedDescription)  <- \(js)") }
        }
    }

    // MARK: hot keys

    static let actionIDs: [String: UInt32] = [
        "next": 1, "save": 2, "like": 3, "showHide": 4, "startStop": 5, "savedMode": 6,
    ]

    func installHotKeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { AppDelegate.shared?.trigger(id, from: "hotkey") }
            return noErr
        }, 1, &spec, nil, nil)

        applyShortcuts()
    }

    /// (Re)binds every shortcut from the config. Safe to call at any time - this is
    /// what makes editing config.json take effect without restarting.
    func applyShortcuts() {
        for ref in hotKeys where ref != nil { UnregisterEventHotKey(ref!) }
        hotKeys.removeAll()
        shortcuts.removeAll()

        for action in Config.actions {
            guard let id = AppDelegate.actionIDs[action] else { continue }
            let raw = config.keys[action] ?? Config.defaults[action] ?? ""
            guard let sc = Keys.parse(raw) else {
                rcLog("config: '\(raw)' is not a key I understand for '\(action)' - skipped")
                continue
            }
            shortcuts[id] = sc
            register(keyCode: sc.keyCode, mods: sc.carbonMods, id: id, name: "\(sc.text) -> \(action)")
        }
        warnAboutBareFKeys()
        rebuildMenu()
    }

    /// With fnState off a bare F-key sends a media action, not an F-key, so a binding
    /// on one silently never fires. install.sh sets up the per-key remap; say so
    /// plainly if the config asks for one and the remap is not in place.
    func warnAboutBareFKeys() {
        let fnOn = UserDefaults.standard.object(forKey: "com.apple.keyboard.fnState") as? Bool ?? false
        guard !fnOn else { return }
        let bare = shortcuts.values.filter { Keys.isBareFKey($0) }.map { $0.text }
        guard !bare.isEmpty else { return }
        rcLog("config: bare F-keys in use (\(bare.joined(separator: ", "))) - these need the "
            + "hidutil remap from install.sh, otherwise macOS sends media keys instead")
    }

    func startWatchingConfig() {
        configStamp = Config.modified()
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let now = Config.modified()
            guard now != self.configStamp else { return }
            self.configStamp = now
            self.config = Config.load()
            rcLog("config: reloaded")
            self.applyShortcuts()
            self.zoom = self.config.zoom
            self.web.pageZoom = self.zoom
            self.resizePanel(w: self.config.width, h: self.config.height)
        }
    }

    @objc func editConfig() {
        _ = Config.load()                       // make sure the file exists first
        NSWorkspace.shared.open(Config.url)
    }

    @objc func reloadConfig() {
        config = Config.load()
        applyShortcuts()
        zoom = config.zoom
        web.pageZoom = zoom
        resizePanel(w: config.width, h: config.height)
        rcLog("config: reloaded on request")
    }

    /// Debug hooks, so every action can be driven from a shell without synthesising
    /// keystrokes (which reach global hot keys only intermittently):
    ///   kill -USR1  -> dump every aria-label      kill -WINCH -> next
    ///   kill -USR2  -> dump the layout chain      kill -INFO  -> like
    ///   kill -IO    -> open / close the panel     kill -URG   -> save
    ///   kill -HUP   -> start / stop the player    kill -PROF  -> saved mode
    func installSignalHooks() {
        for (sig, action) in [(SIGUSR1, #selector(dumpLabels)), (SIGUSR2, #selector(dumpChain)),
                              (SIGWINCH, #selector(doNext)), (SIGINFO, #selector(doLike)),
                              (SIGURG, #selector(doSave)), (SIGIO, #selector(toggleVisible)),
                              (SIGHUP, #selector(togglePlayer)), (SIGPROF, #selector(toggleSaved))] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in _ = self?.perform(action) }
            src.resume()
            signalSources.append(src)
        }
    }

    func register(keyCode: UInt32, mods: UInt32 = 0, id: UInt32, name: String) {
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x52_43_6F_72), id: id) // 'RCor'
        let st = RegisterEventHotKey(keyCode, mods, hkID, GetApplicationEventTarget(), 0, &ref)
        if st == noErr {
            hotKeys.append(ref)
            rcLog("hotkey registered: \(name)")
        } else {
            rcLog("HOTKEY FAILED (\(st)) for \(name) - another app probably owns it")
        }
    }

    // MARK: delegates

    func userContentController(_ c: WKUserContentController, didReceive msg: WKScriptMessage) {
        rcLog("js: \(msg.body)")
    }

    func webView(_ w: WKWebView, didFinish nav: WKNavigation!) {
        rcLog("loaded: \(w.url?.absoluteString ?? "?")")
        guard playerOn else { return }
        run("window.__rc && window.__rc.mute(\(muted ? "true" : "false"))")
    }

    func webView(_ w: WKWebView, didFail nav: WKNavigation!, withError e: Error) {
        rcLog("nav failed: \(e.localizedDescription)")
    }

    func webView(_ w: WKWebView, didFailProvisionalNavigation nav: WKNavigation!, withError e: Error) {
        rcLog("nav failed (provisional): \(e.localizedDescription)")
    }

    // Open target=_blank inside the same view rather than swallowing the click.
    func webView(_ w: WKWebView, createWebViewWith cfg: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = action.request.url { w.load(URLRequest(url: u)) }
        return nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
