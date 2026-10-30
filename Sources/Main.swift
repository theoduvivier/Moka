import AppKit
import SwiftUI
import Combine
import QuartzCore

final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Separate from the template icon so the robot follows the menu bar's appearance
/// while the activity indicator keeps its green color. Clicks reach the button.
final class StatusActivityDot: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var allowsVibrancy: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.25, dy: 0.25))
        NSColor.systemGreen.setFill()
        circle.fill()
        NSColor.black.withAlphaComponent(0.12).setStroke()
        circle.lineWidth = 0.5
        circle.stroke()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem!
    private var panel: MenuPanel?
    private var outsideMonitor: Any?
    private var keyMonitor: Any?
    private var hostingView: NSHostingView<MokaPanel>?
    private var subscriptions: Set<AnyCancellable> = []
    private var quitTimer: Timer?
    private var renderedAwake: Bool?
    private var renderedIndicator: StatusProtectionIndicator?
    private var iconAnimationTimer: Timer?
    private var iconFrame = StatusIconFrame(fill: 0, scale: 1)
    private let activityDot = StatusActivityDot()
    private let lidIndicator = StatusLidIndicator()
    private var presentationGeneration: UInt = 0
    private var isPanelClosing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "fr.local.moka")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let other = others.first {
            other.activate(options: [])
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        installMenu()
        // Reserve space for the dot even when off; neighboring menu items stay put.
        statusItem = NSStatusBar.system.statusItem(withLength: 32)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        // Handle the press, not the release: a focus-loss dismissal between the
        // two used to turn the second click into an unintended reopen.
        statusItem.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        if let button = statusItem.button {
            lidIndicator.translatesAutoresizingMaskIntoConstraints = false
            lidIndicator.setAccessibilityElement(false)
            lidIndicator.isHidden = true
            lidIndicator.alphaValue = 0
            button.addSubview(lidIndicator)
            activityDot.translatesAutoresizingMaskIntoConstraints = false
            activityDot.setAccessibilityElement(false)
            activityDot.isHidden = true
            button.addSubview(activityDot)
            NSLayoutConstraint.activate([
                lidIndicator.widthAnchor.constraint(equalToConstant: 22),
                lidIndicator.heightAnchor.constraint(equalToConstant: 22),
                // The robot is offset inside its fixed-width template image.
                lidIndicator.centerXAnchor.constraint(equalTo: button.centerXAnchor, constant: -3),
                lidIndicator.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                activityDot.widthAnchor.constraint(equalToConstant: 6),
                activityDot.heightAnchor.constraint(equalToConstant: 6),
                activityDot.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -3),
                activityDot.topAnchor.constraint(equalTo: button.topAnchor, constant: 3)
            ])
        }
        updateStatus()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !self.pointerIsOverStatusButton else { return }
            self.hidePanel()
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, let self, self.panel?.isVisible == true, event.window === self.panel {
                self.hidePanel()
                return nil
            }
            return event
        }
        model.objectWillChange.sink { [weak self] in DispatchQueue.main.async { self?.updateStatus() } }.store(in: &subscriptions)
        if !UserDefaults.standard.bool(forKey: "hasLaunched") || CommandLine.arguments.contains("--show") {
            UserDefaults.standard.set(true, forKey: "hasLaunched")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.showPopover() }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.count > index + 1 {
            let path = CommandLine.arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.renderPreview(path: path) }
        }
    }
    private func installMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quitter Moka", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let edit = NSMenuItem()
        let editMenu = NSMenu(title: "Édition")
        editMenu.addItem(withTitle: "Couper", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copier", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Coller", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Tout sélectionner", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = editMenu
        menu.addItem(edit)
        NSApp.mainMenu = menu
    }
    private func updateStatus() {
        guard let button = statusItem?.button else { return }
        let awake = model.awake
        let indicator = StatusProtectionIndicator.resolve(awake: awake, lidActive: model.lid.active, lidStopping: model.lid.stopping, restorationFailed: model.lid.restorationFailed)
        let status: String
        if indicator == .lidWarning {
            status = model.lid.restorationFailed ? "Moka · Attention · Restauration de la veille non confirmée" : model.lid.stopping ? "Moka · Capot fermé · Restauration en cours" : "Moka · Capot fermé actif · Surveillance en cours"
            button.toolTip = status
        } else if awake {
            status = "Moka · Actif · Mac éveillé · Capot fermé non activé"
            button.toolTip = "\(status) · \(model.sessionClock) écoulées"

        } else {
            status = "Moka · Inactif"
            button.toolTip = "\(status) · Cliquer pour démarrer une session"
        }
        button.setAccessibilityLabel(status)
        if renderedIndicator != indicator {
            let hadIndicator = renderedIndicator != nil
            renderedIndicator = indicator
            updateProtectionIndicator(animated: hadIndicator)
        }
        guard renderedAwake != awake else { return }
        let animate = renderedAwake != nil && renderedAwake != awake
        renderedAwake = awake
        transitionStatusIcon(active: awake, animate: animate)
    }
    private func updateProtectionIndicator(animated: Bool) {
        let showWarning = renderedIndicator == .lidWarning
        activityDot.isHidden = showWarning || iconFrame.fill <= 0
        if showWarning { lidIndicator.isHidden = false }
        guard animated else {
            lidIndicator.alphaValue = showWarning ? 1 : 0
            lidIndicator.isHidden = !showWarning
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.10 : 0.20
            lidIndicator.animator().alphaValue = showWarning ? 1 : 0
        } completionHandler: { [weak self] in
            guard let self, self.renderedIndicator != .lidWarning else { return }
            self.lidIndicator.isHidden = true
        }
    }
    private func transitionStatusIcon(active: Bool, animate: Bool) {
        iconAnimationTimer?.invalidate()
        iconAnimationTimer = nil
        guard animate else {
            renderStatusIcon(frame: StatusIconFrame(fill: active ? 1 : 0, scale: 1))
            return
        }
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let transition = StatusIconTransition(from: iconFrame, active: active, reduceMotion: reducedMotion)
        let duration = reducedMotion ? 0.12 : active ? 0.30 : 0.24
        let started = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let progress = min(1, (CACurrentMediaTime() - started) / duration)
            self.renderStatusIcon(frame: transition.frame(at: progress))
            if progress >= 1 {
                timer.invalidate()
                self.iconAnimationTimer = nil
            }
        }
        timer.tolerance = 0.002
        iconAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func renderStatusIcon(frame: StatusIconFrame) {
        iconFrame = frame
        lidIndicator.iconScale = frame.scale
        statusItem.button?.image = MenuBarIcon.image(fill: frame.fill, scale: frame.scale)
        activityDot.alphaValue = frame.fill
        activityDot.isHidden = frame.fill <= 0 || renderedIndicator == .lidWarning
    }
    @objc private func statusClicked() {
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true { model.toggle(); return }
        if NSApp.currentEvent?.type == .rightMouseDown {
            let menu = NSMenu()
            menu.addItem(withTitle: model.enabled ? "Terminer la session" : "Garder mon Mac éveillé", action: #selector(toggleSession), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quitter Moka", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else if panel?.isVisible == true && !isPanelClosing { hidePanel() }
        else { showPopover() }
    }
    @objc private func toggleSession() { model.toggle() }
    private func showPopover() {
        guard let button = statusItem.button, let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let frame = MenuGeometry.frame(anchor: anchor, visible: screen.visibleFrame,
                                       preferredHeight: model.lid.isSupported ? 470 : 414)
        let alreadyOpen = panel?.isVisible == true && !isPanelClosing
        let wasVisible = panel?.isVisible == true
        presentationGeneration &+= 1
        isPanelClosing = false
        if panel == nil {
            let window = MenuPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            // The glass surface supplies its own rounded edge. AppKit's cached
            // window shadow can retain a rectangular outline around transparent
            // corners and while the two faces turn.
            window.hasShadow = false
            // Only our alpha transition runs; no inferred AppKit window animation.
            window.animationBehavior = .none
            window.level = .popUpMenu
            window.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .transient, .ignoresCycle]
            // Dismissal is animated explicitly, including when focus leaves Moka.
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.delegate = self
            panel = window
        }
        let root = MokaPanel(model: model, quit: { NSApp.terminate(nil) }, panelHeight: frame.height)
        if let hostingView { hostingView.rootView = root }
        else {
            let host = NSHostingView(rootView: root)
            host.focusRingType = .none
            hostingView = host
            panel?.contentView = host
        }
        guard let panel else { return }
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.ignoresMouseEvents = false
        if !wasVisible { panel.alphaValue = 0 }
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        panel.contentView?.layoutSubtreeIfNeeded()
        // A nonactivating panel can receive keyboard input without activating
        // Moka, switching the menu bar, or changing the front app's window set.
        model.panelVisible = true
        panel.makeKeyAndOrderFront(nil)
        if alreadyOpen {
            panel.alphaValue = 1
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reducedMotion ? 0.10 : 0.16
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
                panel.animator().alphaValue = 1
            }
        }
    }
    private func hidePanel() {
        guard let panel, panel.isVisible, !isPanelClosing else { return }
        presentationGeneration &+= 1
        let generation = presentationGeneration
        isPanelClosing = true
        model.panelVisible = false
        panel.ignoresMouseEvents = true
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reducedMotion ? 0.08 : 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.presentationGeneration == generation, self.isPanelClosing else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
            panel.ignoresMouseEvents = false
            self.isPanelClosing = false
        }
    }
    private var pointerIsOverStatusButton: Bool {
        guard let button = statusItem?.button, let window = button.window else { return false }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        return frame.contains(NSEvent.mouseLocation)
    }
    func windowDidResignKey(_ notification: Notification) {
        // Clicking the status item can change the key window before or after its
        // action. Let that action alone decide whether this press opens/closes.
        // A keyboard focus change still dismisses, even if the pointer rests here.
        let clickEvent = NSApp.currentEvent.map {
            [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp].contains($0.type)
        } ?? false
        if pointerIsOverStatusButton && (clickEvent || NSEvent.pressedMouseButtons & 3 != 0) { return }
        hidePanel()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitTimer?.isValid == true { return .terminateLater }
        let waitForGuard = model.lid.active || model.lid.pending || model.lid.stopping || model.lid.restorationFailed
        model.stop()
        guard waitForGuard else { return .terminateNow }
        var polls = 0
        quitTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            self?.model.lid.pulse()
            polls += 1
            if self?.model.lid.stopping != true || polls >= 24 {
                timer.invalidate()
                self?.quitTimer = nil
                if self?.model.lid.stopping == true || self?.model.lid.restorationFailed == true {
                    let alert = NSAlert()
                    alert.messageText = "La restauration de la veille n’est pas confirmée."
                    alert.informativeText = "Vérifiez le réglage avec pmset -g. Pour réactiver la veille : sudo pmset -a disablesleep 0"
                    alert.addButton(withTitle: "Rester dans Moka")
                    alert.addButton(withTitle: "Quitter quand même")
                    let quit = alert.runModal() == .alertSecondButtonReturn
                    NSApp.reply(toApplicationShouldTerminate: quit)
                } else { NSApp.reply(toApplicationShouldTerminate: true) }
            }
        }
        // AppKit can wait for a deferred quit outside the default run-loop mode.
        // Continue polling restoration while menus or termination UI are tracking.
        if let quitTimer { RunLoop.main.add(quitTimer, forMode: .common) }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        iconAnimationTimer?.invalidate()
        model.shutdown()
    }

    private func renderPreview(path: String) {
        guard let view = panel?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: path)) }
        }
    }
}

@main
enum MokaMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
