//
//  ThemeGradient.metal
//  rootshell
//
//  Theme-colored gradient: a deep base wash with four soft radial blobs
//  layered back to front, morphed by a slow domain warp and modulated by a
//  soft wave field. Blob centers move on the CPU; per pixel it is seven
//  sines, four distances, and a dither.
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

/// Soft falloff from 1 at the center to 0 at `radius` (height units)
static float themeGradientBlob(float2 p, float2 center, float aspect, float radius) {
    float d = distance(p, float2(center.x * aspect, center.y));
    float w = 1.0 - smoothstep(0.0, radius, d);
    return w * w;
}

[[ stitchable ]] half4 themeGradient(
    float2 position,
    half4 color,
    float2 size,
    float time,
    float4 centersA,
    float4 centersB,
    half4 cDeep,
    half4 cPrimary,
    half4 cAccent,
    half4 cMid,
    float intensity,
    float lightMode
) {
    float2 uv = position / size;
    float aspect = size.x / max(size.y, 1.0);
    float2 p = float2(uv.x * aspect, uv.y);
    float t = time;

    // Domain warp so blobs morph instead of sliding as rigid discs
    p += 0.07 * float2(sin(p.y * 2.3 + t * 0.31), sin(p.x * 1.9 - t * 0.27));

    // Radii grow gently with aspect: wide windows keep distinct blobs
    float span = sqrt(max(aspect, 1.0));
    float3 col = float3(cDeep.rgb);
    float coverage = 0.35;

    float a = 0.60 * themeGradientBlob(p, centersA.xy, aspect, 0.85 * span);
    col = mix(col, float3(cAccent.rgb), a);
    coverage += a * (1.0 - coverage);

    a = 0.45 * themeGradientBlob(p, centersA.zw, aspect, 0.75 * span);
    col = mix(col, float3(cPrimary.rgb), a);
    coverage += a * (1.0 - coverage);

    a = 0.30 * themeGradientBlob(p, centersB.xy, aspect, 0.55 * span);
    col = mix(col, float3(cMid.rgb), a);
    coverage += a * (1.0 - coverage);

    a = 0.25 * themeGradientBlob(p, centersB.zw, aspect, 0.40 * span);
    col = mix(col, float3(cAccent.rgb), a);
    coverage += a * (1.0 - coverage);

    // Wave field: drifting bands of light and color across the blobs
    float w1 = sin(uv.x * 2.0 + t * 0.30 + sin(uv.y * 1.5 + t * 0.24) * 1.5);
    float w2 = sin(uv.x * 1.5 - t * 0.24 + cos(uv.y * 2.0 - t * 0.21) * 1.2);
    float curtain = sin(uv.y * 3.0 + t * 0.36 + w1 * 0.5);
    float flow = (w1 * 0.4 + w2 * 0.35 + curtain * 0.25) * 0.5 + 0.5;
    coverage *= 0.55 + flow * 0.9;
    col = mix(col, float3(cMid.rgb), (1.0 - flow) * 0.35);

    // Calmer toward the bottom, where the prompt usually sits
    coverage *= mix(1.0, 0.55, smoothstep(0.35, 1.0, uv.y));

    // Interleaved gradient noise: breaks up 8-bit banding in slow gradients
    float dither = (fract(52.9829189 * fract(dot(position, float2(0.06711056, 0.00583715)))) - 0.5) / 255.0;

    float gain = intensity * 1.2;
    if (lightMode < 0.5) {
        // Additive (plusLighter): soft-clipped glow over black
        float3 rgb = 1.0 - exp(-col * coverage * gain * 1.4);
        rgb = max(rgb + dither, 0.0);
        return half4(half3(rgb), half(min(1.0, coverage * gain)));
    } else {
        // Multiply: white is identity; darkening capped for text contrast
        float darkening = min(0.45, coverage * gain);
        float3 rgb = mix(float3(1.0), col, darkening) + dither;
        return half4(half3(rgb), 1.0h);
    }
}
