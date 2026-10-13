// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Daniel Pirela

import AVFoundation
import Foundation
import NaturalLanguage

struct Sentence: Identifiable, Equatable {
    let id: Int
    let text: String
}

struct Paragraph: Identifiable, Equatable {
    let id: Int
    let sentences: [Sentence]
}

/// Splits text into sentences, streams them through Piper and plays the PCM from memory.
@MainActor
final class SpeechController: ObservableObject {
    enum Phase: String { case idle, summarizing, speaking, paused, finished }
    /// What produced the text being spoken: a local summary (by backend) or the full answer.
    enum Source: String { case mlx, ollama, full }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var paragraphs: [Paragraph] = []
    @Published private(set) var currentIndex = -1
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var source: Source = .full

    /// Last text spoken (the summary when summarizing is on).
    private(set) var lastText = ""
    /// Last full answer as received from the hook.
    private(set) var lastOriginal = ""
    private(set) var peakLevel: Float = 0
    private(set) var sentenceCount = 0
    var onPhaseChange: ((Phase) -> Void)?

    private let worker: TTSWorker
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var generation: UInt32 = 0
    private var nextToSchedule = 0
    private var pending: [Int: Data] = [:]
    private var ticker: Timer?
    private var lastTick = Date()
    private let summarizer = Summarizer()
    private var summaryRequest = 0

    var isActive: Bool { phase == .speaking || phase == .paused }
    /// Summarizing or speaking: something the stop button can cancel.
    var isBusy: Bool { isActive || phase == .summarizing }
    var engineRunning: Bool { engine.isRunning }

    init(worker: TTSWorker, sampleRate: Double) {
        self.worker = worker
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil, block: Self.levelTap(self))
        worker.onChunk = { [weak self] gen, index, pcm in self?.receive(generation: gen, index: index, pcm: pcm) }
        worker.onCrash = { [weak self] in self?.stop() }
    }

    // MARK: - Commands

    /// Entry point for a new answer: summarizes it locally when enabled, then speaks.
    func handle(_ text: String, config: AppConfig) {
        cancelSummary()
        halt()
        lastOriginal = text
        guard config.summarize, text.count >= config.minChars else {
            source = .full
            return speak(text)
        }

        source = config.backend == .mlx ? .mlx : .ollama
        summaryRequest += 1
        let request = summaryRequest
        paragraphs = []
        currentIndex = -1
        elapsed = 0
        setPhase(.summarizing)
        summarizer.summarize(text, config: config) { [weak self] result in
            guard let self, request == self.summaryRequest, self.phase == .summarizing else { return }
            switch result {
            case .success(let summary):
                self.speak(summary)
            case .failure(let failure):
                NSLog("Notchcast: summary failed, speaking full answer: \(failure)")
                self.source = .full
                self.speak(text)
            }
        }
    }

    func speak(_ text: String) {
        halt()
        lastText = text
        paragraphs = Self.segment(text)
        let sentences = paragraphs.flatMap(\.sentences)
        guard !sentences.isEmpty else { return setPhase(.idle) }

        generation &+= 1
        sentenceCount = sentences.count
        nextToSchedule = 0
        pending = [:]
        currentIndex = 0
        elapsed = 0
        peakLevel = 0

        if !engine.isRunning {
            do { try engine.start() } catch { NSLog("Notchcast: audio engine failed: \(error)") }
        }
        player.play()
        for sentence in sentences {
            worker.speak(generation: generation, index: sentence.id, text: sentence.text)
        }
        startTicker()
        setPhase(.speaking)
    }

    /// Remembers text without speaking it (used while muted).
    func store(_ text: String) {
        lastText = text
        lastOriginal = text
    }

    /// Loads the last text for reading, without audio.
    func presentLast() {
        cancelSummary()
        halt()
        paragraphs = Self.segment(lastOriginal)
        currentIndex = -1
        setPhase(.idle)
    }

    func repeatLast() {
        guard !lastText.isEmpty else { return }
        speak(lastText)
    }

    func pause() {
        guard phase == .speaking else { return }
        player.pause()
        level = 0
        setPhase(.paused)
    }

    func resume() {
        guard phase == .paused else { return }
        player.play()
        lastTick = Date()
        setPhase(.speaking)
    }

    func togglePause() {
        phase == .paused ? resume() : pause()
    }

    func stop() {
        cancelSummary()
        halt()
        engine.stop()
        setPhase(.idle)
    }

    // MARK: - Playback pipeline

    private func cancelSummary() {
        summaryRequest += 1
        summarizer.cancel()
    }

    private func halt() {
        guard isActive else { return }
        worker.cancel(below: generation &+ 1)
        generation &+= 1
        player.stop()
        stopTicker()
        level = 0
    }

    private func receive(generation gen: UInt32, index: Int, pcm: Data) {
        guard gen == generation, isActive else { return }
        pending[index] = pcm
        while let data = pending.removeValue(forKey: nextToSchedule) {
            schedule(data, index: nextToSchedule)
            nextToSchedule += 1
        }
    }

    private func schedule(_ pcm: Data, index: Int) {
        let frames = max(1, pcm.count / 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let out = buffer.floatChannelData![0]
        out[0] = 0
        pcm.withUnsafeBytes { raw in
            for i in 0..<(pcm.count / 2) {
                out[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768
            }
        }
        player.scheduleBuffer(
            buffer, completionCallbackType: .dataPlayedBack,
            completionHandler: Self.playedCallback(self, generation: generation, index: index))
    }

    private func played(generation gen: UInt32, index: Int) {
        guard gen == generation, isActive else { return }
        currentIndex = index + 1
        if currentIndex >= sentenceCount { finish() }
    }

    private func finish() {
        stopTicker()
        level = 0
        setPhase(.finished)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isActive else { return }
                self.engine.stop()
            }
        }
    }

    private func setPhase(_ newPhase: Phase) {
        phase = newPhase
        onPhaseChange?(newPhase)
    }

    // MARK: - Level & timer

    private func updateLevel(_ rms: Float) {
        let target = phase == .speaking ? min(1, rms * 5) : 0
        level = level * 0.5 + target * 0.5
        peakLevel = max(peakLevel, target)
    }

    private func startTicker() {
        stopTicker()
        lastTick = Date()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        let now = Date()
        if phase == .speaking { elapsed += now.timeIntervalSince(lastTick) }
        lastTick = now
    }

    // MARK: - Audio-thread callbacks (must not inherit main-actor isolation)

    nonisolated private static func levelTap(_ owner: SpeechController) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { [weak owner] buffer, _ in
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
            let rms = (sum / Float(buffer.frameLength)).squareRoot()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { owner?.updateLevel(rms) }
            }
        }
    }

    nonisolated private static func playedCallback(
        _ owner: SpeechController, generation: UInt32, index: Int
    ) -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        { [weak owner] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { owner?.played(generation: generation, index: index) }
            }
        }
    }

    // MARK: - Segmentation

    static func segment(_ text: String) -> [Paragraph] {
        var paragraphs: [Paragraph] = []
        var index = 0
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for line in lines {
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.setLanguage(.spanish)
            tokenizer.string = line
            var sentences: [Sentence] = []
            tokenizer.enumerateTokens(in: line.startIndex..<line.endIndex) { range, _ in
                let sentence = line[range].trimmingCharacters(in: .whitespaces)
                if sentence.rangeOfCharacter(from: .alphanumerics) != nil {
                    sentences.append(Sentence(id: index, text: sentence))
                    index += 1
                }
                return true
            }
            if !sentences.isEmpty {
                paragraphs.append(Paragraph(id: paragraphs.count, sentences: sentences))
            }
        }
        return paragraphs
    }
}
