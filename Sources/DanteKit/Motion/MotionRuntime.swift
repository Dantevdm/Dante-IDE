import Foundation

/// The script every scene runs inside: `window.dante`. A scene registers how to draw any
/// moment (`dante.scene({ setup, seek })`) and never keeps its own clock, so the preview,
/// the Stage and an offline 4K render all draw the same frame for the same time. The
/// runtime also hands the scene its brand, its data, helpers for easing and seeded
/// randomness, and reports readiness, time and errors back to Dante.
public enum MotionRuntime {
    public enum Mode: String, Sendable {
        /// In Dante's player: plays in real time, reports time.
        case preview
        /// On the Stage: like preview, and a deck holds at each stop.
        case present
        /// Offline: Dante calls `renderFrame(t)` for each frame.
        case render
        /// An exported page in a browser: plays itself, keys move between stops.
        case browser
    }

    /// The custom scheme scenes load from, so fonts and data come from Dante and `fetch` works.
    public static let scheme = "dante-motion"
    /// Bundled fonts are served under this path.
    public static let fontsPath = "_dante/fonts/"
    /// Project files (the logo, images) are served under this path.
    public static let projectPath = "_dante/project/"

    /// The script, with the piece, brand and data filled in.
    public static func script(piece: MotionPiece, brand: BrandKit, data: Any?, mode: Mode, pixelRatio: Double) -> String {
        let pieceJSON: [String: Any] = [
            "title": piece.title, "kind": piece.kind.rawValue, "duration": piece.duration, "fps": piece.fps,
            "width": piece.width, "height": piece.height, "stops": piece.stops,
            "narration": piece.narration.map { ["at": $0.at, "text": $0.text] },
        ]
        let config: [String: Any] = [
            "mode": mode.rawValue, "pixelRatio": pixelRatio, "piece": pieceJSON, "brand": brand.json,
            "data": data ?? NSNull(), "css": brand.css, "fonts": mode == .browser ? "" : fontFaces,
        ]
        let json = (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return "(function(){const config=\(json);\n\(body)\n})();"
    }

    /// Geist and Geist Mono from the app (they're variable fonts: every weight in one file).
    static let fontFaces = """
    @font-face{font-family:"Geist";src:url("/\(fontsPath)Geist.ttf");font-weight:100 900;font-style:normal}
    @font-face{font-family:"Geist";src:url("/\(fontsPath)Geist-Italic.ttf");font-weight:100 900;font-style:italic}
    @font-face{font-family:"Geist Mono";src:url("/\(fontsPath)GeistMono.ttf");font-weight:100 900;font-style:normal}
    """

    /// What a scene file may name under `_dante/project/`: images, fonts, models, data.
    public static let servedExtensions: Set<String> = ["svg", "png", "jpg", "jpeg", "webp", "gif", "ttf", "otf", "woff", "woff2", "glb", "gltf", "json", "mp3", "wav", "m4a", "mp4", "webm", "hdr"]

    /// The MIME type for a served file.
    public static func mimeType(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": "text/html"
        case "js", "mjs": "text/javascript"
        case "css": "text/css"
        case "json": "application/json"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "webp": "image/webp"
        case "gif": "image/gif"
        case "ttf": "font/ttf"
        case "otf": "font/otf"
        case "woff": "font/woff"
        case "woff2": "font/woff2"
        case "glb": "model/gltf-binary"
        case "gltf": "model/gltf+json"
        case "mp3": "audio/mpeg"
        case "wav": "audio/wav"
        case "m4a": "audio/mp4"
        case "mp4": "video/mp4"
        case "webm": "video/webm"
        case "wasm": "application/wasm"
        default: "application/octet-stream"
        }
    }

    /// Whether a served file is text, sent as UTF-8.
    public static func isText(_ path: String) -> Bool {
        ["html", "htm", "js", "mjs", "css", "json", "svg", "gltf"].contains((path as NSString).pathExtension.lowercased())
    }

    /// A path a scene asked for, made safe: nil when it climbs out of its folder.
    public static func safe(_ path: String) -> String? {
        let decoded = path.removingPercentEncoding ?? path
        let trimmed = decoded.hasPrefix("/") ? String(decoded.dropFirst()) : decoded
        let parts = trimmed.split(separator: "/")
        guard !parts.contains(where: { $0 == ".." }), !trimmed.contains("\0") else { return nil }
        return parts.joined(separator: "/")
    }

    // The runtime. Kept in one string so an exported page carries it too.
    static let body = #"""
    const post = (message) => { try { window.webkit.messageHandlers.dante.postMessage(message); } catch (e) {} };
    const realNow = performance.now.bind(performance);
    const realRAF = window.requestAnimationFrame.bind(window);
    const piece = config.piece;

    // Seeded randomness, so every render of a frame is the same.
    function mulberry32(seed) {
      let a = seed >>> 0;
      return function () {
        a = (a + 0x6D2B79F5) >>> 0;
        let t = a;
        t = Math.imul(t ^ (t >>> 15), t | 1);
        t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
      };
    }
    Math.random = mulberry32(0xDA17E);

    const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x));
    const ease = {
      linear: (t) => t,
      inQuad: (t) => t * t, outQuad: (t) => 1 - (1 - t) * (1 - t),
      inOutQuad: (t) => (t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2),
      inCubic: (t) => t * t * t, outCubic: (t) => 1 - Math.pow(1 - t, 3),
      inOutCubic: (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2),
      outQuart: (t) => 1 - Math.pow(1 - t, 4),
      inOutQuart: (t) => (t < 0.5 ? 8 * t * t * t * t : 1 - Math.pow(-2 * t + 2, 4) / 2),
      inExpo: (t) => (t === 0 ? 0 : Math.pow(2, 10 * t - 10)),
      outExpo: (t) => (t === 1 ? 1 : 1 - Math.pow(2, -10 * t)),
      inOutExpo: (t) => (t === 0 ? 0 : t === 1 ? 1 : t < 0.5 ? Math.pow(2, 20 * t - 10) / 2 : (2 - Math.pow(2, -20 * t + 10)) / 2),
      outBack: (t) => { const c1 = 1.70158, c3 = c1 + 1; return 1 + c3 * Math.pow(t - 1, 3) + c1 * Math.pow(t - 1, 2); },
      outElastic: (t) => (t === 0 ? 0 : t === 1 ? 1 : Math.pow(2, -10 * t) * Math.sin((t * 10 - 0.75) * ((2 * Math.PI) / 3)) + 1),
      // A critically damped spring settling from 0 to 1.
      spring: (t, stiffness = 9) => 1 - Math.exp(-stiffness * t) * (1 + stiffness * t),
    };
    // GSAP-style names ("expo.inOut", "power3.out") for the brand's default ease.
    function named(name) {
      if (!name) return ease.inOutCubic;
      if (ease[name]) return ease[name];
      const [family, kind = "out"] = String(name).split(".");
      const map = { power1: "Quad", power2: "Cubic", power3: "Quart", power4: "Quart", expo: "Expo", quad: "Quad", cubic: "Cubic", quart: "Quart", back: "Back", elastic: "Elastic" };
      const key = (kind === "inOut" ? "inOut" : kind === "in" ? "in" : "out") + (map[family] || "Cubic");
      return ease[key] || ease.inOutCubic;
    }
    // 0 before start, 1 after end, eased between.
    const progress = (t, start, end, curve) => {
      const p = clamp((t - start) / Math.max(1e-6, end - start));
      return (curve ? (typeof curve === "string" ? named(curve) : curve) : (x) => x)(p);
    };
    const lerp = (a, b, p) => a + (b - a) * p;
    // Smooth value noise, 1D and 2D, for drift and shimmer that's the same every render.
    const hash = (x, y = 0) => { const s = Math.sin(x * 127.1 + y * 311.7) * 43758.5453; return s - Math.floor(s); };
    const smooth = (t) => t * t * (3 - 2 * t);
    function noise(x, y = 0) {
      const xi = Math.floor(x), yi = Math.floor(y), xf = x - xi, yf = y - yi;
      const a = hash(xi, yi), b = hash(xi + 1, yi), c = hash(xi, yi + 1), d = hash(xi + 1, yi + 1);
      const u = smooth(xf), v = smooth(yf);
      return lerp(lerp(a, b, u), lerp(c, d, u), v) * 2 - 1;
    }

    const style = document.createElement("style");
    style.textContent = config.fonts + "\n" + config.css + `
    html, body { margin: 0; padding: 0; overflow: hidden; background: var(--brand-background); color: var(--brand-text);
      font-family: var(--brand-body); -webkit-font-smoothing: antialiased; }
    body { width: ${piece.width}px; height: ${piece.height}px; position: relative; }`;
    (document.head || document.documentElement).appendChild(style);

    // In a render, time is Dante's: a library that keeps its own clock (hairline's springs) gets
    // performance.now and requestAnimationFrame from the frame being drawn, stepped one frame at
    // a time up to it, so a film renders the same every time. Going back jumps the clock.
    let virtualMs = 0, nextFrameId = 1;
    const frameCallbacks = new Map();
    if (config.mode === "render") {
      performance.now = () => virtualMs;
      window.requestAnimationFrame = (callback) => { const id = nextFrameId++; frameCallbacks.set(id, callback); return id; };
      window.cancelAnimationFrame = (id) => { frameCallbacks.delete(id); };
    }
    function stepClock(t) {
      const target = t * 1000, step = 1000 / piece.fps;
      if (target < virtualMs) virtualMs = target;
      for (let guard = 0; virtualMs < target - 1e-6 && guard < 900; guard++) {
        virtualMs = Math.min(target, virtualMs + step);
        const due = [...frameCallbacks.values()];
        frameCallbacks.clear();
        due.forEach((callback) => { try { callback(virtualMs); } catch (e) { post({ type: "error", message: String(e && e.stack || e) }); } });
      }
    }

    let scene = null, ready = false, readyWaiters = [], time = 0, playing = false, startClock = 0, startTime = 0, lastPost = 0, rate = 1;

    async function draw(t) {
      time = clamp(t, 0, piece.duration);
      dante.time = time;
      if (scene && scene.seek) await scene.seek(time);
    }

    function report(force) {
      const now = realNow();
      if (force || now - lastPost > 90) { lastPost = now; post({ type: "time", t: time, playing }); }
    }

    function tick() {
      if (!playing) return;
      let t = startTime + ((realNow() - startClock) / 1000) * rate;
      // A deck on the Stage (or exported) holds at its next stop.
      if ((config.mode === "present" || config.mode === "browser") && holdAt !== null && t >= holdAt) {
        t = holdAt; playing = false; holdAt = null;
      }
      if (t >= piece.duration) { t = piece.duration; playing = false; }
      draw(t).then(() => report(!playing));
      if (playing) realRAF(tick);
      else post({ type: "paused", t: time });
    }
    let holdAt = null;

    function whenReady() { return ready ? Promise.resolve() : new Promise((resolve) => readyWaiters.push(resolve)); }

    const dante = {
      mode: config.mode, piece, brand: config.brand, data: config.data, pixelRatio: config.pixelRatio,
      time: 0, clamp, lerp, ease, progress, noise, random: mulberry32, named,
      // The brand's default ease.
      get defaultEase() { return named(config.brand.motion && config.brand.motion.ease); },
      scene(definition) {
        scene = typeof definition === "function" ? { seek: definition } : definition;
        Promise.resolve(scene.setup ? scene.setup({ width: piece.width, height: piece.height, pixelRatio: config.pixelRatio }) : null)
          .then(() => (document.fonts ? document.fonts.ready : null))
          .then(() => draw(0))
          .then(() => {
            ready = true; readyWaiters.splice(0).forEach((r) => r());
            post({ type: "ready", duration: piece.duration });
            if (config.mode === "browser") dante.play();
          })
          .catch((error) => post({ type: "error", message: String(error && error.stack || error) }));
      },
      async renderFrame(t) { await whenReady(); stepClock(t); await draw(t); return true; },
      play(from) {
        if (typeof from === "number") time = from;
        if (time >= piece.duration - 1e-3) time = 0;
        if ((config.mode === "present" || config.mode === "browser") && piece.kind === "deck") {
          const next = piece.stops.find((s) => s > time + 0.01);
          holdAt = next === undefined ? null : next;
        }
        startTime = time; startClock = realNow(); playing = true; realRAF(tick);
      },
      pause() { playing = false; holdAt = null; report(true); },
      async go(t) { playing = false; holdAt = null; await whenReady(); await draw(t); report(true); },
      next() { dante.play(); },
      async previous() {
        const before = piece.stops.filter((s) => s < time - 0.05);
        const back = before.length > 1 ? before[before.length - 2] : 0;
        await dante.go(back); dante.play();
      },
      setRate(r) { startTime = time; startClock = realNow(); rate = r; },
    };
    window.dante = dante;

    window.addEventListener("error", (event) => post({ type: "error", message: String(event.message), line: event.lineno, file: String(event.filename || "").split("/").pop() }));
    window.addEventListener("unhandledrejection", (event) => post({ type: "error", message: String(event.reason && event.reason.stack || event.reason) }));
    if (config.mode === "browser") {
      window.addEventListener("keydown", (event) => {
        if (["ArrowRight", " ", "PageDown"].includes(event.key)) dante.next();
        if (["ArrowLeft", "PageUp"].includes(event.key)) dante.previous();
      });
      const fit = () => { const s = Math.min(innerWidth / piece.width, innerHeight / piece.height); document.body.style.transformOrigin = "0 0"; document.body.style.transform = `translate(${(innerWidth - piece.width * s) / 2}px, ${(innerHeight - piece.height * s) / 2}px) scale(${s})`; };
      window.addEventListener("resize", fit); window.addEventListener("load", fit);
    }
    """#
}
