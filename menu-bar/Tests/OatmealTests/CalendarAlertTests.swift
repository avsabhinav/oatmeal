import XCTest
import EventKit
@testable import Oatmeal

/// Tests the pure `CalendarAccess` → alert mapping
/// (`calendarAlertPlan(for:origin:)`), the pre-request status → denial-origin
/// mapping (`calendarDenialOrigin(for:)`), and the pure button→response
/// mapping (`calendarAlertResponse(plan:pressedButtonIndex:)`) used by the
/// "Start Recording from Calendar…" flow. No live EventKit, no AppKit UI.
final class CalendarAlertTests: XCTestCase {

    func testGrantedNeedsNoAlert() {
        // Access already granted → no alert at all; the event submenu is shown.
        XCTAssertNil(calendarAlertPlan(for: .granted))
    }

    // CAL3.T4: a sticky denial (status was already `.denied` before the
    // request — the default origin) must NOT promise "Try Again" will fix it:
    // macOS remembers the denial and will not ask again. It offers Open
    // System Settings (primary) and explains the `tccutil reset` route.
    func testDeniedStickyOffersSettingsOnlyAndExplainsReset() {
        let plan = calendarAlertPlan(for: .denied)
        XCTAssertNotNil(plan)
        guard let plan else { return }
        XCTAssertTrue(plan.showsSettingsButton)
        XCTAssertFalse(plan.showsTryAgainButton)
        // Honest sticky-denial wording: says the denial is remembered and
        // macOS will not ask again, and does not promise Try Again fixes it.
        XCTAssertTrue(plan.title.contains("already denied"),
                      "sticky-denied title should say access is already denied, got: \(plan.title)")
        XCTAssertTrue(plan.message.contains("remembers") || plan.message.contains("will not ask again"),
                      "sticky-denied message should explain macOS will not ask again, got: \(plan.message)")
        XCTAssertFalse(plan.message.contains("press Try Again"),
                       "sticky-denied message must not promise Try Again will fix it, got: \(plan.message)")
        // The user must still be pointed at the right place...
        XCTAssertTrue(plan.message.contains("System Settings"),
                      "denied message should mention System Settings, got: \(plan.message)")
        XCTAssertTrue(plan.message.contains("Privacy"),
                      "denied message should mention Privacy, got: \(plan.message)")
        // ...and the only way to get a fresh prompt (tccutil reset) is named.
        XCTAssertTrue(plan.message.contains("tccutil reset Calendar"),
                      "sticky-denied message should offer the tccutil reset route, got: \(plan.message)")
    }

    // CAL3.T4: when the denial came from declining a REAL prompt (the state
    // was requestable), "Try Again" is still meaningful and offered.
    func testDeniedFromDeclinedPromptStillOffersTryAgain() {
        let plan = calendarAlertPlan(for: .denied, origin: .declinedRequest)
        XCTAssertNotNil(plan)
        guard let plan else { return }
        XCTAssertTrue(plan.showsSettingsButton)
        XCTAssertTrue(plan.showsTryAgainButton)
        XCTAssertTrue(plan.message.contains("System Settings"),
                      "denied message should mention System Settings, got: \(plan.message)")
        XCTAssertTrue(plan.message.contains("Privacy"),
                      "denied message should mention Privacy, got: \(plan.message)")
    }

    // The `.notDetermined` fallback (still-requestable path) also keeps
    // "Try Again" available.
    func testNotDeterminedFallbackStillOffersTryAgain() {
        let plan = calendarAlertPlan(for: .notDetermined)
        XCTAssertNotNil(plan)
        guard let plan else { return }
        XCTAssertTrue(plan.showsSettingsButton)
        XCTAssertTrue(plan.showsTryAgainButton)
    }

    func testRestrictedHasNoSettingsButtonAndSaysBlockedByProfile() {
        let plan = calendarAlertPlan(for: .restricted)
        XCTAssertNotNil(plan)
        guard let plan else { return }
        // Settings cannot fix a profile/parental-control block — don't offer it.
        XCTAssertFalse(plan.showsSettingsButton)
        // ...and don't tell the user to go enable it there.
        XCTAssertFalse(plan.message.contains("System Settings"),
                       "restricted message must not point at System Settings, got: \(plan.message)")
        // It must say the access is blocked by a profile / parental controls.
        XCTAssertTrue(plan.message.contains("blocked"),
                      "restricted message should say access is blocked, got: \(plan.message)")
        XCTAssertTrue(
            plan.message.contains("profile") || plan.message.contains("parental controls"),
            "restricted message should cite a management profile or parental controls, got: \(plan.message)"
        )
    }

    // CAL3.T4: the pre-request status → denial-origin mapping is display-only
    // and pure: requestable states mean a real prompt was declined; anything
    // else (including an already-recorded denial) is sticky.
    func testDenialOriginFromPreRequestStatus() {
        XCTAssertEqual(calendarDenialOrigin(for: .denied), .stickyDenial)
        XCTAssertEqual(calendarDenialOrigin(for: .fullAccess), .stickyDenial)
        XCTAssertEqual(calendarDenialOrigin(for: .restricted), .stickyDenial)
        XCTAssertEqual(calendarDenialOrigin(for: .notDetermined), .declinedRequest)
        XCTAssertEqual(calendarDenialOrigin(for: .writeOnly), .declinedRequest)
    }

    // MARK: - Button→response mapping (pure, index-based)

    /// A sticky-denied plan is a SINGLE "Open System Settings" button. Its
    /// lone button must map to `.openSettings` — and nothing the plan did not
    /// add may be misread as "Try Again".
    func testButtonMappingStickyPlanSingleSettingsButton() {
        let plan = calendarAlertPlan(for: .denied)
        XCTAssertNotNil(plan)
        guard let plan else { return }
        // First (and only) button is "Open System Settings".
        XCTAssertEqual(calendarAlertResponse(plan: plan, pressedButtonIndex: 0), .openSettings)
        // No second button exists; indices beyond the plan's buttons dismiss.
        XCTAssertEqual(calendarAlertResponse(plan: plan, pressedButtonIndex: 1), .dismiss)
        XCTAssertEqual(calendarAlertResponse(plan: plan, pressedButtonIndex: 2), .dismiss)
    }

    /// Settings + Try Again: position 0 is Settings, position 1 is Try Again,
    /// anything else dismisses.
    func testButtonMappingSettingsAndTryAgain() {
        let plan = calendarAlertPlan(for: .denied, origin: .declinedRequest)
        XCTAssertNotNil(plan)
        guard let plan else { return }
        XCTAssertEqual(calendarAlertResponse(plan: plan, pressedButtonIndex: 0), .openSettings)
        XCTAssertEqual(calendarAlertResponse(plan: plan, pressedButtonIndex: 1), .tryAgain)
        XCTAssertEqual(calendarAlertResponse(plan: plan, pressedButtonIndex: 2), .dismiss)
    }

    /// A dismiss-only plan (restricted) has no action buttons at all — the
    /// lone default "OK" at index 0 must dismiss, never open Settings or
    /// re-request.
    func testButtonMappingDismissOnlyPlanHasNoActions() {
        let plan = calendarAlertPlan(for: .restricted)
        XCTAssertNotNil(plan)
        guard let plan else { return }
        XCTAssertEqual(calendarAlertResponse(plan: plan, pressedButtonIndex: 0), .dismiss)
        XCTAssertEqual(calendarAlertResponse(plan: plan, pressedButtonIndex: 1), .dismiss)
    }

    func testButtonMappingNilPlanDismisses() {
        XCTAssertEqual(calendarAlertResponse(plan: nil, pressedButtonIndex: 0), .dismiss)
        XCTAssertEqual(calendarAlertResponse(plan: nil, pressedButtonIndex: 3), .dismiss)
        XCTAssertEqual(calendarAlertResponse(plan: nil, pressedButtonIndex: -1), .dismiss)
    }

    /// Even a hypothetical Try-Again-only plan (not currently produced) maps
    /// its lone button to `.tryAgain` by position — never to `.openSettings`.
    func testButtonMappingTryAgainOnlyPlanIsPositional() {
        let plan = CalendarAlertPlan(
            title: "t",
            message: "m",
            showsSettingsButton: false,
            showsTryAgainButton: true
        )
        XCTAssertEqual(calendarAlertResponse(plan: plan, pressedButtonIndex: 0), .tryAgain)
        XCTAssertEqual(calendarAlertResponse(plan: plan, pressedButtonIndex: 1), .dismiss)
    }
}
