import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var muteItem: NSMenuItem!
    private var worker: TTSWorker!
    private var speech: SpeechController!
    private var island: IslandController!
    private var server: IPCServer!
    private var lastLongPress = Date.distantPast

    private var isMuted: Bool { FileManager.default.fileExists(atPath: Paths.muteFlag.path) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if IPCServer.isListening(at: Paths.socket) {
            NSApp.terminate(nil)
            return
        }

        worker = TTSWorker()
        worker.start()
        speech = SpeechController(worker: worker, sampleRate: Paths.voiceSampleRate())
        island = IslandController(speech: speech, actions: makeActions())
        speech.onPhaseChange = { [weak self] phase in self?.phaseChanged(phase) }
        setUpStatusItem()

        server = IPCServer(path: Paths.socket) { [weak self] request in
            self?.handle(request) ?? ["ok": false]
        }
        do { try server.start() } catch { NSLog("Notchcast: IPC server failed: \(error)") }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        worker?.shutdown()
    }

    // MARK: - Island behaviour

    private func makeActions() -> IslandActions {
        IslandActions(
            tap: { [weak self] in self?.tapIsland() },
            longPress: { [weak self] in self?.longPressIsland() },
            togglePause: { [weak self] in self?.speech.togglePause() },
            stop: { [weak self] in self?.speech.stop() },
            repeatLast: { [weak self] in self?.speech.repeatLast() },
            close: { [weak self] in self?.closeIsland() }
        )
    }

    private func tapIsland() {
        // A long press also ends with a mouse-up; don't treat it as a tap.
        guard Date().timeIntervalSince(lastLongPress) > 0.4 else { return }
        island.mode == .expanded ? closeIsland() : island.expand()
    }

    private func longPressIsland() {
        lastLongPress = Date()
        speech.stop()
    }

    private func closeIsland() {
        speech.isActive ? island.collapse() : island.hide()
    }

    private func phaseChanged(_ phase: SpeechController.Phase) {
        switch phase {
        case .speaking, .paused:
            island.show()
        case .finished:
            // Keep it open if the user is reading the expanded text.
            if island.mode != .expanded { island.hide() }
        case .idle:
            island.hide()
        }
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.addItem(item("Repetir último", #selector(repeatLast)))
        menu.addItem(item("Leer último", #selector(readLast)))
        menu.addItem(.separator())
        muteItem = item("Silenciar", #selector(toggleMute))
        menu.addItem(muteItem)
        menu.addItem(.separator())
        menu.addItem(item("Salir", #selector(quit)))
        statusItem.menu = menu
        refreshMuteUI()
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func refreshMuteUI() {
        muteItem.state = isMuted ? .on : .off
        let symbol = isMuted ? "speaker.slash" : "waveform"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Notchcast")
    }

    @objc private func repeatLast() { speech.repeatLast() }

    @objc private func readLast() { showLast() }

    @objc private func toggleMute() { setMuted(!isMuted) }

    @objc private func quit() { NSApp.terminate(nil) }

    private func showLast() {
        guard !speech.lastText.isEmpty else { return }
        speech.presentLast()
        island.expand()
    }

    private func setMuted(_ muted: Bool) {
        if muted {
            FileManager.default.createFile(atPath: Paths.muteFlag.path, contents: Data())
            speech.stop()
        } else {
            try? FileManager.default.removeItem(at: Paths.muteFlag)
        }
        refreshMuteUI()
    }

    // MARK: - IPC

    private func handle(_ request: [String: Any]) -> [String: Any] {
        let text = request["text"] as? String ?? ""
        switch request["cmd"] as? String ?? "" {
        case "speak":
            if isMuted {
                speech.store(text)
                return ["ok": true, "muted": true]
            }
            speech.speak(text)
        case "store": speech.store(text)
        case "stop": speech.stop()
        case "pause": speech.pause()
        case "resume": speech.resume()
        case "toggle": speech.togglePause()
        case "repeat": speech.repeatLast()
        case "showLast": showLast()
        case "tap": tapIsland()
        case "longpress": longPressIsland()
        case "collapse": closeIsland()
        case "mute": setMuted(request["on"] as? Bool ?? true)
        case "status": break
        case "quit":
            DispatchQueue.main.async { NSApp.terminate(nil) }
        default:
            return ["ok": false, "error": "unknown command"]
        }
        return status()
    }

    private func status() -> [String: Any] {
        let frame = island.panelFrame
        return [
            "ok": true,
            "phase": speech.phase.rawValue,
            "mode": island.mode.rawValue,
            "visual": island.visual.rawValue,
            "panelVisible": island.isPanelVisible,
            "panelFrame": [frame.origin.x, frame.origin.y, frame.width, frame.height],
            "hasNotch": island.geometry.hasNotch,
            "currentIndex": speech.currentIndex,
            "sentences": speech.sentenceCount,
            "elapsed": (speech.elapsed * 10).rounded() / 10,
            "level": Double(speech.level),
            "peakLevel": Double(speech.peakLevel),
            "engineRunning": speech.engineRunning,
            "workerReady": worker.isReady,
            "muted": isMuted,
            "lastTextLength": speech.lastText.count,
        ]
    }
}
