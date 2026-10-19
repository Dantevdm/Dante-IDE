import AppKit
import DanteKit
import MetalKit
import simd

/// The orb at any size: the menu bar's 22 points, the presence panel, or a TV.
/// It eases towards each new mood's colours and pace, and dims as it dozes off when tired.
/// Drawing stops while it can't be seen.
final class OrbView: MTKView, MTKViewDelegate {
    enum Size {
        /// The menu bar: fewer octaves of noise and a lower frame rate.
        case menuBar
        /// The panel and full screen: full detail at 60 fps.
        case large
    }

    private struct Uniforms {
        var p0: SIMD4<Float>
        var p1: SIMD4<Float>
        var p2: SIMD4<Float>
        var p3: SIMD4<Float>
        var p4: SIMD4<Float>
        var c0: SIMD4<Float>
        var c1: SIMD4<Float>
        var c2: SIMD4<Float>
        var c3: SIMD4<Float>
        var p5 = SIMD4<Float>(0, 0, 0, 0)
        var s0 = SIMD4<Float>(0, 0, 0, 0), s1 = SIMD4<Float>(0, 0, 0, 0), s2 = SIMD4<Float>(0, 0, 0, 0)
        var s3 = SIMD4<Float>(0, 0, 0, 0), s4 = SIMD4<Float>(0, 0, 0, 0), s5 = SIMD4<Float>(0, 0, 0, 0)
        var k0 = SIMD4<Float>(0, 0, 0, 0), k1 = SIMD4<Float>(0, 0, 0, 0), k2 = SIMD4<Float>(0, 0, 0, 0)
        var k3 = SIMD4<Float>(0, 0, 0, 0), k4 = SIMD4<Float>(0, 0, 0, 0), k5 = SIMD4<Float>(0, 0, 0, 0)

        /// Fills the satellite slots (the shader takes six) and the beams' strength.
        mutating func place(_ frames: [Constellation.Frame], beams: Float) {
            let packed = frames.prefix(Constellation.limit).map { frame in
                (SIMD4(Float(frame.x), Float(frame.y), Float(frame.radius), Float(frame.depth)),
                 SIMD4(Float(frame.color.red), Float(frame.color.green), Float(frame.color.blue), Float(frame.out)))
            }
            p5 = SIMD4(Float(packed.count), beams, 0, 0)
            let empty = (SIMD4<Float>(0, 0, 0, 0), SIMD4<Float>(0, 0, 0, 0))
            let all = packed + Array(repeating: empty, count: Constellation.limit - packed.count)
            (s0, k0) = all[0]; (s1, k1) = all[1]; (s2, k2) = all[2]
            (s3, k3) = all[3]; (s4, k4) = all[4]; (s5, k5) = all[5]
        }
    }

    /// Eased values: each frame moves the current ones towards the targets.
    private struct Animated {
        var colors: [SIMD3<Float>]
        var energy: Float
        var glow: Float
        var flicker: Float
        var ring: Float
        var aura: Float
        var lightning: Float
        var pulseDepth: Float
        var pulseRate: Float
        var drowse: Float
        /// Drains the colours as usage runs low.
        var fatigue: Float = 0

        init(_ style: OrbStyle, fatigue: Double = 0) {
            drowse = Float(style.drowse)
            self.fatigue = Float(fatigue)
            colors = style.colors.map { SIMD3(Float($0.red), Float($0.green), Float($0.blue)) }
            energy = Float(style.energy)
            glow = Float(style.glow)
            flicker = Float(style.flicker)
            ring = Float(style.ring)
            aura = Float(style.aura)
            lightning = Float(style.lightning)
            pulseDepth = Float(style.pulseDepth)
            pulseRate = Float(style.pulseRate)
        }
    }

    let size: Size
    /// The mood shown now. Setting it starts the ease to the new style, with a start for
    /// moods that want attention.
    var mood: PresenceMood = .asleep {
        didSet {
            guard mood != oldValue else { return }
            retarget()
            if mood == .needsYou || mood == .trouble || mood == .done { kick = 1 }
            // Every change of mood is a power-up: a flash and a shockwave.
            burstStarted = now
            formStarted = now
            form = 0
            updateFrameRate()
        }
    }
    /// How hard Claude is working and how tired it is; eased like the mood.
    var vitality = Vitality() {
        didSet {
            guard vitality != oldValue else { return }
            let colors = target.colors
            retarget()
            // Keep the idle form's colours; fatigue drains them as they're drawn.
            if mood == .idle { target.colors = colors }
        }
    }

    private func retarget() {
        target = Animated(OrbStyle.of(mood).adjusted(for: vitality), fatigue: vitality.fatigue)
    }

    /// Sub-agents and local models at work: each buds off the orb, circles it and merges back
    /// when it's done. Large orbs only; at menu bar size they'd be a few pixels of noise.
    var satellites: [OrbSatellite] = [] {
        didSet {
            guard size == .large, satellites != oldValue else { return }
            constellation.update(satellites, at: satelliteClock)
            // A split is a small effort: the orb tenses.
            if satellites.count > oldValue.count { kick = max(kick, 0.45) }
        }
    }
    private var constellation = Constellation()
    /// Told where the satellites are each frame, so the Stage can draw what each is doing
    /// beside it, in step with the shader.
    weak var track: SatelliteTrack?
    private var publishedNone = true
    /// Large orbs only; the Stage asks for more on fast displays.
    var framesPerSecond = 60 {
        didSet { updateFrameRate() }
    }

    private static let shared: (device: MTLDevice, pipeline: MTLRenderPipelineState, queue: MTLCommandQueue)? = {
        guard let device = MTLCreateSystemDefaultDevice(),
              let library = try? device.makeLibrary(source: OrbShader.source, options: nil),
              let queue = device.makeCommandQueue() else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "orbVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "orbFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        return (device, pipeline, queue)
    }()

    private var current: Animated
    private var target: Animated
    private let start = CACurrentMediaTime()
    private var lastFrame = CACurrentMediaTime()
    private var clock: Double = 0
    private var phase: Double = 0
    private var kick: Float = 0
    private var burstStarted: Double?
    private var form = 0
    private var formStarted: Double = 0
    private var wakeStarted: Double?
    private var nodStarted: Double?
    private var nextNod: Double = 12
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var occluded = false

    private var now: Double { CACurrentMediaTime() - start }
    /// The constellation's time: seconds of drawing, slowed with Reduce Motion.
    private var satelliteClock: Double = 0

    init(size: Size, mood: PresenceMood = .asleep) {
        self.size = size
        self.mood = mood
        current = Animated(OrbStyle.of(mood))
        target = current
        super.init(frame: .zero, device: Self.shared?.device)
        delegate = self
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        framebufferOnly = true
        layer?.isOpaque = false
        layer?.backgroundColor = .clear
        autoResizeDrawable = true
        updateFrameRate()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screensAsleep), name: name, object: nil)
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screensAwake), name: name, object: nil)
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Clicks go to whatever holds the orb (the status item's button).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Plays the waking animation: the orb grows from a spark with a little overshoot.
    func wake() { wakeStarted = now }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged), name: NSWindow.didChangeOcclusionStateNotification, object: window)
            occluded = !window.occlusionState.contains(.visible)
        }
        updatePaused()
    }

    @objc private func occlusionChanged() {
        occluded = !(window?.occlusionState.contains(.visible) ?? false)
        updatePaused()
    }

    @objc private func accessibilityChanged() { reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    @objc private func screensAsleep() { isPaused = true }
    @objc private func screensAwake() { updatePaused() }

    private func updatePaused() {
        isPaused = window == nil || occluded || Self.shared == nil
        lastFrame = CACurrentMediaTime()
    }

    private func updateFrameRate() {
        preferredFramesPerSecond = size == .large ? framesPerSecond : OrbStyle.of(mood).framesPerSecond
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    /// The orb in one mood as a still image, drawn offscreen: for checking the look of every
    /// mood at once (`DANTE_ORB_SNAPSHOTS=<folder>`) and for screenshots.
    static func snapshot(mood: PresenceMood, pixels: Int, size: Size, time: Float = 14, burst: Float = 1,
                         satellites: [Constellation.Frame] = []) -> CGImage? {
        guard let shared else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: pixels, height: pixels, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = shared.device.makeTexture(descriptor: descriptor),
              let buffer = shared.queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        let style = Animated(OrbStyle.of(mood))
        let colors = style.colors.map { SIMD4<Float>($0, 1) }
        var uniforms = Uniforms(
            p0: SIMD4(Float(pixels), Float(pixels), time, style.energy),
            p1: SIMD4(style.drowse, 0, 0, 0),
            p2: SIMD4(style.pulseDepth * 0.5, 0, style.glow, size == .large ? 1 : 0),
            p3: SIMD4(1, time * 0.01, style.ring, 0),
            p4: SIMD4(style.aura, style.lightning, burst, burst < 1 ? 1 : 0),
            c0: colors[0], c1: colors[1], c2: colors[2], c3: colors[3]
        )
        uniforms.place(satellites, beams: 1)
        encoder.setRenderPipelineState(shared.pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: pixels * pixels * 4)
        texture.getBytes(&bytes, bytesPerRow: pixels * 4, from: MTLRegionMake2D(0, 0, pixels, pixels), mipmapLevel: 0)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: pixels, height: pixels, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pixels * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Writes every mood at both sizes into a folder, as PNGs.
    static func writeSnapshots(to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for mood in PresenceMood.allCases {
            for (size, pixels, name) in [(Size.large, 640, "large"), (Size.menuBar, 48, "menubar")] {
                guard let image = snapshot(mood: mood, pixels: pixels, size: size) else { continue }
                let rep = NSBitmapImageRep(cgImage: image)
                try? rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "\(mood.rawValue)-\(name).png"))
            }
        }
        for (index, burst) in [Float(0.15), 0.4, 0.7].enumerated() {
            guard let image = snapshot(mood: .acting, pixels: 640, size: .large, burst: burst) else { continue }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: folder.appending(path: "burst-\(index).png"))
        }
        // Agents splitting off, circling and merging back.
        var constellation = Constellation()
        let agents = ["Explore", "summary", "Plan"].map { name in
            OrbSatellite(id: name, kind: name == "summary" ? .local(name) : .subagent(name),
                         color: name == "summary" ? RGBA(0x1DE9B6) : name == "Plan" ? RGBA(0xB388FF) : RGBA(0x40C4FF), title: name)
        }
        constellation.update(agents, at: 0)
        for (index, t) in [0.4, 0.9, 3.0, 6.0].enumerated() {
            let frames = constellation.frames(at: t, mainRadius: 0.46, satelliteRadius: 0.1).frames
            guard let image = snapshot(mood: .acting, pixels: 640, size: .large, time: Float(14 + t), satellites: frames) else { continue }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: folder.appending(path: "constellation-\(index).png"))
        }
    }

    func draw(in view: MTKView) {
        guard let shared = Self.shared,
              let pass = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let buffer = shared.queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = step()
        encoder.setRenderPipelineState(shared.pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    /// Advances the animation one frame and returns what the shader needs.
    private func step() -> Uniforms {
        let frameTime = CACurrentMediaTime()
        let dt = Float(min(frameTime - lastFrame, 0.1))
        lastFrame = frameTime
        let t = now
        let pace: Float = reduceMotion ? 0.25 : 1

        // Ease every value towards its target; colours a little slower, so moods blend.
        func ease(_ rate: Float) -> Float { 1 - exp(-dt * rate) }
        for i in 0..<4 { current.colors[i] += (target.colors[i] - current.colors[i]) * ease(2.2) }
        current.energy += (target.energy - current.energy) * ease(3)
        current.glow += (target.glow - current.glow) * ease(3)
        current.flicker += (target.flicker - current.flicker) * ease(5)
        current.ring += (target.ring - current.ring) * ease(2)
        current.aura += (target.aura - current.aura) * ease(2.5)
        current.lightning += (target.lightning - current.lightning) * ease(4)
        current.drowse += (target.drowse - current.drowse) * ease(2)
        current.fatigue += (target.fatigue - current.fatigue) * ease(0.8)

        // At rest it cycles through forms.
        if mood == .idle, t - formStarted > OrbStyle.formDuration {
            formStarted = t
            form = (form + 1) % OrbStyle.idleForms.count
            target.colors = OrbStyle.idleForms[form].map { SIMD3(Float($0.red), Float($0.green), Float($0.blue)) }
        }
        var burst: Float = 1
        if let started = burstStarted {
            burst = Float(min(1, (t - started) / 0.9))
            if burst >= 1 { burstStarted = nil }
        }
        current.pulseDepth += (target.pulseDepth - current.pulseDepth) * ease(3)
        current.pulseRate += (target.pulseRate - current.pulseRate) * ease(3)
        kick = max(0, kick - dt * 1.6)

        // Time runs faster when there's more energy, so the plasma speeds up rather than jumps.
        clock += Double(dt * pace * (0.6 + current.energy * 0.8))
        phase += Double(dt * current.pulseRate * pace)
        let wave = Float(0.5 + 0.5 * sin(phase * 2 * .pi))
        let pulse = min(1, current.pulseDepth * wave * wave + kick * 0.8)

        // Tired: it dims and sways, and now and then nods off for a moment.
        var drowse = current.drowse
        if current.fatigue > 0.05, mood != .asleep {
            drowse += Float(0.06 * sin(t * 0.9)) * current.fatigue
            if let started = nodStarted {
                let elapsed = t - started
                if elapsed < 1.8 {
                    drowse = max(drowse, Float(sin(elapsed / 1.8 * .pi)) * 0.95)
                } else {
                    nodStarted = nil
                    nextNod = t + Double.random(in: 9...22) / Double(max(0.3, current.fatigue))
                }
            } else if current.fatigue > 0.35, t >= nextNod, !reduceMotion {
                nodStarted = t
            }
        }
        drowse = min(1, max(0, drowse))

        var wake: Float = 1
        if let started = wakeStarted {
            let w = t - started
            if w < 2 {
                wake = Float(max(0.02, 1 - exp(-w * 4.5) * cos(w * 8)))
            } else {
                wakeStarted = nil
            }
        }

        // Fatigue drains the colour towards a dim grey.
        let colors = current.colors.map { color -> SIMD4<Float> in
            let grey = SIMD3<Float>(repeating: simd_dot(color, SIMD3(0.3, 0.59, 0.11)) * 0.6)
            return SIMD4(color + (grey - color) * current.fatigue * 0.7, 1)
        }
        var uniforms = Uniforms(
            p0: SIMD4(Float(drawableSize.width), Float(drawableSize.height), Float(clock), current.energy * pace),
            p1: SIMD4(drowse, 0, 0, 0),
            p2: SIMD4(pulse * (reduceMotion ? 0.3 : 1), current.flicker * (reduceMotion ? 0.2 : 1), current.glow, size == .large ? 1 : 0),
            p3: SIMD4(wake, Float(t * 0.01), current.ring, 0),
            p4: SIMD4(current.aura * (reduceMotion ? 0.5 : 1), reduceMotion ? 0 : current.lightning, burst, burst < 1 && !reduceMotion ? 1 : 0),
            c0: colors[0], c1: colors[1], c2: colors[2], c3: colors[3]
        )
        if !constellation.isEmpty {
            // Satellites keep their own clock, slowed like everything else for Reduce Motion.
            satelliteClock += Double(dt * pace)
            let (frames, merged) = constellation.frames(at: satelliteClock, mainRadius: 0.46 * Double(wake), satelliteRadius: 0.1)
            // Each one merging back lands with a pulse.
            if merged > 0 { kick = min(1, kick + 0.6 * Float(merged)) }
            uniforms.place(frames, beams: reduceMotion ? 0.4 : 0.7 + 0.3 * current.energy)
            track?.moved(frames, time: satelliteClock)
            publishedNone = frames.isEmpty
        } else if !publishedNone {
            track?.moved([], time: satelliteClock)
            publishedNone = true
        }
        return uniforms
    }
}
