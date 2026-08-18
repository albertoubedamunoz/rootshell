//
//  Aurora.metal
//  rootshell
//
//  Procedural aurora borealis: three parallax curtain layers built from
//  value-noise fbm, with a bright folding lower edge, vertical ray streaks,
//  an altitude color ramp (green edge -> teal -> magenta, purple fringe),
//  and minutes-scale substorm breathing. All frequencies are incommensurate
//  so the motion never visibly loops.
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

static float auroraHash(float2 p) {
    p = fract(p * float2(123.34, 345.45));
    p += dot(p, p + 34.345);
    return fract(p.x * p.y);
}

static float auroraNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(auroraHash(i),                    auroraHash(i + float2(1.0, 0.0)), u.x),
               mix(auroraHash(i + float2(0.0, 1.0)), auroraHash(i + float2(1.0, 1.0)), u.x),
               u.y);
}

/// 3-octave fbm, domain rotated per octave to hide grid alignment
static float auroraFbm(float2 p) {
    const float2x2 rot = float2x2(float2(0.8, -0.6), float2(0.6, 0.8));
    float value = 0.0;
    float amplitude = 0.5;
    for (int i = 0; i < 3; i++) {
        value += amplitude * auroraNoise(p);
        p = rot * (p * 2.07);
        amplitude *= 0.5;
    }
    return value;
}

/// Aurora borealis background effect
///
/// Parameters:
/// - position/color: provided by SwiftUI colorEffect
/// - size: view dimensions in points
/// - time: accumulated animation phase (already speed-scaled on the Swift side)
/// - intensity: effect intensity (0.05-0.6 from settings)
/// - cBase: lower-edge color (oxygen green)
/// - cMid: mid-altitude color (teal)
/// - cHigh: high-altitude color (red/magenta)
/// - cFringe: lower-fringe color (purple)
/// - lightMode: 0 = dark theme (composited plusLighter), 1 = light theme (multiply)
/// - shimmer: 0/1 fast per-ray shimmer toggle
[[ stitchable ]] half4 aurora(
    float2 position,
    half4 color,
    float2 size,
    float time,
    float intensity,
    half4 cBase,
    half4 cMid,
    half4 cHigh,
    half4 cFringe,
    float lightMode,
    float shimmer
) {
    float2 uv = position / size;

    // The bottom of the screen stays untouched so terminal text keeps full
    // contrast: white is identity under multiply, transparent black under
    // plusLighter and normal compositing.
    if (uv.y > 0.62) {
        return (lightMode > 0.5) ? half4(1.0h) : half4(0.0h);
    }

    float t = time;
    float x0 = uv.x * size.x / max(size.y, 1.0);

    // Slow shared domain warp so all three curtains belong to the same sky
    float warp = auroraFbm(float2(x0 * 1.3 - t * 0.045, t * 0.017)) - 0.5;

    // Back / mid / front layer constants (parallax depth)
    float scales[3]   = {0.8, 1.15, 1.6};
    float drifts[3]   = {0.021, 0.034, 0.052};
    float brights[3]  = {0.45, 0.7, 1.0};
    float phases[3]   = {0.0, 7.3, 13.7};
    float edges[3]    = {0.38, 0.42, 0.46};
    float highBias[3] = {0.30, 0.12, 0.0};

    float rayTime = mix(t * 0.05, t * 0.55, shimmer);

    float3 base   = float3(cBase.rgb);
    float3 midC   = float3(cMid.rgb);
    float3 high   = float3(cHigh.rgb);
    float3 fringe = float3(cFringe.rgb);

    float3 accum = float3(0.0);
    float lumTotal = 0.0;

    for (int i = 0; i < 3; i++) {
        float x = x0 * scales[i] + phases[i] + warp * 0.9;

        // Folding lower edge of the curtain (the "skirt")
        float edgeY = edges[i]
            + 0.20 * (auroraFbm(float2(x * 0.9 - t * drifts[i], t * 0.013 + phases[i])) - 0.5);

        // Altitude above the lower edge: 0 at the edge, 1 near the curtain top
        float altitude = (edgeY - uv.y) / 0.38;

        // Hard bright lower edge, exponential fade upward
        float envelope = smoothstep(-0.06, 0.04, altitude) * exp(-max(altitude, 0.0) * 2.4);
        if (envelope < 0.003) { continue; }

        // Vertical ray streaks: high-frequency noise in x, stretched
        // vertically and sheared so rays follow the curtain folds
        float rays = auroraNoise(float2(x * 16.0 + warp * 4.0 + uv.y * 1.8,
                                        rayTime + phases[i] * 3.1));
        rays = 0.35 + 0.65 * pow(rays, 1.6);

        // Minutes-scale substorm breathing, incommensurate per layer
        float breathe = 0.70 + 0.30 * (0.5 + 0.5 * sin(t * 0.043 + phases[i])
                                             * sin(t * 0.011 + phases[i] * 1.7));

        float lum = envelope * rays * breathe * brights[i];

        // Altitude color ramp; distant layers lean toward the high-altitude hue
        float3 c = mix(base, midC, smoothstep(0.12, 0.45, altitude));
        c = mix(c, high, smoothstep(0.45, 0.95, altitude));
        c = mix(fringe, c, smoothstep(-0.05, 0.05, altitude));
        c = mix(c, high, highBias[i]);

        accum += c * lum;
        lumTotal += lum;
    }

    float gain = intensity * 1.8;

    if (lightMode < 0.5) {
        // Additive (plusLighter): glow over black, exponential soft-clip so
        // stacked layers roll off instead of clipping to white
        float3 rgb = 1.0 - exp(-accum * gain * 1.4);
        float alpha = min(1.0, lumTotal * gain);
        return half4(half3(rgb), half(alpha));
    } else {
        // Multiply: white where empty, aurora reads as colored darkening.
        // Darkening is capped so terminal text stays readable.
        float darkening = min(0.5, lumTotal * gain);
        float3 tint = (lumTotal > 1e-4) ? accum / lumTotal : float3(1.0);
        float3 rgb = mix(float3(1.0), tint, darkening);
        return half4(half3(rgb), 1.0h);
    }
}
