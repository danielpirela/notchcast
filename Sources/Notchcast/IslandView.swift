// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Daniel Pirela

import SwiftUI

struct IslandView: View {
    @ObservedObject var island: IslandController
    @ObservedObject var speech: SpeechController
    let actions: IslandActions

    var body: some View {
        let geometry = island.geometry
        let size = geometry.size(for: island.visual)
        let radii = geometry.cornerRadii(for: island.visual)
        let shape = IslandShape(top: radii.top, bottom: radii.bottom)

        ZStack(alignment: .top) {
            shape.fill(Color.black)
            VStack(spacing: 0) {
                header(geometry)
                if island.visual == .expanded {
                    expandedBody
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
            HStack(spacing: 7) {
                SourceBadge(source: speech.source)
                LevelBars(level: speech.level, active: speech.phase == .speaking || speech.phase == .summarizing,
                          thinking: speech.phase == .summarizing)
            }
            .frame(width: 58, alignment: .leading)
            Spacer(minLength: geometry.hasNotch ? geometry.notch.width : 8)
            HStack(spacing: 8) {
                Text(headerTrailing)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
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
        .contentShape(Rectangle())
        .onTapGesture { actions.tap() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Notchcast")
        .accessibilityAddTraits(.isButton)
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
            part.foregroundColor = isCurrent ? .white : .white.opacity(speech.isActive ? 0.42 : 0.85)
            if isCurrent { part.backgroundColor = Color.white.opacity(0.12) }
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

/// Which engine produced what is being spoken.
struct SourceBadge: View {
    var source: SpeechController.Source

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.75))
            .frame(width: 14)
            .help(help)
            .accessibilityLabel(help)
    }

    private var symbol: String {
        switch source {
        case .mlx: return "cpu"
        case .ollama: return "server.rack"
        case .full: return "text.alignleft"
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
    private static let speakingColors = [Color(red: 0.45, green: 0.9, blue: 1), Color(red: 0.55, green: 0.6, blue: 1)]
    private static let thinkingColors = [Color(red: 0.85, green: 0.6, blue: 1), Color(red: 0.6, green: 0.45, blue: 1)]

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
