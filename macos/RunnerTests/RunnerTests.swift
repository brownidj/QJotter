import Cocoa
import XCTest
@testable import notefile

@MainActor
final class RunnerTests: XCTestCase {
  private func makeWindow() -> MainFlutterWindow {
    let window = MainFlutterWindow(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
      styleMask: [.titled, .closable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.delegate = window
    addTeardownBlock {
      await MainActor.run {
        window.orderOut(nil)
        window.delegate = nil
      }
    }
    return window
  }

  func testClosingWindowHidesItInsteadOfDestroyingIt() {
    let window = makeWindow()
    window.makeKeyAndOrderFront(nil)
    XCTAssertTrue(window.isVisible)

    window.performClose(nil)
    XCTAssertFalse(window.isVisible)

    // The same native window remains usable after closing.
    window.showQuickCapture()
    XCTAssertTrue(window.isVisible)
  }

  func testQuickCaptureShowsAHiddenWindow() {
    let window = makeWindow()
    window.orderOut(nil)
    XCTAssertFalse(window.isVisible)

    window.showQuickCapture()
    XCTAssertTrue(window.isVisible)
    XCTAssertTrue(window.collectionBehavior.contains(.moveToActiveSpace))
  }

  func testQuickCaptureRestoresAMinimisedWindow() async {
    let window = makeWindow()
    window.makeKeyAndOrderFront(nil)
    let minimised = expectation(forNotification: NSWindow.didMiniaturizeNotification, object: window)
    window.miniaturize(nil)
    await fulfillment(of: [minimised], timeout: 5)
    XCTAssertTrue(window.isMiniaturized)

    let restored = expectation(forNotification: NSWindow.didDeminiaturizeNotification, object: window)
    window.showQuickCapture()
    await fulfillment(of: [restored], timeout: 5)
    XCTAssertFalse(window.isMiniaturized)
    XCTAssertTrue(window.isVisible)
  }

  func testClosingLastWindowDoesNotQuitTheApp() {
    let delegate = AppDelegate()
    XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))
  }

  func testLosingWindowFocusHidesItAndAllowsQuickCaptureToReopenIt() {
    let window = makeWindow()
    window.makeKeyAndOrderFront(nil)
    window.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
    XCTAssertFalse(window.isVisible)
    window.showQuickCapture()
    XCTAssertTrue(window.isVisible)
  }

  func testSwitchingToAnotherAppHidesTheWindowWithoutQuitting() {
    let window = makeWindow()
    window.makeKeyAndOrderFront(nil)
    window.applicationDidResignActive(
      Notification(name: NSApplication.didResignActiveNotification, object: NSApp)
    )
    XCTAssertFalse(window.isVisible)
    XCTAssertFalse(AppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApp))
    window.showQuickCapture()
    XCTAssertTrue(window.isVisible)
  }

  func testAppDeactivationNotificationHidesTheRealFlutterWindow() throws {
    let delegate = try XCTUnwrap(NSApp.delegate as? AppDelegate)
    let window = try XCTUnwrap(delegate.mainFlutterWindow as? MainFlutterWindow)
    window.showQuickCapture()
    XCTAssertTrue(window.isVisible)

    NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
    XCTAssertFalse(window.isVisible)

    window.showQuickCapture()
    XCTAssertTrue(window.isVisible)
  }

  func testLosingFocusDuringMinimisationDoesNotHideTheWindow() {
    let window = makeWindow()
    window.makeKeyAndOrderFront(nil)
    window.windowWillMiniaturize(Notification(name: NSWindow.willMiniaturizeNotification, object: window))
    window.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
    XCTAssertTrue(window.isVisible)
  }

  func testNativeDialogsKeepTheWindowAliveUntilEveryActionCompletes() {
    let window = makeWindow()
    window.makeKeyAndOrderFront(nil)
    window.beginExternalAction()
    window.beginExternalAction()
    window.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
    XCTAssertTrue(window.isVisible)
    window.endExternalAction()
    window.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
    XCTAssertTrue(window.isVisible)
    window.endExternalAction()
    window.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
    XCTAssertFalse(window.isVisible)
  }

  func testNativeTestHostHasAnIsolatedStorageMarker() {
    XCTAssertNotNil(ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"])
  }

  func testDockReopenShowsTheExistingWindow() {
    let window = makeWindow()
    let delegate = AppDelegate()
    delegate.mainFlutterWindow = window
    window.orderOut(nil)

    XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
    XCTAssertTrue(window.isVisible)
    XCTAssertTrue(delegate.mainFlutterWindow === window)
  }
}
