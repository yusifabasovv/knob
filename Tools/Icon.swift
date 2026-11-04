// Renders Knob's app icon (and alternative concepts) to PNG with SwiftUI.
// The app uses "screen" (chosen 2026-11-05; see ICON_CONCEPT in build.sh).
//   swiftc -O -parse-as-library Tools/Icon.swift -o build/icon
//   build/icon <dial|screen|sun> <out.png> [pixels]
// Drawn on the macOS icon grid: 1024 pt canvas, 824 pt continuous-corner tile, ~100 pt margin.
import AppKit
import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

let canvas: CGFloat = 1024
let tileSize: CGFloat = 824
let tileRadius: CGFloat = 185
/// Gauge sweep: 270° starting at 7:30 (135°, measured clockwise from 3 o'clock), gap at the bottom.
let sweepStart = 135.0, sweep = 270.0

/// Offset-then-rotate places a view on a circle around the ZStack centre, pointing outward.
extension View {
    func orbit(radius: CGFloat, angle: Double) -> some View {
        offset(y: -radius).rotationEffect(.degrees(angle - 270))
    }
}

struct Tile: View {
    let colors: [Color]
    var dark = true
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: tileRadius, style: .continuous)
        shape.fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            .overlay(shape.fill(LinearGradient(colors: [.white.opacity(dark ? 0.10 : 0.55), .clear],
                                               startPoint: .top, endPoint: .center)))
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(dark ? 0.24 : 0.95),
                                                                .white.opacity(dark ? 0.03 : 0.25)],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 2.5))
            .frame(width: tileSize, height: tileSize)
            .shadow(color: .black.opacity(0.32), radius: 18, y: 12)
    }
}

/// Brushed-aluminium knob with a glowing indicator at `level` (0...1 along the sweep).
struct MetalKnob: View {
    let radius: CGFloat
    let level: Double
    var indicator = Color(hex: 0x2F8CFF)

    var body: some View {
        let d = radius * 2
        ZStack {
            Circle().fill(.black.opacity(0.55))
                .frame(width: d, height: d)
                .blur(radius: radius * 0.13)
                .offset(y: radius * 0.11)
            Circle()
                .fill(AngularGradient(colors: [
                    Color(hex: 0xEEF1F5), Color(hex: 0xA5ADBA), Color(hex: 0xF8F9FB), Color(hex: 0x959EAD),
                    Color(hex: 0xE7EBF0), Color(hex: 0xB0B7C3), Color(hex: 0xEEF1F5),
                ], center: .center))
                .frame(width: d, height: d)
            Circle()
                .fill(RadialGradient(colors: [.white.opacity(0.38), .clear], center: UnitPoint(x: 0.32, y: 0.22),
                                     startRadius: 0, endRadius: radius * 1.3))
                .frame(width: d, height: d)
            Circle()
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.95), Color(hex: 0x566070, opacity: 0.85)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: radius * 0.035)
                .frame(width: d, height: d)
            // Concave cap: darker at the top, lighter at the bottom, with a radial brushed sheen.
            Circle()
                .fill(LinearGradient(colors: [Color(hex: 0xBFC6D1), Color(hex: 0xF2F4F7)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(Circle().fill(AngularGradient(colors: [.white.opacity(0.28), .clear, .white.opacity(0.2),
                                                                .clear, .white.opacity(0.28)], center: .center)))
                .overlay(Circle().strokeBorder(LinearGradient(colors: [Color(hex: 0x737C8B, opacity: 0.75),
                                                                       .white.opacity(0.95)],
                                                              startPoint: .top, endPoint: .bottom),
                                               lineWidth: radius * 0.022))
                .frame(width: d * 0.74, height: d * 0.74)
            Capsule()
                .fill(indicator)
                .frame(width: radius * 0.09, height: radius * 0.30)
                .shadow(color: indicator, radius: radius * 0.07)
                .orbit(radius: radius * 0.66, angle: sweepStart + sweep * level)
        }
    }
}

// MARK: - Concept 1: Dial

struct DialIcon: View {
    let level = 0.72
    let arcColors = [Color(hex: 0x3BE0FF), Color(hex: 0x2F8CFF), Color(hex: 0x8B5CFF)]

    var body: some View {
        ZStack {
            Tile(colors: [Color(hex: 0x27355F), Color(hex: 0x0A0F1F)])
            ZStack {
                arc(to: 1, style: AnyShapeStyle(Color.white.opacity(0.08)))
                arc(to: level, style: AnyShapeStyle(gradient)).blur(radius: 26).opacity(0.9)
                arc(to: level, style: AnyShapeStyle(gradient))
                ForEach(0..<13, id: \.self) { i in
                    let f = Double(i) / 12
                    Circle()
                        .fill(Color.white.opacity(f <= level + 0.001 ? 0.6 : 0.16))
                        .frame(width: 13, height: 13)
                        .orbit(radius: 248, angle: sweepStart + sweep * f)
                }
                MetalKnob(radius: 196, level: level)
            }
            .offset(y: 18)
        }
        .frame(width: canvas, height: canvas)
    }

    private var gradient: AngularGradient {
        AngularGradient(colors: arcColors, center: .center,
                        startAngle: .degrees(-10), endAngle: .degrees(sweep * level + 10))
    }

    private func arc(to fraction: Double, style: AnyShapeStyle) -> some View {
        Circle()
            .trim(from: 0, to: sweep / 360 * fraction)
            .stroke(style, style: StrokeStyle(lineWidth: 50, lineCap: .round))
            .frame(width: 600, height: 600)
            .rotationEffect(.degrees(sweepStart))
    }
}

// MARK: - Concept 2: Screen

struct ScreenIcon: View {
    var body: some View {
        ZStack {
            Tile(colors: [Color(hex: 0xFDFDFE), Color(hex: 0xD6DCE6)], dark: false)
            // Stand
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(colors: [Color(hex: 0xA9B0BC), Color(hex: 0x7E8695)], startPoint: .top, endPoint: .bottom))
                .frame(width: 84, height: 112)
                .offset(y: 214) // top tucks behind the monitor
            Capsule()
                .fill(LinearGradient(colors: [Color(hex: 0xC4CAD4), Color(hex: 0x8D95A3)], startPoint: .top, endPoint: .bottom))
                .frame(width: 300, height: 34)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 5)
                .offset(y: 282)
            // Monitor
            RoundedRectangle(cornerRadius: 42, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x2C3039), Color(hex: 0x121419)], startPoint: .top, endPoint: .bottom))
                .frame(width: 640, height: 420)
                .shadow(color: .black.opacity(0.3), radius: 16, y: 10)
                .offset(y: -50)
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x16245E), Color(hex: 0x5B3A9E), Color(hex: 0xE2557A), Color(hex: 0xFFA552)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(
                    Circle().fill(RadialGradient(colors: [Color(hex: 0xFFE7A8), Color(hex: 0xFFB45C, opacity: 0)],
                                                 center: .center, startRadius: 10, endRadius: 150))
                        .frame(width: 300, height: 300)
                        .offset(y: 150)
                )
                .overlay(
                    LinearGradient(colors: [.white.opacity(0.18), .clear], startPoint: .topLeading, endPoint: .center)
                )
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .frame(width: 596, height: 376)
                .offset(y: -50)
            MetalKnob(radius: 150, level: 0.72)
                .offset(x: 232, y: 178)
        }
        .frame(width: canvas, height: canvas)
    }
}

// MARK: - Concept 3: Sun

struct SunIcon: View {
    let level = 0.72
    let palette: [UInt32] = [0xFFB000, 0xFF7A1A, 0xFF4D4D, 0xFF2D95, 0xB44DFF, 0x6B5BFF, 0x2F8CFF]
    let rays = 19

    var body: some View {
        ZStack {
            Tile(colors: [Color(hex: 0x1D1D24), Color(hex: 0x060608)])
            ZStack {
                ForEach(0..<rays, id: \.self) { i in
                    let f = Double(i) / Double(rays - 1)
                    let lit = f <= level + 0.001
                    let len = 62 + 74 * f
                    let c = lit ? color(at: f / level) : Color(hex: 0x2B2B33)
                    Capsule()
                        .fill(c)
                        .frame(width: 30, height: len)
                        .shadow(color: lit ? c.opacity(0.85) : .clear, radius: 14)
                        .orbit(radius: 236 + len / 2, angle: sweepStart + sweep * f)
                }
                graphiteKnob
            }
            .offset(y: 22)
        }
        .frame(width: canvas, height: canvas)
    }

    private var graphiteKnob: some View {
        let r: CGFloat = 182
        return ZStack {
            Circle().fill(.black.opacity(0.7)).frame(width: r * 2, height: r * 2).blur(radius: 24).offset(y: 18)
            Circle()
                .fill(AngularGradient(colors: [Color(hex: 0x40414A), Color(hex: 0x1C1D22), Color(hex: 0x4A4B54),
                                               Color(hex: 0x18191D), Color(hex: 0x40414A)], center: .center))
                .frame(width: r * 2, height: r * 2)
            ForEach(0..<72, id: \.self) { i in
                Capsule().fill(Color.white.opacity(0.13))
                    .frame(width: 4, height: 20)
                    .orbit(radius: r - 16, angle: Double(i) * 5)
            }
            Circle()
                .fill(RadialGradient(colors: [Color(hex: 0x34353D), Color(hex: 0x16171B)], center: UnitPoint(x: 0.4, y: 0.3),
                                     startRadius: 0, endRadius: r))
                .overlay(Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .black.opacity(0.5)],
                                                              startPoint: .top, endPoint: .bottom), lineWidth: 3))
                .frame(width: r * 1.62, height: r * 1.62)
            Circle()
                .fill(Color.white)
                .frame(width: 30, height: 30)
                .shadow(color: .white, radius: 12)
                .orbit(radius: r * 0.56, angle: sweepStart + sweep * level)
        }
    }

    /// Palette colour at t (0...1), linearly blended between stops.
    private func color(at t: Double) -> Color {
        let x = min(max(t, 0), 1) * Double(palette.count - 1)
        let i = min(Int(x), palette.count - 2)
        let k = x - Double(i)
        func ch(_ h: UInt32, _ s: UInt32) -> Double { Double((h >> s) & 0xFF) / 255 }
        let a = palette[i], b = palette[i + 1]
        return Color(.sRGB,
                     red: ch(a, 16) + (ch(b, 16) - ch(a, 16)) * k,
                     green: ch(a, 8) + (ch(b, 8) - ch(a, 8)) * k,
                     blue: ch(a, 0) + (ch(b, 0) - ch(a, 0)) * k)
    }
}

// MARK: - Entry point

@main
struct IconTool {
    @MainActor static func main() {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            print("usage: icon <dial|screen|sun> <out.png> [pixels]")
            exit(2)
        }
        let pixels = args.count > 3 ? Double(args[3]) ?? 1024 : 1024
        let view: AnyView
        switch args[1] {
        case "dial": view = AnyView(DialIcon())
        case "screen": view = AnyView(ScreenIcon())
        case "sun": view = AnyView(SunIcon())
        default:
            print("unknown concept \(args[1])")
            exit(2)
        }
        let renderer = ImageRenderer(content: view.frame(width: canvas, height: canvas))
        renderer.scale = pixels / canvas
        guard let cg = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            print("render failed")
            exit(1)
        }
        do { try png.write(to: URL(fileURLWithPath: args[2])) } catch { print(error); exit(1) }
    }
}
