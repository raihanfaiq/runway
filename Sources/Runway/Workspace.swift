import SwiftUI
import AppKit

/// App-wide state + actions for the agent list. Owned here (not in a view) so the
/// app-level keyboard monitor can drive it even while a terminal has focus.
@MainActor @Observable final class Workspace {
    static let shared = Workspace()

    var boxes: [AgentBox] = [AgentBox(name: "agent1")]
    /// The box the user last focused (click or keyboard). Drives the focus glow,
    /// the accordion's larger share, and the solo target.
    var focusedID: UUID?
    /// Accordion: no scroll, boxes split the height, focused box larger.
    var accordion = false
    /// Solo / zoom: show only the focused box, filling the pane.
    var soloed = false

    /// Quick terminal: a persistent background terminal overlaid bottom-left,
    /// toggled with ⌘⌥Q. `quickHeight == 0` means "use 50% of the pane".
    var quickVisible = false
    var quickHeight: CGFloat = 0

    /// Width of the left pane (the split divider position).
    var leftWidth: CGFloat = 460

    /// Freeform scratchpad shown in the lower-left. Autosaved with the layout.
    var notes: String = ""

    /// The card designated as "lead" (a purely visual marker — pinned to the top
    /// of the board with a badge). `nil` = no lead.
    var leadID: UUID?

    /// True while the window is full screen (no traffic lights → less top inset).
    var isFullScreen = false

    /// Last raw control-file contents seen per box, so we only apply changes (and
    /// don't clobber the user's UI edits with a stale file).
    private var lastControl: [UUID: String] = [:]
    private var lastSaved: Data?

    private init() { load() }

    // MARK: Persistence

    private struct Persisted: Codable {
        var boxes: [AgentBox]
        var leftWidth: CGFloat
        var quickHeight: CGFloat
        var accordion: Bool
        var notes: String?    // optional: older state files predate it
        var leadID: UUID?     // optional: older state files predate it
    }

    private static var stateFile: URL { AgentControl.supportDir.appendingPathComponent("workspace.json") }

    private func load() {
        guard let data = try? Data(contentsOf: Self.stateFile),
              let s = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        if !s.boxes.isEmpty { boxes = s.boxes }
        leftWidth = s.leftWidth
        quickHeight = s.quickHeight
        accordion = s.accordion
        notes = s.notes ?? notes
        leadID = s.leadID
        lastSaved = data
    }

    /// Write current layout to disk if it changed. Cheap enough to call on the poll tick.
    func saveIfNeeded() {
        let snapshot = Persisted(boxes: boxes, leftWidth: leftWidth,
                                 quickHeight: quickHeight, accordion: accordion,
                                 notes: notes, leadID: leadID)
        guard let data = try? JSONEncoder().encode(snapshot), data != lastSaved else { return }
        lastSaved = data
        try? data.write(to: Self.stateFile)
    }

    func toggleQuick() { quickVisible.toggle() }

    var focusedIndex: Int? { boxes.firstIndex { $0.id == focusedID } }

    // MARK: Agent control channel

    /// Poll each box's control file and apply name/description/state the agent wrote.
    func startAgentWatch() {
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                pollControlFiles()
                processFleetCommands()
                saveIfNeeded()
            }
        }
    }

    private func pollControlFiles() {
        for i in boxes.indices {
            let id = boxes[i].id
            guard let data = try? Data(contentsOf: AgentControl.file(for: id)),
                  let raw = String(data: data, encoding: .utf8) else { continue }
            if lastControl[id] == raw { continue }   // unchanged → skip
            lastControl[id] = raw
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let name = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty {
                boxes[i].name = String(name.prefix(40))
            }
            if let desc = json["description"] as? String {
                boxes[i].detail = String(desc.prefix(40))
            }
            if let state = json["state"] as? String {
                boxes[i].state = AgentState(control: state)
            }
        }
    }

    /// Consume fleet commands dropped by the lead card (add/remove). A command is
    /// only honored if its `from` matches the *current* lead — so the ability
    /// follows the lead badge even if you re-assign it at runtime.
    private func processFleetCommands() {
        let inbox = AgentControl.fleetInbox
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: inbox, includingPropertiesForKeys: nil) else { return }
        // Process oldest-first; the filename prefix is a unix timestamp.
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            defer { try? FileManager.default.removeItem(at: file) }
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let action = json["action"] as? String else { continue }
            // Lead-only: ignore commands unless they came from the current lead card.
            guard let leadID, (json["from"] as? String) == leadID.uuidString else { continue }
            switch action {
            case "add":
                addBox(named: json["name"] as? String)
            case "remove":
                if let name = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !name.isEmpty {
                    removeBox(named: name)
                }
            default:
                break
            }
        }
    }

    // MARK: Actions (driven by the keyboard monitor + clicks)

    func newBox() { addBox() }

    /// Append a new agent card (optionally named) and focus it.
    @discardableResult
    func addBox(named name: String? = nil) -> AgentBox {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let box = AgentBox(name: (trimmed?.isEmpty == false)
                           ? String(trimmed!.prefix(40))
                           : "agent\(boxes.count + 1)")
        boxes.append(box)
        setFocus(box.id)
        return box
    }

    @discardableResult
    func closeFocused() -> Bool {
        guard let idx = focusedIndex else { return false }
        removeBox(at: idx)
        return true
    }

    /// Remove the first card matching `name` (used by the fleet control channel).
    func removeBox(named name: String) {
        guard let idx = boxes.firstIndex(where: { $0.name == name }) else { return }
        removeBox(at: idx)
    }

    /// Remove a card and tidy up its session/registry/lead/focus state.
    private func removeBox(at idx: Int) {
        guard boxes.indices.contains(idx) else { return }
        let removed = boxes.remove(at: idx)
        TerminalRegistry.shared.unregister(id: removed.id)
        AgentControl.cleanup(removed.id)
        lastControl[removed.id] = nil
        if leadID == removed.id { leadID = nil }
        if focusedID == removed.id {
            if boxes.isEmpty {
                focusedID = nil
                soloed = false
            } else {
                setFocus(boxes[min(idx, boxes.count - 1)].id)
            }
        }
    }

    func focus(offset: Int) {
        guard !boxes.isEmpty else { return }
        let current = focusedIndex ?? 0
        let next = ((current + offset) % boxes.count + boxes.count) % boxes.count
        setFocus(boxes[next].id)
    }

    func focus(index: Int) {
        guard boxes.indices.contains(index) else { return }
        setFocus(boxes[index].id)
    }

    func moveFocused(by delta: Int) {
        guard let idx = focusedIndex else { return }
        let target = idx + delta
        guard boxes.indices.contains(target) else { return }
        boxes.swapAt(idx, target)
    }

    /// Toggle which card is the (visual) lead. Only one at a time.
    func toggleLead(_ id: UUID) {
        leadID = (leadID == id) ? nil : id
    }

    func toggleAccordion() {
        // Choosing a base layout un-zooms.
        soloed = false
        accordion.toggle()
    }

    func toggleSolo() {
        // Solo is an overlay on the current mode; toggling it preserves
        // `accordion`, so exiting solo returns to whatever mode you were in.
        guard focusedID != nil else { return }
        soloed.toggle()
    }

    /// Set the visual focus and give that box's terminal keyboard focus.
    func setFocus(_ id: UUID?) {
        focusedID = id
        TerminalRegistry.shared.focusTerminal(id)
    }
}

/// Maps box ids to their terminal NSViews (both directions) so clicks resolve to
/// a box, and keyboard navigation can make a box's terminal first responder.
@MainActor final class TerminalRegistry {
    static let shared = TerminalRegistry()
    private var viewToID: [ObjectIdentifier: UUID] = [:]
    private var idToView: [UUID: NSView] = [:]
    private init() {}

    func register(_ view: NSView, id: UUID) {
        viewToID[ObjectIdentifier(view)] = id
        idToView[id] = view
    }

    func unregister(id: UUID) {
        if let view = idToView[id] { viewToID.removeValue(forKey: ObjectIdentifier(view)) }
        idToView.removeValue(forKey: id)
    }

    /// Walks up from `view` to find the first registered terminal and its box id.
    func boxID(under view: NSView) -> UUID? {
        var node: NSView? = view
        while let cur = node {
            if let id = viewToID[ObjectIdentifier(cur)] { return id }
            node = cur.superview
        }
        return nil
    }

    func focusTerminal(_ id: UUID?) {
        guard let id, let view = idToView[id] else { return }
        view.window?.makeFirstResponder(view)
    }
}
