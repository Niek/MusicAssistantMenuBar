import AppKit
import CoreGraphics

final class MediaKeyMonitor {
    enum CaptureMode {
        case exclusive
        case passive
    }

    private let nxKeyTypePlayPause: Int32 = 16
    private let mediaKeySubtype: Int16 = 8
    private static let systemDefinedEventType = CGEventType(rawValue: 14)!
    private let onPlayPause: () -> Void

    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var captureMode: CaptureMode = .passive

    init(onPlayPause: @escaping () -> Void) {
        self.onPlayPause = onPlayPause
    }

    @discardableResult
    func start() -> CaptureMode {
        guard eventTap == nil, globalMonitor == nil, localMonitor == nil else {
            return captureMode
        }

        if startExclusiveEventTap() {
            captureMode = .exclusive
            return captureMode
        }

        captureMode = .passive
        startPassiveMonitors()
        return captureMode
    }

    private func startPassiveMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            self?.handlePassive(event)
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            guard let self else {
                return event
            }

            let consumed = self.handlePassive(event)
            return consumed ? nil : event
        }
    }

    func stop() {
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
            self.eventTapSource = nil
        }

        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }

        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }

        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    deinit {
        stop()
    }

    private func startExclusiveEventTap() -> Bool {
        let mask = CGEventMask(1) << MediaKeyMonitor.systemDefinedEventType.rawValue
        let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: MediaKeyMonitor.eventTapCallback,
            userInfo: userInfo
        ) else {
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }

        eventTap = tap
        eventTapSource = source

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }

        let monitor = Unmanaged<MediaKeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        return monitor.handleEventTap(type: type, event: event)
    }

    private func handleEventTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == MediaKeyMonitor.systemDefinedEventType else {
            return Unmanaged.passUnretained(event)
        }

        guard let nsEvent = NSEvent(cgEvent: event) else {
            return Unmanaged.passUnretained(event)
        }

        guard let parsed = parseMediaKeyEvent(nsEvent), parsed.keyCode == nxKeyTypePlayPause else {
            return Unmanaged.passUnretained(event)
        }

        if parsed.isKeyDown, !parsed.isRepeat {
            onPlayPause()
        }

        return nil
    }

    @discardableResult
    private func handlePassive(_ event: NSEvent) -> Bool {
        guard let parsed = parseMediaKeyEvent(event), parsed.keyCode == nxKeyTypePlayPause else {
            return false
        }

        guard parsed.isKeyDown, !parsed.isRepeat else {
            return true
        }

        onPlayPause()
        return true
    }

    private func parseMediaKeyEvent(_ event: NSEvent) -> (keyCode: Int32, isKeyDown: Bool, isRepeat: Bool)? {
        guard event.type == .systemDefined, event.subtype.rawValue == mediaKeySubtype else {
            return nil
        }

        let data = UInt32(bitPattern: Int32(truncatingIfNeeded: event.data1))
        let keyCode = Int32((data & 0xFFFF0000) >> 16)
        let keyFlags = Int32(data & 0x0000FFFF)

        let keyState = (keyFlags & 0xFF00) >> 8
        let isRepeat = (keyFlags & 0x1) == 0x1
        let isKeyDown = keyState == 0xA

        return (keyCode, isKeyDown, isRepeat)
    }
}
