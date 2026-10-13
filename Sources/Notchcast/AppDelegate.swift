// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Daniel Pirela

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var muteItem: NSMenuItem!
    private var summarizeItem: NSMenuItem!
    private var backendItems: [SummaryBackend: NSMenuItem] = [:]
    private var config = AppConfig.load()
    private var worker: TTSWorker!
    private var speech: SpeechController!
    private var monitor: AgentMonitor!
    private var statusItemToggle: NSMenuItem!
    private var waveUntil = Date.distantPast
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
        monitor = AgentMonitor()
        island = IslandController(speech: speech, monitor: monitor, actions: makeActions())
        speech.onPhaseChange = { [weak self] phase in self?.phaseChanged(phase) }
        monitor.onChange = { [weak self] in self?.refreshIsland() }
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
        guard island.mode == .expanded else { return island.hide() }
        island.collapse()
        refreshIsland()
    }

    private func phaseChanged(_ phase: SpeechController.Phase) {
        if phase == .finished {
            // Let Drift wave goodbye before the island closes or returns to Claude's status.
            waveUntil = Date().addingTimeInterval(1.1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) { [weak self] in
                MainActor.assumeIsolated { self?.refreshIsland() }
            }
        }
        refreshIsland()
    }

    /// Single place that decides what the island shows: speech first, then Claude's live status.
    private func refreshIsland() {
        let speaking = speech.isBusy || (speech.phase == .finished && Date() < waveUntil)
        if speaking {
            island.content = .speech
            island.show()
        } else if config.showAgentStatus, monitor.isActive {
            if island.mode != .expanded { island.content = .status }
            island.show()
        } else if island.mode != .expanded {
            // An expanded island stays until the user closes it (they may be reading).
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
        summarizeItem = item("Resumir con IA local", #selector(toggleSummarize))
        menu.addItem(summarizeItem)
        let backendMenu = NSMenu()
        for backend in SummaryBackend.allCases {
            let entry = item(backend == .mlx ? "MLX (nativo)" : "Ollama", #selector(selectBackend(_:)))
            entry.representedObject = backend.rawValue
            backendItems[backend] = entry
            backendMenu.addItem(entry)
        }
        let backendRoot = NSMenuItem(title: "Motor de resumen", action: nil, keyEquivalent: "")
        backendRoot.submenu = backendMenu
        menu.addItem(backendRoot)
        menu.addItem(.separator())
        statusItemToggle = item("Mostrar estado de Claude", #selector(toggleAgentStatus))
        menu.addItem(statusItemToggle)
        menu.addItem(.separator())
        muteItem = item("Silenciar", #selector(toggleMute))
        menu.addItem(muteItem)
        menu.addItem(.separator())
        menu.addItem(item("Salir", #selector(quit)))
        statusItem.menu = menu
        refreshMuteUI()
        refreshSummaryUI()
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

    private func refreshSummaryUI() {
        summarizeItem.state = config.summarize ? .on : .off
        statusItemToggle.state = config.showAgentStatus ? .on : .off
        for (backend, entry) in backendItems {
            entry.state = backend == config.backend ? .on : .off
        }
    }

    private func updateConfig(_ change: (inout AppConfig) -> Void) {
        change(&config)
        config.save()
        refreshSummaryUI()
    }

    @objc private func toggleSummarize() { updateConfig { $0.summarize.toggle() } }

    @objc private func toggleAgentStatus() {
        updateConfig { $0.showAgentStatus.toggle() }
        refreshIsland()
    }

    @objc private func selectBackend(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let backend = SummaryBackend(rawValue: raw) else { return }
        updateConfig { $0.backend = backend }
    }

    @objc private func repeatLast() { speech.repeatLast() }

    @objc private func readLast() { showLast() }

    @objc private func toggleMute() { setMuted(!isMuted) }

    @objc private func quit() { NSApp.terminate(nil) }

    private func showLast() {
        guard !speech.lastOriginal.isEmpty else { return }
        speech.presentLast()
        island.content = .speech
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
            speech.handle(text, config: config)
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
        case "event":
            if let payload = request["payload"] as? [String: Any] { monitor.handle(payload) }
            return ["ok": true]
        case "summarize": updateConfig { $0.summarize = request["on"] as? Bool ?? true }
        case "backend":
            guard let backend = SummaryBackend(rawValue: request["name"] as? String ?? "") else {
                return ["ok": false, "error": "backend must be mlx or ollama"]
            }
            updateConfig { $0.backend = backend }
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
            "summarize": config.summarize,
            "backend": config.backend.rawValue,
            "source": speech.source.rawValue,
            "spokenText": speech.lastText,
            "content": island.content.rawValue,
            "showAgentStatus": config.showAgentStatus,
            "agent": monitor.focus.map { ["project": $0.project, "activity": $0.activity.rawValue,
                                          "tool": $0.tool ?? "", "subagents": $0.subagents.count] as [String: Any] }
                ?? [:],
            "activeSessions": monitor.activeSessions.count,
            "lastTextLength": speech.lastText.count,
        ]
    }
}
