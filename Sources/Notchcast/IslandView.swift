// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Daniel Pirela

import SwiftUI

struct IslandView: View {
    @ObservedObject var island: IslandController
    @ObservedObject var speech: SpeechController
    @ObservedObject var monitor: AgentMonitor
    let actions: IslandActions

    private var showsStatus: Bool { island.content == .status }

    var body: some View {
        let geometry = island.geometry
        let size = geometry.size(for: island.visual)
        let radii = geometry.cornerRadii(for: island.visual)
        let shape = IslandShape(top: radii.top, bottom: radii.bottom)

        ZStack(alignment: .top) {
            shape.fill(Color.black)
            VStack(spacing: 0) {
                Group {
                    if showsStatus { statusHeader(geometry) } else { header(geometry) }
                }
                .contentShape(Rectangle())
                .onTapGesture { actions.tap() }
                if island.visual == .expanded {
                    Group {
                        if showsStatus { statusBody } else { expandedBody }
                    }
                    .transition(.opacity.combined(with: .offset(y: -8)))
                }
            }
            .opacity(island.visual == .closed ? 0 : 1)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(shape)
        .opacity(island.visual == .closed && !geometry.hasNotch ? 0 : 1)
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in actions.longPress() })
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Header (the part that lives beside the notch)

    private func header(_ geometry: IslandGeometry) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                DriftView(mood: driftMood)
                LevelBars(level: speech.level, active: speech.phase == .speaking || speech.phase == .summarizing,
                          thinking: speech.phase == .summarizing)
            }
            .frame(width: 92, alignment: .leading)
            Spacer(minLength: geometry.hasNotch ? geometry.notch.width : 8)
            HStack(spacing: 8) {
                Text(headerTrailing)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(IslandPalette.text.opacity(0.85))
                    .lineLimit(1)
                if speech.isBusy {
                    QuickStopButton(action: actions.stop)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 66, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: geometry.headerHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Notchcast")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Claude Code status

    private func statusHeader(_ geometry: IslandGeometry) -> some View {
        let focus = monitor.focus
        let activity = focus?.activity ?? .idle
        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                DriftColony(mood: activity.driftMood, subagents: focus?.subagents.count ?? 0)
                if (focus?.subagents.count ?? 0) == 0 {
                    Text(activity.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(activity == .waiting || activity == .question
                                         ? IslandPalette.engine : IslandPalette.text)
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity)
                }
            }
            .frame(width: 92, alignment: .leading)
            Spacer(minLength: geometry.hasNotch ? geometry.notch.width : 8)
            HStack(spacing: 7) {
                if let count = focus?.subagents.count, count > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "person.2.fill").font(.system(size: 9, weight: .semibold))
                        Text("\(count)").font(.system(size: 11, weight: .semibold).monospacedDigit())
                    }
                    .foregroundStyle(IslandPalette.engine)
                    .help("\(count) subagentes trabajando")
                }
                if let started = focus?.startedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Self.clock(context.date.timeIntervalSince(started)))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(IslandPalette.text.opacity(0.85))
                    }
                }
            }
            .frame(width: 66, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: geometry.headerHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Claude Code: \(activity.label)")
        .accessibilityAddTraits(.isButton)
    }

    private var statusBody: some View {
        VStack(spacing: 12) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    if monitor.activeSessions.isEmpty {
                        Text("Claude no está trabajando ahora.")
                            .font(.system(size: 14))
                            .foregroundStyle(IslandPalette.textDim)
                    }
                    ForEach(monitor.activeSessions) { session in
                        HStack(spacing: 10) {
                            DriftView(mood: session.activity.driftMood, pixel: 1)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.project)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(IslandPalette.text)
                                Text(Self.detail(session))
                                    .font(.system(size: 12))
                                    .foregroundStyle(IslandPalette.textDim)
                            }
                            Spacer()
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 6)
            }
            HStack(spacing: 22) {
                ControlButton(symbol: "arrow.counterclockwise", label: "Repetir", action: actions.repeatLast)
                    .disabled(speech.lastText.isEmpty)
                ControlButton(symbol: "chevron.up", label: "Cerrar", action: actions.close)
            }
        }
        .padding(.bottom, 14)
    }

    private static func detail(_ session: AgentMonitor.Session) -> String {
        var parts = [session.activity.label]
        if let tool = session.tool, session.activity == .working { parts[0] = "Usando \(tool)" }
        if !session.subagents.isEmpty {
            parts.append(session.subagents.count == 1 ? "1 subagente" : "\(session.subagents.count) subagentes")
        }
        return parts.joined(separator: " · ")
    }

    private var driftMood: DriftMood {
        switch speech.phase {
        case .summarizing: return .thinking
        case .speaking: return .speaking(level: speech.level)
        case .paused: return .paused
        case .finished: return .goodbye
        case .idle: return .idle
        }
    }

    private var headerTrailing: String {
        switch speech.phase {
        case .idle where speech.currentIndex < 0: return ""
        case .summarizing: return "···"
        case .paused: return "❙❙ " + Self.clock(speech.elapsed)
        default: return Self.clock(speech.elapsed)
        }
    }

    // MARK: Expanded body

    private var expandedBody: some View {
        VStack(spacing: 12) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        if speech.phase == .summarizing {
                            Text("Resumiendo con \(speech.source == .ollama ? "Ollama" : "MLX")…")
                                .font(.system(size: 14))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        ForEach(speech.paragraphs) { paragraph in
                            Text(attributed(paragraph))
                                .font(.system(size: 14))
                                .lineSpacing(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(paragraph.id)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 6)
                }
                .onChange(of: speech.currentIndex) { _, index in
                    guard let paragraph = speech.paragraphs.first(where: { $0.sentences.contains { $0.id == index } })
                    else { return }
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(paragraph.id, anchor: .center) }
                }
            }
            controls
                .frame(maxWidth: .infinity)
                .overlay(alignment: .bottomLeading) {
                    EngineLabel(source: speech.source)
                        .padding(.leading, 22)
                        .padding(.bottom, 2)
                }
        }
        .padding(.bottom, 14)
    }

    private var controls: some View {
        HStack(spacing: 22) {
            ControlButton(symbol: speech.phase == .paused ? "play.fill" : "pause.fill",
                          label: speech.phase == .paused ? "Reanudar" : "Pausa",
                          action: actions.togglePause)
                .disabled(!speech.isActive)
            ControlButton(symbol: "stop.fill", label: "Parar", action: actions.stop)
                .disabled(!speech.isBusy)
            ControlButton(symbol: "arrow.counterclockwise", label: "Repetir", action: actions.repeatLast)
                .disabled(speech.lastText.isEmpty)
            ControlButton(symbol: "chevron.up", label: "Cerrar", action: actions.close)
        }
    }

    private func attributed(_ paragraph: Paragraph) -> AttributedString {
        var result = AttributedString()
        for sentence in paragraph.sentences {
            var part = AttributedString(sentence.text + " ")
            let isCurrent = sentence.id == speech.currentIndex && speech.isActive
            part.foregroundColor = isCurrent || !speech.isActive ? IslandPalette.text : IslandPalette.textDim
            if isCurrent { part.backgroundColor = IslandPalette.highlight }
            result += part
        }
        return result
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Pieces

struct IslandShape: Shape {
    var top: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(top, bottom) }
        set { top = newValue.first; bottom = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let limit = min(rect.width, rect.height) / 2
        let t = min(top, limit), b = min(bottom, limit)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + t, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + t), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - b))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - b, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + b, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - b), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + t))
        path.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// Island colors from the Notchcast design tokens (dark system derived from Drift).
enum IslandPalette {
    static let engine = Color(hex: 0xF2A65A)
    static let engineAlt = Color(hex: 0x8A9099)
    static let text = Color(hex: 0xF5F5F7)
    static let textDim = Color(hex: 0x7C818B)
    static let highlight = Color(hex: 0x3A2A18)
    static let speakingBars = [Color(hex: 0xFCE3C4), Color(hex: 0xF2A65A)]
    static let summarizingBars = [Color(hex: 0xC9D1DC), Color(hex: 0x6F7A8A)]
}

/// Which engine produced what is being spoken (a car-style "engine" light for local summaries).
struct SourceBadge: View {
    var source: SpeechController.Source

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: source == .full ? .semibold : .heavy))
            .foregroundStyle(color)
            .frame(width: 16)
            .help(help)
            .accessibilityLabel(help)
    }

    private var symbol: String {
        switch source {
        case .mlx, .ollama: return "engine.combustion"
        case .full: return "text.alignleft"
        }
    }

    private var color: Color {
        switch source {
        case .mlx: return IslandPalette.engine
        case .ollama: return IslandPalette.engineAlt
        case .full: return .white.opacity(0.75)
        }
    }

    private var help: String {
        switch source {
        case .mlx: return "Resumen local con MLX"
        case .ollama: return "Resumen local con Ollama"
        case .full: return "Respuesta completa"
        }
    }
}

/// Engine in use, shown at the bottom-left of the expanded island.
struct EngineLabel: View {
    var source: SpeechController.Source

    var body: some View {
        HStack(spacing: 5) {
            SourceBadge(source: source)
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(IslandPalette.textDim)
        }
        .accessibilityElement(children: .combine)
    }

    private var name: String {
        switch source {
        case .mlx: return "MLX"
        case .ollama: return "Ollama"
        case .full: return "Respuesta completa"
        }
    }
}

/// Small always-visible stop control in the compact island.
struct QuickStopButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "stop.fill")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.white.opacity(0.18)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Parar")
        .accessibilityLabel("Parar")
    }
}

/// Bars driven by the real output level; a small per-bar wobble keeps them from moving in lockstep.
/// While summarizing they show a gentle "thinking" wave instead.
struct LevelBars: View {
    var level: Float
    var active: Bool
    var thinking = false

    private static let weights: [Double] = [0.55, 0.85, 1.0, 0.8, 0.6]
    private static let speakingColors = IslandPalette.speakingBars
    private static let thinkingColors = IslandPalette.summarizingBars

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { i in
                    let wobble = 0.65 + 0.35 * sin(t * 10 + Double(i) * 1.9)
                    let wave = 0.5 + 0.5 * sin(t * 5 - Double(i) * 0.9)
                    let height = thinking
                        ? 4 + CGFloat(wave) * 8
                        : 3 + CGFloat(Double(level) * Self.weights[i] * wobble) * 15
                    Capsule()
                        .fill(LinearGradient(colors: thinking ? Self.thinkingColors : Self.speakingColors,
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 3, height: height)
                }
            }
            .frame(height: 18)
            .animation(.easeOut(duration: 0.08), value: level)
        }
    }
}

struct ControlButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.14)))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.white.opacity(isEnabled ? 0.95 : 0.3))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
