import Foundation
import XCTest
import EventKit
@testable import Oatmeal

// CAL3.T3: tests the ordering contract of
// `StatusItemController.runCalendarRequestActivated` — activate FIRST (main
// thread), then read the app's active state (with a bounded settle wait),
// then issue the request with the OBSERVED state threaded through.
//
// These tests use injected closures, so they pin the ordering and the
// pass-through without a live AppKit environment. They do NOT verify real
// AppKit activation, real TCC prompting, or the prompt being attributed to
// Oatmeal — that is the lead's manual verification.

final class CalendarActivationTests: XCTestCase {

    /// Fake `CalendarSource` (same pattern as `CalendarServiceTests`).
    /// No live EventKit, no real calendar data.
    private final class FakeCalendarSource: CalendarSource {
        var status: EKAuthorizationStatus
        private(set) var requestCount = 0

        init(status: EKAuthorizationStatus) {
            self.status = status
        }

        func authorizationStatus() -> EKAuthorizationStatus {
            status
        }

        func requestFullAccessToEvents() async throws -> Bool {
            requestCount += 1
            return true
        }

        func events(start: Date, end: Date) -> [EKEvent] {
            []
        }
    }

    func testActivateRunsBeforeActiveReadAndRequestAndRequestReceivesIt() async {
        var order: [String] = []
        let result = await StatusItemController.runCalendarRequestActivated(
            activate: { order.append("activate") },
            isAppActive: {
                order.append("readActive")
                return true
            },
            request: { active in
                order.append("request(\(active))")
                return .granted
            },
            settleTimeout: 0,
            pollInterval: 0
        )
        XCTAssertEqual(result, .granted)
        // The contract: activate → read active state → request, and the
        // request receives the value that was read.
        XCTAssertEqual(order, ["activate", "readActive", "request(true)"])
    }

    func testRequestReceivesFalseWhenAppNeverBecomesActive() async {
        var reads = 0
        let result = await StatusItemController.runCalendarRequestActivated(
            activate: {},
            isAppActive: {
                reads += 1
                return false
            },
            request: { active in
                active ? .granted : .denied
            },
            settleTimeout: 0.05,
            pollInterval: 0.01
        )
        // Honest pass-through: the request gets the OBSERVED state (false),
        // not an assumed default, and the settle wait is bounded (it polls
        // more than once and then gives up at the deadline).
        XCTAssertEqual(result, .denied)
        XCTAssertGreaterThan(reads, 1)
    }

    func testAppBecomingActiveDuringSettleIsObserved() async {
        var reads = 0
        let result = await StatusItemController.runCalendarRequestActivated(
            activate: {},
            isAppActive: {
                reads += 1
                return reads >= 3
            },
            request: { active in
                active ? .granted : .denied
            },
            settleTimeout: 0.5,
            pollInterval: 0.01
        )
        // The settle loop keeps polling until activation is observed.
        XCTAssertEqual(result, .granted)
        XCTAssertEqual(reads, 3)
    }

    func testActiveStateIsThreadedIntoDecisionFunction() async {
        var forwarded: [Bool] = []
        let fake = FakeCalendarSource(status: .fullAccess)
        let result = await StatusItemController.runCalendarRequestActivated(
            activate: {},
            isAppActive: { true },
            request: { active in
                forwarded.append(active)
                return await checkOrRequestAccess(fake, isAppActive: active)
            },
            settleTimeout: 0,
            pollInterval: 0
        )
        XCTAssertEqual(result, .granted)
        // The observed state is what `checkOrRequestAccess` receives — never
        // the omitted `false` default.
        XCTAssertEqual(forwarded, [true])
        // `.fullAccess` short-circuits: no request was actually made.
        XCTAssertEqual(fake.requestCount, 0)
    }
}
