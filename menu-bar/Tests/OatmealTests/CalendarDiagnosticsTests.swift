import Foundation
import XCTest
import EventKit
@testable import Oatmeal

/// Fake `CalendarSource` that scripts the authorization status and the
/// request outcome, and records how many times the request was attempted.
/// (Same pattern as `FakeCalendarSource` in `CalendarServiceTests`, which is
/// private there, so it is duplicated here rather than modified.)
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

final class CalendarDiagnosticsTests: XCTestCase {

    // MARK: - Status-name mapping (readability contract)

    func testStatusNameMapsAllKnownStatuses() {
        XCTAssertEqual(CalendarDiagnostics.statusName(.notDetermined), "notDetermined(0)")
        XCTAssertEqual(CalendarDiagnostics.statusName(.restricted), "restricted(1)")
        XCTAssertEqual(CalendarDiagnostics.statusName(.denied), "denied(2)")
        XCTAssertEqual(CalendarDiagnostics.statusName(.fullAccess), "fullAccess(3)")
        XCTAssertEqual(CalendarDiagnostics.statusName(.writeOnly), "writeOnly(4)")
    }

    // MARK: - Behavior preservation (CAL3.T1: diagnostics must not change outcomes)

    func testFullAccessReturnsGrantedWithoutAnyRequest() async {
        let fake = FakeCalendarSource(status: .fullAccess, requestSucceeds: true)
        let result = await checkOrRequestAccess(fake)
        XCTAssertEqual(result, .granted)
        XCTAssertEqual(fake.requestCount, 0)
    }

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

    // MARK: - Log file is actually written (fail-soft, no crash)

    func testLogAppendsTimestampedLineToCalendarLog() throws {
        let marker = "CAL3.T1-marker-\(UUID().uuidString)"
        // Point the log at a temp file via the internal seam; the production
        // entry point `log(_:)` uses `~/Library/Logs/Oatmeal/calendar.log`.
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OatmealTest/calendar.log")
        CalendarDiagnostics.log(marker, to: fileURL)
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains(marker), "log line should be appended")
        // Each line is timestamped: the line containing the marker must start
        // with an ISO-8601 date.
        if let line = contents.split(separator: "\n").first(where: { $0.contains(marker) }) {
            XCTAssertTrue(
                line.hasPrefix("20"),
                "expected an ISO-8601 timestamp prefix, got: \(line)"
            )
        } else {
            XCTFail("marker line not found as its own line")
        }
    }
}
