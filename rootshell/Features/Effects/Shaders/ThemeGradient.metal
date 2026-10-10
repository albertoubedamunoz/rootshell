//
//  ThemeGradient.metal
//  rootshell
//
//  Theme-colored gradient: a primary base under four soft radial gradients
//  composited back to front, then darkened toward the bottom. Gradient
//  centers drift slightly on the CPU.
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

static float4 themeGradientStop(half4 c, float alpha) {
    return float4(float3(c.rgb) * alpha, alpha);
}

/// Premultiplied ramp: c0 at 0, c1 at l1, c2 at l2, clear at 1
static float4 themeGradientRamp(float t, float4 c0, float l1, float4 c1, float l2, float4 c2) {
    t = saturate(t);
    if (t < l1) return mix(c0, c1, t / l1);
    if (t < l2) return mix(c1, c2, (t - l1) / (l2 - l1));
    return mix(c2, float4(0.0), (t - l2) / (1.0 - l2));
}

static float4 themeGradientOver(float4 dst, float4 src) {
    return src + dst * (1.0 - src.a);
}

[[ stitchable ]] half4 themeGradient(
    float2 position,
    half4 color,
    float2 size,
    float4 offsetsA,
    float4 offsetsB,
    half4 cPrimary,
    half4 cAccent,
    half4 cMid,
    float intensity,
    float backdrop,
    float lightMode
) {
    float2 uv = position / size;
    // Width-based radii use the short side so landscape keeps the portrait look
    float s = min(size.x, size.y);
    float h = size.y;

    float4 col = float4(float3(cPrimary.rgb), 1.0);

    // Top-left: large and soft
    float2 c = (float2(0.10, 0.10) + offsetsA.xy) * size;
    float t = distance(position, c) / (0.9 * s);
    col = themeGradientOver(col, themeGradientRamp(t,
        themeGradientStop(cAccent, 0.6), 0.3, themeGradientStop(cAccent, 0.3),
        0.7, themeGradientStop(cMid, 0.15)));

    // Bottom: below the edge, diffuse, starting at 0.2h
    c = (float2(0.70, 1.10) + offsetsA.zw) * size;
    t = (distance(position, c) - 0.2 * h) / (0.6 * h);
    col = themeGradientOver(col, themeGradientRamp(t,
        themeGradientStop(cPrimary, 0.4), 0.3, themeGradientStop(cPrimary, 0.2),
        0.6, themeGradientStop(cMid, 0.1)));

    // Mid-right: softens the bottom corner
    c = (float2(1.00, 0.60) + offsetsB.xy) * size;
    t = distance(position, c) / (0.5 * s);
    col = themeGradientOver(col, themeGradientRamp(t,
        themeGradientStop(cMid, 0.2), 0.5, themeGradientStop(cAccent, 0.1),
        0.75, themeGradientStop(cAccent, 0.05)));

    // Center: smaller and focused
    c = (float2(0.35, 0.45) + offsetsB.zw) * size;
    t = distance(position, c) / (0.35 * s);
    col = themeGradientOver(col, themeGradientRamp(t,
        themeGradientStop(cAccent, 0.25), 0.4, themeGradientStop(cMid, 0.15),
        0.7, themeGradientStop(cMid, 0.075)));

    // Depth: darker toward the bottom
    float shade = uv.y < 0.3 ? mix(0.0, 0.1, uv.y / 0.3)
        : uv.y < 0.7 ? mix(0.1, 0.3, (uv.y - 0.3) / 0.4)
        : mix(0.3, 0.5, (uv.y - 0.7) / 0.3);
    float3 rgb = col.rgb * (1.0 - shade);

    // Interleaved gradient noise: breaks up 8-bit banding in slow gradients
    float dither = (fract(52.9829189 * fract(dot(position, float2(0.06711056, 0.00583715)))) - 0.5) / 255.0;

    if (lightMode > 0.5) {
        // Light themes: a pale wash of the same surface
        rgb = 1.0 - (1.0 - rgb) * 0.45;
    }
    if (backdrop > 0.5) {
        return half4(half3(rgb + dither), 1.0h);
    }
    if (lightMode < 0.5) {
        // Additive (plusLighter) tint over the terminal
        float a = saturate(intensity);
        return half4(half3(max(rgb * a + dither, 0.0)), half(a));
    }
    // Multiply: white is identity
    return half4(half3(mix(float3(1.0), rgb, saturate(intensity * 1.5)) + dither), 1.0h);
}
