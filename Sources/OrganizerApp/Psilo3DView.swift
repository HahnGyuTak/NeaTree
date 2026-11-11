import AppKit
import Combine
import OrganizerAppSupport
import RealityKit
import SwiftUI
import simd

@MainActor private var psiloDebugLoggingEnabled: Bool {
    #if DEBUG
    CommandLine.arguments.contains("--psilo-demo")
        || Bundle.main.object(forInfoDictionaryKey: "PsiloMotionLabMode") as? Bool == true
    #else
    false
    #endif
}

/// One transparent, mouse-pass-through viewport for Psilo's real USD model.
/// Keep this view's identity stable while changing its frame between placements.
@MainActor
struct Psilo3DView: NSViewRepresentable {
    let activity: PsiloActivity
    let issue: PsiloIssue?
    var isPresented = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> PsiloViewportHost {
        let view = PsiloViewportHost()
        view.configure(activity: activity, issue: issue, presented: isPresented, reduceMotion: reduceMotion)
        return view
    }

    func updateNSView(_ nsView: PsiloViewportHost, context: Context) {
        nsView.configure(activity: activity, issue: issue, presented: isPresented, reduceMotion: reduceMotion)
    }

    static func dismantleNSView(_ nsView: PsiloViewportHost, coordinator: ()) {
        nsView.shutdown()
    }
}

/// ARView on macOS has no public pause API. Removing and releasing the rendering
/// view is deliberate: a minimized or hidden window retains its pose, not a live
/// Metal viewport. The mesh stays loaded for a quick, continuous return.
@MainActor
final class PsiloViewportHost: NSView {
    private var renderer: ARView?
    private let anchor = AnchorEntity(world: .zero)
    private let driver = PsiloMotionDriver()
    private var loadSubscription: AnyCancellable?
    private var updateSubscription: (any Cancellable)?
    private var notifications: [NSObjectProtocol] = []
    private var mouseMonitor: Any?
    private weak var trackedWindow: NSWindow?
    private var previousMouseMovedSetting: Bool?
    private var presented = true
    private var didStartLoading = false
    private var lastVisibility = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    func configure(activity: PsiloActivity, issue: PsiloIssue?, presented: Bool, reduceMotion: Bool) {
        self.presented = presented
        driver.reduceMotion = reduceMotion
        driver.receive(activity: activity, issue: issue)
        reconcileVisibility()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        uninstallObservation()
        guard let window else { stopRendering(); return }
        trackedWindow = window
        previousMouseMovedSetting = window.acceptsMouseMovedEvents
        window.acceptsMouseMovedEvents = true
        let center = NotificationCenter.default
        for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification] {
            notifications.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                let isClosing = note.name == NSWindow.willCloseNotification
                MainActor.assumeIsolated {
                    if isClosing { self?.stopRendering() }
                    else { self?.reconcileVisibility() }
                }
            })
        }
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            notifications.append(center.addObserver(forName: name, object: NSApp, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcileVisibility() }
            })
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated { self?.trackMouse(event) }
            return event
        }
        reconcileVisibility()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        reconcileVisibility()
    }

    override var isHidden: Bool {
        didSet { reconcileVisibility() }
    }

    override func layout() {
        super.layout()
        renderer?.frame = bounds
        reconcileVisibility()
    }

    func shutdown() {
        uninstallObservation()
        stopRendering()
        loadSubscription?.cancel()
        loadSubscription = nil
    }

    private func uninstallObservation() {
        notifications.forEach(NotificationCenter.default.removeObserver)
        notifications.removeAll()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        if let previousMouseMovedSetting { trackedWindow?.acceptsMouseMovedEvents = previousMouseMovedSetting }
        previousMouseMovedSetting = nil
        trackedWindow = nil
    }

    private func reconcileVisibility() {
        let visible = presented && window != nil && window?.isVisible == true
            && window?.isMiniaturized == false && !NSApp.isHidden
            && window?.occlusionState.contains(.visible) == true
            && !isHiddenOrHasHiddenAncestor && bounds.width > 1 && bounds.height > 1
        if visible {
            startLoadingIfNeeded()
            startRendering()
        } else {
            stopRendering()
        }
    }

    private func startLoadingIfNeeded() {
        guard !didStartLoading else { return }
        didStartLoading = true
        guard let url = modelURL else {
            NSLog("NeaTree: Psilo.usdz is missing from the application resources.")
            return
        }
        loadSubscription = Entity.loadAsync(contentsOf: url)
            .receive(on: RunLoop.main)
            .sink(receiveCompletion: { completion in
                if case .failure(let error) = completion { NSLog("NeaTree: Psilo model load failed: %@", error.localizedDescription) }
            }, receiveValue: { [weak self] model in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.driver.attach(model)
                    self.anchor.addChild(model)
                }
            })
    }

    private var modelURL: URL? {
        if let resources = Bundle.main.resourceURL,
           let bundle = Bundle(url: resources.appendingPathComponent("NeaTree_OrganizerApp.bundle")),
           let url = bundle.url(forResource: "Psilo", withExtension: "usdz") { return url }
        guard Bundle.main.bundleURL.pathExtension != "app" else { return nil }
        return Bundle.module.url(forResource: "Psilo", withExtension: "usdz")
    }

    private func startRendering() {
        guard renderer == nil else { return }
        let view = ARView(frame: bounds)
        view.environment.background = .color(.clear)
        view.environment.reverb = .noReverb
        let camera = PerspectiveCamera()
        camera.camera = PerspectiveCameraComponent(near: 0.01, far: 2, fieldOfViewInDegrees: 26)
        camera.look(at: [0, 0.072, 0], from: [0, 0.072, 0.45], relativeTo: nil)
        let cameraAnchor = AnchorEntity(world: .zero)
        cameraAnchor.addChild(camera)
        let light = DirectionalLight()
        light.light.intensity = 1_100
        light.shadow = nil
        light.look(at: .zero, from: [-0.4, 0.7, 0.6], relativeTo: nil)
        cameraAnchor.addChild(light)
        view.scene.addAnchor(cameraAnchor)
        view.scene.addAnchor(anchor)
        updateSubscription = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            MainActor.assumeIsolated { self?.driver.update(deltaTime: Float(event.deltaTime)) }
        }
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        renderer = view
        lastVisibility = true
        if psiloDebugLoggingEnabled { NSLog("Psilo renderer active") }
    }

    private func stopRendering() {
        guard let renderer else { return }
        updateSubscription?.cancel()
        updateSubscription = nil
        renderer.scene.removeAnchor(anchor)
        renderer.removeFromSuperview()
        self.renderer = nil
        driver.cursor = .zero
        if lastVisibility && psiloDebugLoggingEnabled { NSLog("Psilo renderer stopped (no hidden viewport)") }
        lastVisibility = false
    }

    private func trackMouse(_ event: NSEvent) {
        guard renderer != nil, NSApp.isActive, event.window === window, let window else { return }
        let point = convert(event.locationInWindow, from: nil)
        let width = max(window.contentView?.bounds.width ?? bounds.width, 1)
        let height = max(window.contentView?.bounds.height ?? bounds.height, 1)
        driver.cursor = SIMD2<Float>(
            Float(max(-1, min(1, (point.x - bounds.midX) / (width * 0.5)))),
            Float(max(-1, min(1, (point.y - bounds.midY) / (height * 0.5))))
        )
    }
}

/// Continuous pose parameters are integrated with damped springs, rather than
/// resetting clips to frame zero. Work, celebration and error can interrupt one
/// another without throwing away the current pose or accessory positions.
@MainActor
private final class PsiloMotionDriver {
    var reduceMotion = false
    var cursor = SIMD2<Float>.zero
    private enum Mode { case idle, working, celebrating, error }
    private var mode: Mode = .idle
    private var lastID: UUID?
    private var lastPhase: PsiloActivity.Phase?
    private var clock: Float = 0
    private var modeTime: Float = 0
    private var errorKeepsWork = false
    private var root: Entity?
    private var head: Entity?
    private var hat: Entity?
    private var horns: Entity?
    private var glasses: Entity?
    private var errorEyes: Entity?
    private var eyes: [Entity] = []
    private var spirals: [Entity] = []
    private var idleMouth: Entity?
    private var proudMouth: Entity?
    private var files: [Entity] = []
    private var poses: [ObjectIdentifier: Transform] = [:]
    private var yaw = PsiloSpring(), pitch = PsiloSpring(), roll = PsiloSpring()
    private var lookX = PsiloSpring(), lookY = PsiloSpring()
    private var accessoryPitch = PsiloSpring(), accessoryRoll = PsiloSpring()
    private var work = PsiloSpring(), proud = PsiloSpring(), confused = PsiloSpring()
    private var fileAmounts = [PsiloSpring(), PsiloSpring(), PsiloSpring()]

    func receive(activity: PsiloActivity, issue: PsiloIssue?) {
        let phaseChanged = lastID != activity.id || lastPhase != activity.phase
        if phaseChanged && psiloDebugLoggingEnabled {
            NSLog("Psilo activity: %@ / %@ / %@", activity.kind?.rawValue ?? "none", activity.phase.rawValue, activity.outcome?.rawValue ?? "none")
        }
        lastID = activity.id
        lastPhase = activity.phase
        let desired: Mode
        if activity.phase == .working { desired = .working }
        else if issue != nil || activity.phase == .failed { desired = .error }
        else if activity.phase == .succeeded && phaseChanged { desired = .celebrating }
        else if activity.phase == .succeeded && mode == .celebrating { desired = .celebrating }
        else { desired = .idle }
        if desired != mode {
            if desired == .error { errorKeepsWork = work.value > 0.15 }
            mode = desired
            modeTime = 0
        }
    }

    func attach(_ entity: Entity) {
        root = entity
        head = entity.findEntity(named: "Head")
        hat = entity.findEntity(named: "Hat")
        horns = entity.findEntity(named: "Horns")
        glasses = entity.findEntity(named: "Glasses")
        errorEyes = entity.findEntity(named: "ErrorEyes")
        eyes = ["eye_L", "eye_R"].compactMap { entity.findEntity(named: $0) }
        spirals = ["spiral_L", "spiral_R"].compactMap { entity.findEntity(named: $0) }
        idleMouth = entity.findEntity(named: "mouth_idle")
        proudMouth = entity.findEntity(named: "mouth_proud")
        files = (0..<3).compactMap { entity.findEntity(named: "file_\($0)") }
        let parts = [entity] + [head, hat, horns, glasses, errorEyes, idleMouth, proudMouth].compactMap { $0 } + eyes + spirals + files
        for part in parts { poses[ObjectIdentifier(part)] = part.transform }
        if psiloDebugLoggingEnabled {
            NSLog("Psilo rig loaded: head=%d, eyes=%ld, files=%ld, spirals=%ld", head == nil ? 0 : 1, eyes.count, files.count, spirals.count)
        }
        update(deltaTime: 1 / 60)
    }

    func update(deltaTime: Float) {
        guard let root else { return }
        let dt = max(0, min(deltaTime, 1 / 30))
        clock += dt
        modeTime += dt
        if mode == .celebrating && modeTime > 2.5 { mode = .idle; modeTime = 0 }
        let activeWork = mode == .working || (mode == .error && errorKeepsWork)
        let finishingWork = mode == .celebrating && modeTime < 0.35 && work.value > 0.1
        let workTarget: Float = (activeWork && (modeTime > 0.3 || work.value > 0.1)) || finishingWork ? 1 : 0
        let prideTarget: Float = mode == .celebrating ? 1 : 0
        let errorTarget: Float = mode == .error ? 1 : 0
        work.step(to: workTarget, dt: dt, frequency: 3.8)
        proud.step(to: prideTarget, dt: dt, frequency: 3.5)
        confused.step(to: errorTarget, dt: dt, frequency: 3.4)

        let motion: Float = reduceMotion ? 0 : 1
        let scanning = sin(clock * 1.65) * 0.65
        let gazeX = cursor.x * (1 - work.value) + scanning * work.value
        let gazeY = cursor.y * (1 - work.value) - 0.65 * work.value
        lookX.step(to: gazeX, dt: dt, frequency: 7)
        lookY.step(to: gazeY, dt: dt, frequency: 7)
        let proudWiggle = sin(modeTime * 7.1) * max(0, 1 - modeTime / 2.4) * proud.value
        let wobble = sin(clock * 5.2) * confused.value
        yaw.step(to: (gazeX * 0.15 + proudWiggle * 0.06) * motion, dt: dt, frequency: 3.5)
        pitch.step(to: (-gazeY * 0.09 - proud.value * 0.055) * motion, dt: dt, frequency: 3.2)
        roll.step(to: (proudWiggle * 0.065 + wobble * 0.07) * motion, dt: dt, frequency: 3)
        accessoryPitch.step(to: pitch.value, dt: dt, frequency: 2.2)
        accessoryRoll.step(to: roll.value, dt: dt, frequency: 2.2)
        if let head {
            var t = original(head)
            t.rotation = t.rotation * simd_quatf(angle: yaw.value, axis: [0, 1, 0])
                * simd_quatf(angle: pitch.value, axis: [1, 0, 0])
                * simd_quatf(angle: roll.value, axis: [0, 0, 1])
            t.translation.y += (sin(clock * 1.7) * 0.0007 + abs(proudWiggle) * 0.002) * motion
            head.transform = t
        }
        // The hat and blunt horns settle slightly after the head, like soft
        // lightweight props, without a physics solver or extra animation clips.
        for (part, weight) in [(hat, Float(1)), (horns, Float(0.45))] {
            guard let part else { continue }
            var t = original(part)
            t.rotation = t.rotation
                * simd_quatf(angle: (accessoryPitch.value - pitch.value) * weight, axis: [1, 0, 0])
                * simd_quatf(angle: (accessoryRoll.value - roll.value) * weight, axis: [0, 0, 1])
            part.transform = t
        }
        var rootPose = original(root)
        rootPose.scale.y *= 1 + sin(clock * 1.7) * 0.008 * motion
        root.transform = rootPose

        // A narrow eyelid-like squash preserves the original tiny black eyes.
        let blinkTime = clock.truncatingRemainder(dividingBy: 4.1)
        let blink = reduceMotion ? Float(1) : 1 - 0.9 * exp(-pow((blinkTime - 3.8) / 0.075, 2))
        for eye in eyes {
            var t = original(eye)
            t.translation.x += lookX.value * 0.0011 * motion
            t.translation.y += lookY.value * 0.0007 * motion
            t.scale *= max(0.001, 1 - confused.value)
            t.scale.y *= blink
            eye.isEnabled = 1 - confused.value > 0.003
            eye.transform = t
        }
        if let glasses {
            var t = original(glasses)
            let amount = max(0.001, min(1, work.value))
            t.scale = SIMD3(repeating: amount)
            t.translation.y += (1 - amount) * 0.045 * motion
            t.rotation = t.rotation * simd_quatf(angle: (1 - amount) * -0.22 * motion, axis: [0, 0, 1])
            glasses.isEnabled = amount > 0.003
            glasses.transform = t
        }
        if let errorEyes {
            var t = original(errorEyes)
            t.scale = SIMD3(repeating: max(0.001, confused.value))
            errorEyes.isEnabled = confused.value > 0.003
            errorEyes.transform = t
        }
        for spiral in spirals where confused.value > 0.003 {
            var t = original(spiral)
            t.rotation = t.rotation * simd_quatf(angle: clock * 2.6 * motion, axis: [0, 0, 1])
            spiral.transform = t
        }
        if let idleMouth {
            var t = original(idleMouth)
            t.scale *= max(0.001, 1 - proud.value)
            t.scale.y *= 1 - work.value * 0.7
            idleMouth.isEnabled = 1 - proud.value > 0.003
            idleMouth.transform = t
        }
        if let proudMouth {
            var t = original(proudMouth)
            t.scale = SIMD3(repeating: max(0.001, proud.value))
            proudMouth.isEnabled = proud.value > 0.003
            proudMouth.transform = t
        }
        for (index, file) in files.enumerated() {
            let finishingFile = mode == .celebrating && modeTime < 0.35 && fileAmounts[index].value > 0.1
            let target: Float = (activeWork && (modeTime > Float(index) * 0.12 || fileAmounts[index].value > 0.1)) || finishingFile ? 1 : 0
            fileAmounts[index].step(to: target, dt: dt, frequency: 3.8)
            let amount = max(0, min(1, fileAmounts[index].value))
            var t = original(file)
            let direction: Float = index == 1 ? -1 : 1
            if !reduceMotion {
                let origin = SIMD3<Float>(direction * 0.135, 0.15 + Float(index) * 0.007, 0.02)
                let c1 = SIMD3<Float>(direction * 0.12, 0.17, 0.04)
                let c2 = t.translation + SIMD3<Float>(0, 0.024, 0.02)
                t.translation = bezier(origin, c1, c2, t.translation, amount)
                t.rotation = t.rotation * simd_quatf(angle: (1 - amount) * direction * 1.3, axis: [0, 0, 1])
            }
            t.scale = SIMD3(repeating: max(0.001, amount))
            file.isEnabled = amount > 0.003
            file.transform = t
        }
    }

    private func original(_ entity: Entity) -> Transform { poses[ObjectIdentifier(entity)] ?? entity.transform }
    private func bezier(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        let u = 1 - t
        return u * u * u * a + 3 * u * u * t * b + 3 * u * t * t * c + t * t * t * d
    }
}

private struct PsiloSpring {
    var value: Float = 0
    private var velocity: Float = 0

    mutating func step(to target: Float, dt: Float, frequency: Float) {
        // Analytic critically damped spring: stable across frame-time variation,
        // continuous velocity when an operation changes in the middle of a pose.
        let omega = frequency * 2 * Float.pi
        let displacement = value - target
        let decay = exp(-omega * dt)
        let c = velocity + omega * displacement
        value = target + (displacement + c * dt) * decay
        velocity = (velocity - omega * c * dt) * decay
    }
}
