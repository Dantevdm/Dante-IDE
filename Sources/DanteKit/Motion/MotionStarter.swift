import Foundation

/// The scene a new piece starts with: its title set in the brand, rising out of a slow field
/// of light, so it plays (and shows the contract working) before the agent has written a frame.
public enum MotionStarter {
    public static func html(title: String) -> String {
        let escaped = title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        return #"""
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>\#(escaped)</title>
        <style>
          #field { position: absolute; inset: 0; }
          .title { position: absolute; left: 160px; right: 160px; top: 50%; transform: translateY(-50%);
            font-family: var(--brand-display); font-weight: 600; font-size: 128px; line-height: 1.02; letter-spacing: -0.035em; }
          .title span { display: inline-block; will-change: transform, opacity, filter; }
          .eyebrow { position: absolute; left: 164px; top: calc(50% - 150px); font-family: var(--brand-mono);
            font-size: 22px; letter-spacing: 0.3em; text-transform: uppercase; color: var(--brand-accent); }
          .rule { position: absolute; left: 164px; top: calc(50% + 120px); height: 2px; width: 520px;
            background: linear-gradient(90deg, var(--brand-accent), transparent); transform-origin: left; }
        </style>
        </head>
        <body>
        <canvas id="field"></canvas>
        <div class="eyebrow" id="eyebrow">Made in Dante</div>
        <div class="title" id="title">\#(escaped)</div>
        <div class="rule" id="rule"></div>
        <script>
        let ctx, words, dots;
        dante.scene({
          setup({ width, height, pixelRatio }) {
            const canvas = document.getElementById("field");
            canvas.width = width * pixelRatio; canvas.height = height * pixelRatio;
            canvas.style.width = width + "px"; canvas.style.height = height + "px";
            ctx = canvas.getContext("2d");
            ctx.scale(pixelRatio, pixelRatio);
            const title = document.getElementById("title");
            title.innerHTML = title.textContent.split(" ").map((w) => `<span>${w}</span>`).join(" ");
            words = [...title.querySelectorAll("span")];
            const random = dante.random(7);
            dots = Array.from({ length: 220 }, () => ({ x: random(), y: random(), z: 0.2 + random() * 0.8, phase: random() * 10 }));
          },
          seek(t) {
            const { width, height } = dante.piece;
            const accent = dante.brand.colors.accent, second = dante.brand.colors.accent2;
            ctx.clearRect(0, 0, width, height);
            // A glow that breathes, and dots drifting through it at three depths.
            const glow = ctx.createRadialGradient(width * 0.72, height * 0.42, 0, width * 0.72, height * 0.42, width * 0.6);
            glow.addColorStop(0, accent + "33"); glow.addColorStop(0.5, second + "11"); glow.addColorStop(1, "transparent");
            ctx.globalAlpha = 0.6 + 0.4 * Math.sin(t * 0.6);
            ctx.fillStyle = glow; ctx.fillRect(0, 0, width, height);
            ctx.globalAlpha = 1;
            for (const d of dots) {
              const x = ((d.x + t * 0.012 * d.z) % 1) * width;
              const y = d.y * height + dante.noise(d.phase, t * 0.2) * 30 * d.z;
              ctx.fillStyle = d.z > 0.7 ? accent : dante.brand.colors.muted;
              ctx.globalAlpha = (0.15 + 0.6 * d.z) * dante.progress(t, 0, 1.2, "outCubic");
              ctx.beginPath(); ctx.arc(x, y, 0.6 + d.z * 1.8, 0, Math.PI * 2); ctx.fill();
            }
            ctx.globalAlpha = 1;
            // The title rises word by word, out of a blur.
            words.forEach((word, i) => {
              const p = dante.progress(t, 0.5 + i * 0.12, 1.6 + i * 0.12, "outExpo");
              word.style.opacity = p;
              word.style.transform = `translateY(${(1 - p) * 60}px)`;
              word.style.filter = `blur(${(1 - p) * 14}px)`;
            });
            const e = dante.progress(t, 0.2, 1.0, "outCubic");
            document.getElementById("eyebrow").style.opacity = e;
            document.getElementById("eyebrow").style.transform = `translateX(${(1 - e) * -30}px)`;
            document.getElementById("rule").style.transform = `scaleX(${dante.progress(t, 1.2, 2.4, "inOutExpo")})`;
          },
        });
        </script>
        </body>
        </html>

        """#
    }
}
