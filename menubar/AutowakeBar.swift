// AutowakeBar: menu bar status for claude-autowake and Claude's usage windows.
//
// Build with ../menubar/build.sh. No Xcode project needed.

import AppKit
import Charts
import Foundation
import SwiftUI

// MARK: - Constants

let pingLabel = "com.autowake.ping"
let caffeinateLabel = "com.autowake.caffeinate"
let home = FileManager.default.homeDirectoryForCurrentUser.path
let logDir = "\(home)/.claude-autowake/logs"
let pingPlistPath = "\(home)/Library/LaunchAgents/\(pingLabel).plist"
let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

let localStateInterval: TimeInterval = 30
// The usage endpoint rate-limits hard (429 with a ~20 min Retry-After), so poll gently.
let usageInterval: TimeInterval = 600
let menuOpenRefreshInterval: TimeInterval = 180
let staleAfter: TimeInterval = 900

// MARK: - Shell helper

@discardableResult
func run(_ path: String, _ args: [String]) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

// MARK: - Usage API

struct UsageWindow {
    let utilization: Double
    let resetsAt: Date?
}

struct Usage {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let fetchedAt: Date
}

enum UsageError: Error {
    case noToken
    case http(Int)
    case rateLimited(retryAfter: TimeInterval?)
    case network(String)
    case parse

    var message: String {
        switch self {
        case .noToken: return "No Claude Code login in Keychain"
        case .http(401): return "Token expired, run claude once to refresh"
        case .rateLimited: return "Usage API rate limited"
        case .http(let code): return "Usage API returned HTTP \(code)"
        case .network(let msg): return "Network error: \(msg)"
        case .parse: return "Could not parse usage response"
        }
    }
}

func readAccessToken() -> String? {
    let r = run("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
    guard r.status == 0,
          let data = r.out.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = json["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String
    else { return nil }
    return token
}

// The API returns microsecond timestamps ("2026-11-11T10:10:00.783883+00:00"),
// which ISO8601DateFormatter rejects, so drop the fractional part first.
func parseDate(_ s: String?) -> Date? {
    guard var s = s else { return nil }
    if let dot = s.firstIndex(of: ".") {
        let rest = s[dot...]
        if let tz = rest.firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            s.removeSubrange(dot..<tz)
        }
    }
    return ISO8601DateFormatter().date(from: s)
}

func parseWindow(_ obj: Any?) -> UsageWindow? {
    guard let d = obj as? [String: Any], let u = d["utilization"] as? Double else { return nil }
    return UsageWindow(utilization: u, resetsAt: parseDate(d["resets_at"] as? String))
}

func fetchUsage(completion: @escaping (Result<Usage, UsageError>) -> Void) {
    DispatchQueue.global().async {
        guard let token = readAccessToken() else {
            completion(.failure(.noToken)); return
        }
        var req = URLRequest(url: usageURL, timeoutInterval: 20)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err { completion(.failure(.network(err.localizedDescription))); return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 429 {
                let header = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")
                completion(.failure(.rateLimited(retryAfter: header.flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) })))
                return
            }
            guard code == 200 else { completion(.failure(.http(code))); return }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { completion(.failure(.parse)); return }
            completion(.success(Usage(
                fiveHour: parseWindow(json["five_hour"]),
                sevenDay: parseWindow(json["seven_day"]),
                fetchedAt: Date()
            )))
        }.resume()
    }
}

// MARK: - Local autowake state

struct LastPing {
    let date: Date
    let ok: Bool
    let path: String
}

struct LocalState {
    var pingLoaded = false
    var caffeinateLoaded = false
    var caffeinating = false
    var nextPing: Date?
    var lastPing: LastPing?
}

func isLoaded(_ label: String) -> Bool {
    run("/bin/launchctl", ["list", label]).status == 0
}

func nextScheduledPing(after now: Date = Date()) -> Date? {
    guard let data = FileManager.default.contents(atPath: pingPlistPath),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    else { return nil }

    var entries: [[String: Any]] = []
    if let arr = plist["StartCalendarInterval"] as? [[String: Any]] { entries = arr }
    else if let one = plist["StartCalendarInterval"] as? [String: Any] { entries = [one] }

    let cal = Calendar.current
    return entries.compactMap { e -> Date? in
        var comps = DateComponents()
        comps.hour = e["Hour"] as? Int
        comps.minute = e["Minute"] as? Int ?? 0
        // launchd weekday: 0 or 7 = Sunday. Calendar weekday: 1 = Sunday.
        if let wd = e["Weekday"] as? Int { comps.weekday = (wd % 7) + 1 }
        return cal.nextDate(after: now, matching: comps, matchingPolicy: .nextTime)
    }.min()
}

func lastPing() -> LastPing? {
    let fm = FileManager.default
    guard let files = try? fm.contentsOfDirectory(atPath: logDir) else { return nil }
    let logs = files.filter { $0.hasPrefix("ping_") && $0.hasSuffix(".log") }
    // Filenames are ping_YYYY-MM-DD_HH-MM-SS.log, so lexical order is chronological.
    guard let latest = logs.max() else { return nil }
    let path = "\(logDir)/\(latest)"

    let stamp = latest.dropFirst("ping_".count).dropLast(".log".count)
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    let date = fmt.date(from: String(stamp))
        ?? (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date)
        ?? Date.distantPast

    let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    let ok = text.contains("Ping completed") && !text.contains("WARNING:")
    return LastPing(date: date, ok: ok, path: path)
}

func readLocalState() -> LocalState {
    var s = LocalState()
    s.pingLoaded = isLoaded(pingLabel)
    s.caffeinateLoaded = isLoaded(caffeinateLabel)
    s.caffeinating = run("/usr/bin/pgrep", ["-x", "caffeinate"]).status == 0
    s.nextPing = nextScheduledPing()
    s.lastPing = lastPing()
    return s
}

// MARK: - Formatting

func timeString(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "EEE HH:mm"
    return f.string(from: d)
}

func durationString(_ seconds: TimeInterval) -> String {
    let mins = max(0, Int(seconds / 60))
    let d = mins / 1440, h = (mins % 1440) / 60, m = mins % 60
    if d > 0 { return "\(d)d \(h)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

func relative(_ d: Date) -> String {
    let delta = d.timeIntervalSinceNow
    if abs(delta) < 60 { return "just now" }
    return delta >= 0 ? "in \(durationString(delta))" : "\(durationString(-delta)) ago"
}

func usageColor(_ pct: Double) -> NSColor {
    switch pct {
    case 90...: return .systemRed
    case 70..<90: return .systemOrange
    default: return .labelColor
    }
}

func compact(_ v: Double) -> String {
    if v < 1000 { return "\(Int(v.rounded()))" }
    if v < 1_000_000 { return String(format: "%.1fk", v / 1000) }
    if v < 1_000_000_000 { return String(format: "%.1fM", v / 1_000_000) }
    return String(format: "%.2fB", v / 1_000_000_000)
}

// MARK: - Token stats from local transcripts

let projectsDir = "\(home)/.claude/projects"
let statsHorizon: TimeInterval = 7 * 86400

struct TokenRecord {
    let id: String
    let time: Date
    let session: String
    let workspace: String
    let fresh: Int, write: Int, read: Int, out: Int

    var context: Int { fresh + write + read }
    // Weighted at API price ratios relative to fresh input.
    var weighted: Double { Double(fresh) + Double(write) * 1.25 + Double(read) * 0.1 + Double(out) * 5 }
}

final class TranscriptFile {
    var offset: UInt64 = 0
    /// Where the session started; later cwds wander into subfolders.
    var workspace: String?
    var records: [String: TokenRecord] = [:]
    var customTitle: String?
    var aiTitle: String?
    var lastPrompt: String?

    var title: String? { customTitle ?? aiTitle ?? lastPrompt }
}

let isoFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
let isoPlain = ISO8601DateFormatter()

typealias Bytes = UnsafeRawBufferPointer

let usageMarker = Array("\"usage\":".utf8)
let titleMarker = Array("-title\"".utf8)
let lastPromptMarker = Array("\"last-prompt\"".utf8)
let timestampMarker = Array("\"timestamp\":\"".utf8)

/// Byte offset just past `needle` in `line`, or nil.
func find(_ line: Bytes, _ needle: [UInt8]) -> Int? {
    guard let base = line.baseAddress,
          let hit = needle.withUnsafeBytes({ memmem(base, line.count, $0.baseAddress, $0.count) })
    else { return nil }
    return base.distance(to: UnsafeRawPointer(hit)) + needle.count
}

/// Pulls the timestamp out of the raw bytes so old lines skip the full JSON parse.
func rawTimestamp(_ line: Bytes) -> Date? {
    guard let start = find(line, timestampMarker) else { return nil }
    var end = start
    while end < line.count, line[end] != 0x22, end - start < 40 { end += 1 }
    guard let s = String(bytes: line[start..<end], encoding: .utf8) else { return nil }
    return isoFractional.date(from: s) ?? isoPlain.date(from: s)
}

func handleTranscriptLine(_ line: Bytes, _ f: TranscriptFile, cutoff: Date) {
    // Cheap byte checks first: most lines are tool results and prompts we don't need.
    let hasUsage = find(line, usageMarker) != nil
    if hasUsage, let t = rawTimestamp(line), t < cutoff { return }
    guard hasUsage || find(line, titleMarker) != nil || find(line, lastPromptMarker) != nil,
          let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
          let type = obj["type"] as? String
    else { return }

    switch type {
    case "assistant":
        guard hasUsage,
              let msg = obj["message"] as? [String: Any],
              let u = msg["usage"] as? [String: Any],
              let id = (msg["id"] as? String) ?? (obj["requestId"] as? String),
              let ts = obj["timestamp"] as? String,
              let time = isoFractional.date(from: ts) ?? isoPlain.date(from: ts),
              time >= cutoff
        else { return }
        let fresh = u["input_tokens"] as? Int ?? 0
        let write = u["cache_creation_input_tokens"] as? Int ?? 0
        let read = u["cache_read_input_tokens"] as? Int ?? 0
        let out = u["output_tokens"] as? Int ?? 0
        if fresh + write + read + out == 0 { return }  // synthetic messages, no API call
        if f.workspace == nil, let cwd = obj["cwd"] as? String, !cwd.isEmpty {
            f.workspace = (cwd as NSString).lastPathComponent
        }
        // A response is logged once per content block with the same usage; the id key keeps one.
        f.records[id] = TokenRecord(
            id: id,
            time: time,
            session: obj["sessionId"] as? String ?? "",
            workspace: f.workspace ?? "unknown",
            fresh: fresh, write: write, read: read, out: out
        )
    case "custom-title":
        if let t = obj["customTitle"] as? String, !t.isEmpty { f.customTitle = t }
    case "ai-title":
        if let t = obj["aiTitle"] as? String, !t.isEmpty { f.aiTitle = t }
    case "last-prompt":
        if let t = obj["lastPrompt"] as? String, !t.isEmpty { f.lastPrompt = t }
    default:
        break
    }
}

/// Reads the bytes appended since the last pass, up to the last complete line.
func readAppended(_ path: String, into f: TranscriptFile, cutoff: Date) {
    guard let h = FileHandle(forReadingAtPath: path) else { return }
    defer { try? h.close() }
    guard (try? h.seek(toOffset: f.offset)) != nil,
          let data = try? h.readToEnd(),
          let lastNewline = data.lastIndex(of: 0x0A)
    else { return }
    let length = data.distance(from: data.startIndex, to: lastNewline) + 1
    f.offset += UInt64(length)
    data.withUnsafeBytes { (all: Bytes) in
        guard let base = all.baseAddress else { return }
        var pos = 0
        while pos < length {
            let nl = memchr(base + pos, 0x0A, length - pos).map { base.distance(to: UnsafeRawPointer($0)) } ?? length
            if nl > pos { handleTranscriptLine(Bytes(rebasing: all[pos..<nl]), f, cutoff: cutoff) }
            pos = nl + 1
        }
    }
}

/// Keeps parsed transcripts in memory so a refresh only reads what was appended.
final class TranscriptStore {
    private var files: [String: TranscriptFile] = [:]
    private let queue = DispatchQueue(label: "autowake.transcripts")

    func load(completion: @escaping (_ records: [TokenRecord], _ titles: [String: String]) -> Void) {
        queue.async {
            let fm = FileManager.default
            let cutoff = Date().addingTimeInterval(-statsHorizon)
            var work: [(String, TranscriptFile)] = []
            var live: [String: TranscriptFile] = [:]

            for dir in (try? fm.contentsOfDirectory(atPath: projectsDir)) ?? [] {
                let dirPath = "\(projectsDir)/\(dir)"
                for name in (try? fm.contentsOfDirectory(atPath: dirPath)) ?? [] where name.hasSuffix(".jsonl") {
                    let path = "\(dirPath)/\(name)"
                    guard let attrs = try? fm.attributesOfItem(atPath: path),
                          let mtime = attrs[.modificationDate] as? Date, mtime >= cutoff,
                          let size = (attrs[.size] as? NSNumber)?.uint64Value
                    else { continue }
                    var f = self.files[path] ?? TranscriptFile()
                    if size < f.offset { f = TranscriptFile() }  // rewritten, start over
                    live[path] = f
                    if size > f.offset { work.append((path, f)) }
                }
            }

            // Each file is parsed by one worker, so no locking is needed.
            DispatchQueue.concurrentPerform(iterations: work.count) { i in
                readAppended(work[i].0, into: work[i].1, cutoff: cutoff)
            }
            self.files = live

            var seen = Set<String>()
            var records: [TokenRecord] = []
            var titles: [String: String] = [:]
            for f in live.values {
                f.records = f.records.filter { $0.value.time >= cutoff }
                for r in f.records.values where seen.insert(r.id).inserted {
                    records.append(r)
                    // A forked session repeats earlier messages; title by the session that owns them.
                    if titles[r.session] == nil, let t = f.title { titles[r.session] = t }
                }
            }
            completion(records, titles)
        }
    }
}

enum StatsRange: String, CaseIterable, Identifiable {
    case window = "This window", today = "Today", day = "24 hours", week = "7 days"
    var id: String { rawValue }
}

struct StatsTotals {
    var fresh = 0, write = 0, read = 0, out = 0, requests = 0
    var weighted = 0.0
    mutating func add(_ r: TokenRecord) {
        fresh += r.fresh; write += r.write; read += r.read; out += r.out
        requests += 1; weighted += r.weighted
    }
    var avgContext: Double { requests == 0 ? 0 : Double(fresh + write + read) / Double(requests) }
}

struct StatsBucket: Identifiable {
    let start: Date
    let weighted: Double
    var id: Date { start }
}

struct WorkspaceRow: Identifiable {
    let name: String
    let weighted: Double
    let sessions: Int
    var id: String { name }
}

struct SessionRow: Identifiable {
    let id: String
    let start: Date
    let workspace: String
    let title: String
    let calls: Int
    let peakContext: Int
    let weighted: Double
}

struct StatsSnapshot {
    let start: Date
    let end: Date
    let bucketUnit: Calendar.Component
    let totals: StatsTotals
    let buckets: [StatsBucket]
    let workspaces: [WorkspaceRow]
    let sessions: [SessionRow]
    let sessionCount: Int
}

let maxWorkspaceRows = 10

func topWorkspaces(_ weighted: [String: Double], _ sessions: [String: Set<String>]) -> [WorkspaceRow] {
    let all = weighted.map { WorkspaceRow(name: $0.key, weighted: $0.value, sessions: sessions[$0.key]?.count ?? 0) }
        .sorted { $0.weighted > $1.weighted }
    guard all.count > maxWorkspaceRows else { return all }
    let rest = all.dropFirst(maxWorkspaceRows - 1)
    return Array(all.prefix(maxWorkspaceRows - 1)) + [WorkspaceRow(
        name: "\(rest.count) others",
        weighted: rest.reduce(0) { $0 + $1.weighted },
        sessions: rest.reduce(0) { $0 + $1.sessions }
    )]
}

func buildSnapshot(_ records: [TokenRecord], titles: [String: String], start: Date, end: Date,
                   unit: Calendar.Component) -> StatsSnapshot {
    let cal = Calendar.current
    let now = Date()
    var totals = StatsTotals()
    var buckets: [Date: Double] = [:]
    var wsWeighted: [String: Double] = [:]
    var wsSessions: [String: Set<String>] = [:]
    var sessions: [String: (start: Date, ws: String, calls: Int, peak: Int, weighted: Double)] = [:]

    for r in records where r.time >= start && r.time <= now {
        totals.add(r)
        let b = unit == .hour
            ? Date(timeIntervalSince1970: (r.time.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
            : cal.startOfDay(for: r.time)
        buckets[b, default: 0] += r.weighted
        wsWeighted[r.workspace, default: 0] += r.weighted
        wsSessions[r.workspace, default: []].insert(r.session)
        var s = sessions[r.session] ?? (r.time, r.workspace, 0, 0, 0)
        s.start = min(s.start, r.time)
        s.calls += 1
        s.peak = max(s.peak, r.context)
        s.weighted += r.weighted
        sessions[r.session] = s
    }

    return StatsSnapshot(
        start: start,
        end: end,
        bucketUnit: unit,
        totals: totals,
        buckets: buckets.map { StatsBucket(start: $0.key, weighted: $0.value) }.sorted { $0.start < $1.start },
        workspaces: topWorkspaces(wsWeighted, wsSessions),
        sessions: sessions.map { id, s in
            SessionRow(id: id, start: s.start, workspace: s.ws, title: titles[id] ?? "", calls: s.calls,
                       peakContext: s.peak, weighted: s.weighted)
        }.sorted { $0.weighted > $1.weighted }.prefix(12).map { $0 },
        sessionCount: sessions.count
    )
}

final class StatsModel: ObservableObject {
    @Published var range: StatsRange = .window { didSet { recompute() } }
    @Published private(set) var snapshot: StatsSnapshot?
    @Published private(set) var loading = false
    @Published private(set) var usage: Usage?

    private let store = TranscriptStore()
    private var records: [TokenRecord] = []
    private var titles: [String: String] = [:]
    private var loaded = false

    var activeWindow: UsageWindow? {
        guard let w = usage?.fiveHour, let r = w.resetsAt, r > Date() else { return nil }
        return w
    }

    func setUsage(_ u: Usage?) {
        usage = u
        if loaded { recompute() }
    }

    func reload() {
        guard !loading else { return }
        loading = true
        store.load { records, titles in
            DispatchQueue.main.async {
                self.records = records
                self.titles = titles
                self.loaded = true
                self.loading = false
                self.recompute()
            }
        }
    }

    func recompute() {
        let now = Date()
        let start: Date, end: Date, unit: Calendar.Component
        switch range {
        case .window:
            guard let reset = activeWindow?.resetsAt else { snapshot = nil; return }
            start = reset.addingTimeInterval(-5 * 3600); end = reset; unit = .hour
        case .today:
            start = Calendar.current.startOfDay(for: now)
            end = Calendar.current.date(byAdding: .day, value: 1, to: start)!; unit = .hour
        case .day:
            start = now.addingTimeInterval(-86400); end = now; unit = .hour
        case .week:
            start = Calendar.current.startOfDay(for: now.addingTimeInterval(-6 * 86400))
            end = Calendar.current.date(byAdding: .day, value: 7, to: start)!; unit = .day
        }
        snapshot = buildSnapshot(records, titles: titles, start: start, end: end, unit: unit)
    }
}

// MARK: - Token stats view

struct StatCell: View {
    let label: String
    let value: String
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 17).monospacedDigit()).foregroundStyle(color)
        }
        .lineLimit(1)
        .fixedSize()
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 10)).foregroundStyle(.secondary)
    }
}

struct StatsView: View {
    @ObservedObject var model: StatsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Where the tokens went").font(.headline)
                Spacer()
                if model.loading { ProgressView().controlSize(.small) }
                Picker("", selection: $model.range) {
                    ForEach(StatsRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 340)
            }

            if let s = model.snapshot {
                content(s)
            } else if model.range == .window && !model.loading {
                Spacer()
                Text("No active 5-hour window").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                Spacer()
                ProgressView("Reading transcripts…").frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .padding(20)
        .frame(minWidth: 820, minHeight: 640)
    }

    @ViewBuilder
    func content(_ s: StatsSnapshot) -> some View {
        let t = s.totals
        HStack(alignment: .top, spacing: 16) {
            StatCell(label: "Weighted", value: compact(t.weighted), color: .accentColor)
            StatCell(label: "Fresh in", value: compact(Double(t.fresh)))
            StatCell(label: "Cache written", value: compact(Double(t.write)))
            StatCell(label: "Cache read", value: compact(Double(t.read)))
            StatCell(label: "Out", value: compact(Double(t.out)))
            StatCell(label: "Requests", value: "\(t.requests)")
            StatCell(label: "Context / req", value: compact(t.avgContext))
            if let w = model.activeWindow, let r = w.resetsAt {
                StatCell(label: "Window used", value: "\(Int(w.utilization.rounded()))%",
                         color: Color(nsColor: usageColor(w.utilization) == .labelColor ? .systemGreen : usageColor(w.utilization)))
                StatCell(label: "Resets in", value: durationString(r.timeIntervalSinceNow))
            }
            Spacer()
            Text("\(s.sessionCount) sessions").font(.caption).foregroundStyle(.secondary).fixedSize()
        }

        Chart(s.buckets) { b in
            BarMark(x: .value("Time", b.start, unit: s.bucketUnit), y: .value("Weighted", b.weighted))
                .foregroundStyle(Color.accentColor)
        }
        .chartXScale(domain: s.start...s.end)
        .chartYAxis {
            AxisMarks { v in
                AxisGridLine()
                AxisValueLabel { if let d = v.as(Double.self) { Text(compact(d)) } }
            }
        }
        .frame(height: 120)

        Text("Weighted at API price ratios: cache reads count a tenth of fresh input, cache writes 1.25x, output 5x. Read from local Claude Code transcripts.")
            .font(.caption2).foregroundStyle(.secondary)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                workspaces(s)
                sessions(s)
            }
        }
    }

    func workspaces(_ s: StatsSnapshot) -> some View {
        let maxW = s.workspaces.first?.weighted ?? 1
        return VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "By workspace")
            ForEach(s.workspaces) { w in
                HStack(spacing: 12) {
                    Text(w.name).lineLimit(1).frame(width: 150, alignment: .leading)
                    GeometryReader { g in
                        Capsule().fill(Color.accentColor)
                            .frame(width: max(3, g.size.width * CGFloat(w.weighted / max(maxW, 1))), height: 6)
                            .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(height: 16)
                    Text(compact(w.weighted)).monospacedDigit().frame(width: 60, alignment: .trailing)
                    Text("\(w.sessions) session\(w.sessions == 1 ? "" : "s")")
                        .foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                }
                .font(.system(size: 12))
            }
        }
    }

    func sessions(_ s: StatsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Biggest sessions")
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(s.sessions) { r in
                    GridRow {
                        Text(timeString(r.start)).foregroundStyle(.secondary)
                        Text(r.workspace).lineLimit(1)
                        Text(r.title).lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(r.calls) calls").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Text("\(compact(Double(r.peakContext))) ctx")
                            .foregroundStyle(r.peakContext > 200_000 ? Color.accentColor : .secondary)
                            .gridColumnAlignment(.trailing)
                        Text(compact(r.weighted)).gridColumnAlignment(.trailing)
                    }
                    .font(.system(size: 12).monospacedDigit())
                }
            }
        }
    }
}

/// Closes on Esc and Cmd-W; the accessory app has no main menu to provide those.
final class StatsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "w" {
            close(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()

    var local = LocalState()
    var usage: Usage?
    var usageError: UsageError?
    var lastUsageAttempt = Date.distantPast
    var rateLimitedUntil = Date.distantPast
    var rateLimitBackoff: TimeInterval = 0

    let statsModel = StatsModel()
    var statsWindow: StatsWindow?

    func applicationDidFinishLaunching(_ note: Notification) {
        menu.delegate = self
        item.menu = menu
        item.button?.imagePosition = .imageLeading

        refreshLocal()
        refreshUsage()
        // The first transcript scan takes a few seconds; do it now so the stats window opens ready.
        statsModel.reload()

        Timer.scheduledTimer(withTimeInterval: localStateInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.refreshLocal()
            self.refreshUsage(ifOlderThan: usageInterval)
        }

        // Keep the stats window live while it's open; only appended transcript bytes are read.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self = self, self.statsWindow?.isVisible == true else { return }
            self.statsModel.reload()
        }

        // Catch up right after the Mac wakes, when the morning ping just ran.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshLocal()
            self?.refreshUsage()
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshLocal()
        // Opening the menu is a good moment for fresh numbers, but don't hammer the API.
        refreshUsage(ifOlderThan: menuOpenRefreshInterval)
    }

    func refreshLocal() {
        DispatchQueue.global().async {
            let s = readLocalState()
            DispatchQueue.main.async {
                self.local = s
                self.render()
            }
        }
    }

    /// Fetches usage unless the server told us to back off or the last try was too recent.
    func refreshUsage(ifOlderThan minAge: TimeInterval = 0) {
        let now = Date()
        guard now >= rateLimitedUntil, now.timeIntervalSince(lastUsageAttempt) >= minAge else { render(); return }
        lastUsageAttempt = now
        fetchUsage { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let u):
                    self.usage = u
                    self.usageError = nil
                    self.rateLimitBackoff = 0
                    self.statsModel.setUsage(u)
                case .failure(let e):
                    self.usageError = e
                    if case .rateLimited(let retryAfter) = e {
                        // Honor Retry-After; without one, back off 5, 10, 20... up to 60 minutes.
                        self.rateLimitBackoff = min(3600, max(300, self.rateLimitBackoff * 2))
                        self.rateLimitedUntil = Date().addingTimeInterval(max(60, retryAfter ?? self.rateLimitBackoff))
                    }
                }
                self.render()
            }
        }
    }

    // MARK: Rendering

    func render() {
        renderButton()
        renderMenu()
    }

    var usageIsStale: Bool {
        guard let u = usage else { return false }
        return Date().timeIntervalSince(u.fetchedAt) > staleAfter
    }

    func activeFiveHour() -> UsageWindow? {
        guard let w = usage?.fiveHour, let r = w.resetsAt, r > Date() else { return nil }
        return w
    }

    func renderButton() {
        guard let button = item.button else { return }

        let symbol: String
        if !local.pingLoaded { symbol = "exclamationmark.triangle" }
        else if local.lastPing.map({ !$0.ok }) ?? false { symbol = "exclamationmark.circle" }
        else { symbol = "sunrise" }
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Claude Autowake")
        img?.isTemplate = true
        button.image = img

        let text: String
        var color = NSColor.labelColor
        if let w = activeFiveHour(), let r = w.resetsAt {
            // A stale reading is marked with ~ and greyed so it doesn't pass for a live number.
            text = " \(usageIsStale ? "~" : "")\(Int(w.utilization.rounded()))% · \(durationString(r.timeIntervalSinceNow))"
            color = usageIsStale ? .secondaryLabelColor : usageColor(w.utilization)
        } else if usage != nil {
            text = " idle"
        } else {
            text = " –"
        }
        button.attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: color,
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
        ])
    }

    func info(_ title: String, symbol: String? = nil, color: NSColor? = nil) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        if let symbol = symbol {
            let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            if let color = color {
                mi.image = img?.withSymbolConfiguration(.init(paletteColors: [color]))
            } else {
                mi.image = img
            }
        }
        // Disabled items render grey; keep them readable.
        mi.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.menuFont(ofSize: 0),
        ])
        return mi
    }

    func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
        return info(title)
    }

    func action(_ title: String, _ sel: Selector, key: String = "", enabled: Bool = true) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        mi.target = self
        mi.isEnabled = enabled
        return mi
    }

    func bar(_ pct: Double, width: Int = 20) -> String {
        let filled = min(width, max(0, Int((pct / 100 * Double(width)).rounded())))
        return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
    }

    func usageItem(_ label: String, _ w: UsageWindow?, idleText: String) -> [NSMenuItem] {
        guard let w = w, let r = w.resetsAt, r > Date() else {
            return [info("\(label): \(idleText)", symbol: "moon.zzz")]
        }
        let pct = w.utilization
        let line = info("\(label): \(Int(pct.rounded()))% used", symbol: "gauge.with.dots.needle.33percent",
                        color: usageColor(pct))
        let barItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        barItem.isEnabled = false
        barItem.attributedTitle = NSAttributedString(string: bar(pct), attributes: [
            .foregroundColor: usageColor(pct),
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
        ])
        barItem.indentationLevel = 1
        let reset = info("Resets \(timeString(r)) (\(relative(r)))")
        reset.indentationLevel = 1
        return [line, barItem, reset]
    }

    func renderMenu() {
        menu.removeAllItems()

        // Usage
        menu.addItem(header("Claude usage"))
        if let u = usage {
            usageItem("5-hour", u.fiveHour, idleText: "no active window").forEach(menu.addItem)
            usageItem("7-day", u.sevenDay, idleText: "no usage").forEach(menu.addItem)
            let updated = usageIsStale
                ? info("Last updated \(relative(u.fetchedAt)), numbers may be out of date",
                       symbol: "clock.badge.exclamationmark", color: .systemOrange)
                : info("Updated \(relative(u.fetchedAt))")
            if !usageIsStale { updated.indentationLevel = 1 }
            menu.addItem(updated)
        } else if usageError == nil {
            menu.addItem(info("Loading…"))
        }
        if let e = usageError {
            var msg = e.message
            if case .rateLimited = e, rateLimitedUntil > Date() {
                msg += ", retrying at \(timeString(rateLimitedUntil))"
            }
            menu.addItem(info(msg, symbol: "exclamationmark.triangle", color: .systemOrange))
        }

        menu.addItem(.separator())

        // Autowake
        menu.addItem(header("Autowake"))
        menu.addItem(info(local.pingLoaded ? "Ping agent loaded" : "Ping agent not loaded (run ./install.sh)",
                          symbol: local.pingLoaded ? "checkmark.circle.fill" : "xmark.circle.fill",
                          color: local.pingLoaded ? .systemGreen : .systemRed))
        let caff: String
        if local.caffeinating { caff = "Keeping Mac awake" }
        else if local.caffeinateLoaded { caff = "Caffeinate agent loaded, idle" }
        else { caff = "Caffeinate agent not loaded" }
        menu.addItem(info(caff, symbol: local.caffeinating ? "cup.and.saucer.fill" : "cup.and.saucer"))

        if let next = local.nextPing {
            menu.addItem(info("Next ping \(timeString(next)) (\(relative(next)))", symbol: "alarm"))
        }
        if let last = local.lastPing {
            menu.addItem(info("Last ping \(timeString(last.date)) (\(relative(last.date))): \(last.ok ? "ok" : "failed")",
                              symbol: last.ok ? "checkmark.seal" : "xmark.seal",
                              color: last.ok ? .systemGreen : .systemRed))
        } else {
            menu.addItem(info("No pings logged yet", symbol: "questionmark.circle"))
        }

        menu.addItem(.separator())

        menu.addItem(action("Token stats…", #selector(openStats), key: "t"))
        menu.addItem(action("Ping now", #selector(pingNow), enabled: local.pingLoaded))
        menu.addItem(action("Open last log", #selector(openLastLog), enabled: local.lastPing != nil))
        menu.addItem(action("Open logs folder", #selector(openLogs)))
        menu.addItem(action("Refresh", #selector(refreshAll), key: "r"))
        menu.addItem(.separator())
        menu.addItem(action("Quit", #selector(quit), key: "q"))
    }

    // MARK: Actions

    @objc func pingNow() {
        // Kickstart the launchd job so it runs with the same PATH/env as scheduled pings.
        run("/bin/launchctl", ["kickstart", "gui/\(getuid())/\(pingLabel)"])
        // The ping takes ~15s; pick up the new log and the started window afterwards.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self.refreshLocal(); self.refreshUsage() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { self.refreshLocal() }
    }

    @objc func openStats() {
        statsModel.setUsage(usage)
        if statsWindow == nil {
            let w = StatsWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            w.title = "Token stats"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: StatsView(model: statsModel))
            w.center()
            w.setFrameAutosaveName("AutowakeTokenStats")
            statsWindow = w
        }
        statsModel.reload()
        NSApp.activate(ignoringOtherApps: true)
        statsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func openLastLog() {
        if let p = local.lastPing?.path { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
    }

    @objc func openLogs() {
        NSWorkspace.shared.open(URL(fileURLWithPath: logDir))
    }

    @objc func refreshAll() {
        refreshLocal()
        refreshUsage()
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
