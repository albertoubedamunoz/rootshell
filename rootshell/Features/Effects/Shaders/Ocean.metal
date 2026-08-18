//
//  Ocean.metal
//  rootshell
//
//  Metal shader for ultra-realistic ocean simulation with Gerstner waves.
//  Renders below the horizon line in the Solar effect.
//
//  Features:
//  - Multi-octave Gerstner waves for physically accurate wave shapes
//  - Sun reflection path (specular highlights) synchronized with sun position
//  - Time-of-day color variation (sunrise teal → daytime blue → sunset mauve)
//  - Moonlit mode for subtle night-time waves
//  - Flow/current animation for natural movement
//  - Adaptive dithering to prevent banding artifacts
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// MARK: - Oklab Color Space Functions (shared with SunGlow.metal)

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

/// Convert Oklab to linear RGB
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

/// Interpolate two sRGB colors in Oklab space for perceptual uniformity
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

/// Blend three colors by time-of-day weights
static float3 blendTimeOfDay(float3 sunrise, float3 daytime, float3 sunset,
                              float sunriseW, float daytimeW, float sunsetW) {
    float total = sunriseW + daytimeW + sunsetW;
    if (total < 0.001f) return daytime;

    sunriseW /= total;
    daytimeW /= total;
    sunsetW /= total;

    float3 sunriseDaytime = interpolateOklab(sunrise, daytime, daytimeW / max(0.001f, sunriseW + daytimeW));
    return interpolateOklab(sunriseDaytime, sunset, sunsetW);
}

// MARK: - Smoothstep Variants

/// Perlin's smootherstep: C2-continuous
static float smootherstep(float edge0, float edge1, float x) {
    x = saturate((x - edge0) / (edge1 - edge0));
    return x * x * x * (x * (x * 6.0f - 15.0f) + 10.0f);
}

// MARK: - Noise Functions

/// Hash function for noise generation
static float hash(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031f);
    p3 += dot(p3, p3.yzx + 33.33f);
    return fract((p3.x + p3.y) * p3.z);
}

/// 2D value noise
static float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);

    float2 u = f * f * (3.0f - 2.0f * f);

    float a = hash(i);
    float b = hash(i + float2(1.0f, 0.0f));
    float c = hash(i + float2(0.0f, 1.0f));
    float d = hash(i + float2(1.0f, 1.0f));

    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

/// Fractal Brownian Motion for complex noise patterns
static float fbm(float2 p, int octaves) {
    float value = 0.0f;
    float amplitude = 0.5f;
    float frequency = 1.0f;

    for (int i = 0; i < octaves; i++) {
        value += amplitude * valueNoise(p * frequency);
        amplitude *= 0.5f;
        frequency *= 2.0f;
    }

    return value;
}

// MARK: - Caustics

/// Hash for Voronoi cell centers
static float2 voronoiHash(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031f, 0.1030f, 0.0973f));
    p3 += dot(p3, p3.yzx + 33.33f);
    return fract((p3.xx + p3.yz) * p3.zy);
}

/// Voronoi edge distance for caustics network pattern
static float voronoiEdge(float2 uv) {
    float2 i = floor(uv);
    float2 f = fract(uv);
    float minDist = 1.0f, secondDist = 1.0f;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            float2 neighbor = float2(float(x), float(y));
            float2 offset = neighbor + voronoiHash(i + neighbor) - f;
            float dist = length(offset);
            if (dist < minDist) { secondDist = minDist; minDist = dist; }
            else if (dist < secondDist) { secondDist = dist; }
        }
    }
    return secondDist - minDist;
}

/// Animated caustics - light network on shallow water
/// Uses high-frequency pattern to avoid visible cell structure in narrow views
static float caustics(float2 uv, float time, float depth, float sunAltitude, float isNight) {
    // Only visible in daylight, fades with depth
    float sunFactor = smootherstep(5.0f, 25.0f, sunAltitude);
    float nightFactor = 1.0f - saturate(isNight * 2.0f);
    float depthFactor = (1.0f - depth) * (1.0f - depth) * (1.0f - depth);

    if (sunFactor < 0.01f || nightFactor < 0.01f || depthFactor < 0.01f) return 0.0f;

    // High frequency Voronoi - small cells that blend together
    // Scale much higher (15-20x) so individual cells aren't visible as ropes
    float v1 = voronoiEdge(uv * 18.0f + float2(time * 0.15f, time * 0.12f));
    float v2 = voronoiEdge(uv * 15.0f + float2(-time * 0.1f, time * 0.18f));

    // Third layer at different angle to break up any remaining horizontal bias
    float v3 = voronoiEdge(uv * 12.0f + float2(time * 0.08f, -time * 0.14f));

    // Combine layers - multiply for network, add third for variation
    float pattern = v1 * v2 * 0.7f + v3 * 0.3f;
    pattern = smootherstep(0.01f, 0.08f, pattern);

    return pattern * depthFactor * sunFactor * nightFactor * 0.2f;
}

// MARK: - Adaptive Dithering

/// Triangular dithering with adaptive strength for low-intensity regions
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

// MARK: - Gerstner Wave Functions

/// Single Gerstner wave contribution
/// Returns float3: xy = horizontal displacement, z = vertical displacement
static float3 gerstnerWave(float2 position, float2 direction, float amplitude,
                           float wavelength, float steepness, float time) {
    float k = 2.0f * M_PI_F / wavelength;
    float c = sqrt(9.8f / k);  // Wave speed from dispersion relation
    float2 d = normalize(direction);
    float phase = k * dot(d, position) - c * k * time;

    float q = steepness / (k * amplitude * 6.0f);  // Limit steepness to prevent loops
    q = min(q, 1.0f);

    float sinP = sin(phase);
    float cosP = cos(phase);

    return float3(
        q * amplitude * d.x * cosP,
        q * amplitude * d.y * cosP,
        amplitude * sinP
    );
}

/// Sum multiple Gerstner waves for realistic ocean surface
/// Returns float3: xy = horizontal displacement, z = height
[[maybe_unused]] static float3 oceanWaves(float2 worldPos, float time, float amplitudeScale) {
    float3 result = float3(0.0f);

    // Primary swell (medium wavelength for visible rolling waves)
    result += gerstnerWave(worldPos, float2(1.0f, 0.2f), 3.0f * amplitudeScale, 25.0f, 0.5f, time);
    result += gerstnerWave(worldPos, float2(0.85f, 0.5f), 2.5f * amplitudeScale, 20.0f, 0.45f, time * 1.08f);

    // Secondary waves (cross-swell, slightly smaller)
    result += gerstnerWave(worldPos, float2(0.3f, 1.0f), 2.0f * amplitudeScale, 15.0f, 0.4f, time * 0.95f);
    result += gerstnerWave(worldPos, float2(-0.3f, 0.85f), 1.5f * amplitudeScale, 12.0f, 0.35f, time * 1.12f);

    // Ripples (high frequency for surface texture)
    result += gerstnerWave(worldPos, float2(1.0f, 0.1f), 0.8f * amplitudeScale, 5.0f, 0.25f, time * 1.4f);
    result += gerstnerWave(worldPos, float2(0.1f, 1.0f), 0.6f * amplitudeScale, 4.0f, 0.2f, time * 1.35f);

    return result;
}

// MARK: - Sun Reflection

/// Calculate sun reflection intensity on water surface
static float sunReflection(float3 normal, float2 pixelPos, float2 viewSize,
                           float sunX, float sunAltitude, float reflectionStrength) {
    // Normalized pixel position (0-1)
    float2 uv = pixelPos / viewSize;

    // View direction (camera looking at water from above at slight angle)
    float3 viewDir = normalize(float3(0.0f, -0.4f, 1.0f));

    // Sun direction based on sun position
    float altRad = sunAltitude * M_PI_F / 180.0f;
    float sunDirX = (sunX - 0.5f) * 2.0f;  // -1 to 1
    float3 lightDir = normalize(float3(sunDirX, sin(altRad) * 0.5f + 0.3f, cos(altRad)));

    // Blinn-Phong specular reflection
    float3 halfVec = normalize(lightDir + viewDir);
    float spec = pow(max(dot(normal, halfVec), 0.0f), 128.0f);

    // Fresnel effect - stronger reflection at grazing angles
    float fresnel = pow(1.0f - max(dot(normal, viewDir), 0.0f), 4.0f);

    // Horizontal alignment with sun - reflection path
    float horizAlign = 1.0f - abs(uv.x - sunX) * 2.0f;
    horizAlign = smootherstep(0.0f, 1.0f, horizAlign);
    horizAlign = pow(horizAlign, 1.5f);

    // Combine reflection components
    float reflection = (spec * 0.6f + fresnel * 0.3f) * horizAlign * reflectionStrength;

    // Reduce reflection when sun is low/below horizon
    float altitudeFactor = smootherstep(-5.0f, 15.0f, sunAltitude);
    reflection *= altitudeFactor;

    return saturate(reflection);
}

// MARK: - Ocean Color Palettes

// Sunrise colors (warm teal/turquoise)
constant float3 OCEAN_SUNRISE_DEEP = float3(0.02f, 0.06f, 0.10f);
constant float3 OCEAN_SUNRISE_SHALLOW = float3(0.12f, 0.22f, 0.28f);
constant float3 OCEAN_SUNRISE_REFLECT = float3(1.0f, 0.7f, 0.4f);

// Daytime colors (deep blue)
constant float3 OCEAN_DAYTIME_DEEP = float3(0.01f, 0.04f, 0.14f);
constant float3 OCEAN_DAYTIME_SHALLOW = float3(0.08f, 0.25f, 0.40f);
constant float3 OCEAN_DAYTIME_REFLECT = float3(0.9f, 0.95f, 1.0f);

// Sunset colors (purple-mauve)
constant float3 OCEAN_SUNSET_DEEP = float3(0.04f, 0.02f, 0.10f);
constant float3 OCEAN_SUNSET_SHALLOW = float3(0.18f, 0.12f, 0.22f);
constant float3 OCEAN_SUNSET_REFLECT = float3(1.0f, 0.5f, 0.35f);

// Moonlit colors (cool blue-gray)
constant float3 OCEAN_NIGHT_DEEP = float3(0.01f, 0.02f, 0.04f);
constant float3 OCEAN_NIGHT_SHALLOW = float3(0.04f, 0.06f, 0.10f);
constant float3 OCEAN_NIGHT_REFLECT = float3(0.6f, 0.7f, 0.85f);

// MARK: - Main Ocean Shader

/// Ocean surface shader with Gerstner waves and sun reflection
///
/// Parameters:
/// - position: Current pixel position (provided by SwiftUI)
/// - color: Input color (ignored, we generate our own)
/// - sizeX, sizeY: View dimensions
/// - horizonY: Y position of horizon line in view coordinates
/// - time: Animation time (independent 60fps timeline)
/// - sunX: Sun horizontal position (0-1 normalized)
/// - sunAltitude: Sun altitude in degrees
/// - intensity: Overall effect intensity (0.0-1.0)
/// - sunriseWeight, daytimeWeight, sunsetWeight: Time-of-day blend weights
/// - waveAmplitude: User-controllable wave height (0.1-1.0)
/// - reflectionStrength: User-controllable sun reflection (0.0-1.0)
/// - isNight: Night mode flag (0.0 = day, 1.0 = full night)
/// - waveSpeed: Animation speed multiplier (0.1-3.0)
/// - moonX: Moon horizontal position (0-1 normalized)
/// - moonAltitude: Moon altitude in degrees
/// - moonIllumination: Moon illumination (0.0 = new, 1.0 = full)
[[ stitchable ]] half4 ocean(
    float2 position,
    half4 color,
    float sizeX,
    float sizeY,
    float horizonY,
    float time,
    float sunX,
    float sunAltitude,
    float intensity,
    float sunriseWeight,
    float daytimeWeight,
    float sunsetWeight,
    float waveAmplitude,
    float reflectionStrength,
    float isNight,
    float waveSpeed,
    float moonX,
    float moonAltitude,
    float moonIllumination
) {
    // Note: position is in LOCAL coordinates relative to the Rectangle
    // sizeX = full view width, sizeY = ocean height (not full view height)
    float2 size = float2(sizeX, sizeY);

    // Calculate normalized position within ocean area
    // position.y goes from 0 (top of ocean/horizon) to sizeY (bottom)
    float2 oceanUV = float2(position.x / size.x, position.y / size.y);

    // Use FBM (fractal brownian motion) noise for natural-looking waves
    // Scale coordinates for wave size - larger numbers = smaller waves
    float2 waveCoord = oceanUV * float2(8.0f, 4.0f);

    // Wind-coherent wave drift
    // Dominant wind direction with secondary cross-wind and ripple layers
    float windAngle = 0.25f;  // Slight angle from horizontal (radians)
    float2 windDir = float2(cos(windAngle), sin(windAngle));
    float2 crossWind = float2(-windDir.y, windDir.x);  // Perpendicular

    // waveSpeed multiplier controls overall animation rate
    float2 drift1 = windDir * time * 0.15f * waveSpeed;           // Primary swell follows wind
    float2 drift2 = crossWind * time * 0.10f * waveSpeed;         // Cross-swell perpendicular
    float2 drift3 = (windDir + crossWind * 0.3f) * time * 0.20f * waveSpeed;  // Ripples slightly varied

    // Layer multiple octaves of noise at different scales
    float wave = 0.0f;

    // Large swells (slow-moving, dominant)
    wave += fbm(waveCoord * 1.0f + drift1, 3) * 0.5f;

    // Medium waves
    wave += fbm(waveCoord * 2.0f + drift2, 3) * 0.3f;

    // Small ripples (faster, more detail near horizon)
    float detailFade = 1.0f - oceanUV.y * 0.6f;  // More detail near top
    wave += fbm(waveCoord * 4.0f + drift3 * 2.0f, 2) * 0.2f * detailFade;

    // Normalize and apply amplitude
    float waveHeight = wave * waveAmplitude + 0.5f;
    waveHeight = saturate(waveHeight);

    // Calculate surface normal from noise gradients for lighting
    float eps = 0.002f;
    float2 coordDx = waveCoord + float2(eps, 0.0f);
    float2 coordDy = waveCoord + float2(0.0f, eps);

    float waveDx = fbm(coordDx * 1.0f + drift1, 3) * 0.5f +
                   fbm(coordDx * 2.0f + drift2, 3) * 0.3f +
                   fbm(coordDx * 4.0f + drift3 * 2.0f, 2) * 0.2f * detailFade;
    float waveDy = fbm(coordDy * 1.0f + drift1, 3) * 0.5f +
                   fbm(coordDy * 2.0f + drift2, 3) * 0.3f +
                   fbm(coordDy * 4.0f + drift3 * 2.0f, 2) * 0.2f * detailFade;

    float dzdx = (waveDx - wave) / eps * waveAmplitude;
    float dzdy = (waveDy - wave) / eps * waveAmplitude;
    float3 normal = normalize(float3(-dzdx, -dzdy, 1.0f));

    // Depth factor (darker further down)
    float depth = oceanUV.y;

    // === Color calculation ===

    // Base ocean colors by time of day
    float3 deepColor, shallowColor, reflectColor;

    if (isNight > 0.5f) {
        // Night mode - moonlit colors
        float nightBlend = (isNight - 0.5f) * 2.0f;  // 0-1 within night
        deepColor = mix(
            blendTimeOfDay(OCEAN_SUNRISE_DEEP, OCEAN_DAYTIME_DEEP, OCEAN_SUNSET_DEEP,
                          sunriseWeight, daytimeWeight, sunsetWeight),
            OCEAN_NIGHT_DEEP,
            nightBlend
        );
        shallowColor = mix(
            blendTimeOfDay(OCEAN_SUNRISE_SHALLOW, OCEAN_DAYTIME_SHALLOW, OCEAN_SUNSET_SHALLOW,
                          sunriseWeight, daytimeWeight, sunsetWeight),
            OCEAN_NIGHT_SHALLOW,
            nightBlend
        );
        reflectColor = mix(
            blendTimeOfDay(OCEAN_SUNRISE_REFLECT, OCEAN_DAYTIME_REFLECT, OCEAN_SUNSET_REFLECT,
                          sunriseWeight, daytimeWeight, sunsetWeight),
            OCEAN_NIGHT_REFLECT,
            nightBlend
        );
    } else {
        // Daytime colors blended by time-of-day
        deepColor = blendTimeOfDay(OCEAN_SUNRISE_DEEP, OCEAN_DAYTIME_DEEP, OCEAN_SUNSET_DEEP,
                                   sunriseWeight, daytimeWeight, sunsetWeight);
        shallowColor = blendTimeOfDay(OCEAN_SUNRISE_SHALLOW, OCEAN_DAYTIME_SHALLOW, OCEAN_SUNSET_SHALLOW,
                                      sunriseWeight, daytimeWeight, sunsetWeight);
        reflectColor = blendTimeOfDay(OCEAN_SUNRISE_REFLECT, OCEAN_DAYTIME_REFLECT, OCEAN_SUNSET_REFLECT,
                                      sunriseWeight, daytimeWeight, sunsetWeight);
    }

    // Interpolate between shallow and deep based on depth and wave height
    // Wave troughs appear deeper/darker, crests appear shallower/brighter
    float waveDepthInfluence = (1.0f - waveHeight) * 0.8f * waveAmplitude;
    float depthMix = depth * 0.4f + waveDepthInfluence;
    float3 baseColor = interpolateOklab(shallowColor, deepColor, saturate(depthMix));

    // === Wave shading (makes waves visible through light/dark variation) ===
    // Direct brightness variation based on wave height
    float waveBrightness = mix(0.6f, 1.4f, waveHeight);  // Strong contrast
    baseColor *= waveBrightness;

    // === Caustics - light patterns on shallow water ===
    float causticsVal = caustics(oceanUV, time * waveSpeed, depth, sunAltitude, isNight);
    baseColor += float3(0.95f, 0.92f, 0.85f) * causticsVal;

    // === Subsurface scattering - light transmission through wave crests ===
    // Creates the "glowing edge" effect when sunlight passes through thin water
    float3 lightDir = normalize(float3((sunX - 0.5f) * 2.0f,
                                        sin(sunAltitude * M_PI_F / 180.0f) * 0.5f + 0.3f,
                                        cos(sunAltitude * M_PI_F / 180.0f)));
    float sssThickness = smootherstep(0.55f, 0.85f, waveHeight);  // Thin at crests
    float backlight = pow(max(dot(normal, -lightDir), 0.0f), 2.0f);  // Light from behind
    float3 sssColor = shallowColor * 1.4f;  // Brighter, more saturated version
    float sssIntensity = sssThickness * backlight * 0.25f;
    sssIntensity *= smootherstep(-5.0f, 20.0f, sunAltitude);  // Only when sun is up
    sssIntensity *= (1.0f - isNight);  // Suppress at night
    baseColor += sssColor * sssIntensity;

    // === Sun/Moon reflection ===
    float reflIntensity = sunReflection(normal, position, size, sunX, sunAltitude, reflectionStrength);

    // Moon reflection using actual moon position and illumination
    // Moon reflection is fainter than sun, scaled by illumination (brighter when full)
    if (moonAltitude > -5.0f && moonIllumination > 0.05f) {
        float moonReflStrength = reflectionStrength * 0.35f * moonIllumination;
        float moonRefl = sunReflection(normal, position, size, moonX, moonAltitude, moonReflStrength);
        // Silver-white moon reflection color (cooler than sun)
        // Blend moon reflection with sun reflection - moon dominates at night
        float moonDominance = isNight * moonIllumination;
        reflIntensity = mix(reflIntensity, max(reflIntensity, moonRefl), moonDominance);
    }

    // === Micro-facet sparkles ===
    // Natural glints from wave facets catching sunlight
    // Use continuous noise rather than grid cells for organic distribution
    float sparkleNoise1 = valueNoise(waveCoord * 12.0f + drift1 * 2.0f);
    float sparkleNoise2 = valueNoise(waveCoord * 18.0f - drift2 * 1.5f);
    float sparklePattern = sparkleNoise1 * sparkleNoise2;  // Multiply for sparser peaks

    // Only the highest peaks become sparkles
    float sparkleMask = smootherstep(0.35f, 0.45f, sparklePattern);

    // Sparkle intensity based on how well the surface reflects toward viewer
    float3 sparkleHalfVec = normalize(lightDir + float3(0.0f, -0.4f, 1.0f));
    float sparkleSpec = pow(max(dot(normal, sparkleHalfVec), 0.0f), 48.0f);
    float sparkle = sparkleMask * sparkleSpec * 0.35f;
    sparkle *= smootherstep(-5.0f, 15.0f, sunAltitude);  // Only when sun is up
    sparkle *= (1.0f - isNight);  // No sparkles at night

    reflIntensity += sparkle;

    // Blend reflection color
    float3 oceanColor = mix(baseColor, reflectColor, reflIntensity);

    // === Textured foam/whitecaps with noise-based breakup ===
    // Use smooth noise instead of hash for organic foam texture
    float foamNoise = valueNoise(waveCoord * 10.0f + drift1 * 2.0f);
    float foamNoise2 = valueNoise(waveCoord * 16.0f - drift2 * 1.5f);
    float foamTexture = foamNoise * 0.6f + foamNoise2 * 0.4f;  // Layered for variety

    float foamBase = smootherstep(0.58f, 0.88f, waveHeight);
    float foam = foamBase * (0.4f + foamTexture * 0.6f);  // Organic patchy appearance
    foam *= min(waveAmplitude, 0.7f);  // Cap foam intensity at high amplitudes

    // Foam is slightly blue-white, blends over water color
    float3 foamColor = float3(0.82f, 0.88f, 0.95f);
    oceanColor = mix(oceanColor, foamColor, foam * 0.4f);

    // === Apply overall intensity ===
    // Night mode reduces overall brightness
    float nightDimming = 1.0f - isNight * 0.7f;
    float finalIntensity = intensity * nightDimming;

    oceanColor *= finalIntensity;

    // === Alpha calculation ===
    // Fade in from horizon
    float horizonFade = smootherstep(0.0f, 0.15f, oceanUV.y);
    // Slight fade at bottom
    float bottomFade = 1.0f - smootherstep(0.85f, 1.0f, oceanUV.y) * 0.3f;

    float alpha = horizonFade * bottomFade * finalIntensity;

    // === Apply adaptive dithering ===
    float3 dither = adaptiveDither(position, time, finalIntensity);
    oceanColor += dither;

    return half4(half3(saturate(oceanColor)), half(saturate(alpha)));
}
