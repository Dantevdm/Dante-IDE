/// The orb, drawn per pixel: a sphere of plasma whose surface breathes, an aura of flames
/// rising off it, lightning crackling through the aura, a halo, an orbital ring of sparks,
/// and a shockwave when it powers up. Compiled at runtime
/// from source, since SwiftPM doesn't build .metal files.
enum OrbShader {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4 p0;   // resolution.xy, time, energy
        float4 p1;   // drowse, 0, 0, 0
        float4 p2;   // pulse, flicker, glow, detail
        float4 p3;   // wake, hue, ring, 0
        float4 p4;   // aura, lightning, burst (0…1 after a power-up), flash
        float4 c0, c1, c2, c3;
        float4 p5;   // satellites, beam strength, 0, 0
        float4 s[6]; // per satellite: centre.xy, radius, depth (-1 behind … 1 in front)
        float4 k[6]; // per satellite: colour, how far out (0 inside the orb … 1 free)
    };

    struct VOut { float4 position [[position]]; };

    vertex VOut orbVertex(uint id [[vertex_id]]) {
        float2 p = float2(float((id << 1) & 2), float(id & 2));
        VOut out;
        out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        return out;
    }

    static float hash3(float3 p) {
        p = fract(p * 0.3183099 + 0.1);
        p *= 17.0;
        return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
    }

    static float noise3(float3 x) {
        float3 i = floor(x);
        float3 f = fract(x);
        f = f * f * (3.0 - 2.0 * f);
        return mix(mix(mix(hash3(i + float3(0, 0, 0)), hash3(i + float3(1, 0, 0)), f.x),
                       mix(hash3(i + float3(0, 1, 0)), hash3(i + float3(1, 1, 0)), f.x), f.y),
                   mix(mix(hash3(i + float3(0, 0, 1)), hash3(i + float3(1, 0, 1)), f.x),
                       mix(hash3(i + float3(0, 1, 1)), hash3(i + float3(1, 1, 1)), f.x), f.y), f.z);
    }

    static float fbm(float3 p, int octaves) {
        float value = 0.0;
        float amplitude = 0.5;
        for (int i = 0; i < octaves; i++) {
            value += amplitude * noise3(p);
            p = p * 2.03 + float3(1.7, 9.2, 3.1);
            amplitude *= 0.5;
        }
        return value;
    }

    static float3 palette(float t, constant Uniforms& u) {
        float s = fract(t) * 4.0;
        int i = int(floor(s));
        float f = smoothstep(0.0, 1.0, fract(s));
        float3 a = i == 0 ? u.c0.rgb : i == 1 ? u.c1.rgb : i == 2 ? u.c2.rgb : u.c3.rgb;
        float3 b = i == 0 ? u.c1.rgb : i == 1 ? u.c2.rgb : i == 2 ? u.c3.rgb : u.c0.rgb;
        return mix(a, b, f);
    }

    // Composites a premultiplied layer under what's already there.
    static void under(thread float3& color, thread float& alpha, float3 layer, float layerAlpha) {
        color += layer * layerAlpha * (1.0 - alpha);
        alpha += layerAlpha * (1.0 - alpha);
    }

    // A satellite orb (an agent at work): its plasma sphere, the neck joining it to the
    // orb while it splits off or merges back, and its glow. Premultiplied colour and alpha.
    static float4 satellite(float2 uv, float4 s, float4 k, float mainRadius, float time, float pixel, float index, bool large) {
        float2 c = s.xy;
        float r = s.z;
        float2 local = (uv - c) / max(r, 0.0001);
        float e = length(local);
        float d = length(uv);
        float3 tint = k.rgb;
        float3 color = float3(0.0);
        float alpha = 0.0;

        // Sphere.
        if (e < 1.0 + pixel / r) {
            float z = sqrt(max(0.0, 1.0 - e * e));
            float n = fbm(float3(local * 1.7, time * 0.7 + index * 3.1), large ? 4 : 2);
            float m = fbm(float3(local * 3.1 + n, time * 0.4 - index), 2);
            float3 body = mix(tint * 0.35, tint * 1.25, n) * (0.45 + 0.55 * pow(z, 0.6));
            body += mix(tint, float3(1.0), 0.45) * pow(1.0 - z, 2.4) * 1.4;
            body = mix(body, float3(1.0), smoothstep(0.62, 0.85, m) * 0.35);
            body += float3(1.0) * exp(-e * e * 7.0) * 0.45;
            float a = smoothstep(1.0 + pixel / r, 1.0 - pixel / r, e);
            color += body * a;
            alpha += a;
        }

        // The neck: where the two fields together cross the surface, outside both spheres.
        float field = pow(mainRadius / max(d, 0.0001), 2.0) + pow(r / max(length(uv - c), 0.0001), 2.0);
        if (d > mainRadius && e > 1.0 && k.w < 0.999) {
            float neck = smoothstep(1.0, 1.25, field) * (1.0 - smoothstep(0.55, 1.0, k.w));
            float along = clamp(dot(uv, c) / max(dot(c, c), 0.0001), 0.0, 1.0);
            float3 neckColor = mix(tint * 1.1, mix(tint, float3(1.0), 0.6), along) * (0.9 + 0.5 * fbm(float3(uv * 9.0, time), 2));
            color += neckColor * neck * (1.0 - alpha);
            alpha += neck * (1.0 - alpha);
        }

        // Glow.
        float outside = max(e - 1.0, 0.0) * r;
        float glow = exp(-outside * (large ? 16.0 : 24.0)) * 0.55 * smoothstep(0.9, 1.02, e);
        color += tint * glow * (1.0 - alpha);
        alpha += glow * (1.0 - alpha);
        return float4(color, clamp(alpha, 0.0, 1.0));
    }

    fragment float4 orbFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float2 res = u.p0.xy;
        float time = u.p0.z;
        float energy = u.p0.w;
        float drowse = u.p1.x;
        float pulse = u.p2.x;
        float flicker = u.p2.y;
        float glowStrength = u.p2.z;
        float detail = u.p2.w;
        float wake = u.p3.x;
        float hue = u.p3.y;
        float ringStrength = u.p3.z;
        float aura = u.p4.x;
        float lightning = u.p4.y;
        float burst = u.p4.z;
        float flash = u.p4.w;
        bool large = detail > 0.5;
        int octaves = large ? 5 : 3;

        float scale = min(res.x, res.y) * 0.5;
        float2 uv = (in.position.xy - res * 0.5) / scale;
        uv.y = -uv.y;
        // Large orbs sit a little low, so the flames have room to rise.
        if (large) { uv.y += 0.16; }
        float pixel = 1.5 / scale;

        float angle = atan2(uv.y, uv.x);
        float d = length(uv);
        float2 direction = uv / max(d, 0.0001);

        // A living surface: the edge breathes and ripples with energy.
        float wobble = fbm(float3(cos(angle) * 1.4, sin(angle) * 1.4, time * (0.25 + 0.6 * energy)), 3) - 0.5;
        float baseRadius = large ? 0.46 : 0.6;
        float radius = baseRadius * wake * (1.0 + 0.07 * pulse) * (1.0 + wobble * (0.05 + 0.12 * energy));
        float edge = d / max(radius, 0.001);

        float3 color = float3(0.0);
        float alpha = 0.0;

        // MARK: Front layers, drawn first and composited from the front back.

        // Satellites passing in front of the orb.
        int satellites = int(u.p5.x);
        for (int i = 0; i < satellites; i++) {
            if (u.s[i].w <= 0.0) { continue; }
            float4 sat = satellite(uv, u.s[i], u.k[i], radius, time, pixel, float(i), large);
            under(color, alpha, sat.rgb / max(sat.a, 0.0001), sat.a);
        }

        // Beams to each satellite: energy pulsing out along the link while they work together.
        // Drawn before the flames and halo, so they aren't lost in them.
        float beamStrength = u.p5.y;
        for (int i = 0; i < satellites; i++) {
            float2 c = u.s[i].xy;
            float len2 = max(dot(c, c), 0.0001);
            float t = clamp(dot(uv, c) / len2, 0.0, 1.0);
            float2 nearest = c * t;
            float h = length(uv - nearest);
            float clear = smoothstep(radius * 0.98, radius * 1.1, d) * smoothstep(u.s[i].z * 0.95, u.s[i].z * 1.25, length(uv - c));
            float wiggle = (noise3(float3(t * 9.0, time * 3.0, float(i))) - 0.5) * 0.02;
            float core = exp(-pow(h + wiggle, 2.0) * (large ? 6000.0 : 1800.0));
            float sheath = exp(-pow(h + wiggle, 2.0) * (large ? 500.0 : 260.0)) * 0.35;
            float flow = 0.35 + 0.65 * pow(0.5 + 0.5 * sin(t * 26.0 - time * 9.0 + float(i) * 1.7), 6.0);
            float gate = clear * beamStrength * smoothstep(0.35, 0.9, u.k[i].w);
            under(color, alpha, mix(u.k[i].rgb, float3(1.0), 0.6) * 1.3, clamp(core * flow * gate, 0.0, 1.0));
            under(color, alpha, u.k[i].rgb, clamp(sheath * (0.5 + 0.5 * flow) * gate, 0.0, 1.0));
        }

        // Shockwave from a power-up.
        if (flash > 0.0 && burst < 1.0) {
            float ringAt = radius * (1.0 + burst * 1.5);
            float width = (0.02 + 0.06 * burst) * (large ? 1.0 : 1.6);
            float shock = exp(-pow((d - ringAt) / width, 2.0)) * pow(1.0 - burst, 1.6);
            under(color, alpha, mix(float3(1.0), palette(hue + angle / 6.2831853, u), 0.35), clamp(shock * 1.2, 0.0, 1.0));
        }

        // Lightning: jagged bolts in a few sectors, struck anew several times a second.
        if (lightning > 0.01) {
            float sectors = 7.0;
            float sector = floor((angle + 3.1415927) / 6.2831853 * sectors);
            float strike = floor(time * 9.0);
            float on = step(0.7 - 0.25 * lightning, hash3(float3(sector, strike, 3.7)));
            float centre = (sector + 0.5) / sectors * 6.2831853 - 3.1415927 + (hash3(float3(sector, strike, 1.1)) - 0.5) * 0.5;
            float jag = (noise3(float3(d * 13.0, strike, sector)) - 0.5) * 0.45 + (noise3(float3(d * 37.0, strike * 1.3, sector)) - 0.5) * 0.14;
            float off = abs(angle - centre - jag) * d;
            float reach = radius * (1.35 + 0.35 * hash3(float3(sector, strike, 7.7)));
            float along = smoothstep(radius * 0.92, radius * 1.04, d) * smoothstep(reach, radius * 1.15, d);
            float sharpness = large ? 14000.0 : 2500.0;
            float bolt = (exp(-off * off * sharpness) + 0.35 * exp(-off * off * sharpness * 0.08)) * along * on * lightning;
            float3 boltColor = mix(float3(0.92, 0.96, 1.0), palette(hue + 0.3, u), 0.25);
            under(color, alpha, boltColor * 1.3, clamp(bolt, 0.0, 1.0));
        }

        // The orbital ring's front half.
        float ringFront = 0.0;
        float ringBack = 0.0;
        if (ringStrength > 0.01) {
            float tilt = -0.42;
            float2 r = float2(uv.x * cos(tilt) - uv.y * sin(tilt), uv.x * sin(tilt) + uv.y * cos(tilt));
            float2 ellipse = float2(r.x, r.y * 3.4);
            float ringRadius = radius * 1.42;
            float distance = abs(length(ellipse) - ringRadius);
            float band = exp(-distance * distance * (large ? 900.0 : 300.0));
            float around = atan2(ellipse.y, ellipse.x);
            float sparks = pow(0.5 + 0.5 * cos(around * 3.0 - time * (1.5 + 3.0 * energy)), 24.0)
                         + 0.6 * pow(0.5 + 0.5 * cos(around * 5.0 + time * (1.0 + 2.0 * energy)), 40.0);
            float strength = band * (0.18 + 1.6 * sparks) * ringStrength * wake;
            if (r.y < 0.0) { ringFront = strength; } else { ringBack = strength; }
        }
        under(color, alpha, palette(hue + 0.4, u), clamp(ringFront, 0.0, 1.0));

        // MARK: The sphere.
        if (edge < 1.0 + pixel) {
            float z = sqrt(max(0.0, 1.0 - edge * edge));
            float3 normal = float3(uv / max(radius, 0.001), z);
            float t = time * (0.12 + 0.55 * energy);
            float3 q = normal * (large ? 1.6 : 1.05) + float3(0.0, 0.0, t);
            float w1 = fbm(q + float3(t * 0.7, -t * 0.4, 0.0), octaves);
            float w2 = fbm(q * 1.7 + w1 * 2.2 + float3(-t * 0.3, t * 0.5, 1.3), octaves);
            float v = fbm(q + w2 * 1.8, octaves);

            float3 body = palette(hue + v * 1.2 + w1 * 0.4 + time * 0.04, u);
            body *= 0.35 + 0.65 * pow(z, 0.6);

            // Filaments of light through the plasma, and white-hot where it's brightest.
            float filaments = pow(abs(sin((v + w2) * 11.0 + time * (0.5 + 2.0 * energy))), 16.0) * (0.25 + energy) * (large ? 1.0 : 0.25);
            body += palette(hue + 0.5 + v, u) * filaments * 0.8;
            body = mix(body, float3(1.0), smoothstep(0.62, 0.9, v + filaments * 0.25) * (0.25 + 0.35 * energy));

            // Bright rim and a hot core.
            float rim = pow(1.0 - z, 2.6);
            body += mix(palette(hue + time * 0.05 + angle / 6.2831853, u), float3(1.0), 0.25) * rim * 1.5;
            body += palette(hue + 0.25, u) * exp(-edge * edge * 4.0) * 0.3 * (0.5 + energy);

            // Dozing dims it, as if it were nodding off.
            body *= 1.0 - 0.4 * drowse;

            // A power-up flashes the sphere white for a moment.
            if (flash > 0.0 && burst < 1.0) {
                body = mix(body, float3(1.0), pow(1.0 - burst, 3.0) * 0.55);
            }

            float bodyAlpha = smoothstep(1.0 + pixel, 1.0 - pixel, edge);
            under(color, alpha, body, bodyAlpha);
        }

        // MARK: Behind the sphere.

        // Aura: flames rising off the orb, taller above it, ragged at the tips, white-hot at the root.
        if (aura > 0.01) {
            float up = smoothstep(-0.35, 1.0, direction.y);
            float speed = 2.2 + 3.0 * energy;
            // Stretched upwards, so the noise reads as streaks and tongues rather than blobs.
            float n1 = fbm(float3(uv.x * 4.5, uv.y * 1.6 - time * speed, time * 0.5), large ? 4 : 2);
            float n2 = noise3(float3(uv.x * 11.0, uv.y * 3.0 - time * speed * 1.8, time * 0.9));
            float tongues = pow(1.0 - abs(n2 * 2.0 - 1.0), 2.0);
            float height = radius * (1.08 + aura * ((0.22 + 0.62 * up) * (0.35 + 0.95 * n1) + 0.22 * tongues * up));
            float inside = smoothstep(height, mix(radius, height, 0.55), d);
            float heat = 1.0 - clamp((d - radius) / max(height - radius, 0.001), 0.0, 1.0);
            float3 flame = mix(palette(hue + n1 * 0.6 + time * 0.05, u), float3(1.0), pow(heat, 3.0) * 0.7);
            float flameAlpha = inside * aura * (0.45 + 0.55 * tongues) * wake * (0.85 + 0.15 * pulse);
            under(color, alpha, flame * 1.15, clamp(flameAlpha, 0.0, 1.0));
        }

        // The ring's back half and the halo.
        under(color, alpha, palette(hue + 0.4, u), clamp(ringBack, 0.0, 1.0));
        float outside = max(d - radius, 0.0);
        float halo = exp(-outside * (large ? 4.0 : 6.5)) * glowStrength * (0.55 + 0.45 * pulse) * wake;
        halo *= smoothstep(radius * 0.9, radius * 1.02, d);
        under(color, alpha, palette(hue + time * 0.03 + angle / 6.2831853, u), clamp(halo, 0.0, 1.0));

        // Satellites behind the orb.
        for (int i = 0; i < satellites; i++) {
            if (u.s[i].w > 0.0) { continue; }
            float4 sat = satellite(uv, u.s[i], u.k[i], radius, time, pixel, float(i), large);
            under(color, alpha, sat.rgb / max(sat.a, 0.0001), sat.a * (0.75 + 0.25 * (1.0 + u.s[i].w)));
        }

        // Nothing reaches the edge of the frame: a hard cut there would show the view's square.
        float frame = smoothstep(1.0, 0.82, max(abs(uv.x), abs(uv.y - (large ? 0.16 : 0.0))));
        color *= frame;
        alpha *= frame;

        // Trouble flickers like a failing light.
        float flick = step(0.62, noise3(float3(time * 22.0, 0.0, 0.0)));
        color *= 1.0 - flicker * flick * 0.65;

        return float4(min(color, float3(alpha * 1.4)), alpha);
    }
    """
}
