import SwiftUI

@main
struct KnobApp: App {
    // --bench/--snapshot run their own model; keep the menu bar one idle so timings are clean.
    @StateObject private var model = MonitorModel(
        autoStart: !CommandLine.arguments.contains("--bench") && !CommandLine.arguments.contains("--snapshot"))

    init() {
        // Menu bar only: no Dock icon, no app menu (LSUIElement in Info.plist does the same at launch).
        NSApplication.shared.setActivationPolicy(.accessory)

        // `Knob --snapshot out.png`: render the panel with live monitor values and exit.
        // Used for self-checks and README screenshots.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let path = args[i + 1]
            Task { @MainActor in await Snapshot.render(to: path) }
        }
        // `Knob --bench`: time mode/color changes through the real model, restore, exit.
        if args.contains("--bench") {
            Task { @MainActor in await Bench.run() }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(model)
        } label: {
            Image(systemName: "display")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
enum Snapshot {
    static func render(to path: String) async {
        let model = MonitorModel()
        for _ in 0..<100 where model.state == .connecting || model.refreshing {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let scheme: ColorScheme = CommandLine.arguments.contains("--light") ? .light : .dark
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
        var bg = Color.black
        appearance.performAsCurrentDrawingAppearance { bg = Color(nsColor: NSColor.windowBackgroundColor.usingColorSpace(.sRGB)!) }
        let renderer = ImageRenderer(content: PanelView().environmentObject(model)
            .background(bg).environment(\.colorScheme, scheme))
        renderer.scale = 2
        guard let cg = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write("snapshot failed\n".data(using: .utf8)!)
            exit(1)
        }
        try? data.write(to: URL(fileURLWithPath: path))
        print("state=\(model.state) values=\(model.values.sorted { $0.key < $1.key }.map { String(format: "%02X=%d", $0.key, $0.value) })")
        exit(0)
    }
}

@MainActor
enum Bench {
    static func run() async {
        let model = MonitorModel()
        let tLoad = ContinuousClock.now
        await waitIdle(model) { model.state != .connecting }
        print("initial load: \(ms(tLoad.duration(to: .now)))  state=\(model.state)  brightness=\(model.value(VCP.brightness) ?? -1)  controls=\(model.options(VCP.pictureMode).count) modes")
        if CommandLine.arguments.contains("--rescan") {
            let t = ContinuousClock.now
            await model.refresh(force: true, rescan: true)
            print("rescan (Refresh button): \(ms(t.duration(to: .now)))  controls=\(model.options(VCP.pictureMode).count) modes")
        }
        if CommandLine.arguments.contains("--launch-only") { exit(0) }
        guard model.state == .ready, let dc0 = model.value(VCP.pictureMode), let c0 = model.value(VCP.colorPreset) else {
            print("not ready: \(model.state)"); exit(1)
        }
        let dcAlt = model.options(VCP.pictureMode).first { $0 != dc0 && $0 != 0 } ?? dc0
        let cAlt = model.options(VCP.colorPreset).first { $0 != c0 && $0 != 0x01 } ?? c0
        let steps: [(String, UInt8, Int)] = [
            ("mode  -> \(model.label(VCP.pictureMode, dcAlt))", VCP.pictureMode, dcAlt),
            ("mode  -> \(model.label(VCP.pictureMode, dc0)) (back)", VCP.pictureMode, dc0),
            ("color -> \(model.label(VCP.colorPreset, cAlt))", VCP.colorPreset, cAlt),
            ("color -> \(model.label(VCP.colorPreset, c0)) (back)", VCP.colorPreset, c0),
        ]
        for (name, code, v) in steps {
            let t = ContinuousClock.now
            model.set(code, v)
            await waitIdle(model) { true }
            let ok = model.value(code) == v
            print("\(name): \(ms(t.duration(to: .now)))  \(ok ? "ok" : "MISMATCH")  brightness=\(model.value(VCP.brightness) ?? -1) contrast=\(model.value(VCP.contrast) ?? -1)")
        }

        // Panel-open refresh (non-forced, past the 1 s throttle).
        try? await Task.sleep(for: .milliseconds(1100))
        var opens: [String] = []
        for _ in 0..<3 {
            let t = ContinuousClock.now
            await model.refresh()
            opens.append(ms(t.duration(to: .now)))
            try? await Task.sleep(for: .milliseconds(1100))
        }
        print("panel-open refresh: \(opens.joined(separator: ", "))")

        // Slider drag: 30 brightness steps at ~60 Hz, then wait until the final value is confirmed.
        if let b0 = model.value(VCP.brightness), model.lockNote(VCP.brightness) == nil {
            let target = max(0, b0 - 30)
            let t = ContinuousClock.now
            for step in 1...30 {
                model.set(VCP.brightness, b0 - step * (b0 - target) / 30)
                try? await Task.sleep(for: .milliseconds(16))
            }
            let released = ContinuousClock.now
            await waitIdle(model) { true }
            print("slider drag \(b0)->\(target): drag \(ms(t.duration(to: released))), confirmed \(ms(released.duration(to: .now))) after release, final=\(model.value(VCP.brightness) ?? -1) rejected=\(model.rejected.contains(VCP.brightness))")
            model.set(VCP.brightness, b0)
            await waitIdle(model) { true }
        }
        exit(0)
    }

    private static func waitIdle(_ model: MonitorModel, _ extra: () -> Bool) async {
        try? await Task.sleep(for: .milliseconds(20)) // let the drain/refresh task start
        for _ in 0..<2000 {
            if !model.isBusy && extra() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func ms(_ d: Duration) -> String {
        let c = d.components
        return "\(Int(Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15)) ms"
    }
}
