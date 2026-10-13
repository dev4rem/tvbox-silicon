#if os(tvOS)
import XCTest

/// Apple TV navigation with the Siri Remote against Scripts/qa-server.py (Scripts/test-tv-ui.sh).
final class TVNavigationUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// Back on a video page whose details are still loading returns to the source. With nothing
    /// focusable on the page, tvOS used to hand the press to the system, which left the app.
    func testBackWhileDetailsLoadReturnsToTheSource() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-qaSection", "sites", "-qaPage", "open-detail:qa-stall:1", "-qaIsolatedData", "1",
                               "-qaSubscription", "http://127.0.0.1:8776/stall-config.json",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let remote = XCUIRemote.shared
        let open = app.buttons["qa.open-detail"]
        XCTAssertTrue(open.waitForExistence(timeout: 60), "The QA page did not appear")
        // Focus starts in the tab sidebar on the left; move right into the page until Select opens the video.
        let loading = app.staticTexts["Loading video details…"]
        for _ in 0..<4 where !loading.exists {
            remote.press(.right); sleep(1)
            remote.press(.select)
            _ = loading.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(loading.exists, "The video page did not open")
        sleep(3)
        remote.press(.menu)
        sleep(3)
        XCTAssertEqual(app.state, .runningForeground, "Back left the app")
        XCTAssertFalse(loading.exists, "Back did not leave the loading video page")
        XCTAssertTrue(open.waitForExistence(timeout: 10), "Back did not return to the previous page")
    }

    /// A source page searches from the remote: the search keyboard has no return key, so a Search
    /// button below it runs the query that was typed, and typing alone does not search.
    func testSourcePageSearchesWithTheSearchButton() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-qaSection", "sites", "-qaPage", "site:qa-standard", "-qaSearchDraft", "hello", "-qaIsolatedData", "1",
                               "-qaSubscription", "http://127.0.0.1:8776/config.json",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let remote = XCUIRemote.shared
        XCTAssertTrue(shown("测试影片 01", in: app).waitForExistence(timeout: 60), "The source page did not load")
        // `-qaSearchDraft` stands in for typing (UI tests cannot type into the tvOS search keyboard).
        let submit = app.buttons["site.search.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 10), "A typed query did not show the Search button")
        // Focus starts in the tab sidebar; right moves it into the search keyboard.
        remote.press(.right); sleep(1)
        XCTAssertFalse(shown("hello 01", in: app).exists, "The search ran before it was submitted")
        // Down from the keyboard lands on the Search button.
        remote.press(.down); sleep(1)
        remote.press(.select)
        XCTAssertTrue(shown("hello 01", in: app).waitForExistence(timeout: 20), "Pressing Search did not show results")
        XCTAssertFalse(submit.exists, "The Search button stayed after its query ran")
    }
    /// Poster titles are part of their card's label, so look for the text anywhere in a label.
    private func shown(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }
}
#endif
