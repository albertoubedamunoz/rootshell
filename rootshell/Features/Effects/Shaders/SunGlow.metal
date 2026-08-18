//
//  SunGlow.metal
//  rootshell
//
//  Metal shader for physically-accurate sun rendering with continuous gradients.
//  Eliminates banding by computing per-pixel values using mathematical functions
//  rather than discrete gradient stops.
//
//  Features:
//  - Multi-scale Gaussian/exponential glow (C∞ continuous)
//  - Minnaert limb darkening for realistic sun disc
//  - Oklab color space interpolation for perceptual uniformity
//  - Triangular PDF dithering for optimal quantization error distribution
//  - Time-of-day color blending (sunrise/daytime/sunset)
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// MARK: - Oklab Color Space Functions

/// Convert sRGB gamma to linear
static float srgbToLinear(float x) {
    return x <= 0.04045f ? x / 12.92f : pow((x + 0.055f) / 1.055f, 2.4f);
}

/// Convert linear to sRGB gamma
static float linearToSrgb(float x) {
    return x <= 0.0031308f ? 12.92f * x : 1.055f * pow(x, 1.0f/2.4f) - 0.055f;
}

/// Convert linear RGB to Oklab color space
static float3 linearRGBToOklab(float3 rgb) {
    // RGB to LMS cone responses
    float l = 0.4122214708f * rgb.r + 0.5363325363f * rgb.g + 0.0514459929f * rgb.b;
    float m = 0.2119034982f * rgb.r + 0.6806995451f * rgb.g + 0.1073969566f * rgb.b;
    float s = 0.0883024619f * rgb.r + 0.2817188376f * rgb.g + 0.6299787005f * rgb.b;

    // Cube root for perceptual uniformity
    float l_ = pow(max(l, 0.0f), 1.0f/3.0f);
    float m_ = pow(max(m, 0.0f), 1.0f/3.0f);
    float s_ = pow(max(s, 0.0f), 1.0f/3.0f);

    // LMS to Oklab
    return float3(
        0.2104542553f * l_ + 0.7936177850f * m_ - 0.0040720468f * s_,
        1.9779984951f * l_ - 2.4285922050f * m_ + 0.4505937099f * s_,
        0.0259040371f * l_ + 0.7827717662f * m_ - 0.8086757660f * s_
    );
}

/// Convert Oklab to linear RGB
static float3 oklabToLinearRGB(float3 oklab) {
    // Oklab to LMS (cube root space)
    float l_ = oklab.x + 0.3963377774f * oklab.y + 0.2158037573f * oklab.z;
    float m_ = oklab.x - 0.1055613458f * oklab.y - 0.0638541728f * oklab.z;
    float s_ = oklab.x - 0.0894841775f * oklab.y - 1.2914855480f * oklab.z;

    // Cube to get LMS
    float l = l_ * l_ * l_;
    float m = m_ * m_ * m_;
    float s = s_ * s_ * s_;

    // LMS to linear RGB
    return float3(
        +4.0767416621f * l - 3.3077115913f * m + 0.2309699292f * s,
        -1.2684380046f * l + 2.6097574011f * m - 0.3413193965f * s,
        -0.0041960863f * l - 0.7034186147f * m + 1.7076147010f * s
    );
}

/// Interpolate two sRGB colors in Oklab space
static float3 interpolateOklab(float3 srgbA, float3 srgbB, float t) {
    // Convert to linear RGB
    float3 linA = float3(srgbToLinear(srgbA.r), srgbToLinear(srgbA.g), srgbToLinear(srgbA.b));
    float3 linB = float3(srgbToLinear(srgbB.r), srgbToLinear(srgbB.g), srgbToLinear(srgbB.b));

    // Convert to Oklab
    float3 okA = linearRGBToOklab(linA);
    float3 okB = linearRGBToOklab(linB);

    // Linear interpolation in Oklab
    float3 okResult = mix(okA, okB, t);

    // Convert back to linear RGB
    float3 linResult = oklabToLinearRGB(okResult);

    // Apply gamma and clamp
    return float3(
        saturate(linearToSrgb(linResult.r)),
        saturate(linearToSrgb(linResult.g)),
        saturate(linearToSrgb(linResult.b))
    );
}

// MARK: - Adaptive Triangular PDF Dithering

/// Triangular dithering with adaptive strength for low-intensity regions
/// At low intensity, quantization errors become more visible, so we increase dither strength
static float3 adaptiveDither(float2 position, float time, float intensity) {
    // Two independent noise values using interleaved gradient noise (Jorge Jimenez, SIGGRAPH 2014)
    float3 magic = float3(0.06711056f, 0.00583715f, 52.9829189f);
    float noise1 = fract(magic.z * fract(dot(position, magic.xy)));
    float noise2 = fract(magic.z * fract(dot(position + float2(1.0f, 0.0f), magic.xy)));
    float noise3 = fract(magic.z * fract(dot(position + float2(0.0f, 1.0f), magic.xy)));

    // Add temporal variation to prevent static patterns
    noise1 = fract(noise1 + time * 0.1f);
    noise2 = fract(noise2 + time * 0.17f);
    noise3 = fract(noise3 + time * 0.23f);

    // Triangular PDF from sum of two uniform distributions
    float ditherR = noise1 + noise2 - 1.0f;
    float ditherG = noise2 + noise3 - 1.0f;
    float ditherB = noise3 + noise1 - 1.0f;

    // Adaptive strength: increase dither at low intensity
    // At intensity=1.0, use 1 LSB; at intensity=0.1, use ~3 LSB
    float adaptiveStrength = 1.0f / (255.0f * max(0.15f, sqrt(intensity)));

    return float3(ditherR, ditherG, ditherB) * adaptiveStrength;
}

// MARK: - Time-of-Day Color Palettes

// Sunrise colors (warm orange-gold)
constant float3 SUNRISE_CORE = float3(1.0f, 0.88f, 0.65f);      // Bright warm center
constant float3 SUNRISE_MID = float3(1.0f, 0.65f, 0.35f);       // Orange mid
constant float3 SUNRISE_GLOW = float3(1.0f, 0.55f, 0.25f);      // Glow color

// Daytime colors (bright white-blue)
constant float3 DAYTIME_CORE = float3(1.0f, 0.99f, 0.97f);      // Near white
constant float3 DAYTIME_MID = float3(0.92f, 0.96f, 1.0f);       // Light blue tint
constant float3 DAYTIME_GLOW = float3(0.6f, 0.85f, 1.0f);       // Blue glow

// Sunset colors (deep red-orange with purple transition)
constant float3 SUNSET_CORE = float3(1.0f, 0.78f, 0.55f);       // Warm center (unchanged)
constant float3 SUNSET_MID = float3(0.95f, 0.50f, 0.42f);       // Orange with purple hint
constant float3 SUNSET_GLOW = float3(0.85f, 0.35f, 0.45f);      // Purple-tinged glow

/// Blend three color sets by time-of-day weights in Oklab space
static float3 blendTimeOfDay(float3 sunrise, float3 daytime, float3 sunset,
                              float sunriseW, float daytimeW, float sunsetW) {
    // Normalize weights
    float total = sunriseW + daytimeW + sunsetW;
    if (total < 0.001f) return daytime;

    sunriseW /= total;
    daytimeW /= total;
    sunsetW /= total;

    // Blend in Oklab: first sunrise-daytime, then with sunset
    float3 sunriseDaytime = interpolateOklab(sunrise, daytime, daytimeW / max(0.001f, sunriseW + daytimeW));
    return interpolateOklab(sunriseDaytime, sunset, sunsetW);
}

// MARK: - Smoothstep Variants

/// Perlin's smootherstep: C2-continuous (has continuous second derivative)
static float smootherstep(float edge0, float edge1, float x) {
    x = saturate((x - edge0) / (edge1 - edge0));
    return x * x * x * (x * (x * 6.0f - 15.0f) + 10.0f);
}

// MARK: - Sun Glow Shader

/// Sun glow shader with physically-accurate continuous gradients
///
/// Parameters:
/// - position: Current pixel position (provided by SwiftUI)
/// - color: Input color (ignored, we generate our own)
/// - sunCenterX: Sun center X position in view coordinates
/// - sunCenterY: Sun center Y position in view coordinates
/// - sunRadius: Base sun radius in pixels
/// - sunAltitude: Sun altitude in degrees
/// - backgroundR/G/B: Theme background color in sRGB (0-1)
/// - intensity: Overall intensity (0.0-1.0)
/// - time: Elapsed time for dither animation
/// - sunriseWeight: Weight for sunrise colors (0.0-1.0)
/// - daytimeWeight: Weight for daytime colors (0.0-1.0)
/// - sunsetWeight: Weight for sunset colors (0.0-1.0)
/// - hotspotOffsetX: X offset for 3D depth effect (e.g., -0.15)
/// - hotspotOffsetY: Y offset for 3D depth effect (e.g., -0.15)
[[ stitchable ]] half4 sunGlow(
    float2 position,
    half4 color,
    float sunCenterX,
    float sunCenterY,
    float sunRadius,
    float sunAltitude,
    float backgroundR,
    float backgroundG,
    float backgroundB,
    float intensity,
    float time,
    float sunriseWeight,
    float daytimeWeight,
    float sunsetWeight,
    float hotspotOffsetX,
    float hotspotOffsetY
) {
    // Reconstruct float2 values from individual floats
    float2 sunCenter = float2(sunCenterX, sunCenterY);
    float2 hotspotOffset = float2(hotspotOffsetX, hotspotOffsetY);
    float3 background = float3(backgroundR, backgroundG, backgroundB);

    // Early exit for pixels far from sun (optimization)
    float2 delta = position - sunCenter;
    float dist = length(delta);
    float altitudeT = smootherstep(-4.0f, 22.0f, sunAltitude);
    float verticalScale = mix(0.55f, 1.0f, altitudeT);
    float2 glowDelta = float2(delta.x, delta.y / max(0.001f, verticalScale));
    float glowDist = length(glowDelta);
    float maxGlowRadius = sunRadius * 8.0f;
    if (glowDist > maxGlowRadius) {
        return half4(0.0h);
    }

    float normalizedDist = dist / sunRadius;  // 1.0 = sun disc edge
    float normalizedGlowDist = glowDist / sunRadius;

    // ===== Layer 1: Outer Atmospheric Glow =====
    // Use a single Gaussian with controlled falloff for a tight, natural glow
    //
    // Target: bright core, rapid falloff, subtle outer haze
    // - r=0: 1.0 (bright center)
    // - r=1: ~0.78 (disc edge)
    // - r=2: ~0.37 (tight inner glow)
    // - r=4: ~0.02 (fading fast)
    // - r=6: ~0.0003 (nearly invisible)

    float r = normalizedGlowDist;
    float r2 = r * r;

    // Primary glow: tight Gaussian for the main visible corona
    float primaryGlow = exp(-r2 * 0.25f);

    // Secondary glow: slightly wider but much fainter for subtle haze
    float secondaryGlow = exp(-r2 * 0.08f) * 0.12f;

    // Combine - primary dominates, secondary adds subtle reach
    float glowIntensity = primaryGlow + secondaryGlow;

    // Soft outer fade
    float outerFade = 1.0f - smootherstep(5.0f, 8.0f, normalizedGlowDist);
    glowIntensity *= outerFade;

    // Blend glow colors by time of day
    float3 glowColor = blendTimeOfDay(SUNRISE_GLOW, DAYTIME_GLOW, SUNSET_GLOW,
                                       sunriseWeight, daytimeWeight, sunsetWeight);
    float backgroundLuma = dot(background, float3(0.2126f, 0.7152f, 0.0722f));
    float edgeBlend = smootherstep(1.0f, 4.5f, normalizedGlowDist);
    float backgroundMix = mix(0.45f, 0.15f, backgroundLuma);
    glowColor = mix(glowColor, background, edgeBlend * backgroundMix);

    // ===== Layer 2: Inner Halo (Optical Bloom) =====
    // Gaussian centered near disc edge for tight corona effect
    float haloWidth = 0.6f;
    float haloCenter = 0.9f;
    float haloDist = abs(normalizedGlowDist - haloCenter);
    float haloIntensity = exp(-haloDist * haloDist / (2.0f * haloWidth * haloWidth)) * 0.5f;

    // Warmer halo color
    float3 haloColor = blendTimeOfDay(
        float3(1.0f, 0.92f, 0.75f),
        float3(1.0f, 0.98f, 0.92f),
        float3(1.0f, 0.85f, 0.65f),
        sunriseWeight, daytimeWeight, sunsetWeight
    );

    // ===== Layer 3: Sun Disc with Limb Darkening =====
    float discIntensity = 0.0f;
    float3 discColor = float3(0.0f);

    if (normalizedDist < 1.05f) {  // Slight overshoot for anti-aliasing
        // Minnaert limb darkening: I(r) = I0 * mu^k
        // where mu = cos(angle from center) = sqrt(1 - (r/R)^2)
        // k = 0.6 is empirically good for the sun
        float rSquared = normalizedDist * normalizedDist;
        float mu = sqrt(max(0.0001f, 1.0f - min(rSquared, 1.0f)));
        float limbFactor = pow(mu, 0.6f);

        // Smootherstep at edge for anti-aliasing (soft disc edge)
        float edgeSoftness = 1.0f - smootherstep(0.92f, 1.02f, normalizedDist);
        discIntensity = limbFactor * edgeSoftness;

        // Interpolate disc color from edge to center using limb factor
        float3 coreColor = blendTimeOfDay(SUNRISE_CORE, DAYTIME_CORE, SUNSET_CORE,
                                           sunriseWeight, daytimeWeight, sunsetWeight);
        float3 edgeColor = blendTimeOfDay(SUNRISE_MID, DAYTIME_MID, SUNSET_MID,
                                           sunriseWeight, daytimeWeight, sunsetWeight);

        // Oklab interpolation for perceptually uniform transition
        discColor = interpolateOklab(edgeColor, coreColor, limbFactor);
    }

    // ===== Layer 4: Off-Center Hotspot (3D Depth) =====
    float2 hotspotCenter = sunCenter + hotspotOffset * sunRadius;
    float hotspotDist = length(position - hotspotCenter);
    float hotspotRadius = sunRadius * 0.35f;
    float normalizedHotspot = hotspotDist / hotspotRadius;

    // Gaussian hotspot with smooth falloff
    float hotspotIntensity = exp(-normalizedHotspot * normalizedHotspot * 2.0f) * 0.4f;

    // Only show hotspot inside/near disc
    hotspotIntensity *= smootherstep(1.1f, 0.8f, normalizedDist);

    // Pure white hotspot with slight warmth
    float3 hotspotColor = float3(1.0f, 0.995f, 0.985f);

    // ===== Composite All Layers =====
    // Build up from back to front with proper alpha blending
    float3 result = float3(0.0f);
    float alpha = 0.0f;
    float themeScale = mix(0.75f, 1.0f, backgroundLuma);

    // Outer glow (base layer) - premultiplied alpha style
    // Use higher base alpha for better precision in outer regions
    float glowAlpha = glowIntensity * 0.7f * themeScale;
    result = glowColor * glowAlpha;
    alpha = glowAlpha;

    // Halo (additive blend for bloom effect)
    float haloAlpha = haloIntensity * 0.65f * themeScale;
    result += haloColor * haloAlpha;
    alpha = max(alpha, haloAlpha);

    // Sun disc (over blend - opaque disc)
    if (discIntensity > 0.001f) {
        // Standard "over" compositing
        float discAlpha = discIntensity;
        result = mix(result, discColor, discAlpha);
        alpha = discAlpha + alpha * (1.0f - discAlpha);
    }

    // Hotspot (additive for bright specular highlight)
    result += hotspotColor * hotspotIntensity;
    alpha = min(1.0f, alpha + hotspotIntensity * 0.5f);

    // Apply overall intensity scaling
    result *= intensity;
    alpha *= intensity;

    // Apply adaptive dithering - stronger at low intensity to combat quantization
    // This is critical for eliminating banding in the outer glow regions
    float3 dither = adaptiveDither(position, time, intensity);
    result += dither;

    // Final clamp and output
    return half4(half3(saturate(result)), half(saturate(alpha)));
}

// MARK: - Horizon Glow Shader

/// Horizon glow shader for sunrise/sunset atmospheric effects
/// Uses per-pixel Gaussian computation to eliminate banding artifacts
///
/// Parameters:
/// - position: Current pixel position (provided by SwiftUI)
/// - color: Input color (ignored, we generate our own)
/// - glowCenterX: Glow center X position in view coordinates
/// - glowCenterY: Glow center Y position in view coordinates
/// - outerRadius: Outer extent of the glow in pixels
/// - intensity: Overall intensity (0.0-1.0)
/// - time: Elapsed time for dither animation
/// - coreR/G/B: Core glow color (sRGB, 0-1)
/// - edgeR/G/B: Edge glow color (sRGB, 0-1)
[[ stitchable ]] half4 horizonGlow(
    float2 position,
    half4 color,
    float glowCenterX,
    float glowCenterY,
    float outerRadius,
    float intensity,
    float time,
    float coreR, float coreG, float coreB,
    float edgeR, float edgeG, float edgeB
) {
    float2 glowCenter = float2(glowCenterX, glowCenterY);

    // Early exit for pixels far from glow center
    float2 delta = position - glowCenter;
    float dist = length(delta);
    if (dist > outerRadius * 1.2f) {
        return half4(0.0h);
    }

    float normalizedDist = dist / outerRadius;

    // ===== Multi-layer Gaussian glow for soft/diffuse appearance =====

    // Layer 1: Tight core glow (bright center)
    // sigma = 0.3 of outerRadius, so the Gaussian decays quickly
    float sigma1 = 0.3f;
    float gauss1 = exp(-0.5f * (normalizedDist * normalizedDist) / (sigma1 * sigma1));

    // Layer 2: Medium spread glow (main atmospheric effect)
    // sigma = 0.6 of outerRadius
    float sigma2 = 0.6f;
    float gauss2 = exp(-0.5f * (normalizedDist * normalizedDist) / (sigma2 * sigma2));

    // Layer 3: Wide ambient glow (soft outer haze)
    // sigma = 1.0 of outerRadius for very soft falloff
    float sigma3 = 1.0f;
    float gauss3 = exp(-0.5f * (normalizedDist * normalizedDist) / (sigma3 * sigma3));

    // Combine layers with different weights
    // Tight core (0.4) + medium (0.4) + wide (0.2) = smooth multi-scale glow
    float combinedGlow = gauss1 * 0.4f + gauss2 * 0.4f + gauss3 * 0.2f;

    // Soft outer fade using smootherstep
    float outerFade = 1.0f - smootherstep(0.7f, 1.0f, normalizedDist);
    combinedGlow *= outerFade;

    // ===== Color interpolation in Oklab space =====

    // Interpolate from core color (at center) to edge color (at distance)
    // Use smootherstep for perceptually smooth transition
    float colorT = smootherstep(0.0f, 0.8f, normalizedDist);

    float3 coreColor = float3(coreR, coreG, coreB);
    float3 edgeColor = float3(edgeR, edgeG, edgeB);
    float3 glowColor = interpolateOklab(coreColor, edgeColor, colorT);

    // ===== Composite result =====

    float alpha = combinedGlow * intensity;
    float3 result = glowColor * alpha;

    // ===== Apply adaptive dithering =====
    // Critical for eliminating quantization banding at low intensity
    float3 dither = adaptiveDither(position, time, intensity * combinedGlow);
    result += dither;

    // Final clamp and output
    return half4(half3(saturate(result)), half(saturate(alpha)));
}
