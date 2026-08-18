//
//  Moon.metal
//  rootshell
//
//  Metal shader for physically-accurate moon rendering with phase shadows.
//  Eliminates banding by computing per-pixel values using mathematical functions.
//
//  Features:
//  - Multi-scale Gaussian glow with enhanced artistic intensity
//  - Accurate phase shadow (terminator) rendering
//  - Minnaert limb darkening (k=0.3 for moon)
//  - Procedural FBM noise maria (dark patches)
//  - Earthshine effect for dark limb near new moon
//  - Oklab color space interpolation
//  - Adaptive triangular PDF dithering
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// MARK: - Oklab Color Space Functions

static float srgbToLinear(float x) {
    return x <= 0.04045f ? x / 12.92f : pow((x + 0.055f) / 1.055f, 2.4f);
}

static float linearToSrgb(float x) {
    return x <= 0.0031308f ? 12.92f * x : 1.055f * pow(x, 1.0f/2.4f) - 0.055f;
}

static float3 linearRGBToOklab(float3 rgb) {
    float l = 0.4122214708f * rgb.r + 0.5363325363f * rgb.g + 0.0514459929f * rgb.b;
    float m = 0.2119034982f * rgb.r + 0.6806995451f * rgb.g + 0.1073969566f * rgb.b;
    float s = 0.0883024619f * rgb.r + 0.2817188376f * rgb.g + 0.6299787005f * rgb.b;

    float l_ = pow(max(l, 0.0f), 1.0f/3.0f);
    float m_ = pow(max(m, 0.0f), 1.0f/3.0f);
    float s_ = pow(max(s, 0.0f), 1.0f/3.0f);

    return float3(
        0.2104542553f * l_ + 0.7936177850f * m_ - 0.0040720468f * s_,
        1.9779984951f * l_ - 2.4285922050f * m_ + 0.4505937099f * s_,
        0.0259040371f * l_ + 0.7827717662f * m_ - 0.8086757660f * s_
    );
}

static float3 oklabToLinearRGB(float3 oklab) {
    float l_ = oklab.x + 0.3963377774f * oklab.y + 0.2158037573f * oklab.z;
    float m_ = oklab.x - 0.1055613458f * oklab.y - 0.0638541728f * oklab.z;
    float s_ = oklab.x - 0.0894841775f * oklab.y - 1.2914855480f * oklab.z;

    float l = l_ * l_ * l_;
    float m = m_ * m_ * m_;
    float s = s_ * s_ * s_;

    return float3(
        +4.0767416621f * l - 3.3077115913f * m + 0.2309699292f * s,
        -1.2684380046f * l + 2.6097574011f * m - 0.3413193965f * s,
        -0.0041960863f * l - 0.7034186147f * m + 1.7076147010f * s
    );
}

static float3 interpolateOklab(float3 srgbA, float3 srgbB, float t) {
    float3 linA = float3(srgbToLinear(srgbA.r), srgbToLinear(srgbA.g), srgbToLinear(srgbA.b));
    float3 linB = float3(srgbToLinear(srgbB.r), srgbToLinear(srgbB.g), srgbToLinear(srgbB.b));

    float3 okA = linearRGBToOklab(linA);
    float3 okB = linearRGBToOklab(linB);

    float3 okResult = mix(okA, okB, t);
    float3 linResult = oklabToLinearRGB(okResult);

    return float3(
        saturate(linearToSrgb(linResult.r)),
        saturate(linearToSrgb(linResult.g)),
        saturate(linearToSrgb(linResult.b))
    );
}

// MARK: - Adaptive Dithering

static float3 adaptiveDither(float2 position, float time, float intensity) {
    float3 magic = float3(0.06711056f, 0.00583715f, 52.9829189f);
    float noise1 = fract(magic.z * fract(dot(position, magic.xy)));
    float noise2 = fract(magic.z * fract(dot(position + float2(1.0f, 0.0f), magic.xy)));
    float noise3 = fract(magic.z * fract(dot(position + float2(0.0f, 1.0f), magic.xy)));

    noise1 = fract(noise1 + time * 0.1f);
    noise2 = fract(noise2 + time * 0.17f);
    noise3 = fract(noise3 + time * 0.23f);

    float ditherR = noise1 + noise2 - 1.0f;
    float ditherG = noise2 + noise3 - 1.0f;
    float ditherB = noise3 + noise1 - 1.0f;

    float adaptiveStrength = 1.0f / (255.0f * max(0.15f, sqrt(intensity)));

    return float3(ditherR, ditherG, ditherB) * adaptiveStrength;
}

// MARK: - Procedural Noise for Maria

static float hash(float2 p) {
    return fract(sin(dot(p, float2(127.1f, 311.7f))) * 43758.5453f);
}

static float noise2D(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0f - 2.0f * f);  // Smoothstep

    float a = hash(i);
    float b = hash(i + float2(1.0f, 0.0f));
    float c = hash(i + float2(0.0f, 1.0f));
    float d = hash(i + float2(1.0f, 1.0f));

    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// Fractal Brownian Motion for organic maria patterns
static float fbm(float2 p, int octaves) {
    float value = 0.0f;
    float amplitude = 0.5f;
    float frequency = 1.0f;

    for (int i = 0; i < octaves; i++) {
        value += amplitude * noise2D(p * frequency);
        amplitude *= 0.5f;
        frequency *= 2.0f;
    }

    return value;
}

// MARK: - Smoothstep Variants

static float smootherstep(float edge0, float edge1, float x) {
    x = saturate((x - edge0) / (edge1 - edge0));
    return x * x * x * (x * (x * 6.0f - 15.0f) + 10.0f);
}

// MARK: - Moon Color Palettes

// Moon surface colors (silver-gray with subtle blue tints)
constant float3 MOON_SURFACE_BRIGHT = float3(0.85f, 0.85f, 0.87f);   // Highlands
constant float3 MOON_SURFACE_DARK = float3(0.35f, 0.35f, 0.38f);     // Maria (basalt)
constant float3 MOON_GLOW_COLOR = float3(0.95f, 0.95f, 0.98f);       // Subtle neutral bloom
constant float3 MOON_HALO_COLOR = float3(0.90f, 0.92f, 0.98f);       // Faint cool halo
constant float3 EARTHSHINE_COLOR = float3(0.35f, 0.42f, 0.55f);      // Blue-gray earthshine

// MARK: - Moon Glow Shader

/// Moon glow shader with phase shadows and maria
///
/// Parameters:
/// - position: Current pixel position
/// - color: Input color (ignored)
/// - moonCenterX/Y: Moon center position
/// - moonRadius: Base moon radius in pixels
/// - intensity: Overall intensity (0.0-1.0)
/// - time: Elapsed time for dither animation
/// - illumination: Phase illumination (0.0 = new, 1.0 = full)
/// - phaseAngle: 0-360 degrees through lunar cycle
/// - positionAngle: Bright limb orientation (degrees from screen up toward screen right)
/// - showMaria: Whether to show maria texture (1.0 = yes, 0.0 = no)
/// - showEarthshine: Whether to show earthshine (1.0 = yes, 0.0 = no)
[[ stitchable ]] half4 moonGlow(
    float2 position,
    half4 color,
    float moonCenterX,
    float moonCenterY,
    float moonRadius,
    float intensity,
    float time,
    float illumination,
    float phaseAngle,
    float positionAngle,
    float showMaria,
    float showEarthshine
) {
    float2 moonCenter = float2(moonCenterX, moonCenterY);

    // Early exit for pixels far from moon
    float2 delta = position - moonCenter;
    float dist = length(delta);
    // The moon has no atmosphere: keep bloom subtle and tight.
    float maxGlowRadius = moonRadius * 2.25f;
    if (dist > maxGlowRadius) {
        return half4(0.0h);
    }

    float normalizedDist = dist / moonRadius;

    // Phase-aware lighting direction.
    // We reuse this for both the disc terminator and to bias the halo/glow toward the bright limb.
    float2 localPos = (position - moonCenter) / moonRadius;
    const float DEG2RAD = 0.017453292519943295f;
    float phaseRad = phaseAngle * DEG2RAD;
    float positionRad = (positionAngle - 90.0f) * DEG2RAD; // convert "up→right" to "+x axis"

    // Light direction points toward the sun. At new moon (0°): -Z (behind the moon).
    // At full moon (180°): +Z (toward the viewer). At quarter phases: in the XY plane.
    float sinPhase = sin(phaseRad);
    float3 lightDir = normalize(float3(
        sinPhase * cos(positionRad),
        sinPhase * sin(positionRad),
        -cos(phaseRad)
    ));

    // Phase-shaped halo/glow bias:
    // - near full: mostly symmetric
    // - near new/quarter: concentrated on the bright-limb side
    float glowPhaseMask = 1.0f;
    float localR2 = dot(localPos, localPos);
    if (localR2 > 1e-6f) {
        float3 edgeNormal = normalize(float3(localPos.x, localPos.y, 0.0f));
        float edgeDot = dot(edgeNormal, lightDir); // lit side > 0
        float limbSide = smootherstep(-0.2f, 0.2f, edgeDot);

        // Only approach a symmetric halo near full moon; at/under half phases the halo should
        // strongly favor the illuminated side.
        float fullness = saturate((illumination - 0.5f) / 0.5f); // 0 at half, 1 at full
        float symmetric = fullness * fullness;
        glowPhaseMask = saturate(symmetric + (1.0f - symmetric) * limbSide);
    }

    // ===== Layer 1: Subtle Lens Bloom =====
    // A tight Gaussian around the limb reads as camera/eye bloom without looking atmospheric.
    float edgeDist = normalizedDist - 1.0f;
    float edgeMask = smootherstep(0.85f, 1.0f, normalizedDist);

    float sigmaTight = 0.10f;
    float sigmaWide = 0.28f;
    float tightBloom = exp(-(edgeDist * edgeDist) / (2.0f * sigmaTight * sigmaTight));
    float wideBloom = exp(-(edgeDist * edgeDist) / (2.0f * sigmaWide * sigmaWide)) * 0.20f;

    float glowIntensity = (tightBloom + wideBloom) * edgeMask;

    // Scale bloom by illumination, but keep it subtle even at full moon.
    float glowScale = 0.015f + 0.085f * pow(illumination, 1.8f);
    glowIntensity *= glowScale * glowPhaseMask;

    // Outer fade to the shader cutoff.
    float outerFade = 1.0f - smootherstep(1.7f, 2.25f, normalizedDist);
    glowIntensity *= outerFade;

    // ===== Layer 2: Very Faint Halo Ring =====
    float haloCenter = 1.03f;
    float haloWidth = 0.07f;
    float haloDist = abs(normalizedDist - haloCenter);
    float haloIntensity = exp(-(haloDist * haloDist) / (2.0f * haloWidth * haloWidth)) * 0.08f;
    haloIntensity *= glowScale * glowPhaseMask;

    // ===== Layer 3: Moon Disc with Limb Darkening =====
    float discIntensity = 0.0f;
    float3 discColor = float3(0.0f);
    float shadowMask = 1.0f;

    if (normalizedDist < 1.05f) {
        // Minnaert limb darkening (k=0.3 for moon, less than sun's 0.6)
        float rSquared = normalizedDist * normalizedDist;
        float mu = sqrt(max(0.0001f, 1.0f - min(rSquared, 1.0f)));
        float limbFactor = pow(mu, 0.3f);

        // Anti-aliased disc edge
        float edgeSoftness = 1.0f - smootherstep(0.94f, 1.02f, normalizedDist);
        // Keep the disc visually "present" at small sizes; apply limb darkening to color only.
        // (Multiplying limbFactor into both alpha and color makes thin crescents nearly disappear.)
        discIntensity = edgeSoftness;

        // ===== Phase Shadow (Terminator) =====
        // Use a physically-based sphere lighting model for accurate crescents/gibbous phases.
        // Visible surface normal n = (x, y, z) where z = sqrt(1 - x^2 - y^2).
        // A point is illuminated if dot(n, lightDir) > 0.
        float localZ = sqrt(max(0.0f, 1.0f - localR2));
        float3 normal = float3(localPos.x, localPos.y, localZ);

        float dotNL = dot(normalize(normal), lightDir);

        // Soft shadow edge for smooth terminator.
        // Keep a minimum width in pixels so thin crescents remain visible at small radii.
        float shadowSoftness = max(0.03f, 1.0f / max(1.0f, moonRadius));
        shadowMask = smootherstep(-shadowSoftness, shadowSoftness, dotNL);

        // ===== Maria Texture (FBM Noise) =====
        float mariaPattern = 0.0f;
        if (showMaria > 0.5f) {
            // Sample FBM at moon surface coordinates
            float2 moonUV = localPos * 3.0f;  // Scale for detail
            mariaPattern = fbm(moonUV, 3);

            // Create distinct dark patches (maria regions)
            mariaPattern = smootherstep(0.45f, 0.65f, mariaPattern) * 0.35f;
        }

        // Base surface color with maria
        float3 surfaceColor = interpolateOklab(MOON_SURFACE_BRIGHT, MOON_SURFACE_DARK, mariaPattern);
        discColor = surfaceColor * limbFactor;

        // Apply phase shadow
        discColor *= shadowMask;

        // ===== Earthshine Effect =====
        // Visible when illumination < 30% (near new moon)
        float earthshineMask = 0.0f;
        if (showEarthshine > 0.5f && illumination < 0.3f && shadowMask < 0.5f) {
            float earthshineStrength = (0.3f - illumination) * 0.15f;
            earthshineStrength *= (1.0f - shadowMask);  // Only on dark side
            earthshineStrength *= limbFactor;  // Limb darkening applies
            discColor += EARTHSHINE_COLOR * earthshineStrength;

            // Keep earthshine from "blackening" the background by giving it its own alpha.
            // This makes the unlit side mostly transparent, with a faint earthshine presence.
            earthshineMask = saturate(earthshineStrength * 8.0f);
        }

        // Make the unlit portion transparent instead of blending "black" over the background.
        // (SwiftUI will composite this layer over the sky/ocean; we don't want the dark limb to
        // act as an occluder.)
        discIntensity *= max(shadowMask, earthshineMask);
    }

    // ===== Composite All Layers =====
    float3 result = float3(0.0f);
    float alpha = 0.0f;

    // Outer glow
    float glowAlpha = glowIntensity * 0.35f;
    result = MOON_GLOW_COLOR * glowAlpha;
    alpha = glowAlpha;

    // Halo (additive)
    float haloAlpha = haloIntensity * 0.25f;
    result += MOON_HALO_COLOR * haloAlpha;
    alpha = max(alpha, haloAlpha);

    // Moon disc (over blend)
    if (discIntensity > 0.001f) {
        float discAlpha = discIntensity;
        result = mix(result, discColor, discAlpha);
        alpha = discAlpha + alpha * (1.0f - discAlpha);
    }

    // Apply overall intensity
    result *= intensity;
    alpha *= intensity;

    // Apply adaptive dithering
    float3 dither = adaptiveDither(position, time, intensity);
    result += dither;

    return half4(half3(saturate(result)), half(saturate(alpha)));
}
