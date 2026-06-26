import SwiftUI
import Foundation

/// Lifecycle state of an agent, shown as the colored header dot.
enum AgentState: String {
    case idle
    case running
    case needsAction

    /// Lenient parse of the `state` value written to the control file.
    init(control value: String) {
        switch value.lowercased().replacingOccurrences(of: "_", with: "-") {
        case "running", "busy", "working": self = .running
        case "needs-action", "needsaction", "attention", "waiting", "blocked", "input": self = .needsAction
        default: self = .idle
        }
    }

    var color: Color {
        switch self {
        case .idle: return Color(red: 0.42, green: 0.45, blue: 0.50)        // grey
        case .running: return Color(red: 0.247, green: 0.725, blue: 0.314)  // green
        case .needsAction: return Color(red: 0.91, green: 0.62, blue: 0.20) // amber
        }
    }

    var glows: Bool { self != .idle }
}

/// The agent control channel + automatic Claude Code state reporting.
///
/// - Any agent/script in a box can set its name/description/state by writing JSON
///   to `$RUNWAY_CONTROL`:  echo '{"state":"running"}' > "$RUNWAY_CONTROL"
/// - For Claude Code specifically, state updates automatically with **zero user
///   setup**: each box's zsh is pointed at a Runway `ZDOTDIR` that sources the
///   user's real config and then defines a `claude` function adding
///   `--settings <runway-hooks>`. The hooks report state to `$RUNWAY_CONTROL`.
///   Nothing in the user's `~/.claude` or `~/.zshrc` is modified.
enum AgentControl {
    static let supportDir: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Runway", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var controlDir: URL { supportDir.appendingPathComponent("control", isDirectory: true) }
    static var zdotdir: URL { supportDir.appendingPathComponent("zsh", isDirectory: true) }
    static var hooksFile: URL { supportDir.appendingPathComponent("claude-hooks.json") }
    /// Inbox dir where the lead card drops fleet commands (add/remove). Each
    /// command is a uniquely-named JSON file Runway consumes and deletes.
    static var fleetInbox: URL { supportDir.appendingPathComponent("fleet", isDirectory: true) }

    static func file(for id: UUID) -> URL {
        controlDir.appendingPathComponent("\(id.uuidString).json")
    }

    /// Environment for a box's terminal: where to report state, plus the zsh
    /// wrapper that auto-injects Claude Code hooks.
    static func environment(for id: UUID) -> [String: String] {
        try? FileManager.default.createDirectory(at: controlDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: fleetInbox, withIntermediateDirectories: true)
        return [
            "RUNWAY_BOX": id.uuidString,
            "RUNWAY_CONTROL": file(for: id).path,
            "RUNWAY_CLAUDE_HOOKS": hooksFile.path,
            "RUNWAY_FLEET": fleetInbox.path,
            "ZDOTDIR": zdotdir.path,
        ]
    }

    static func cleanup(_ id: UUID) {
        try? FileManager.default.removeItem(at: file(for: id))
    }

    // MARK: One-time install (idempotent; call at launch)

    static func install() {
        clearFleetInbox()   // drop stale commands from a previous run
        writeHooks()
        writeZshWrapper()
    }

    /// Remove any leftover command files so a relaunch doesn't replay them.
    private static func clearFleetInbox() {
        try? FileManager.default.createDirectory(at: fleetInbox, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: fleetInbox,
                                                                  includingPropertiesForKeys: nil)) ?? []
        for f in files { try? FileManager.default.removeItem(at: f) }
    }

    private static func writeHooks() {
        func reporter(_ state: String) -> [String: Any] {
            ["hooks": [[
                "type": "command",
                "command": "[ -n \"$RUNWAY_CONTROL\" ] && printf '{\"state\":\"\(state)\"}' > \"$RUNWAY_CONTROL\"",
            ]]]
        }
        let settings: [String: Any] = ["hooks": [
            "UserPromptSubmit": [reporter("running")],
            "PreToolUse": [reporter("running")],
            "Notification": [reporter("needs-action")],
            "Stop": [reporter("idle")],
        ]]
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted]) else { return }
        try? data.write(to: hooksFile)
    }

    private static func writeZshWrapper() {
        try? FileManager.default.createDirectory(at: zdotdir, withIntermediateDirectories: true)
        // zsh reads each startup file from $ZDOTDIR; source the user's real ones
        // so their environment is preserved, then add the claude function.
        write(".zshenv", #"[ -f "$HOME/.zshenv" ] && source "$HOME/.zshenv""#)
        write(".zprofile", #"[ -f "$HOME/.zprofile" ] && source "$HOME/.zprofile""#)
        write(".zlogin", #"[ -f "$HOME/.zlogin" ] && source "$HOME/.zlogin""#)
        write(".zshrc", """
        # Managed by Runway. Loads your real zsh config, then — only inside a Runway
        # box — routes `claude` through state-reporting hooks. Shells outside Runway
        # are unaffected; your ~/.zshrc and ~/.claude are never modified.
        [ -f "$HOME/.zshrc" ] && source "$HOME/.zshrc"
        if [ -n "$RUNWAY_CONTROL" ] && [ -n "$RUNWAY_CLAUDE_HOOKS" ]; then
          claude() { command claude --settings "$RUNWAY_CLAUDE_HOOKS" "$@"; }
        fi
        # Fleet control: add/remove agent cards. Only honored by Runway when run
        # from the current lead card (star a card in the board to make it lead).
        if [ -n "$RUNWAY_FLEET" ]; then
          runway() {
            local action="$1" name="$2"
            local file="$RUNWAY_FLEET/$(date +%s)-$$-$RANDOM.json"
            case "$action" in
              add)
                printf '{"action":"add","name":"%s","from":"%s"}' "$name" "$RUNWAY_BOX" > "$file" ;;
              remove)
                if [ -z "$name" ]; then echo "usage: runway remove <name>" >&2; return 1; fi
                printf '{"action":"remove","name":"%s","from":"%s"}' "$name" "$RUNWAY_BOX" > "$file" ;;
              *)
                echo "usage: runway add [name] | runway remove <name>" >&2; return 1 ;;
            esac
          }
        fi
        """)
    }

    private static func write(_ name: String, _ contents: String) {
        try? (contents + "\n").data(using: .utf8)?
            .write(to: zdotdir.appendingPathComponent(name))
    }
}
