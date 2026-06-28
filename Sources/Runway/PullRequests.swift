import SwiftUI
import AppKit
import Foundation

// MARK: - Model

/// One open pull request with its live mergeability + CI, plus a derived status
/// that turns those raw fields into a single glanceable verdict + suggestion.
/// `Sendable` so it can be produced in detached fetch tasks and handed back to
/// the `@MainActor` store.
struct PullRequest: Identifiable, Sendable {
    let repo: String          // short name, e.g. "monorepo"
    let number: Int
    let title: String
    let isDraft: Bool
    let additions: Int
    let deletions: Int
    let changedFiles: Int
    let updatedAt: Date?
    let url: String
    let status: PRStatus

    var id: String { "\(repo)#\(number)" }
}

/// A one-word verdict combining draft / CI / mergeability — what to do next.
/// `sortKey` orders quick wins first (matching the skill's easiest→hardest list).
enum PRStatus: Sendable {
    case ready          // clean + mergeable → merge it
    case rebase         // dirty / behind / conflicting → rebase
    case ciFailing      // a required check failed → fix CI
    case review         // blocked on review / changes requested
    case checking       // GitHub still computing, or CI pending
    case draft          // work in progress

    var label: String {
        switch self {
        case .ready: return "ready"
        case .rebase: return "rebase"
        case .ciFailing: return "CI"
        case .review: return "review"
        case .checking: return "checking"
        case .draft: return "draft"
        }
    }

    var symbol: String {
        switch self {
        case .ready: return "checkmark"
        case .rebase: return "arrow.triangle.merge"
        case .ciFailing: return "xmark"
        case .review: return "eye"
        case .checking: return "clock"
        case .draft: return "pencil"
        }
    }

    var color: Color {
        switch self {
        case .ready: return Color(red: 0.247, green: 0.725, blue: 0.314)  // green
        case .rebase: return Color(red: 0.91, green: 0.62, blue: 0.20)    // amber
        case .ciFailing: return Color(red: 0.90, green: 0.41, blue: 0.48) // red
        case .review: return Color(red: 0.35, green: 0.65, blue: 0.88)    // blue
        case .checking: return Color(red: 0.55, green: 0.58, blue: 0.62)  // grey
        case .draft: return Color(red: 0.50, green: 0.50, blue: 0.55)     // dim grey
        }
    }

    var sortKey: Int {
        switch self {
        case .ready: return 0
        case .rebase: return 1
        case .ciFailing: return 2
        case .review: return 3
        case .checking: return 4
        case .draft: return 5
        }
    }
}

// MARK: - Store (polls `gh` for the user's open PRs across the three repos)

/// Live source for the left pane's PR list. Same scope + commands as the
/// `update-lists` skill, but rendered natively and refreshed on a timer.
@MainActor @Observable final class PRStore {
    static let shared = PRStore()

    /// Fixed scope, matching the `update-lists` skill.
    private static let repos = ["VISKA-IO/monorepo", "VISKA-IO/upsell-pos", "VISKA-IO/upsell-kiosk"]
    private static let author = "raihanfaiq"

    var prs: [PullRequest] = []
    var loading = false
    /// True once a fetch has completed, so the UI distinguishes "still loading"
    /// (skeleton) from "loaded, nothing here" (empty notice).
    var didLoad = false
    var lastError: String?
    var lastRefreshed: Date?

    /// Seconds between automatic polls. PR-view calls are heavier than the feed's
    /// single events call, so we poll less often and offer a manual refresh.
    let pollInterval: UInt64 = 90
    private init() {}

    /// PRs grouped by repo in the fixed order; within a group, quick wins first.
    var groups: [(repo: String, prs: [PullRequest])] {
        Self.repos.map { full in
            let short = Self.shortName(full)
            let items = prs.filter { $0.repo == short }
                .sorted { a, b in
                    if a.status.sortKey != b.status.sortKey { return a.status.sortKey < b.status.sortKey }
                    return (a.updatedAt ?? .distantPast) > (b.updatedAt ?? .distantPast)
                }
            return (repo: short, prs: items)
        }
        .filter { !$0.prs.isEmpty }
    }

    func startPolling() {
        Task { @MainActor in
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(nanoseconds: pollInterval * 1_000_000_000)
            }
        }
    }

    func refresh() async {
        if prs.isEmpty { loading = true }
        var collected: [PullRequest] = []
        var sawError = false
        // Fan out across the three repos concurrently.
        await withTaskGroup(of: [PullRequest]?.self) { group in
            for repo in Self.repos {
                group.addTask { await Self.fetchRepo(repo) }
            }
            for await result in group {
                if let result { collected.append(contentsOf: result) } else { sawError = true }
            }
        }

        if sawError && collected.isEmpty {
            // Couldn't reach gh at all — keep any stale list, just surface the hint.
            if prs.isEmpty { lastError = GitHubFeed.ghHint }
        } else {
            prs = collected
            lastError = nil
            didLoad = true
            lastRefreshed = Date()
        }
        loading = false
    }

    // MARK: gh fetching (nonisolated: runs off the main actor, returns Sendable values)

    /// Stub from the cheap `gh search prs` call, before the per-PR detail fetch.
    private struct Stub: Sendable {
        let number: Int
        let title: String
        let isDraft: Bool
        let url: String
    }

    private nonisolated static func shortName(_ full: String) -> String {
        full.split(separator: "/").last.map(String.init) ?? full
    }

    /// All open PRs for one repo, each enriched with mergeability + CI. `nil` only
    /// if the repo's search call itself fails (so the caller can flag a gh error).
    private nonisolated static func fetchRepo(_ repo: String) async -> [PullRequest]? {
        guard let stubs = await searchOpen(repo) else { return nil }
        var out: [PullRequest] = []
        await withTaskGroup(of: PullRequest?.self) { group in
            for stub in stubs {
                group.addTask { await detail(repo: repo, stub: stub) }
            }
            for await pr in group { if let pr { out.append(pr) } }
        }
        return out
    }

    private nonisolated static func searchOpen(_ repo: String) async -> [Stub]? {
        guard let data = await GH.run([
            "search", "prs", "--repo", repo, "--author", author, "--state", "open",
            "--sort", "updated",
            "--json", "number,title,isDraft,url", "--limit", "50"
        ]) else { return nil }
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return arr.compactMap { o in
            guard let n = o["number"] as? Int else { return nil }
            return Stub(number: n,
                        title: o["title"] as? String ?? "",
                        isDraft: o["isDraft"] as? Bool ?? false,
                        url: o["url"] as? String ?? "")
        }
    }

    private nonisolated static func detail(repo: String, stub: Stub) async -> PullRequest? {
        let short = shortName(repo)
        guard let data = await GH.run([
            "pr", "view", "\(stub.number)", "--repo", repo,
            "--json", "number,title,isDraft,mergeable,mergeStateStatus,additions," +
                      "deletions,changedFiles,updatedAt,reviewDecision,statusCheckRollup"
        ]), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Detail call failed — still show the PR from its search stub.
            return PullRequest(repo: short, number: stub.number, title: stub.title,
                               isDraft: stub.isDraft, additions: 0, deletions: 0, changedFiles: 0,
                               updatedAt: nil, url: stub.url, status: .checking)
        }
        let isDraft = o["isDraft"] as? Bool ?? stub.isDraft
        let mergeable = (o["mergeable"] as? String ?? "UNKNOWN").uppercased()
        let mergeState = (o["mergeStateStatus"] as? String ?? "UNKNOWN").uppercased()
        let reviewDecision = (o["reviewDecision"] as? String ?? "").uppercased()
        let ci = ciStatus(o["statusCheckRollup"])
        let status = derive(isDraft: isDraft, mergeable: mergeable, mergeState: mergeState,
                            reviewDecision: reviewDecision, ci: ci)
        return PullRequest(
            repo: short,
            number: o["number"] as? Int ?? stub.number,
            title: o["title"] as? String ?? stub.title,
            isDraft: isDraft,
            additions: o["additions"] as? Int ?? 0,
            deletions: o["deletions"] as? Int ?? 0,
            changedFiles: o["changedFiles"] as? Int ?? 0,
            updatedAt: parseDate(o["updatedAt"] as? String),
            url: stub.url,
            status: status
        )
    }

    private enum CI { case passing, failing, pending, none }

    /// Reads `statusCheckRollup[]`, which mixes GraphQL CheckRun entries
    /// (`status` + `conclusion`) and legacy StatusContext entries (`state`).
    private nonisolated static func ciStatus(_ any: Any?) -> CI {
        guard let arr = any as? [[String: Any]], !arr.isEmpty else { return .none }
        var anyPending = false
        for c in arr {
            if let state = (c["state"] as? String)?.uppercased() {        // StatusContext
                switch state {
                case "FAILURE", "ERROR": return .failing
                case "PENDING", "EXPECTED": anyPending = true
                default: break
                }
            } else {                                                       // CheckRun
                let status = (c["status"] as? String ?? "").uppercased()
                if status != "COMPLETED" { anyPending = true; continue }
                switch (c["conclusion"] as? String ?? "").uppercased() {
                case "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE":
                    return .failing
                default: break
                }
            }
        }
        return anyPending ? .pending : .passing
    }

    private nonisolated static func derive(isDraft: Bool, mergeable: String, mergeState: String,
                                           reviewDecision: String, ci: CI) -> PRStatus {
        if isDraft { return .draft }
        if case .failing = ci { return .ciFailing }
        switch mergeState {
        case "DIRTY", "BEHIND": return .rebase
        case "BLOCKED": return .review
        default: break
        }
        if mergeable == "CONFLICTING" { return .rebase }
        if reviewDecision == "REVIEW_REQUIRED" || reviewDecision == "CHANGES_REQUESTED" { return .review }
        if case .pending = ci { return .checking }
        if mergeable == "UNKNOWN" || mergeState == "UNKNOWN" { return .checking }
        if mergeState == "CLEAN" && mergeable == "MERGEABLE" { return .ready }
        return .checking
    }

    private nonisolated static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        return ISO8601DateFormatter().date(from: s)
    }
}

// MARK: - View

/// The left pane's lower section: a live, grouped list of the user's open PRs.
struct PRListView: View {
    @Bindable private var store = PRStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private var header: some View {
        HStack(spacing: 7) {
            Text("PULL REQUESTS")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.3))
                .tracking(0.8)
            if store.loading {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.65)
                    .frame(width: 12, height: 12)
            }
            Spacer(minLength: 6)
            if !store.prs.isEmpty {
                Text("\(store.prs.count)")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.3))
            }
            Button { Task { await store.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.45))
            }
            .buttonStyle(.plain)
            .onHover { if $0 { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() } }
            .help("Refresh pull requests")
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder private var content: some View {
        if let err = store.lastError, store.prs.isEmpty {
            notice(systemImage: "exclamationmark.triangle", text: err)
        } else if !store.didLoad && store.prs.isEmpty {
            skeleton
        } else if store.prs.isEmpty {
            notice(systemImage: "checkmark.seal", text: "No open PRs 🎉")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(store.groups, id: \.repo) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.repo)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.35))
                                .padding(.horizontal, 4)
                            ForEach(group.prs) { PRRow(pr: $0) }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 2)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func notice(systemImage: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 18))
                .foregroundStyle(Color.white.opacity(0.3))
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<4, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.white.opacity(0.04))
                    .frame(height: 44)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
    }
}

/// One PR: number + title + status chip, with a +adds −dels · files · age subline.
/// The whole row opens the PR on GitHub.
private struct PRRow: View {
    let pr: PullRequest
    @State private var hovering = false

    var body: some View {
        Button {
            if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text("#\(pr.number)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.4))
                    Text(pr.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    chip
                }
                subline
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(hovering ? 0.05 : 0.025)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.06), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0; if $0 { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() } }
        .help("Open #\(pr.number) on GitHub")
    }

    private var chip: some View {
        HStack(spacing: 4) {
            Image(systemName: pr.status.symbol).font(.system(size: 8, weight: .bold))
            Text(pr.status.label).font(.system(size: 9.5, weight: .semibold, design: .monospaced))
        }
        .foregroundStyle(pr.status.color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(pr.status.color.opacity(0.14)))
        .overlay(Capsule().stroke(pr.status.color.opacity(0.3), lineWidth: 1))
        .fixedSize()
    }

    private var subline: some View {
        HStack(spacing: 6) {
            Text("+\(pr.additions)").foregroundStyle(Color(red: 0.42, green: 0.72, blue: 0.45))
            Text("−\(pr.deletions)").foregroundStyle(Color(red: 0.82, green: 0.45, blue: 0.50))
            Text("· \(pr.changedFiles) file\(pr.changedFiles == 1 ? "" : "s")")
                .foregroundStyle(Color.white.opacity(0.35))
            if let age = relativeAge(pr.updatedAt) {
                Text("· \(age)").foregroundStyle(Color.white.opacity(0.35))
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .lineLimit(1)
    }

    /// Compact "now / 4m / 2h / 3d" since a date.
    private func relativeAge(_ date: Date?) -> String? {
        guard let date else { return nil }
        let s = Date().timeIntervalSince(date)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86_400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86_400))d"
    }
}
