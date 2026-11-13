import Foundation
import EventKit

/// Value type describing one calendar meeting inside the active window.
/// `attendees` are the attendees' display names (nil names dropped).
struct MeetingEvent {
    let id: String?
    let title: String
    let start: Date?
    let end: Date?
    let attendees: [String]
    let notes: String?
}

/// Coarse outcome of checking (and, when possible, requesting) Calendar access.
///
/// - `notDetermined`: the pre-request state (only reachable if the request itself cannot run).
/// - `granted`: full access; events can be listed.
/// - `denied`: the user said no (or a request failed). Only System Settings can change this.
/// - `restricted`: access cannot be granted locally at all (e.g. MDM/parental
///   controls); no request will help, and the UI needs a different message than `.denied`.
enum CalendarAccess {
    case notDetermined
    case granted
    case denied
    case restricted
}

/// Pure, EventKit-free input record for the mapping/sorting core. The core
/// operates on this (not on `EKEvent`) so it compiles and is testable without
/// EventKit objects at all.
struct RawEvent {
    var id: String?
    var title: String
    var start: Date?
    var end: Date?
    var attendees: [String]
    var notes: String?

    init(
        id: String? = nil,
        title: String = "",
        start: Date? = nil,
        end: Date? = nil,
        attendees: [String] = [],
        notes: String? = nil
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.attendees = attendees
        self.notes = notes
    }
}

/// Maps plain `RawEvent` records to `MeetingEvent` values. Pure.
func mapEvents(_ raw: [RawEvent]) -> [MeetingEvent] {
    raw.map {
        MeetingEvent(
            id: $0.id,
            title: $0.title,
            start: $0.start,
            end: $0.end,
            attendees: $0.attendees,
            notes: $0.notes
        )
    }
}

/// Sorts events ascending by start; events with a nil start sort last. Pure.
func sortEvents(_ events: [MeetingEvent]) -> [MeetingEvent] {
    events.sorted { a, b in
        if let aStart = a.start, let bStart = b.start {
            return aStart < bStart
        }
        if a.start == nil && b.start == nil {
            return false
        }
        // Nil start sorts last.
        return a.start != nil
    }
}

/// Keeps only events whose start falls inside `[window.start, window.end]`;
/// events with a nil start are dropped. Pure (redundant with the EventKit
/// predicate, but makes the window contract explicit and testable).
func filterEvents(
    _ events: [MeetingEvent],
    in window: (start: Date, end: Date)
) -> [MeetingEvent] {
    events.filter { event in
        guard let start = event.start else { return false }
        return start >= window.start && start <= window.end
    }
}

/// Injectable seam over EventKit: everything the service needs from
/// `EKEventStore` in one place, so tests can supply a canned source.
/// Mirrors the repo's `ProcessRunner` injection style.
protocol CalendarSource {
    /// Current authorization state, from `EKEventStore.authorizationStatus(for: .event)`.
    func authorizationStatus() -> EKAuthorizationStatus
    /// Async permission request; throws on denial.
    func requestFullAccessToEvents() async throws -> Bool
    /// Events in `[start, end]` across all event calendars.
    func events(start: Date, end: Date) -> [EKEvent]
}

/// Real implementation over `EKEventStore`.
struct EKCalendarSource: CalendarSource {
    private let store: EKEventStore

    init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    func authorizationStatus() -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    func requestFullAccessToEvents() async throws -> Bool {
        try await store.requestFullAccessToEvents()
    }

    func events(start: Date, end: Date) -> [EKEvent] {
        let predicate = store.predicateForEvents(
            withStart: start,
            end: end,
            calendars: store.calendars(for: .event)
        )
        return store.events(matching: predicate)
    }
}

/// Read-only diagnostics for Calendar permission attempts.
///
/// Appends a timestamped line to `~/Library/Logs/Oatmeal/calendar.log`,
/// creating the directory if needed. Completely fail-soft: every file
/// operation is wrapped in `try?`, so a missing/unwritable log location
/// never throws, never blocks, and never affects the app. Logs only
/// authorization statuses, booleans, and errors — never calendar content.
/// Foundation only; no dependencies.
enum CalendarDiagnostics {
    /// Appends `message` (plus a UTC ISO-8601 timestamp) to the log file.
    static func log(_ message: String) {
        log(message, to: Self.defaultLogFileURL)
    }

    /// Internal seam: appends to an explicit file URL so tests can point the
    /// log at a temporary location. Same fail-soft guarantees.
    static func log(_ message: String, to fileURL: URL) {
        guard let data = (Self.timestamp() + " " + message + "\n").data(using: .utf8) else {
            return
        }
        let directory = fileURL.deletingLastPathComponent()
        let fileManager = FileManager.default
        _ = try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: fileURL.path),
           let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { _ = try? handle.close() }
            _ = try? handle.seekToEnd()
            _ = try? handle.write(data)
        } else {
            _ = try? fileManager.createFile(atPath: fileURL.path, contents: data)
        }
    }

    /// Human-readable name for an `EKAuthorizationStatus`, e.g.
    /// `notDetermined(0)`, `restricted(1)`, `denied(2)`, `fullAccess(3)`,
    /// `writeOnly(4)`; unknown values render as `unknown(<raw>)`.
    static func statusName(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "notDetermined(0)"
        case .restricted:
            return "restricted(1)"
        case .denied:
            return "denied(2)"
        case .fullAccess:
            return "fullAccess(3)"
        case .writeOnly:
            return "writeOnly(4)"
        @unknown default:
            return "unknown(\(status.rawValue))"
        }
    }

    /// Human-readable name for a `CalendarAccess` outcome.
    static func accessName(_ access: CalendarAccess) -> String {
        switch access {
        case .notDetermined:
            return "notDetermined"
        case .granted:
            return "granted"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        }
    }

    /// Default log destination: `~/Library/Logs/Oatmeal/calendar.log`.
    static var defaultLogFileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/Oatmeal/calendar.log", isDirectory: false)
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func timestamp() -> String {
        timestampFormatter.string(from: Date())
    }
}

/// Checks current Calendar access, requesting it when a request can help.
///
/// Distinction that matters here:
/// - `.denied` means the user already said no; only System Settings can change
///   it, so we never re-prompt.
/// - `.notDetermined` and `.writeOnly` are requestable states: `.notDetermined`
///   has never been asked, and `.writeOnly` has a partial grant that
///   `requestFullAccessToEvents()` can upgrade to full access. Both MUST be
///   attempted before reporting a failure — macOS raises a real prompt in
///   both states.
/// - `.restricted` cannot be granted locally at all (MDM/parental controls);
///   it is surfaced as `.restricted` so the UI can say something different
///   from a plain "denied".
///
/// A throwing or failed request is caught and reported as `.denied`; it is
/// never propagated. Returns `.granted` as soon as full access is in hand.
func checkOrRequestAccess(
    _ source: CalendarSource,
    isAppActive: Bool = false
) async -> CalendarAccess {
    let statusBefore = source.authorizationStatus()
    CalendarDiagnostics.log(
        "attempt start: statusBefore=\(CalendarDiagnostics.statusName(statusBefore)) "
        + "appActive=\(isAppActive)"
    )
    let result: CalendarAccess
    switch statusBefore {
    case .fullAccess:
        // `.authorized` (deprecated) is the same value (3), so this one case
        // covers both.
        result = .granted
    case .notDetermined:
        result = await requestFullAccessLogging(source: source) ? .granted : .denied
    case .writeOnly:
        // A write-only grant cannot list events, so it is not usable — but we
        // must TRY to upgrade it to full access before saying so.
        result = await requestFullAccessLogging(source: source) ? .granted : .denied
    case .denied:
        result = .denied
    case .restricted:
        result = .restricted
    @unknown default:
        result = .denied
    }
    let statusAfter = source.authorizationStatus()
    CalendarDiagnostics.log(
        "attempt end: statusAfter=\(CalendarDiagnostics.statusName(statusAfter)) "
        + "result=\(CalendarDiagnostics.accessName(result))"
    )
    return result
}

/// Runs `requestFullAccessToEvents()` exactly once and logs what actually
/// happened — the returned `Bool`, or the thrown error if it threw. Always
/// returns a `Bool` (a thrown error becomes `false`), preserving the original
/// `try?`-based decision logic: `true` → `.granted`, anything else → `.denied`.
/// Fail-soft: the logging never affects the outcome.
private func requestFullAccessLogging(source: CalendarSource) async -> Bool {
    do {
        let granted = try await source.requestFullAccessToEvents()
        CalendarDiagnostics.log("requestFullAccessToEvents returned: \(granted)")
        return granted
    } catch {
        CalendarDiagnostics.log(
            "requestFullAccessToEvents threw: \(error) "
            + "(localized: \(error.localizedDescription))"
        )
        return false
    }
}

/// Builds a `RawEvent` from an `EKEvent`. The stable id prefers
/// `calendar.calendarIdentifier|eventIdentifier`; falls back to the
/// identifier alone, then `nil`.
func rawEvent(from event: EKEvent) -> RawEvent {
    let calendarID = event.calendar.calendarIdentifier
    let id: String?
    if let eventID = event.eventIdentifier {
        id = calendarID.isEmpty ? eventID : "\(calendarID)|\(eventID)"
    } else {
        id = calendarID.isEmpty ? nil : calendarID
    }
    return RawEvent(
        id: id,
        title: event.title ?? "",
        start: event.startDate,
        end: event.endDate,
        attendees: event.attendees?.compactMap { $0.name } ?? [],
        notes: event.notes
    )
}

/// Fetches events in `[now − 1h, now + 2h]`, maps and sorts them.
/// `now` is injectable for determinism.
struct EventListProvider {
    var source: CalendarSource

    /// Builds a provider over the given source. Defaults to a fresh real
    /// `EKEventStore`; pass an already-created source to use ONE store for
    /// both the access check and the event fetch within a single flow.
    init(source: CalendarSource = EKCalendarSource()) {
        self.source = source
    }

    /// Window bounds relative to "now", in seconds.
    static let windowBeforeSeconds: TimeInterval = 3600
    static let windowAfterSeconds: TimeInterval = 7200

    func fetchCalendarEvents(now: Date = Date()) -> [MeetingEvent] {
        let windowStart = now.addingTimeInterval(-Self.windowBeforeSeconds)
        let windowEnd = now.addingTimeInterval(Self.windowAfterSeconds)
        let mapped = mapEvents(source.events(start: windowStart, end: windowEnd).map(rawEvent(from:)))
        return sortEvents(filterEvents(mapped, in: (start: windowStart, end: windowEnd)))
    }
}
