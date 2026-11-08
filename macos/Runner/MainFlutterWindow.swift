import Cocoa
import Carbon
import FlutterMacOS
import ServiceManagement

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  private var quickCaptureChannel: FlutterMethodChannel?
  private var settingsChannel: FlutterMethodChannel?
  private var hotKey: EventHotKeyRef?
  private var hotKeyHandler: EventHandlerRef?
  private var isMinimizing = false
  private var externalActionDepth = 0
  private var pendingPrintResult: FlutterResult?
  private var activePrintOperation: NSPrintOperation?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    RegisterGeneratedPlugins(registry: flutterViewController)
    super.awakeFromNib()

    title = "QJotter"
    delegate = self
    setContentSize(NSSize(width: 560, height: 440))
    minSize = NSSize(width: 400, height: 320)
    center()
    NotificationCenter.default.addObserver(
      self, selector: #selector(applicationDidResignActive(_:)),
      name: NSApplication.didResignActiveNotification, object: NSApp
    )

    let channel = FlutterMethodChannel(
      name: "notefile/quick_capture",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    quickCaptureChannel = channel
    let settings = FlutterMethodChannel(name: "notefile/settings",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    settingsChannel = settings
    settings.setMethodCallHandler { call, result in
      guard #available(macOS 13.0, *) else {
        result(["supported": false, "message": "Automatic startup requires macOS 13 or later."])
        return
      }
      do {
        switch call.method {
        case "getStartupStatus": break
        case "setStartupEnabled":
          guard let enabled = call.arguments as? Bool else {
            result(FlutterError(code: "invalid_setting", message: "A startup setting is required.", details: nil))
            return
          }
          if enabled {
            if SMAppService.mainApp.status != .enabled && SMAppService.mainApp.status != .requiresApproval {
              try SMAppService.mainApp.register()
            }
          } else if SMAppService.mainApp.status != .notRegistered {
            try SMAppService.mainApp.unregister()
          }
        default:
          result(FlutterMethodNotImplemented)
          return
        }
        let status = SMAppService.mainApp.status
        result(["supported": true, "enabled": status == .enabled,
                "requiresApproval": status == .requiresApproval])
      } catch {
        result(FlutterError(code: "startup_unavailable", message: error.localizedDescription, details: nil))
      }
    }
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return result(nil) }
      switch call.method {
      case "registerShortcut":
        let status = self.registerShortcut()
        if status == noErr {
          result(nil)
        } else {
          result(FlutterError(
            code: "shortcut_unavailable",
            message: "Could not register ⌃⌥⌘N (\(status)). Another app may already use it.",
            details: Int(status)
          ))
        }
      case "beginExternalAction":
        self.beginExternalAction()
        result(nil)
      case "endExternalAction":
        self.endExternalAction()
        result(nil)
      case "printNote":
        guard let arguments = call.arguments as? [String: String],
              let text = arguments["text"], let title = arguments["title"] else {
          result(FlutterError(code: "invalid_note", message: "A note is required.", details: nil))
          return
        }
        self.printNote(text: text, title: title, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  func beginExternalAction() {
    externalActionDepth += 1
  }

  func endExternalAction() {
    externalActionDepth = max(0, externalActionDepth - 1)
    if !NSApp.isActive { hideAfterFocusLoss() }
  }

  private func printNote(text: String, title: String, result: @escaping FlutterResult) {
    guard pendingPrintResult == nil else {
      result(FlutterError(code: "print_busy", message: "A print dialog is already open.", details: nil))
      return
    }
    let info = NSPrintInfo.shared.copy() as! NSPrintInfo
    info.leftMargin = 36
    info.rightMargin = 36
    info.topMargin = 36
    info.bottomMargin = 36
    info.isHorizontallyCentered = false
    info.isVerticallyCentered = false
    info.horizontalPagination = .fit
    info.verticalPagination = .automatic
    let width = max(1, info.paperSize.width - info.leftMargin - info.rightMargin)
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
    view.isHorizontallyResizable = false
    view.isVerticallyResizable = true
    view.textContainerInset = .zero
    view.textContainer?.widthTracksTextView = true
    view.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
    view.font = NSFont.systemFont(ofSize: 13)
    view.textColor = .black
    view.string = text
    if let container = view.textContainer, let manager = view.layoutManager {
      manager.ensureLayout(for: container)
      view.setFrameSize(NSSize(width: width, height: max(100, ceil(manager.usedRect(for: container).height))))
    }
    let operation = NSPrintOperation(view: view, printInfo: info)
    operation.jobTitle = title
    operation.canSpawnSeparateThread = false
    pendingPrintResult = result
    activePrintOperation = operation
    operation.runModal(for: self, delegate: self,
      didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
  }

  @objc private func printOperationDidRun(_ operation: NSPrintOperation, success: Bool,
                                         contextInfo: UnsafeMutableRawPointer?) {
    let result = pendingPrintResult
    pendingPrintResult = nil
    activePrintOperation = nil
    result?(success)
  }

  private func registerShortcut() -> OSStatus {
    // A hot restart reuses the same native window and registration.
    if hotKey != nil { return noErr }
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    let installStatus = InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, context in
        guard let event = event, let context = context else {
          return OSStatus(eventNotHandledErr)
        }
        var identifier = EventHotKeyID()
        let status = GetEventParameter(
          event, EventParamName(kEventParamDirectObject),
          EventParamType(typeEventHotKeyID), nil,
          MemoryLayout<EventHotKeyID>.size, nil, &identifier
        )
        guard status == noErr, identifier.signature == 0x4E54464C, identifier.id == 1 else {
          return OSStatus(eventNotHandledErr)
        }
        let window = Unmanaged<MainFlutterWindow>.fromOpaque(context).takeUnretainedValue()
        window.showQuickCapture()
        return noErr
      },
      1, &eventType,
      Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler
    )
    guard installStatus == noErr else { return installStatus }

    // Register only this chord, without monitoring unrelated keyboard input.
    let status = RegisterEventHotKey(
      UInt32(kVK_ANSI_N), UInt32(controlKey | optionKey | cmdKey),
      EventHotKeyID(signature: 0x4E54464C, id: 1),
      GetApplicationEventTarget(), 0, &hotKey
    )
    if status != noErr, let handler = hotKeyHandler {
      RemoveEventHandler(handler)
      hotKeyHandler = nil
    }
    return status
  }

  func showQuickCapture() {
    if isMiniaturized { deminiaturize(nil) }
    collectionBehavior.insert(.moveToActiveSpace)
    NSApp.unhide(nil)
    NSApp.activate(ignoringOtherApps: true)
    makeKeyAndOrderFront(nil)
    if let flutterView = contentViewController?.view {
      makeFirstResponder(flutterView)
    }
    quickCaptureChannel?.invokeMethod("focusEditor", arguments: nil)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    // Keep the Flutter engine and shortcut alive when the window closes.
    orderOut(nil)
    return false
  }

  func windowDidResignKey(_ notification: Notification) {
    hideAfterFocusLoss()
  }

  @objc func applicationDidResignActive(_ notification: Notification) {
    hideAfterFocusLoss()
  }

  private func hideAfterFocusLoss() {
    // Native sheets and minimising have their own window lifecycle.
    guard isVisible, externalActionDepth == 0, !isMinimizing,
          !isMiniaturized, attachedSheet == nil else { return }
    orderOut(nil)
  }

  func windowWillMiniaturize(_ notification: Notification) {
    isMinimizing = true
  }

  func windowDidMiniaturize(_ notification: Notification) {
    isMinimizing = false
  }

  func windowDidDeminiaturize(_ notification: Notification) {
    isMinimizing = false
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    if let hotKey = hotKey { UnregisterEventHotKey(hotKey) }
    if let handler = hotKeyHandler { RemoveEventHandler(handler) }
  }
}
