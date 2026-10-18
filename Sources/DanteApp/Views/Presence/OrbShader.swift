/// The orb, drawn per pixel: a sphere of plasma whose surface breathes, an aura of flames
/// rising off it, lightning crackling through the aura, a halo, an orbital ring of sparks,
/// a shockwave when it powers up, and an eye that looks where it's told. Compiled at runtime
/// from source, since SwiftPM doesn't build .metal files.
enum OrbShader {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float4 p0;   // resolution.xy, time, energy
        float4 p1;   // gaze.xy, dilation, blink
        float4 p2;   // pulse, flicker, glow, detail
        float4 p3;   // wake, hue, ring, eye
        float4 p4;   // aura, lightning, burst (0…1 after a power-up), flash
        float4 c0, c1, c2, c3;
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

    fragment float4 orbFragment(VOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
        float2 res = u.p0.xy;
        float time = u.p0.z;
        float energy = u.p0.w;
        float2 gaze = u.p1.xy;
        float dilation = u.p1.z;
        float blink = u.p1.w;
        float pulse = u.p2.x;
        float flicker = u.p2.y;
        float glowStrength = u.p2.z;
        float detail = u.p2.w;
        float wake = u.p3.x;
        float hue = u.p3.y;
        float ringStrength = u.p3.z;
        float eyeStrength = u.p3.w;
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

            // The eye: an iris that glows, a pupil that dilates, lids that blink.
            if (eyeStrength > 0.01) {
                float irisRadius = radius * (large ? 0.3 : 0.42);
                float2 eyeCentre = gaze * radius * 0.34;
                float2 e = uv - eyeCentre;
                e /= float2(1.0 - abs(gaze.x) * 0.22, 1.0 - abs(gaze.y) * 0.22);
                float r = length(e);
                float open = 1.0 - blink;
                float lid = smoothstep(irisRadius * open + pixel, irisRadius * open - pixel, abs(e.y));
                float irisMask = smoothstep(irisRadius + pixel, irisRadius - pixel, r) * lid * eyeStrength;

                float around = atan2(e.y, e.x);
                float streaks = noise3(float3(around * 7.0, r / irisRadius * 6.0, time * 0.3));
                float3 iris = palette(hue + 0.6 + streaks * 0.2, u);
                iris = mix(iris, float3(1.0), 0.18);
                iris *= 0.55 + 0.9 * streaks * smoothstep(irisRadius, irisRadius * 0.3, r);
                iris *= smoothstep(irisRadius * 1.02, irisRadius * 0.78, r) * 0.6 + 0.4;

                float pupilRadius = irisRadius * (0.3 + 0.38 * dilation);
                float pupilMask = smoothstep(pupilRadius + pixel, pupilRadius - pixel, r) * lid * eyeStrength;
                float3 pupil = palette(hue + 0.1, u) * 0.06 * (1.0 - r / pupilRadius);

                body = mix(body, iris * 1.25, irisMask);
                body = mix(body, pupil, pupilMask);

                float2 glint = e - float2(-0.35, 0.38) * irisRadius;
                float catchlight = smoothstep(irisRadius * 0.16, irisRadius * 0.05, length(glint)) * lid * eyeStrength;
                body += float3(catchlight * 0.9);
            }

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
