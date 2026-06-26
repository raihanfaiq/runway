import SwiftUI
import AppKit

/// Left pane: an at-a-glance board of every agent card and its live state.
/// Rows mirror `Workspace.shared.boxes` (same order as the right pane and the
/// ⌘1–9 jump shortcuts); the state dot updates as each agent reports idle /
/// running / needs-action via its control file. Click a row to focus and scroll
/// to that card.
struct LeftPane: View {
    @Bindable private var ws = Workspace.shared
    /// Natural height of the agent rows, so the list sizes to its content (and only
    /// scrolls past a cap) — leaving the rest of the pane for the notes pad.
    @State private var listContentHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 0) {
                header
                if ws.boxes.isEmpty {
                    emptyNotice
                } else {
                    summary
                    list(cap: geo.size.height * 0.5)
                }
                notesSection
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(white: 0.035))
        }
    }

    // MARK: Header
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Agents")
                .font(.system(size: 27, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.95))
            Spacer(minLength: 8)
            Text("\(ws.boxes.count)")
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.3))
        }
        .padding(.horizontal, 16)
        // Clear the traffic lights when windowed; tighten to the top in full screen.
        .padding(.top, ws.isFullScreen ? 18 : 50)
        .padding(.bottom, 16)
    }

    /// A one-line tally so you can read the room without scanning every row.
    @ViewBuilder private var summary: some View {
        let counts = stateCounts
        HStack(spacing: 12) {
            if counts.running > 0 { tally(AgentState.running, counts.running, "running") }
            if counts.needsAction > 0 { tally(AgentState.needsAction, counts.needsAction, "needs you") }
            if counts.idle > 0 { tally(AgentState.idle, counts.idle, "idle") }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func tally(_ state: AgentState, _ n: Int, _ label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(state.color).frame(width: 6, height: 6)
            Text("\(n) \(label)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.4))
        }
    }

    private var stateCounts: (idle: Int, running: Int, needsAction: Int) {
        var idle = 0, running = 0, needsAction = 0
        for box in ws.boxes {
            switch box.state {
            case .idle: idle += 1
            case .running: running += 1
            case .needsAction: needsAction += 1
            }
        }
        return (idle, running, needsAction)
    }

    // MARK: Agent list
    /// Board order: the lead card pinned first, everything else in array order.
    /// Each entry keeps its true index so the ⌘1–9 numbers stay accurate.
    private var orderedBoxes: [(offset: Int, element: AgentBox)] {
        ws.boxes.enumerated()
            .map { (offset: $0.offset, element: $0.element) }
            .sorted { a, b in
                let aLead = ws.leadID == a.element.id
                let bLead = ws.leadID == b.element.id
                if aLead != bLead { return aLead }
                return a.offset < b.offset
            }
    }

    /// Sized to its content up to `cap`; scrolls only when the rows exceed it, so
    /// the notes pad below always gets the leftover space (no dead gap).
    private func list(cap: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(orderedBoxes, id: \.element.id) { entry in
                    AgentRow(
                        index: entry.offset,
                        box: entry.element,
                        isLead: ws.leadID == entry.element.id,
                        isFocused: ws.focusedID == entry.element.id,
                        onTap: { ws.setFocus(entry.element.id) },
                        onToggleLead: { ws.toggleLead(entry.element.id) }
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 2)
            .padding(.bottom, 12)
            .background(GeometryReader { g in
                Color.clear.preference(key: ListHeightKey.self, value: g.size.height)
            })
        }
        .frame(height: min(listContentHeight, cap))
        .scrollIndicators(.hidden)
        .onPreferenceChange(ListHeightKey.self) { listContentHeight = $0 }
    }

    // MARK: Notes scratchpad
    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("NOTES")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.3))
                .tracking(0.8)
                .padding(.horizontal, 16)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $ws.notes)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.78))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                if ws.notes.isEmpty {
                    Text("Jot tasks, todos, snippets…")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.25))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.06), lineWidth: 1))
            .padding(.horizontal, 12)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private var emptyNotice: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.3))
            Text("No agents yet. Add one to get started.")
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: Footer
    private var footer: some View {
        VStack(spacing: 10) {
            Button { ws.newBox() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Add agent")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .foregroundStyle(Color.white.opacity(0.6))
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.06)))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.white.opacity(0.1),
                                      style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
            }
            .buttonStyle(.plain)
            .onHover { if $0 { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() } }
            .help("Add agent (⌘N)")

            Text("⌘1–9 jump  ·  ⌘⌥↑↓ navigate  ·  ⌘N add  ·  ⌘W close")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.22))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
    }
}

// MARK: - Agent row

/// One agent in the board: a state dot, the name + (optional) description, and a
/// trailing state word. Highlights when it's the focused card.
private struct AgentRow: View {
    let index: Int
    let box: AgentBox
    var isLead: Bool = false
    let isFocused: Bool
    let onTap: () -> Void
    var onToggleLead: () -> Void = {}
    @State private var hovering = false

    private static let gold = Color(red: 0.95, green: 0.78, blue: 0.32)

    var body: some View {
        HStack(spacing: 9) {
            // ⌘1–9 jump number (subtle), only for the first nine.
            Text(index < 9 ? "\(index + 1)" : " ")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.22))
                .frame(width: 11, alignment: .trailing)

            Circle()
                .fill(box.state.color)
                .frame(width: 8, height: 8)
                .shadow(color: box.state.glows ? box.state.color.opacity(0.9) : .clear, radius: 4)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(box.name)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .lineLimit(1)
                    if isLead { leadBadge }
                }
                if !box.detail.isEmpty {
                    Text(box.detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.4))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 6)

            // Star toggles the lead role; only shown for the lead or on hover.
            if isLead || hovering { leadStar }

            Text(stateLabel)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(box.state.color.opacity(0.85))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9).fill(rowFill))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(borderColor, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering = $0; if $0 { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() } }
    }

    private var leadBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "star.fill").font(.system(size: 7.5))
            Text("lead").font(.system(size: 9.5, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(Self.gold)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(Self.gold.opacity(0.14)))
        .overlay(Capsule().stroke(Self.gold.opacity(0.3), lineWidth: 1))
    }

    private var leadStar: some View {
        Button(action: onToggleLead) {
            Image(systemName: isLead ? "star.fill" : "star")
                .font(.system(size: 11))
                .foregroundStyle(isLead ? Self.gold : Color.white.opacity(0.4))
        }
        .buttonStyle(.plain)
        .onHover { if $0 { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() } }
        .help(isLead ? "Remove lead" : "Make lead")
    }

    private var borderColor: Color {
        if isFocused { return Color.white.opacity(0.22) }
        if isLead { return Self.gold.opacity(0.35) }
        return Color.white.opacity(0.06)
    }

    private var rowFill: Color {
        if isFocused { return Color.white.opacity(0.085) }
        if isLead { return Self.gold.opacity(0.06) }
        return Color.white.opacity(hovering ? 0.05 : 0.025)
    }

    private var stateLabel: String {
        switch box.state {
        case .idle: return "idle"
        case .running: return "running"
        case .needsAction: return "needs you"
        }
    }
}

// MARK: - Layout helper

/// Reports the agent list's natural content height up to its container.
private struct ListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
