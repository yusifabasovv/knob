import ServiceManagement
import SwiftUI

struct PanelView: View {
    @EnvironmentObject var model: MonitorModel
    // View state lives in an ObservableObject: the CLT toolchain lacks the SwiftUI macro plugin @State needs.
    @StateObject private var ui = PanelUIState()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            switch model.state {
            case .ready: controls
            case .connecting: message("Connecting…", "Reading the monitor's settings.", icon: "hourglass", retry: false)
            case .noMonitor:
                message("No external monitor", "Connect a monitor over HDMI, DisplayPort or USB-C.",
                        icon: "display.trianglebadge.exclamationmark", retry: true)
            case .noReply:
                message("Monitor isn't answering",
                        "Turn on DDC/CI in the monitor's own menu (on AOC: Extra → DDC/CI → Yes), then try again.",
                        icon: "exclamationmark.triangle", retry: true)
            case let .switchedInput(name):
                message("Switched to \(name)",
                        "This Mac can't reach the monitor while it's on another input. Switch back with the monitor's buttons, then try again.",
                        icon: "arrow.left.arrow.right", retry: true)
            }
            footer
        }
        .padding(12)
        .frame(width: 320)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await model.refresh() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "display")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 1) {
                Text([model.brand, model.model].filter { !$0.isEmpty }.joined(separator: " "))
                    .font(.system(size: 13, weight: .semibold))
                if !model.headerDetail.isEmpty {
                    Text(model.headerDetail).font(Style.detail).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.showBusy { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 2)
    }

    // MARK: Controls

    @ViewBuilder private var controls: some View {
        if model.supports(VCP.brightness) {
            sliderTile("Brightness", VCP.brightness, icon: "sun.max.fill")
        }
        if model.supports(VCP.contrast) {
            sliderTile("Contrast", VCP.contrast, icon: "circle.lefthalf.filled")
        }

        if !model.options(VCP.pictureMode).isEmpty {
            Tile {
                Text("Picture Mode").font(Style.label)
                ChipGroup(options: model.options(VCP.pictureMode), selected: model.value(VCP.pictureMode),
                          label: { model.label(VCP.pictureMode, $0) },
                          onSelect: { model.set(VCP.pictureMode, $0) })
            }
        }

        if !model.options(VCP.colorPreset).isEmpty {
            Tile {
                Text("Color").font(Style.label)
                ChipGroup(options: model.options(VCP.colorPreset), selected: model.value(VCP.colorPreset),
                          label: { model.label(VCP.colorPreset, $0) },
                          onSelect: { model.set(VCP.colorPreset, $0) })
                if model.supports(VCP.redGain) { rgb }
            }
        }

        if !model.options(VCP.inputSource).isEmpty { inputTile }
    }

    private func sliderTile(_ title: String, _ code: UInt8, icon: String) -> some View {
        Tile {
            HStack {
                Text(title).font(Style.label)
                Spacer()
                Text("\(percent(code))%").font(Style.detail.monospacedDigit()).foregroundStyle(.secondary)
            }
            let note = model.lockNote(code)
            PillSlider(value: model.value(code) ?? 0, maximum: model.maximum(code), icon: icon,
                       enabled: note == nil) {
                model.set(code, $0)
            }
            if let note {
                Label(note, systemImage: "lock.fill")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.rejected.contains(code) {
                Label("The monitor didn't accept this change.", systemImage: "exclamationmark.circle")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private func percent(_ code: UInt8) -> Int {
        Int((Double(model.value(code) ?? 0) / Double(model.maximum(code)) * 100).rounded())
    }

    private var rgb: some View {
        let enabled = model.isUserColor
        let channels: [(String, UInt8, Color)] = [
            ("R", VCP.redGain, Color(red: 1, green: 0.27, blue: 0.27)),
            ("G", VCP.greenGain, Color(red: 0.2, green: 0.78, blue: 0.35)),
            ("B", VCP.blueGain, Color(red: 0.2, green: 0.5, blue: 1)),
        ]
        return VStack(alignment: .leading, spacing: 5) {
            ForEach(channels, id: \.1) { name, code, tint in
                HStack(spacing: 8) {
                    Text(name).font(Style.detail.weight(.medium)).foregroundStyle(.secondary).frame(width: 10)
                    ThinSlider(value: model.value(code) ?? 0, maximum: model.maximum(code),
                               tint: tint, enabled: enabled) { model.set(code, $0) }
                    Text("\(model.value(code) ?? 0)").font(Style.detail.monospacedDigit())
                        .foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
                }
            }
            if !enabled {
                Text("Choose User to adjust red, green and blue.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
    }

    private var inputTile: some View {
        let current = model.value(VCP.inputSource)
        return Tile {
            HStack {
                Text("Input").font(Style.label)
                Spacer()
                Menu {
                    ForEach(model.options(VCP.inputSource), id: \.self) { opt in
                        Button {
                            ui.confirmInput = opt == current ? nil : opt
                        } label: {
                            if opt == current {
                                Label(model.label(VCP.inputSource, opt), systemImage: "checkmark")
                            } else {
                                Text(model.label(VCP.inputSource, opt))
                            }
                        }
                    }
                } label: {
                    Text(current.map { model.label(VCP.inputSource, $0) } ?? "—")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(Style.detail)
            }
            if let target = ui.confirmInput {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Switch to \(model.label(VCP.inputSource, target))? This Mac's picture on this monitor goes away until you switch back with the monitor's buttons.")
                        .font(Style.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button("Cancel") { ui.confirmInput = nil }
                            .controlSize(.small)
                        Button("Switch") { model.switchInput(to: target); ui.confirmInput = nil }
                            .controlSize(.small)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
    }

    // MARK: Messages & footer

    private func message(_ title: String, _ detail: String, icon: String, retry: Bool) -> some View {
        Tile(padding: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon).font(.system(size: 16)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Style.label)
                    Text(detail).font(Style.detail).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if retry {
                        Button("Try Again") { Task { await model.refresh(force: true) } }
                            .controlSize(.small)
                            .padding(.top, 4)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Toggle("Open at Login", isOn: $ui.startAtLogin)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(Style.detail)
                .onChange(of: ui.startAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        ui.startAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Spacer()
            IconButton(symbol: "arrow.clockwise", help: "Refresh (re-reads the monitor's settings and controls)") {
                Task { await model.refresh(force: true, rescan: true) }
            }
            IconButton(symbol: "power", help: "Quit") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }
}

final class PanelUIState: ObservableObject {
    @Published var confirmInput: Int?
    @Published var startAtLogin = SMAppService.mainApp.status == .enabled
}
