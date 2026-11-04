import SwiftUI

// Control Center–style building blocks. Colors are semantic so light and dark mode both work.

enum Style {
    static let tileRadius: CGFloat = 12
    static let tileFill = Color.primary.opacity(0.07)
    static let trackFill = Color.primary.opacity(0.13)
    static let chipFill = Color.primary.opacity(0.09)
    static let label = Font.system(size: 12, weight: .semibold)
    static let detail = Font.system(size: 11)
}

/// Rounded translucent card, like a Control Center module.
struct Tile<Content: View>: View {
    var padding: CGFloat = 10
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Style.tileRadius, style: .continuous).fill(Style.tileFill))
    }
}

/// Big pill slider with an icon inside, as in Control Center's Display/Sound modules.
struct PillSlider: View {
    let value: Int
    let maximum: Int
    let icon: String
    var enabled = true
    let onChange: (Int) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let frac = CGFloat(min(max(value, 0), maximum)) / CGFloat(maximum)
            // Keep the fill at least a circle wide so the icon always sits on white.
            let fillW = max(h, w * frac)
            ZStack(alignment: .leading) {
                Capsule().fill(Style.trackFill)
                Capsule()
                    .fill(Color.white)
                    .frame(width: fillW)
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.55))
                    .frame(width: h, height: h)
            }
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                guard enabled else { return }
                let f = min(max(g.location.x / w, 0), 1)
                let v = Int((f * CGFloat(maximum)).rounded())
                if v != value { onChange(v) }
            })
        }
        .frame(height: 26)
        .opacity(enabled ? 1 : 0.45)
        .animation(.easeOut(duration: 0.08), value: value)
    }
}

/// Slim slider for RGB gains.
struct ThinSlider: View {
    let value: Int
    let maximum: Int
    let tint: Color
    var enabled = true
    let onChange: (Int) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let frac = CGFloat(min(max(value, 0), maximum)) / CGFloat(maximum)
            ZStack(alignment: .leading) {
                Capsule().fill(Style.trackFill).frame(height: 5)
                Capsule().fill(tint).frame(width: max(5, w * frac), height: 5)
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                    .frame(width: 14, height: 14)
                    .offset(x: min(max(0, w * frac - 7), w - 14))
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                guard enabled else { return }
                let f = min(max(g.location.x / w, 0), 1)
                let v = Int((f * CGFloat(maximum)).rounded())
                if v != value { onChange(v) }
            })
        }
        .frame(height: 16)
        .opacity(enabled ? 1 : 0.4)
    }
}

/// Wrapping row of capsule chips; the selected one uses the system accent color.
struct ChipGroup: View {
    let options: [Int]
    let selected: Int?
    let label: (Int) -> String
    let onSelect: (Int) -> Void

    var body: some View {
        FlowLayout(spacing: 5) {
            ForEach(options, id: \.self) { opt in
                let on = opt == selected
                Button { log.notice("chip tapped \(label(opt), privacy: .public)"); onSelect(opt) } label: {
                    Text(label(opt))
                        .font(.system(size: 11, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(on ? Color.accentColor : Style.chipFill))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Left-to-right wrapping layout.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let h = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var cur = Row()
        for i in subviews.indices {
            let s = subviews[i].sizeThatFits(.unspecified)
            let needed = cur.indices.isEmpty ? s.width : cur.width + spacing + s.width
            if needed > width, !cur.indices.isEmpty {
                rows.append(cur)
                cur = Row(y: cur.y + cur.height + spacing)
            }
            cur.width = cur.indices.isEmpty ? s.width : cur.width + spacing + s.width
            cur.indices.append(i)
            cur.height = max(cur.height, s.height)
        }
        if !cur.indices.isEmpty { rows.append(cur) }
        return rows
    }
}

/// Small borderless icon button for the footer.
struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @StateObject private var hover = HoverState()
    var body: some View {
        Button(action: { log.notice("icon tapped \(help, privacy: .public)"); action() }) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hover.on ? Color.primary : Color.secondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(hover.on ? Style.chipFill : Color.clear))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover.on = $0 }
    }
}

/// Hover flag held in an ObservableObject (the CLT toolchain lacks the macro plugin @State needs).
final class HoverState: ObservableObject { @Published var on = false }
