import Foundation
import XCTest
import EventKit
@testable import Oatmeal

/// Fake `CalendarSource` that scripts the authorization status and the
/// request outcome, and records how many times the request was attempted.
/// No live EventKit, no real calendar data.
private final class FakeCalendarSource: CalendarSource {
    var status: EKAuthorizationStatus
    var requestResult: Result<Bool, Error>
    private(set) var requestCount = 0

    private struct FakeRequestError: Error {}

    init(status: EKAuthorizationStatus, requestSucceeds: Bool) {
        self.status = status
        self.requestResult = requestSucceeds
            ? .success(true)
            : .failure(FakeRequestError())
    }

    func authorizationStatus() -> EKAuthorizationStatus {
        status
    }

    func requestFullAccessToEvents() async throws -> Bool {
        requestCount += 1
        return try requestResult.get()
    }

    func events(start: Date, end: Date) -> [EKEvent] {
        []
    }
}

final class CalendarServiceTests: XCTestCase {

    func testNotDeterminedRequestSucceedsReturnsGrantedAndRequestsOnce() async {
        let fake = FakeCalendarSource(status: .notDetermined, requestSucceeds: true)
        let result = await checkOrRequestAccess(fake)
        XCTAssertEqual(result, .granted)
        XCTAssertEqual(fake.requestCount, 1)
    }

    func testNotDeterminedRequestFailsReturnsDenied() async {
        let fake = FakeCalendarSource(status: .notDetermined, requestSucceeds: false)
        let result = await checkOrRequestAccess(fake)
        XCTAssertEqual(result, .denied)
        XCTAssertEqual(fake.requestCount, 1)
    }

    func testWriteOnlyUpgradeSucceedsReturnsGrantedAndRequestsOnce() async {
        // The upgrade path: a write-only grant must be upgraded via the
        // request, and that request must actually be made.
        let fake = FakeCalendarSource(status: .writeOnly, requestSucceeds: true)
        let result = await checkOrRequestAccess(fake)
        XCTAssertEqual(result, .granted)
        XCTAssertEqual(fake.requestCount, 1)
    }

    func testWriteOnlyUpgradeFailsReturnsDeniedAfterAttemptingRequest() async {
        let fake = FakeCalendarSource(status: .writeOnly, requestSucceeds: false)
        let result = await checkOrRequestAccess(fake)
        XCTAssertEqual(result, .denied)
        XCTAssertEqual(fake.requestCount, 1)
    }

    func testFullAccessReturnsGrantedWithoutAnyRequest() async {
        let fake = FakeCalendarSource(status: .fullAccess, requestSucceeds: true)
        let result = await checkOrRequestAccess(fake)
        XCTAssertEqual(result, .granted)
        XCTAssertEqual(fake.requestCount, 0)
    }

    func testDeniedReturnsDeniedWithoutAnyRequest() async {
        let fake = FakeCalendarSource(status: .denied, requestSucceeds: true)
        let result = await checkOrRequestAccess(fake)
        XCTAssertEqual(result, .denied)
        XCTAssertEqual(fake.requestCount, 0)
    }

    func testRestrictedReturnsRestrictedNotDenied() async {
        let fake = FakeCalendarSource(status: .restricted, requestSucceeds: true)
        let result = await checkOrRequestAccess(fake)
        XCTAssertEqual(result, .restricted)
        XCTAssertEqual(fake.requestCount, 0)
    }

    // MARK: - Single-source flow (CAL2.T4)

    /// Fake source that serves a canned event list and records how many times
    /// `events(start:end:)` was called, so tests can prove that the provider
    /// uses the INJECTED source rather than building its own.
    private final class EventServingSource: CalendarSource {
        private let canned: [EKEvent]
        private(set) var eventsCallCount = 0

        init(events: [EKEvent]) {
            canned = events
        }

        func authorizationStatus() -> EKAuthorizationStatus { .fullAccess }

        func requestFullAccessToEvents() async throws -> Bool { true }

        func events(start: Date, end: Date) -> [EKEvent] {
            eventsCallCount += 1
            return canned
        }
    }

    /// Builds an in-memory `EKEvent` (no live calendar, no permission needed).
    private func makeEvent(title: String, start: Date) -> EKEvent {
        let store = EKEventStore()
        let calendar = EKCalendar(for: .event, eventStore: store)
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.startDate = start
        event.endDate = start.addingTimeInterval(1800)
        return event
    }

    func testInjectedSourceIsTheOneThatServesEvents() async {
        let now = Date(timeIntervalSinceReferenceDate: 1_700_000_000)
        let fake = EventServingSource(events: [
            makeEvent(title: "Standup", start: now)
        ])
        // ONE source, used for BOTH the access check and the event fetch —
        // the same seam the controller now threads through the flow.
        let provider = EventListProvider(source: fake)
        let access = await checkOrRequestAccess(provider.source)
        XCTAssertEqual(access, .granted)
        _ = provider.fetchCalendarEvents(now: now)
        XCTAssertEqual(fake.eventsCallCount, 1)
    }

    func testFetchCalendarEventsReturnsMappedSortedEventsFromInjectedSource() {
        let now = Date(timeIntervalSinceReferenceDate: 1_700_000_000)
        // Out of order on purpose: the provider must sort by start.
        let later = makeEvent(title: "Later meeting", start: now.addingTimeInterval(3600))
        let earlier = makeEvent(title: "Earlier meeting", start: now.addingTimeInterval(-1800))
        let fake = EventServingSource(events: [later, earlier])
        let provider = EventListProvider(source: fake)
        let events = provider.fetchCalendarEvents(now: now)
        XCTAssertEqual(events.map(\.title), ["Earlier meeting", "Later meeting"])
        XCTAssertEqual(fake.eventsCallCount, 1)
    }

    func testFetchCalendarEventsDropsEventsOutsideWindow() {
        let now = Date(timeIntervalSinceReferenceDate: 1_700_000_000)
        let inside = makeEvent(title: "In window", start: now)
        let farPast = makeEvent(
            title: "Far past",
            start: now.addingTimeInterval(-7200) // beyond the 1h lookback
        )
        let fake = EventServingSource(events: [farPast, inside])
        let provider = EventListProvider(source: fake)
        let events = provider.fetchCalendarEvents(now: now)
        XCTAssertEqual(events.map(\.title), ["In window"])
        XCTAssertEqual(fake.eventsCallCount, 1)
    }
}
