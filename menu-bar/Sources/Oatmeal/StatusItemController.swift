import AppKit
import EventKit

/// Owns the `NSStatusItem` and drives all UI state (MB-SW3).
///
/// - Icon: a two-state swap — idle shows the `icon-white` template glyph,
///   recording shows the distinct full-color `icon-recording` image (non-template).
///   The OS's separate recording privacy indicator also appears while recording
///   (kept as-is; never hidden).
/// - Refresh is **lazy**: the button-click handler (`togglePressed`) rebuilds
///   the menu and icon from the locally-tracked live state — no subprocess on
///   the open path, no timers/polling.
/// - Start is a quick synchronous CLI call; Stop is dispatched to a background
///   queue (it blocks 1–3 min transcribing) and the icon flips to idle
///   **immediately**, per the brief.
///
/// The controller only shells out to `mr` via `MRCLI` — it never spawns
/// `mr-capture` and never touches the pidfile/heartbeat files (read-only).
final class StatusItemController: NSObject {
    let statusItem: NSStatusItem
    let menuBuilder: MenuBuilder

    /// Base for the transcription heartbeat: the current resolved `out_root`
    /// from `mr config get out_root` (MB-SW4), falling back to `~/Meetings`
    /// (the `mr` default) when the CLI is unavailable or errors. Computed
    /// (not stored) so a storage-location change is picked up on the next use
    /// (the "Check Active Transcriptions…" item in MB-DISPLAY/D2).
    private var transcriptionBase: URL {
        if let root = StorageLocation.currentRoot() {
            return URL(fileURLWithPath: root)
        }
        return URL(fileURLWithPath: ("~/Meetings" as NSString).expandingTildeInPath)
    }

    private var isLiveRecording = false

    /// Floating side pill shown while recording; clicking it stops the recording.
    private let floatingIndicator = FloatingRecordingIndicator()

    /// Events fetched by `startRecordingFromCalendar`, indexed by the row tag
    /// of the dynamic submenu items so selection maps back to the meeting.
    /// Set on the main thread just before the submenu pops; read only there.
    private var pendingMeetingEvents: [MeetingEvent] = []

    /// Stamp shown in the "Check Active Transcriptions…" alert, set just before
    /// `runModal` so the Stop button knows what to stop. Main thread only.
    private var pendingStopStamp: String?

    /// Whether `mr` can be resolved (fixed at launch; resolving once avoids a
    /// `which mr` subprocess on every menu open).
    private let cliAvailable: Bool

    override init() {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.menuBuilder = MenuBuilder()
        // Resolving `mr` here (before super.init — required for stored lets)
        // is the app's single `which mr` spawn: the app's environment is fixed
        // at launch, so the result never needs re-resolving.
        self.cliAvailable = AppInfo.resolveMrInvocation() != nil
        super.init()
        self.menuBuilder.target = self
        floatingIndicator.onClick = { [weak self] in self?.stopRecording(nil) }

        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePressed(_:))
        setLive(false)
    }

    // MARK: - Icon

    /// Sets the status-item icon to the state-appropriate glyph.
    /// - Idle: the `icon-white` template image (AppKit tints it to match the
    ///   menu-bar appearance, giving the built-in active/click highlight).
    /// - Recording: the distinct full-color `icon-recording` image, rendered
    ///   non-template so its colors show as drawn. (The OS's separate
    ///   recording privacy indicator also appears; it is kept, never hidden.)
    private func setLive(_ live: Bool) {
        isLiveRecording = live
        if live { floatingIndicator.show() } else { floatingIndicator.hide() }
        guard let button = statusItem.button else { return }
        // Two-state swap: `icon-white` (template) when idle, `icon-recording`
        // (full-color, non-template) while recording. No tint is applied in
        // either state — template rendering tints the idle glyph itself.
        let resourceName = live ? "icon-recording" : "icon-white"
        if let url = Bundle.module.url(forResource: resourceName, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = !live
            image.size = NSSize(width: 18, height: 18)
            button.image = image
        } else {
            button.image = NSImage(
                systemSymbolName: "mic.fill",
                accessibilityDescription: live ? "Recording" : "Idle"
            )
        }
        button.contentTintColor = nil
        button.image?.accessibilityDescription = live ? "Recording" : "Idle"
        button.needsDisplay = true
    }

    // MARK: - Lazy refresh (main thread)

    /// Rebuilds icon + menu from locally-tracked live state. Called on menu
    /// open (and after start/stop) — never on a timer, and never with a
    /// subprocess (see the comment inside).
    func refresh() {
        // No subprocess on the open path: running `mr status` / `which mr` here on
        // the main thread blocked the status-bar tracking event and made the
        // dropdown fail to open while recording. Live state is tracked locally by
        // start/stop; the explicit "Check Active Transcriptions…" item queries the
        // CLI on demand.
        setLive(isLiveRecording)
        let status = MRStatus(recording: isLiveRecording, pid: nil, stamp: nil, startedAt: nil)
        menuBuilder.rebuild(status: status, isCLIAvailable: cliAvailable)
        statusItem.button?.needsDisplay = true
    }

    /// Button click handler — the ONLY way the dropdown opens. Refreshes state,
    /// then pops the menu up explicitly. Because popUp is invoked from a
    /// completed, separate click event, nothing inside the menu can be
    /// auto-activated by the SAME click that opened it (unlike assigning
    /// `.menu` directly, which lets AppKit treat open+click as one gesture).
    @objc func togglePressed(_ sender: Any?) {
        refresh()
        guard let button = statusItem.button else { return }
        // Anchor at the button's bottom edge with NO manual offset. The old
        // `maxY + 4` was tuned when an inert "(idle)" label was row 1 and a
        // few points of slop went unnoticed; now that row 1 is a real,
        // highlightable item, AppKit re-positions the menu as soon as the
        // cursor enters it — which is the "jump" (first item clipped, then the
        // menu shifting down and sitting off the menu bar).
        menuBuilder.menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.maxY),
            in: button
        )
    }

    // MARK: - Actions (target of the menu items)

    /// "Start Recording" → `mr start` on a background queue. Exit 0 (incl.
    /// "already recording") means live; the item turns red only **after** the
    /// CLI returns, so the menu/open tracking is never blocked by the
    /// subprocess.
    @objc func startRecording(_ sender: Any?) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Fresh MRCLI inside the closure: no shared-state races with the
            // main thread (invocation is re-resolved; that is fine).
            var failure: (title: String, detail: String)? = nil
            var success = false
            do {
                let (out, exit) = try MRCLI().start()
                if exit == 0 {
                    success = true
                } else {
                    failure = ("Could not start recording",
                               out.isEmpty ? "mr start failed." : "mr start reported: \(out)")
                }
            } catch {
                if let e = error as? MRCLIError {
                    switch e {
                    case .mrUnavailable:
                        failure = ("mr CLI not found",
                                   "Neither a 'mr' command on PATH nor the MR_PYTHON environment " +
                                   "variable is available to this app. Start the app with MR_PYTHON " +
                                   "set, or install mr on PATH.")
                    case .processTimeout:
                        failure = ("mr did not respond",
                                   "The mr CLI did not finish within the timeout.")
                    }
                } else {
                    failure = ("mr CLI not found", "The mr CLI could not be launched.")
                }
            }
            guard let self else { return }
            DispatchQueue.main.async {
                if success {
                    self.setLive(true)
                }
                if let failure {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = failure.title
                    alert.informativeText = failure.detail
                    alert.runModal()
                }
                self.statusItem.button?.needsDisplay = true
            }
        }
    }

    /// "Stop Recording & Transcribe" → `mr stop` on a background queue.
    /// The icon flips to idle **immediately**; transcription (1–3 min) runs
    /// without blocking the menu bar. A later status read returns
    /// "recording: no", so idle stays correct.
    @objc func stopRecording(_ sender: Any?) {
        setLive(false)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Fresh MRCLI inside the closure: no shared-state races with the
            // main thread (invocation is re-resolved; that is fine).
            var failure: (title: String, detail: String)? = nil
            do {
                let (out, exit) = try MRCLI().stop()
                if exit != 0 {
                    failure = ("Could not stop recording",
                               out.isEmpty ? "mr stop failed." : "mr stop reported: \(out)")
                }
            } catch {
                if let e = error as? MRCLIError {
                    switch e {
                    case .mrUnavailable:
                        failure = ("mr CLI not found",
                                   "Neither a 'mr' command on PATH nor the MR_PYTHON environment " +
                                   "variable is available to this app. Start the app with MR_PYTHON " +
                                   "set, or install mr on PATH.")
                    case .processTimeout:
                        failure = ("mr did not respond",
                                   "The mr CLI did not finish within the timeout.")
                    }
                } else {
                    failure = ("mr CLI not found", "The mr CLI could not be launched.")
                }
            }
            guard let self else { return }
            DispatchQueue.main.async {
                if let failure {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = failure.title
                    alert.informativeText = failure.detail
                    alert.runModal()
                }
                self.statusItem.button?.needsDisplay = true
            }
        }
    }

    /// "Check Active Transcriptions…" → on-demand, OFF the main thread. Queries
    /// `mr status` + the heartbeat, syncs live state, and reports the result in
    /// an alert.
    ///
    /// The result MUST go somewhere that outlives the menu: clicking a menu
    /// item dismisses the dropdown, and the next open calls
    /// `MenuBuilder.rebuild`, which removes and recreates every row. An
    /// in-place retitle of the clicked row (what this used to do) was therefore
    /// written to an item nobody could see and discarded on the next open —
    /// the item looked like it did nothing at all.
    @objc func checkActiveTranscriptions(_ sender: Any?) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var recording = false
            let cli = MRCLI()
            if let (out, exit) = try? cli.status(), exit == 0 {
                recording = MRStatus.parse(out).recording
            }
            // Report the in-flight transcription (fresh heartbeat) if any; else "None".
            let base = self.transcriptionBase
            let heartbeat = TranscriptionState(baseURL: base).activeHeartbeat()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isLiveRecording = recording
                self.setLive(recording)

                let alert = NSAlert()
                alert.alertStyle = .informational
                // Fresh stamp for this alert (a stale one must never be reused);
                // cleared again after the modal in case the user never stops.
                self.pendingStopStamp = nil
                if let heartbeat {
                    alert.messageText = "Transcription in progress"
                    var detail = MenuBuilder.transcriptionResultText(stamp: heartbeat.stamp)
                    if let startedAt = heartbeat.startedAt {
                        let elapsed = Int(Date().timeIntervalSince(startedAt))
                        detail += "\nRunning for \(elapsed / 60)m \(elapsed % 60)s."
                    }
                    detail += "\n\nThe transcript appears in the transcripts folder when it finishes."
                    alert.informativeText = detail
                    alert.addButton(withTitle: "Stop Transcription")
                    alert.addButton(withTitle: "OK")
                    pendingStopStamp = heartbeat.stamp
                } else {
                    alert.messageText = "No active transcription"
                    alert.informativeText =
                        MenuBuilder.transcriptionResultText(stamp: nil) +
                        "\n\nIf a recording finished without producing a transcript, check " +
                        "the transcripts folder for a `.FAILED.md` file."
                    alert.addButton(withTitle: "OK")
                }
                let response = alert.runModal()
                if response == .alertFirstButtonReturn, let stamp = self.pendingStopStamp {
                    self.stopActiveTranscription(stamp)
                }
                self.pendingStopStamp = nil
                self.statusItem.button?.needsDisplay = true
            }
        }
    }

    /// "Stop Transcription" (first button of the "Check Active Transcriptions…"
    /// alert) → `mr stop-transcribe <stamp>` on a background queue. Exit 0
    /// (incl. "already finished") posts the app-branded "Transcription stopped"
    /// notification and confirms in an alert; any other outcome warns.
    private func stopActiveTranscription(_ stamp: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Fresh MRCLI inside the closure: no shared-state races with the
            // main thread (invocation is re-resolved; that is fine).
            var failure: (title: String, detail: String)? = nil
            do {
                let (out, exit) = try MRCLI().stopTranscribe(stamp: stamp)
                if exit == 0 {
                    // Honest and useful in the "already finished" case: the CLI
                    // line ("\<stamp> already finished") goes in the alert too.
                    TranscriptNotifier.postTranscriptionStopped(stamp: stamp)
                    var detail = "Transcription stopped for \(stamp)."
                    let outLine = out.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !outLine.isEmpty { detail += "\n\n\(outLine)" }
                    self?.showStoppedAlert(detail: detail)
                } else {
                    failure = ("Could not stop transcription",
                               out.isEmpty ? "mr stop-transcribe failed." : out)
                }
            } catch {
                if let e = error as? MRCLIError {
                    switch e {
                    case .mrUnavailable:
                        failure = ("Could not stop transcription",
                                   "Neither a 'mr' command on PATH nor the MR_PYTHON environment " +
                                   "variable is available to this app. Start the app with MR_PYTHON " +
                                   "set, or install mr on PATH.")
                    case .processTimeout:
                        failure = ("Could not stop transcription",
                                   "The mr CLI did not finish within the timeout.")
                    }
                } else {
                    failure = ("Could not stop transcription", "The mr CLI could not be launched.")
                }
            }
            guard let self else { return }
            DispatchQueue.main.async {
                if let failure {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = failure.title
                    alert.informativeText = failure.detail
                    alert.runModal()
                }
                self.statusItem.button?.needsDisplay = true
            }
        }
    }

    /// Shows the informational "Transcription stopped" confirmation. Always
    /// called on the main thread.
    private func showStoppedAlert(detail: String) {
        DispatchQueue.main.async { [weak self] in
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Transcription stopped"
            alert.informativeText = detail
            alert.runModal()
            self?.statusItem.button?.needsDisplay = true
        }
    }

    /// "Re-transcribe…" (menu row, tag 709 — disabled when the CLI is
    /// unavailable; `MenuBuilder` sets that). Resolves the storage root OFF the
    /// main thread, then pops the recording picker; the dialog itself handles
    /// the no-recordings case.
    @objc func reTranscribe(_ sender: Any?) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let root = StorageLocation.currentRoot()
            DispatchQueue.main.async {
                if root == nil {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Cannot re-transcribe"
                    alert.informativeText =
                        "The mr CLI is unavailable, so the current storage location is unknown."
                    alert.runModal()
                } else {
                    ReTranscribeDialog.present(root: root!) { stamp in
                        self.reTranscribe(stamp)
                    }
                }
                self.statusItem.button?.needsDisplay = true
            }
        }
    }

    /// Recording picker chose a stamp (already on the main thread) →
    /// `mr retranscribe <stamp>` on a background queue. Exit 0 spawns a
    /// DETACHED worker and returns promptly; the transcript lands in the
    /// transcripts folder when the worker finishes.
    private func reTranscribe(_ stamp: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Fresh MRCLI inside the closure: no shared-state races with the
            // main thread (invocation is re-resolved; that is fine).
            var failure: (title: String, detail: String)? = nil
            var success = false
            do {
                let (out, exit) = try MRCLI().retranscribe(stamp)
                if exit == 0 {
                    success = true
                } else {
                    failure = ("Could not re-transcribe",
                               out.isEmpty ? "mr retranscribe failed." : out)
                }
            } catch {
                if let e = error as? MRCLIError {
                    switch e {
                    case .mrUnavailable:
                        failure = ("Could not re-transcribe",
                                   "Neither a 'mr' command on PATH nor the MR_PYTHON environment " +
                                   "variable is available to this app. Start the app with MR_PYTHON " +
                                   "set, or install mr on PATH.")
                    case .processTimeout:
                        failure = ("Could not re-transcribe",
                                   "The mr CLI did not finish within the timeout.")
                    }
                } else {
                    failure = ("Could not re-transcribe", "The mr CLI could not be launched.")
                }
            }
            guard let self else { return }
            DispatchQueue.main.async {
                if success {
                    let alert = NSAlert()
                    alert.alertStyle = .informational
                    alert.messageText = "Re-transcribing"
                    alert.informativeText =
                        "Re-transcribing \(stamp). The transcript lands in the transcripts " +
                        "folder when it finishes."
                    alert.runModal()
                }
                if let failure {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = failure.title
                    alert.informativeText = failure.detail
                    alert.runModal()
                }
                self.statusItem.button?.needsDisplay = true
            }
        }
    }

    // MARK: - Calendar quick-start (CAL-L3)

/// CAL3.T3: issues a Calendar permission request with the app activated
/// first, so macOS raises a prompt attributed to Oatmeal instead of
/// silently recording a denial.
///
/// Ordering contract (pinned by `CalendarActivationTests`):
/// 1. `activate` runs first, on the main thread — this accessory app never
///    activates itself anywhere else, so without this the TCC request is
///    issued while another app is frontmost.
/// 2. The app's active state is then read on the main thread. Activation
///    is asynchronous, so the helper settles for at most `settleTimeout`
///    (polling every `pollInterval`, non-blocking via `Task.sleep`) before
///    reading the final value.
/// 3. Only then is the async `request` issued, receiving the observed
///    state so `checkOrRequestAccess` logs the app's ACTUAL active state
///    at request time — never an assumed default.
///
/// The closures are injectable so this ordering is unit-testable without
/// a live AppKit/TCC environment. The function is @MainActor so activation
/// and the state read happen on the main thread; the async `request` itself
/// still runs off the main thread (nonisolated async), so the main thread
/// is never blocked.
@MainActor
static func runCalendarRequestActivated(
    activate: @MainActor @escaping () -> Void,
    isAppActive: @MainActor @escaping () -> Bool,
    request: @escaping (_ isAppActive: Bool) async -> CalendarAccess,
    settleTimeout: TimeInterval = 0.5,
    pollInterval: TimeInterval = 0.025
) async -> CalendarAccess {
    activate()
    var active = false
    let deadline = Date().addingTimeInterval(settleTimeout)
    repeat {
        active = isAppActive()
        if active || Date() >= deadline { break }
        try? await Task.sleep(nanoseconds: UInt64(max(0, pollInterval) * 1_000_000_000))
    } while true
    return await request(active)
}

    /// "Start Recording from Calendar…" (top-level item, tag 708). Checks/requests
    /// Calendar access and fetches events in `[now−1h, now+2h]` OFF the main
    /// thread, then pops a dynamic submenu of those events. A denied or
    /// restricted state is surfaced as an actionable alert (settings deep-link
    /// and/or Try Again) — the calendar path never blocks a plain recording.
    @objc func startRecordingFromCalendar(_ sender: Any?) {
        guard let statusItem = statusItem.button else { return }
        let tag = MenuBuilder.calendarMenuTag
        let item = menuBuilder.menu.item(withTag: tag)
        let defaultTitle = item?.title ?? "Start Recording from Calendar…"
        item?.title = "Searching for events…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            // ONE store for the whole flow: created here (off the main
            // thread) and threaded through the access check, the event
            // fetch, and the "Try Again" re-check, so the store macOS
            // authorized is the store that reads the events.
            let source = EKCalendarSource()
            // CAL3.T4: capture the authorization status BEFORE the request —
            // purely for the alert's messaging. If the status is already
            // `.denied`, the TCC denial is STICKY: `requestFullAccessToEvents()`
            // will keep returning `false` and macOS will never prompt again,
            // so a "Try Again" button cannot help. If the status is requestable
            // (`.notDetermined` or `.writeOnly`), any denial came from declining
            // a real prompt, where "Try Again" is still meaningful. This read
            // does not influence `checkOrRequestAccess`'s decision at all.
            let origin = calendarDenialOrigin(for: source.authorizationStatus())
            // CAL3.T3: activate the app (main thread) BEFORE issuing the
            // request, so macOS raises the prompt attributed to Oatmeal
            // instead of silently recording a denial while another app is
            // frontmost. `requestFullAccessToEvents()` is async and
            // non-blocking, so awaiting it after activation is safe: the
            // main thread stays responsive and the prompt is presented over
            // the (now active) app. The REAL active state, read on the main
            // thread, is threaded into the decision function.
            Task { [weak self] in
                let access = await Self.runCalendarRequestActivated(
                    activate: { NSApp.activate() },
                    isAppActive: { NSApp.isActive },
                    request: { active in
                        await checkOrRequestAccess(source, isAppActive: active)
                    }
                )
                await self?.presentCalendarResult(
                    access: access,
                    origin: origin,
                    source: source,
                    statusItem: statusItem,
                    tag: tag,
                    defaultTitle: defaultTitle
                )
            }
        }
    }

    /// Main-thread flow for a calendar quick-start result. `.granted` fetches
    /// events (off the main thread) and pops the event submenu. Otherwise it
    /// shows the alert described by `calendarAlertPlan(for:)` and acts on the
    /// pressed button: "Open System Settings" deep-links to the Calendar
    /// privacy pane; "Try Again" re-runs `checkOrRequestAccess` and, on
    /// success, continues straight to the submenu — no second menu click.
    /// Every path restores the menu title and refreshes the status item.
    @MainActor
    private func presentCalendarResult(
        access: CalendarAccess,
        origin: CalendarDenialOrigin,
        source: CalendarSource,
        statusItem: NSStatusBarButton,
        tag: Int,
        defaultTitle: String
    ) async {
        if access == .granted {
            await self.showCalendarEventSubmenu(
                source: source,
                statusItem: statusItem, tag: tag, defaultTitle: defaultTitle
            )
            return
        }

        let response = self.runCalendarAccessAlert(
            plan: calendarAlertPlan(for: access, origin: origin)
        )
        self.menuBuilder.menu.item(withTag: tag)?.title = defaultTitle
        self.statusItem.button?.needsDisplay = true

        switch response {
        case .openSettings:
            // The documented deep link straight to the Calendar privacy pane.
            NSWorkspace.shared.open(Self.calendarSettingsURL)
        case .tryAgain:
            // CAL3.T3: the user may have switched apps while the alert was up,
            // so re-activate (this is already @MainActor) and read the REAL
            // active state on the main thread before the re-check, so the
            // decision function logs it and the prompt is attributed to
            // Oatmeal. `checkOrRequestAccess` is nonisolated async, so this
            // re-check runs off the main thread and re-raises the real prompt
            // when the state allows one. The SAME source from this flow is
            // re-checked — the store macOS authorized is the one that reads
            // the events.
            NSApp.activate()
            let recheck = await checkOrRequestAccess(source, isAppActive: NSApp.isActive)
            if recheck == .granted {
                await self.showCalendarEventSubmenu(
                    source: source,
                    statusItem: statusItem, tag: tag, defaultTitle: defaultTitle
                )
            } else {
                // Re-present the (possibly different) alert once more. A
                // second "Try Again" would only repeat the same result, so
                // this single re-check avoids an endless loop.
                // CAL3.T4: by the time we are here, the denial is STICKY
                // (either it was sticky before the prompt, or the user just
                // declined the real prompt), so the default `.stickyDenial`
                // origin is the honest one: this re-presented alert offers
                // Settings and the reset guidance, not another "Try Again".
                let recheckResponse = self.runCalendarAccessAlert(
                    plan: calendarAlertPlan(for: recheck)
                )
                self.menuBuilder.menu.item(withTag: tag)?.title = defaultTitle
                self.statusItem.button?.needsDisplay = true
                if recheckResponse == .openSettings {
                    NSWorkspace.shared.open(Self.calendarSettingsURL)
                }
            }
        case .dismiss:
            break
        }
    }

    /// The documented macOS deep link for the Calendar privacy pane.
    private static let calendarSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
    )!

    /// Fetches the current events OFF the main thread, then restores the menu
    /// title and pops the dynamic event submenu at the status item.
    @MainActor
    private func showCalendarEventSubmenu(
        source: CalendarSource,
        statusItem: NSStatusBarButton,
        tag: Int,
        defaultTitle: String
    ) async {
        // Fetch over the SAME source the flow already authorized, off the
        // main thread (the caller of `presentCalendarResult` may be on it).
        let provider = EventListProvider(source: source)
        let events = await Task.detached(priority: .userInitiated) {
            provider.fetchCalendarEvents()
        }.value
        self.menuBuilder.menu.item(withTag: tag)?.title = defaultTitle
        self.pendingMeetingEvents = events
        let sub = MenuBuilder.buildCalendarSubmenu(
            events,
            isEnabled: self.cliAvailable,
            target: self,
            action: #selector(StatusItemController.startRecordingWithCalendarEvent(_:))
        )
        sub.popUp(
            positioning: nil,
            at: NSPoint(x: statusItem.bounds.maxX, y: statusItem.bounds.maxY + 4),
            in: statusItem
        )
        self.statusItem.button?.needsDisplay = true
    }

    /// Presents the `NSAlert` described by `plan` (main thread) and reports
    /// which button the user pressed. Buttons are added in plan order, so the
    /// first is the default (`.alertFirstButtonReturn`). The mapping from the
    /// pressed button to a response lives in the pure, testable
    /// `calendarAlertResponse(plan:pressedButtonIndex:)`, which derives each
    /// button's index from the SAME flags that added the buttons — so a
    /// single-button alert can never be misread as a different action.
    @MainActor
    private func runCalendarAccessAlert(plan: CalendarAlertPlan?) -> CalendarAlertResponse {
        guard let plan else { return .dismiss }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = plan.title
        alert.informativeText = plan.message
        if plan.showsSettingsButton {
            alert.addButton(withTitle: "Open System Settings")
        }
        if plan.showsTryAgainButton {
            alert.addButton(withTitle: "Try Again")
        }
        // `NSApplication.ModalResponse` encodes the pressed button's position:
        // `alertFirstButtonReturn` (1000) + 0-based index, so the index is a
        // plain integer the pure mapping can reason about.
        let modal = alert.runModal()
        let buttonIndex = modal.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return calendarAlertResponse(plan: plan, pressedButtonIndex: buttonIndex)
    }

    /// One event row of the dynamic calendar submenu chosen → start a recording
    /// with that meeting attached via `mr start --context-json <tmp>`.
    @objc func startRecordingWithCalendarEvent(_ sender: Any?) {
        let index = (sender as? NSMenuItem)?.tag ?? -1
        guard pendingMeetingEvents.indices.contains(index) else { return }
        let meeting = pendingMeetingEvents[index]

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failure: (title: String, detail: String)? = nil
            var success = false
            let tmpPath = self?.writeContextTempFile(for: meeting)
            do {
                let (out, exit) = try MRCLI().start(withContextJSON: tmpPath)
                if exit == 0 {
                    success = true
                } else {
                    failure = ("Could not start recording",
                               out.isEmpty ? "mr start failed." : "mr start reported: \(out)")
                }
            } catch {
                if let e = error as? MRCLIError {
                    switch e {
                    case .mrUnavailable:
                        failure = ("mr CLI not found",
                                   "Neither a 'mr' command on PATH nor the MR_PYTHON environment " +
                                   "variable is available to this app. Start the app with MR_PYTHON " +
                                   "set, or install mr on PATH.")
                    case .processTimeout:
                        failure = ("mr did not respond",
                                   "The mr CLI did not finish within the timeout.")
                    }
                } else {
                    failure = ("mr CLI not found", "The mr CLI could not be launched.")
                }
            }
            if let tmpPath { try? FileManager.default.removeItem(atPath: tmpPath) }
            guard let self else { return }
            DispatchQueue.main.async {
                if success {
                    self.setLive(true)
                }
                if let failure {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = failure.title
                    alert.informativeText = failure.detail
                    alert.runModal()
                }
                self.statusItem.button?.needsDisplay = true
            }
        }
    }

    /// ISO8601 string for a meeting date ('' when nil), matching the repo's
    /// existing ISO8601DateFormatter convention (see `TranscriptionState`).
    /// `formatOptions` = internet date-time (no fractional seconds).
    private static func iso8601String(for date: Date?) -> String {
        guard let date else { return "" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// Writes the `--context-json` payload for a meeting to a uniquely-named
    /// file under the system temp dir and returns its path; nil on any failure.
    /// The caller deletes the file after `mr start` returns.
    private func writeContextTempFile(for meeting: MeetingEvent) -> String? {
        guard
            let json = MRCLI.buildContextJSON(
                title: meeting.title,
                eventID: meeting.id ?? "",
                start: StatusItemController.iso8601String(for: meeting.start),
                end: StatusItemController.iso8601String(for: meeting.end),
                attendees: meeting.attendees,
                notes: meeting.notes ?? ""
            )
        else { return nil }
        let stamp = String(format: "%.0f", Date().timeIntervalSince1970)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-context-\(stamp)-\(UInt32.random(in: 1..<UInt32.max)).json")
        do {
            try Data(json.utf8).write(to: url, options: .atomic)
            return url.path
        } catch {
            return nil
        }
    }

    // MARK: - Storage location (MB-SW4)

    /// "Change Storage Location…" → `NSOpenPanel` (directories only) →
    /// `mr config set out_root <dir>`.
    ///
    /// A menu-bar app has no window to sheet the panel onto, so `begin`
    /// (non-blocking) is used instead of `runModal` — the completion handler
    /// runs on the main thread, which is where the `NSAlert` confirmation must
    /// show.
    @objc func changeStorageLocation(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose Storage Location"
        panel.message = "New recordings & transcripts will go here. Existing files are NOT moved."
        panel.prompt = "Choose"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            panel.orderOut(nil)
            self?.changeRoot(url.path)
        }
    }

    /// Applies the chosen root via `mr config set out_root` (the app never
    /// writes config itself), then confirms or reports the CLI's error.
    /// Always called on the main thread.
    private func changeRoot(_ newRoot: String) {
        let result: (out: String, exit: Int32)
        do {
            result = try MRCLI().setOutRoot(newRoot)
        } catch {
            // `mr` unavailable or the process timed out (not a bad path).
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could not change storage location"
            alert.informativeText = "The mr CLI is unavailable or did not respond."
            alert.runModal()
            return
        }

        let alert = NSAlert()
        if result.exit == 0 {
            // Let the transcript watcher follow the move (it would otherwise
            // keep watching the old transcripts dir and stop notifying).
            let newRoot = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !newRoot.isEmpty {
                NotificationCenter.default.post(
                    name: .oatmealStorageRootChanged,
                    object: newRoot
                )
            }
            alert.alertStyle = .informational
            alert.messageText = "Storage location updated."
            alert.informativeText =
                "Recordings and transcripts for NEW sessions go to:\n\(result.out)\n" +
                "Existing files were not moved."
        } else {
            alert.alertStyle = .warning
            alert.messageText = "Could not set storage location"
            alert.informativeText = result.out.isEmpty ? "mr config set out_root failed." : result.out
        }
        alert.runModal()
    }

    // MARK: - Folder open (MB-SW4)

    /// "Open Folder ▸ Recordings" → open `<root>/recordings` in Finder.
    @objc func openRecordingsFolder(_ sender: Any?) {
        openSubfolder("recordings")
    }

    /// "Open Folder ▸ Transcripts" → open `<root>/transcripts` in Finder.
    @objc func openTranscriptsFolder(_ sender: Any?) {
        openSubfolder("transcripts")
    }

    /// Opens a subfolder of the current `out_root` (resolved via
    /// `mr config get out_root`). If the subfolder does not exist yet but the
    /// root does, open the root; if neither exists, tell the user the folder
    /// is created on first use.
    private func openSubfolder(_ sub: String) {
        guard let root = StorageLocation.currentRoot() else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Cannot open folder"
            alert.informativeText =
                "The mr CLI is unavailable, so the current storage location is unknown."
            alert.runModal()
            return
        }

        let dir = root + "/" + sub
        if FileManager.default.fileExists(atPath: dir) {
            _ = NSWorkspace.shared.openFile(dir)
        } else if FileManager.default.fileExists(atPath: root) {
            // Subfolder not created yet (no sessions recorded at this root).
            _ = NSWorkspace.shared.openFile(root)
        } else {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Folder does not exist yet"
            alert.informativeText = "It is created on first use."
            alert.runModal()
        }
    }

    /// "Quit" → terminate the app.
    @objc func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}

// MARK: - Calendar access alert planning (pure, AppKit-free)

/// Which button the user pressed in the calendar-access alert.
enum CalendarAlertResponse {
    case openSettings
    case tryAgain
    case dismiss
}

/// The content of the alert shown when Calendar access is not granted.
/// Pure data — no AppKit types — so the mapping is unit-testable.
struct CalendarAlertPlan {
    let title: String
    let message: String
    let showsSettingsButton: Bool
    let showsTryAgainButton: Bool
}

/// Where a `.denied` outcome came from — this decides whether a "Try Again"
/// button can possibly help (CAL3.T4).
enum CalendarDenialOrigin {
    /// The status was already `.denied` BEFORE the request: a STICKY TCC
    /// denial. `requestFullAccessToEvents()` will keep returning `false` and
    /// macOS will never prompt this app again, so "Try Again" cannot fix it —
    /// only System Settings or a `tccutil reset` can.
    case stickyDenial
    /// The status was requestable (`.notDetermined` or `.writeOnly`) and the
    /// user declined a real prompt — "Try Again" re-runs a request that can
    /// still help, so it remains a meaningful button.
    case declinedRequest
}

/// Pure, display-only mapping from the pre-request authorization status to
/// the denial origin used for alert messaging (CAL3.T4). Requestable states
/// mean any upcoming denial came from declining a real prompt; everything
/// else (including an already-recorded `.denied`) is sticky. This never
/// influences `checkOrRequestAccess`'s decision — it only picks the alert's
/// wording and button set.
func calendarDenialOrigin(for status: EKAuthorizationStatus) -> CalendarDenialOrigin {
    switch status {
    case .notDetermined, .writeOnly:
        return .declinedRequest
    default:
        return .stickyDenial
    }
}

/// Maps a `CalendarAccess` outcome (and, for `.denied`, WHERE that denial
/// came from) to the alert that should be shown, or `nil` when no alert is
/// needed (access is already granted).
///
/// - `.denied` from a STICKY denial: macOS remembers the denial and will not
///   ask again, so the alert must not promise "Try Again" will fix it — it
///   offers "Open System Settings" (primary) and explains the `tccutil
///   reset Calendar` route as the only way to get a fresh prompt.
/// - `.denied` from a DECLINED prompt: the state was requestable, so
///   "Try Again" is still meaningful and is offered alongside Settings.
/// - `.restricted`: a management profile or parental controls blocks Calendar
///   on this Mac — no request can help, so there is no settings button and
///   the message must not suggest Settings will fix it.
func calendarAlertPlan(
    for access: CalendarAccess,
    origin: CalendarDenialOrigin = .stickyDenial
) -> CalendarAlertPlan? {
    switch access {
    case .granted:
        return nil
    case .denied:
        if origin == .declinedRequest {
            return CalendarAlertPlan(
                title: "Calendar access not granted",
                message:
                    "A calendar meeting is needed to start a recording with context. " +
                    "Grant Calendar access in System Settings ▸ Privacy & Security ▸ " +
                    "Calendars, or press Try Again to check once more.",
                showsSettingsButton: true,
                showsTryAgainButton: true
            )
        }
        return CalendarAlertPlan(
            title: "Calendar access is already denied",
            message:
                "A calendar meeting is needed to start a recording with context. " +
                "macOS remembers a Calendar denial and will not ask again, so pressing " +
                "Try Again cannot fix this. Enable Oatmeal in System Settings ▸ Privacy " +
                "& Security ▸ Calendars (use the pane's + button if Oatmeal is not " +
                "listed), or run 'tccutil reset Calendar' in Terminal and click the " +
                "menu item again to make the prompt reappear.",
            showsSettingsButton: true,
            showsTryAgainButton: false
        )
    case .restricted:
        return CalendarAlertPlan(
            title: "Calendar access is blocked",
            message:
                "Calendar access is blocked by a management profile or parental " +
                "controls on this Mac, so the app can't be granted access here. " +
                "Ask the administrator who manages this computer to allow it.",
            showsSettingsButton: false,
            showsTryAgainButton: false
        )
    case .notDetermined:
        // `checkOrRequestAccess` resolves `.notDetermined` to `.granted` or
        // `.denied` (it raises the real prompt first), so this is a fallback
        // for the still-requestable case.
        return calendarAlertPlan(for: .denied, origin: .declinedRequest)
    }
}

/// Pure button→response mapping for the calendar-access alert, testable
/// without AppKit (CAL3.T4).
///
/// `pressedButtonIndex` is the 0-based index of the button the user pressed,
/// in the order the plan added the buttons (the first added button is index
/// 0 — matching `NSApplication.ModalResponse`, whose values are
/// `alertFirstButtonReturn` (1000) + index). The mapping walks the SAME
/// flags that added the buttons, so each button can only ever map to the
/// action it represents: a single-button alert can never be misread as a
/// different action, and any index the plan did not add is a plain dismiss.
func calendarAlertResponse(
    plan: CalendarAlertPlan?,
    pressedButtonIndex: Int
) -> CalendarAlertResponse {
    guard let plan, pressedButtonIndex >= 0 else { return .dismiss }
    var index = 0
    if plan.showsSettingsButton {
        if pressedButtonIndex == index { return .openSettings }
        index += 1
    }
    if plan.showsTryAgainButton {
        if pressedButtonIndex == index { return .tryAgain }
        index += 1
    }
    return .dismiss
}
