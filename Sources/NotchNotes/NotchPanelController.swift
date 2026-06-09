import AppKit
@preconcurrency import ApplicationServices
import SwiftUI

@MainActor
private var cgEventMouseLocation: NSPoint = NSEvent.mouseLocation
@MainActor
private var cgEventTapInstalled = false

@MainActor
private func installCGEventTap() {
    // 已授权则直接安装；未授权仅首次弹窗，之后静默跳过
    if !AXIsProcessTrusted() {
        if !UserDefaults.standard.bool(forKey: "hasPromptedAccessibility") {
            UserDefaults.standard.set(true, forKey: "hasPromptedAccessibility")
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
        return
    }

    let mask: CGEventMask = (1 << CGEventType.mouseMoved.rawValue)
        | (1 << CGEventType.leftMouseDragged.rawValue)
        | (1 << CGEventType.rightMouseDragged.rawValue)
        | (1 << CGEventType.otherMouseDragged.rawValue)

    guard let tap = CGEvent.tapCreate(
        tap: .cghidEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: mask,
        callback: { _, _, event, _ -> Unmanaged<CGEvent>? in
            let loc = event.location
            let h = NSScreen.screens.first?.frame.height ?? 900
            Task { @MainActor in
                cgEventMouseLocation = NSPoint(x: loc.x, y: h - loc.y)
            }
            return Unmanaged.passUnretained(event)
        },
        userInfo: nil
    ) else { return }

    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    cgEventTapInstalled = true
}

@MainActor
final class NotchPanel: NSPanel {
    var onMouseEvent: ((NSEvent) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .leftMouseDragged || event.type == .leftMouseUp {
            onMouseEvent?(event)
        }

        super.sendEvent(event)
    }
}

@MainActor
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

@MainActor
final class NotchPanelController: NSObject {
    private enum Constants {
        static let mousePollingInterval: TimeInterval = 1.0 / 60.0
        static let visibilityCheckInterval: TimeInterval = 1.0
        static let expandFocusDelay: TimeInterval = 0.30
        static let collapseAnimatedDelay: TimeInterval = 0.18
        static let collapseScheduleDelay: TimeInterval = 0.22
        static let expandProtectionWindow: TimeInterval = 0.5
        static let activationMargin: CGFloat = 6
        static let stayRegionMargin: CGFloat = 10
    }

    private let noteStore = NoteStore()
    private let settingsStore = AppSettingsStore()
    private let imageStore = LocalImageStore()
    private let drawerState = DrawerState()
    private let editorInteractionState = EditorInteractionState()
    private lazy var settingsPopoverController = SettingsPopoverController(settingsStore: settingsStore)
    private let compactPanel: NotchPanel
    private let drawerPanel: NotchPanel
    private var hostingView: NSHostingView<NotebookView>?
    private var compactHostingView: NSHostingView<CompactNotchView>?
    private var mousePollingTimer: Timer?
    private var visibilityTimer: Timer?
    private var globalMouseDragMonitor: Any?
    private var globalMouseUpMonitor: Any?
    private var isExpanded = false
    private var activeMenuTrackingCount = 0
    private var collapseTask: DispatchWorkItem?
    private var expandTimestamp: TimeInterval = 0

    override init() {
        compactPanel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        drawerPanel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        super.init()
        installCGEventTap()
        configurePanel(compactPanel)
        configurePanel(drawerPanel)
        rebuildContent()
        startMousePolling()
        startVisibilityWatchdog()
        observeScreenChanges()
        observePanelMouseEvents()
        observeGlobalSelectionMouseEvents()
        observeMenuTracking()
    }

    func showDocked() {
        let layout = currentLayout()
        rebuildContent(layout: layout)
        isExpanded = false
        drawerState.isExpanded = false
        drawerState.revealProgress = 0
        compactPanel.setFrame(hotFrame(for: layout), display: true)
        compactPanel.orderFrontRegardless()
        drawerPanel.setFrame(drawerFrame(for: layout), display: true)
        drawerPanel.orderOut(nil)
    }

    func expand(animated: Bool) {
        guard !isExpanded else { return }
        let layout = currentLayout()
        cancelCollapse()
        isExpanded = true
        expandTimestamp = ProcessInfo.processInfo.systemUptime
        rebuildContent(layout: layout)
        drawerPanel.setFrame(drawerFrame(for: layout), display: true)
        NSApp.activate(ignoringOtherApps: true)
        drawerPanel.makeKeyAndOrderFront(nil)
        compactPanel.orderOut(nil)
        setDrawerExpanded(true, animated: animated)
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.expandFocusDelay) { [weak self] in
            guard let self else { return }
            guard self.isExpanded else { return }
            self.editorInteractionState.restoreSelection(
                self.noteStore.selectionRange(for: self.noteStore.activeTabID),
                searchingIn: self.hostingView
            )
            self.editorInteractionState.requestLayoutRefresh(searchingIn: self.hostingView)
            self.editorInteractionState.requestFocus(searchingIn: self.hostingView)
        }
    }

    func collapse(animated: Bool) {
        guard isExpanded else { return }
        if let range = editorInteractionState.currentSelectionRange() {
            noteStore.updateSelection(for: noteStore.activeTabID, range: range)
        }
        settingsPopoverController.close(animated: false)
        isExpanded = false
        setDrawerExpanded(false, animated: animated)
        let delay: TimeInterval = animated ? Constants.collapseAnimatedDelay : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard !self.isExpanded else { return }
            let layout = self.currentLayout()
            self.drawerPanel.orderOut(nil)
            self.compactPanel.setFrame(self.hotFrame(for: layout), display: true)
            self.compactPanel.orderFrontRegardless()
        }
    }

    private func configurePanel(_ panel: NotchPanel) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
    }

    private func rebuildContent(layout: NotchLayout? = nil) {
        let layout = layout ?? currentLayout()
        let hotView = CompactNotchView(layout: layout)
        let view = NotebookView(
            store: noteStore,
            settingsStore: settingsStore,
            imageStore: imageStore,
            drawerState: drawerState,
            editorInteractionState: editorInteractionState,
            layout: layout,
            onOpenSettings: { [weak self] in self?.openSettingsPopover() }
        )

        if let compactHostingView {
            compactHostingView.rootView = hotView
        } else {
            let host = FirstMouseHostingView(rootView: hotView)
            host.translatesAutoresizingMaskIntoConstraints = false
            host.wantsLayer = true
            host.layer?.masksToBounds = true
            compactPanel.contentView = host
            compactHostingView = host
        }

        if let hostingView {
            hostingView.rootView = view
            return
        }

        let host = FirstMouseHostingView(rootView: view)
        host.translatesAutoresizingMaskIntoConstraints = false
        host.wantsLayer = true
        host.layer?.masksToBounds = true
        drawerPanel.contentView = host
        hostingView = host
    }

    private func setDrawerExpanded(_ expanded: Bool, animated: Bool) {
        guard animated else {
            drawerState.isExpanded = expanded
            drawerState.revealProgress = expanded ? 1 : 0
            return
        }

        let animation: Animation = expanded
            ? .spring(response: 0.28, dampingFraction: 0.86)
            : .easeOut(duration: 0.16)

        withAnimation(animation) {
            drawerState.isExpanded = expanded
            drawerState.revealProgress = expanded ? 1 : 0
        }
    }

    private func startMousePolling() {
        let timer = Timer(
            timeInterval: Constants.mousePollingInterval,
            target: self,
            selector: #selector(mousePollingTick),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        mousePollingTimer = timer
    }

    private func startVisibilityWatchdog() {
        let timer = Timer(
            timeInterval: Constants.visibilityCheckInterval,
            target: self,
            selector: #selector(visibilityWatchdogTick),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        visibilityTimer = timer
    }

    @objc private func visibilityWatchdogTick(_ timer: Timer) {
        guard !isExpanded else { return }
        compactPanel.setFrame(hotFrame(for: currentLayout()), display: true)
        compactPanel.orderFrontRegardless()
    }

    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    private func observePanelMouseEvents() {
        compactPanel.onMouseEvent = { [weak self] event in
            guard let self else { return }
            guard event.type == .leftMouseDown else { return }
            self.expand(animated: true)
        }

        drawerPanel.onMouseEvent = { [weak self] event in
            guard let self else { return }
            self.editorInteractionState.handleMouseEvent(event, searchingIn: self.hostingView)
        }
    }

    private func observeGlobalSelectionMouseEvents() {
        globalMouseDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            Task { @MainActor in
                self?.editorInteractionState.noteGlobalMouseDragged()
            }
        }

        globalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            Task { @MainActor in
                self?.editorInteractionState.noteGlobalMouseUp()
            }
        }
    }

    private func observeMenuTracking() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuTrackingDidBegin),
            name: NSMenu.didBeginTrackingNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuTrackingDidEnd),
            name: NSMenu.didEndTrackingNotification,
            object: nil
        )
    }

    @objc private func screenParametersChanged(_ notification: Notification) {
        let layout = currentLayout()
        cancelCollapse()
        rebuildContent(layout: layout)
        compactPanel.setFrame(hotFrame(for: layout), display: true)
        drawerPanel.setFrame(drawerFrame(for: layout), display: true)
        if !isExpanded {
            compactPanel.orderFrontRegardless()
        }
    }

    @objc private func mousePollingTick(_ timer: Timer) {
        if !cgEventTapInstalled {
            cgEventMouseLocation = NSEvent.mouseLocation
        }
        handleMouseLocation(cgEventMouseLocation)
    }

    @objc private func menuTrackingDidBegin(_ notification: Notification) {
        activeMenuTrackingCount += 1
        cancelCollapse()
    }

    @objc private func menuTrackingDidEnd(_ notification: Notification) {
        activeMenuTrackingCount = max(0, activeMenuTrackingCount - 1)
        guard activeMenuTrackingCount == 0, isExpanded else { return }
        handleMouseLocation(cgEventMouseLocation)
    }

    private func handleMouseLocation(_ point: NSPoint) {
        if isExpanded {
            if activeMenuTrackingCount > 0 {
                cancelCollapse()
                return
            }

            if editorInteractionState.isDraggingSelection {
                cancelCollapse()
                return
            }

            let elapsed = ProcessInfo.processInfo.systemUptime - expandTimestamp
            if elapsed < Constants.expandProtectionWindow {
                cancelCollapse()
                return
            }

            if isPointInExpandedStayRegion(point) {
                cancelCollapse()
            } else {
                scheduleCollapse()
            }
            return
        }

        if activationFrame().contains(point) {
            ensureHotPanelVisible()
            if settingsStore.triggerMode == .hover {
                expand(animated: true)
            }
        }
    }

    private func scheduleCollapse() {
        guard collapseTask == nil else { return }

        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.collapseTask = nil
            guard !self.editorInteractionState.isDraggingSelection else { return }
            guard !self.isPointInExpandedStayRegion(cgEventMouseLocation) else { return }
            self.activeMenuTrackingCount = 0
            self.collapse(animated: true)
        }

        collapseTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.collapseScheduleDelay, execute: task)
    }

    private func cancelCollapse() {
        collapseTask?.cancel()
        collapseTask = nil
    }

    private func activationFrame() -> NSRect {
        let layout = currentLayout()
        let frame = compactPanel.frame
        let base: NSRect
        if frame.width > 0, frame.height > 0 {
            base = frame
        } else {
            base = hotFrame(for: layout)
        }

        let margin: CGFloat = Constants.activationMargin
        return base.insetBy(dx: -margin, dy: -margin)
    }

    private func isPointInExpandedStayRegion(_ point: NSPoint) -> Bool {
        let margin: CGFloat = Constants.stayRegionMargin
        if drawerPanel.frame.insetBy(dx: -margin, dy: -margin).contains(point) { return true }
        if activationFrame().contains(point) { return true }
        if settingsPopoverController.contains(point) { return true }
        return false
    }

    private func openSettingsPopover() {
        cancelCollapse()
        settingsPopoverController.show(relativeTo: drawerPanel)
    }

    private func ensureHotPanelVisible() {
        guard !isExpanded else { return }
        // 确保 drawerPanel 不会遮挡 compactPanel
        // 在折叠动画期间，drawerPanel 可能还未隐藏
        if drawerPanel.isVisible {
            drawerPanel.orderOut(nil)
        }
        compactPanel.orderFrontRegardless()
        // 在 Click 模式下，确保 compactPanel 能接收鼠标事件
        // 仅在 panel 未成为 key window 时才调用，避免重复激活
        if settingsStore.triggerMode == .click, !compactPanel.isKeyWindow {
            compactPanel.makeKeyAndOrderFront(nil)
        }
    }

    private func currentLayout() -> NotchLayout {
        NotchGeometry.layout(for: targetScreen())
    }

    private func targetScreen() -> NSScreen? {
        NotchGeometry.targetScreen()
    }

    private func hotFrame(for layout: NotchLayout) -> NSRect {
        let screen = targetScreen()
        let screenFrame = screen?.frame ?? NotchGeometry.fallbackScreenFrame
        return frame(for: layout.compactSize, topY: screenFrame.maxY + layout.compactTopOffset, in: screenFrame)
    }

    private func drawerFrame(for layout: NotchLayout) -> NSRect {
        let screen = targetScreen()
        let screenFrame = screen?.frame ?? NotchGeometry.fallbackScreenFrame
        let topY = screenFrame.maxY + layout.expandedTopOffset
        return frame(for: layout.expandedSize, topY: topY, in: screenFrame)
    }

    private func frame(for size: NSSize, topY: CGFloat, in screenFrame: NSRect) -> NSRect {
        let x = screenFrame.midX - size.width / 2
        let y = topY - size.height

        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}
