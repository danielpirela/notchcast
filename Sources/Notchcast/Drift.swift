// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Daniel Pirela

import SwiftUI

/// Drift, the Notchcast mascot: a 16×16 pixel jellyfish. Frames are plain strings so they stay
/// easy to edit; '.' is transparent and every other character is a palette key.
enum DriftSprites {
    static let palette: [Character: Color] = [
        "a": Color(hex: 0xF2A65A),  // amber body
        "s": Color(hex: 0xC7823A),  // burnt-amber shade
        "h": Color(hex: 0xFCE3C4),  // cream highlight
        "w": Color(hex: 0xFFFFFF),  // white glint
        "g": Color(hex: 0x8A9099),  // slate tentacle tips
        "k": Color(hex: 0x05060A),  // ink (eyes, mouth)
        "l": Color(hex: 0x3A3F4A),  // laptop lid
        "m": Color(hex: 0x5A6170),  // laptop base
    ]

    private static let empty = "................"
    private static let top = [".....aaaaaa.....", "...aahhaaaaaa..."]
    private static let crown = "..aahaaaaaaaaa.."
    private static let eyesOpen = ["..aaakaaaakaaa..", ".aaaakaaaakaaaa."]
    private static let eyesShut = ["..aaaaaaaaaaaa..", ".aaakkaaaakkaaa."]
    private static let eyesHappy = ["..aaakaaaakaaa..", ".aaakakaakakaaa."]
    private static let eyesDown = ["..aaaaaaaaaaaa..", ".aaaakaaaakaaaa."]
    private static let mouthNone = [".aaaaaaaaaaaaaa.", ".ssssssssssssss."]
    private static let mouthSmall = [".aaaaaakkaaaaaa.", ".ssssssssssssss."]
    private static let mouthWide = [".aaaaakkkkaaaaa.", ".sssssskkssssss."]
    private static let lookUp = top + ["..aahkaaaakaaa..", "..aaakaaaakaaa..", ".aaaaaaaaaaaaaa."] + mouthNone
    private static let tentQuiet = ["...h..h..h..h...", "...a..a..a..a...", "...g..a..a..g...", "......g..g......"]
    private static let tentSway = ["...h..h..h..h...", "....a..a..a..a..", "....g..a..a..g..", ".......g..g....."]
    private static let tentMid = ["...h..h..h..h...", "..a...a..a...a..", "..a...a..a...a..", "...g..a..a..g...", "......g..g......"]
    private static let tentLoud = ["...h..h..h..h...", "..a...a..a...a..", "..a..a....a..a..", "...a..a..a..a...",
                                   "..g...a..a...g..", "......g..g......"]
    private static let tentLimp = ["...h..h..h..h...", "...g..g..g..g..."]
    // Laptop seen from behind, two tentacles tapping on its sides.
    private static let laptopLeftUp = ["..h.llllllll....", "..a.llllwlll.h..", "....llllllll.a..", "..mmmmmmmmmmmm.."]
    private static let laptopRightUp = ["....llllllll.h..", "..h.llllwlll.a..", "..a.llllllll....", "..mmmmmmmmmmmm.."]

    private static func bell(_ eyes: [String], _ mouth: [String]) -> [String] { top + [crown] + eyes + mouth }

    private static func pad(_ rows: [String]) -> [String] {
        rows.count >= 16 ? Array(rows.prefix(16)) : rows + Array(repeating: empty, count: 16 - rows.count)
    }

    static let speakQuiet = pad([empty] + bell(eyesOpen, mouthNone) + tentQuiet)
    static let speakMid = pad([empty] + bell(eyesOpen, mouthSmall) + tentMid)
    static let speakLoud = pad(bell(eyesOpen, mouthWide) + tentLoud)
    static let think = [
        pad([empty] + lookUp + tentQuiet),
        pad(["...........w...."] + lookUp + tentSway),
        pad(["...........w.w.."] + lookUp + tentQuiet),
        pad(["...........w.w.w"] + lookUp + tentSway),
    ]
    static let sleep = [
        pad([empty, empty] + bell(eyesShut, mouthNone) + tentLimp),
        pad([".............hhh", "..............h.", ".....aaaaaa..hhh"] + Array(bell(eyesShut, mouthNone).dropFirst()) + tentLimp),
        pad([".............www", "..............w.", ".....aaaaaa..www"] + Array(bell(eyesShut, mouthNone).dropFirst()) + tentLimp),
    ]
    static let wave: [[String]] = {
        let happy = pad([empty] + bell(eyesHappy, mouthNone) + tentMid)
        return [happy, pad([empty] + bell(eyesHappy, mouthNone) + tentSway),
                pad(Array(happy.dropFirst(6))), pad(Array(happy.dropFirst(11))), pad([])]
    }()
    static let blink = pad([empty] + bell(eyesShut, mouthNone) + tentQuiet)
    static let work = [
        pad([empty, empty] + bell(eyesDown, mouthNone) + laptopLeftUp),
        pad([empty, empty] + bell(eyesDown, mouthNone) + laptopRightUp),
    ]
    static let alert: [[String]] = {
        let body = pad([empty] + bell(eyesOpen, mouthSmall) + tentMid)
        var flagged = body
        for row in [0, 1, 3] {
            var chars = Array(flagged[row])
            chars[14] = "w"
            flagged[row] = String(chars)
        }
        return [flagged, body]
    }()
}

/// What Drift is doing; each mood maps to a frame loop.
enum DriftMood: Equatable {
    case idle, thinking, working, waiting, speaking(level: Float), paused, goodbye
}

/// Renders Drift crisply: each sprite pixel is a whole number of device pixels and same-color runs
/// are drawn as single rectangles, so there are no seams or blur between pixels.
struct DriftView: View {
    var mood: DriftMood
    /// Points per sprite pixel. 1.5 pt = 3 device pixels on Retina.
    var pixel: CGFloat = 1.5

    private static let tick: TimeInterval = 0.12

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.tick)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate / Self.tick)
            Canvas { graphics, _ in
                Self.draw(frame(at: step), pixel: pixel, in: &graphics)
            }
        }
        .frame(width: pixel * 16, height: pixel * 16)
        .accessibilityHidden(true)
    }

    private func frame(at step: Int) -> [String] {
        func loop(_ frames: [[String]], hold: Int) -> [String] { frames[(step / hold) % frames.count] }
        switch mood {
        case .idle:
            return step % 26 < 24 ? DriftSprites.speakQuiet : DriftSprites.blink
        case .thinking:
            return loop(DriftSprites.think, hold: 3)
        case .working:
            return loop(DriftSprites.work, hold: 2)
        case .waiting:
            return loop(DriftSprites.alert, hold: 4)
        case .speaking(let level):
            if level < 0.3 { return DriftSprites.speakQuiet }
            return level < 0.6 ? DriftSprites.speakMid : DriftSprites.speakLoud
        case .paused:
            return loop(DriftSprites.sleep, hold: 5)
        case .goodbye:
            return loop(DriftSprites.wave, hold: 3)
        }
    }

    private static func draw(_ rows: [String], pixel: CGFloat, in graphics: inout GraphicsContext) {
        for (y, row) in rows.enumerated() {
            let chars = Array(row)
            var x = 0
            while x < chars.count {
                let key = chars[x]
                var end = x + 1
                while end < chars.count, chars[end] == key { end += 1 }
                if key != ".", let color = DriftSprites.palette[key] {
                    let rect = CGRect(x: CGFloat(x) * pixel, y: CGFloat(y) * pixel,
                                      width: CGFloat(end - x) * pixel, height: pixel)
                    graphics.fill(Path(rect), with: .color(color))
                }
                x = end
            }
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
