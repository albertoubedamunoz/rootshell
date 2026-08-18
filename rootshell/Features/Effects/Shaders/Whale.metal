//
//  Whale.metal
//  rootshell
//
//  Physics-based shader for realistic whale animation in the Solar ocean effect.
//  Features SDF-based whale body, Gerstner wave coupling, subsurface scattering,
//  Kelvin wake patterns, and physically-accurate blowhole spout simulation.
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// MARK: - Constants

// Physics constants
constant float BUOYANCY_FACTOR = 0.6f;           // Whale floats 60% above water
constant float KELVIN_ANGLE = 0.3398f;           // 19.47 degrees in radians

// Whale body dimensions (in shader units, scaled by whaleScale)
constant float WHALE_LENGTH = 120.0f;

// Whale colors - darker charcoal like real humpback whales
constant float3 WHALE_BODY_DARK = float3(0.08f, 0.08f, 0.10f);   // Near-black back
constant float3 WHALE_BODY_MID = float3(0.15f, 0.14f, 0.16f);    // Dark charcoal
constant float3 WHALE_BELLY = float3(0.35f, 0.33f, 0.32f);       // Lighter gray belly
constant float3 WHALE_HIGHLIGHT = float3(0.50f, 0.48f, 0.46f);   // Wet skin highlights

// Spout colors - more subtle, translucent
constant float3 SPOUT_CORE = float3(0.70f, 0.75f, 0.82f);
constant float3 SPOUT_MIST = float3(0.60f, 0.68f, 0.78f);

// Wake/foam colors
constant float3 WAKE_FOAM = float3(0.80f, 0.85f, 0.92f);

// Underwater depth effect colors
constant float3 DEEP_WATER_COLOR = float3(0.08f, 0.15f, 0.25f);

// MARK: - Oklab Color Space Functions (shared with Ocean.metal)

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

static float smootherstep(float edge0, float edge1, float x) {
    x = saturate((x - edge0) / (edge1 - edge0));
    return x * x * x * (x * (x * 6.0f - 15.0f) + 10.0f);
}

// MARK: - Noise Functions

static float hash(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031f);
    p3 += dot(p3, p3.yzx + 33.33f);
    return fract((p3.x + p3.y) * p3.z);
}

static float hash3(float3 p) {
    p = fract(p * float3(0.1031f, 0.1030f, 0.0973f));
    p += dot(p, p.yxz + 33.33f);
    return fract((p.x + p.y) * p.z);
}

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

static float valueNoise3D(float3 p) {
    float3 i = floor(p);
    float3 f = fract(p);
    float3 u = f * f * (3.0f - 2.0f * f);

    return mix(
        mix(mix(hash3(i + float3(0,0,0)), hash3(i + float3(1,0,0)), u.x),
            mix(hash3(i + float3(0,1,0)), hash3(i + float3(1,1,0)), u.x), u.y),
        mix(mix(hash3(i + float3(0,0,1)), hash3(i + float3(1,0,1)), u.x),
            mix(hash3(i + float3(0,1,1)), hash3(i + float3(1,1,1)), u.x), u.y),
        u.z
    );
}

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

static float fbm3D(float3 p, int octaves) {
    float value = 0.0f;
    float amplitude = 0.5f;
    float frequency = 1.0f;

    for (int i = 0; i < octaves; i++) {
        value += amplitude * valueNoise3D(p * frequency);
        amplitude *= 0.5f;
        frequency *= 2.0f;
    }

    return value;
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

// MARK: - Gerstner Wave Functions (shared with Ocean.metal)

static float3 gerstnerWave(float2 position, float2 direction, float amplitude,
                           float wavelength, float steepness, float time) {
    float k = 2.0f * M_PI_F / wavelength;
    float c = sqrt(9.8f / k);
    float2 d = normalize(direction);
    float phase = k * dot(d, position) - c * k * time;

    float q = steepness / (k * amplitude * 6.0f);
    q = min(q, 1.0f);

    float sinP = sin(phase);
    float cosP = cos(phase);

    return float3(
        q * amplitude * d.x * cosP,
        q * amplitude * d.y * cosP,
        amplitude * sinP
    );
}

static float3 oceanWaves(float2 worldPos, float time, float amplitudeScale) {
    float3 result = float3(0.0f);

    // Primary swell
    result += gerstnerWave(worldPos, float2(1.0f, 0.2f), 3.0f * amplitudeScale, 25.0f, 0.5f, time);
    result += gerstnerWave(worldPos, float2(0.85f, 0.5f), 2.5f * amplitudeScale, 20.0f, 0.45f, time * 1.08f);

    // Secondary waves
    result += gerstnerWave(worldPos, float2(0.3f, 1.0f), 2.0f * amplitudeScale, 15.0f, 0.4f, time * 0.95f);
    result += gerstnerWave(worldPos, float2(-0.3f, 0.85f), 1.5f * amplitudeScale, 12.0f, 0.35f, time * 1.12f);

    // Ripples
    result += gerstnerWave(worldPos, float2(1.0f, 0.1f), 0.8f * amplitudeScale, 5.0f, 0.25f, time * 1.4f);
    result += gerstnerWave(worldPos, float2(0.1f, 1.0f), 0.6f * amplitudeScale, 4.0f, 0.2f, time * 1.35f);

    return result;
}

// MARK: - SDF Primitives

/// Smooth minimum for organic blending
static float smin(float a, float b, float k) {
    float h = max(k - abs(a - b), 0.0f) / k;
    return min(a, b) - h * h * k * 0.25f;
}

// MARK: - Buoyancy Physics

/// Calculate whale buoyancy response to ocean waves
/// Returns: x = horizontal drift, y = vertical heave, z = pitch angle
static float3 calculateBuoyancy(float2 whaleWorldPos, float time, float waveAmplitude, float whaleScale) {
    float scaledLength = WHALE_LENGTH * whaleScale * 0.5f;

    // Sample ocean at front, center, and back of whale
    float3 waveFront = oceanWaves(whaleWorldPos + float2(-scaledLength, 0.0f), time, waveAmplitude);
    float3 waveCenter = oceanWaves(whaleWorldPos, time, waveAmplitude);
    float3 waveBack = oceanWaves(whaleWorldPos + float2(scaledLength, 0.0f), time, waveAmplitude);

    // Heave (vertical position) - whale floats with wave
    float heave = waveCenter.z * BUOYANCY_FACTOR * whaleScale * 2.0f;

    // Pitch from front-back height difference
    float heightDiff = waveFront.z - waveBack.z;
    float pitch = atan2(heightDiff, scaledLength * 2.0f) * 0.5f;  // Damped pitch response

    // Surge (horizontal drift) from wave displacement
    float surge = waveCenter.x * 0.2f * whaleScale;

    return float3(surge, heave, pitch);
}

// MARK: - Skin Rendering

/// Generate whale skin texture with mottled pattern, barnacles, and scarring
static float whaleSkinPattern(float3 localPos, float time) {
    // Large mottled pattern
    float mottled = fbm3D(localPos * 0.08f, 4);

    // Medium scale variation
    float medium = fbm3D(localPos * 0.2f + float3(100.0f, 0.0f, 0.0f), 3);

    // Fine texture
    float fine = fbm3D(localPos * 0.5f + float3(0.0f, 100.0f, 0.0f), 2);

    // Barnacle clusters - high frequency noise with threshold
    float barnacleNoise = fbm3D(localPos * 0.4f + float3(50.0f, 50.0f, 0.0f), 3);
    float barnacles = smootherstep(0.62f, 0.72f, barnacleNoise);

    // Scarring - elongated linear patterns
    float2 scarCoord = float2(localPos.x * 0.1f + localPos.z * 0.3f, localPos.y * 0.2f);
    float scarNoise = fbm(scarCoord, 3);
    float scars = smootherstep(0.58f, 0.65f, scarNoise) * 0.5f;

    // Combine: base mottling + medium detail + fine detail + barnacles + scars
    float pattern = mottled * 0.5f + medium * 0.3f + fine * 0.15f + barnacles * 0.3f + scars;

    return saturate(pattern);
}

// MARK: - Kelvin Wake Pattern

/// Calculate Kelvin wake pattern behind moving whale
static float kelvinWake(float2 pixelPos, float2 whalePos, float2 whaleFacing, float whaleSpeed, float time) {
    // Wake only forms when whale is moving (during surface/dive)
    if (whaleSpeed < 0.01f) return 0.0f;

    // Transform to wake-aligned coordinates
    float2 wakeDir = normalize(whaleFacing);
    float2 relPos = pixelPos - whalePos;
    float alongWake = dot(relPos, -wakeDir);  // Positive = behind whale
    float acrossWake = dot(relPos, float2(-wakeDir.y, wakeDir.x));

    // Only behind whale
    if (alongWake < 10.0f) return 0.0f;

    // Wake envelope: V-shape at Kelvin angle
    float envelope = smootherstep(0.0f, alongWake * tan(KELVIN_ANGLE), abs(acrossWake));
    envelope = 1.0f - envelope;

    // Transverse waves - perpendicular to wake direction
    float transversePhase = alongWake * 0.15f - time * 2.5f;
    float transverse = sin(transversePhase) * exp(-alongWake * 0.008f);

    // Divergent waves - at angle to wake
    float divergentPhase = (alongWake + abs(acrossWake) * 1.5f) * 0.12f - time * 2.0f;
    float divergent = sin(divergentPhase) * exp(-(alongWake + abs(acrossWake)) * 0.01f);

    // Combine with distance falloff
    float wakeStrength = (transverse * 0.5f + divergent * 0.5f) * envelope;
    wakeStrength *= whaleSpeed;
    wakeStrength *= 1.0f / (1.0f + alongWake * 0.003f);

    return saturate(wakeStrength * 0.5f + 0.5f) - 0.5f;  // Centered at 0
}

// MARK: - Water Interaction Effects

/// Foam generation where whale breaks water surface - subtle disturbance
static float surfaceFoam(float2 pixelPos, float2 whalePos, float whaleScale, float surfaceProgress) {
    float dist = length(pixelPos - whalePos);
    float foamRadius = 60.0f * whaleScale * surfaceProgress;

    // Very subtle foam around whale body - no ring, just soft gradient
    float central = smootherstep(foamRadius, foamRadius * 0.2f, dist);

    // Add noise for organic look
    float foamNoise = fbm(pixelPos * 0.08f, 3);

    // Much more subtle foam effect
    return central * (0.3f + foamNoise * 0.2f) * surfaceProgress * 0.3f;
}

/// Water dripping effect during emergence
static float waterDrip(float2 pixelPos, float2 whalePos, float whaleScale, float emergeProgress, float time) {
    // Multiple drip streams
    float drip = 0.0f;
    for (int i = 0; i < 8; i++) {
        float offset = float(i) * 15.0f - 52.5f;
        float2 dripStart = whalePos + float2(offset * whaleScale, -10.0f * whaleScale);

        // Drip falls with gravity
        float dripTime = time + float(i) * 0.1f;
        float dripY = dripStart.y + 80.0f * whaleScale * fract(dripTime * 0.5f);

        float2 dripPos = float2(dripStart.x, dripY);
        float dripDist = length(pixelPos - dripPos);

        // Elongated droplet shape
        float droplet = smootherstep(4.0f * whaleScale, 0.0f, dripDist);
        drip += droplet * (1.0f - emergeProgress);
    }

    return saturate(drip);
}

// MARK: - Spout Physics (Hero Feature)

/// Spout rendered as a tall vertical column that disperses at the top
/// Like a real whale blow - shoots up high, spreads at top
static float spoutDensity(float2 pixelPos, float2 blowholePos, float spoutProgress, float time,
                          float2 windDir, float windSpeed, float scale) {
    // 8 second spout phase
    float spoutDuration = 8.0f;
    float spoutTime = spoutProgress * spoutDuration;

    if (spoutTime < 0.05f) return 0.0f;

    // Spout height grows quickly then stays
    float maxHeight = 120.0f * scale;
    float currentHeight = maxHeight * smootherstep(0.0f, 1.5f, spoutTime);

    // Column from blowhole up to current height
    float2 relPos = pixelPos - blowholePos;

    // Wind drift increases with height
    float heightRatio = saturate(-relPos.y / max(1.0f, currentHeight));
    float windDrift = windDir.x * windSpeed * 20.0f * scale * heightRatio * spoutTime * 0.3f;
    relPos.x -= windDrift;

    // Column width - narrow at base, wider at top
    float baseWidth = 6.0f * scale;
    float topWidth = 25.0f * scale * (1.0f + spoutTime * 0.3f);
    float columnWidth = mix(baseWidth, topWidth, heightRatio);

    // Only render above blowhole (negative Y is up)
    if (relPos.y > 5.0f * scale) return 0.0f;
    if (relPos.y < -currentHeight) return 0.0f;

    // Horizontal distance from column center
    float horizDist = abs(relPos.x) / columnWidth;

    // Add noise for wispy edges
    float2 noiseCoord = pixelPos * 0.05f / scale + float2(time * 0.1f, time * 0.08f);
    float edgeNoise = fbm(noiseCoord, 3) * 0.3f;

    // Column density - solid core, soft edges
    float density = 1.0f - smootherstep(0.3f, 1.0f + edgeNoise, horizDist);

    // Density varies along height - denser at base, wispier at top
    float verticalFade = 1.0f - heightRatio * 0.5f;
    density *= verticalFade;

    // Add turbulent wisps
    float2 wispCoord = pixelPos * 0.08f / scale + float2(time * 0.15f, -time * 0.1f);
    float wisps = fbm(wispCoord, 4);
    density *= (0.7f + wisps * 0.4f);

    // Fade over time - builds up, holds, then dissipates
    float fadeIn = smootherstep(0.0f, 0.5f, spoutTime);
    float fadeOut = 1.0f - smootherstep(4.0f, 7.5f, spoutTime);
    float timeFade = fadeIn * fadeOut;

    return density * timeFade;
}

// MARK: - Main Whale Shader

/// Main whale shader entry point
/// Renders whale body, wake, foam, and spout effects
[[ stitchable ]] half4 whale(
    float2 position,
    half4 color,
    // View parameters
    float sizeX,
    float sizeY,
    float time,
    // Whale state
    float whaleX,           // 0-1 normalized horizontal position
    float whaleY,           // Vertical offset (positive = below surface)
    float diveAngle,        // Radians
    float tailLift,         // 0-1
    float whaleOpacity,     // 0-1 fade
    float depthFactor,      // 0-1 depth (0 = surface, 1 = max depth)
    // Phase
    float phaseIndex,       // 0=idle, 1=emerging, 2=surfaced, 3=spouting, 4=diving
    float phaseProgress,    // 0-1
    // Spout
    float spoutIntensity,   // 0-1
    float spoutProgress,    // 0-1
    // Wind
    float windDirX,
    float windDirY,
    float windSpeed,
    // Environment
    float sunriseWeight,
    float daytimeWeight,
    float sunsetWeight,
    float isNight,
    float sunX,
    float sunAltitude,
    // Wave parameters
    float waveAmplitude,
    float waveSpeed,
    // Scale
    float whaleScale
) {
    // Early exit if whale not visible
    if (whaleOpacity < 0.01f || phaseIndex < 0.5f) {
        return half4(0.0h);
    }

    float2 windDir = normalize(float2(windDirX, windDirY));

    // Calculate whale world position
    float2 whaleWorldPos = float2(whaleX * sizeX, sizeY * 0.35f);

    // Apply buoyancy from ocean waves
    float3 buoyancy = calculateBuoyancy(whaleWorldPos, time * waveSpeed, waveAmplitude, whaleScale);
    whaleWorldPos.x += buoyancy.x;
    float waveHeave = buoyancy.y;
    float wavePitch = buoyancy.z;

    // Final whale center position
    float2 whaleCenter = whaleWorldPos + float2(0.0f, whaleY + waveHeave);

    // Accumulated color and alpha
    float4 result = float4(0.0f);

    // Calculate distance to whale for early exit
    float distToWhale = length(position - whaleCenter);
    float maxRadius = 150.0f * whaleScale;

    // === LAYER 1: Kelvin Wake ===
    if (distToWhale < maxRadius * 3.0f) {
        float whaleMovement = 0.0f;
        if (phaseIndex > 1.5f && phaseIndex < 4.5f) {  // surfaced, spouting, or diving
            whaleMovement = 0.3f + phaseProgress * 0.3f;
        }

        float wake = kelvinWake(position, whaleCenter, float2(-1.0f, 0.0f), whaleMovement, time * waveSpeed);
        if (abs(wake) > 0.01f) {
            float3 wakeColor = wake > 0.0f ? WAKE_FOAM : WHALE_BODY_DARK * 0.5f;
            float wakeAlpha = abs(wake) * 0.3f * whaleOpacity;
            // Standard alpha blend
            result.rgb = wakeColor * wakeAlpha + result.rgb * (1.0f - wakeAlpha);
            result.a = wakeAlpha + result.a * (1.0f - wakeAlpha);
        }
    }

    // === LAYER 2: Surface Foam ===
    float surfaceProgress = 0.0f;
    if (phaseIndex > 0.5f && phaseIndex < 2.5f) {  // emerging or surfaced
        surfaceProgress = phaseIndex < 1.5f ? phaseProgress : 1.0f;
    } else if (phaseIndex > 3.5f) {  // diving
        surfaceProgress = 1.0f - phaseProgress;
    }

    if (surfaceProgress > 0.01f && distToWhale < maxRadius * 1.5f) {
        float foam = surfaceFoam(position, whaleCenter, whaleScale, surfaceProgress);
        if (foam > 0.01f) {
            float foamAlpha = foam * 0.5f * whaleOpacity;
            // Standard alpha blend
            result.rgb = WAKE_FOAM * foamAlpha + result.rgb * (1.0f - foamAlpha);
            result.a = foamAlpha + result.a * (1.0f - foamAlpha);
        }
    }

    // === LAYER 3: Whale Body (2D Side View) ===
    if (distToWhale < maxRadius) {
        // Apply depth-based scale reduction (whale appears smaller at depth)
        float effectiveScale = whaleScale * (1.0f - depthFactor * 0.3f);

        // Transform to whale-local coordinates (2D side view)
        float2 localPos2D = (position - whaleCenter) / effectiveScale;

        // Apply dive angle and wave pitch
        float totalPitch = diveAngle + wavePitch;
        float c = cos(totalPitch);
        float s = sin(totalPitch);
        localPos2D = float2(c * localPos2D.x - s * localPos2D.y,
                            s * localPos2D.x + c * localPos2D.y);

        // Simple 2D whale silhouette SDF (side view)
        // Main body - elongated ellipse
        float2 bodySize = float2(55.0f, 12.0f);
        float bodyDist = length(localPos2D / bodySize) - 1.0f;
        bodyDist *= min(bodySize.x, bodySize.y);

        // Head bulge
        float2 headPos = localPos2D - float2(-42.0f, 2.0f);
        float headDist = length(headPos) - 14.0f;

        // Tail stock and flukes
        float2 tailStockPos = localPos2D - float2(40.0f, 0.0f);
        float tailStockDist = length(tailStockPos / float2(15.0f, 5.0f)) - 1.0f;
        tailStockDist *= 5.0f;

        // Tail flukes - lift based on tailLift
        float flukeAngle = tailLift * 0.5f;
        float2 flukePos = localPos2D - float2(55.0f, -tailLift * 8.0f);
        float cF = cos(flukeAngle);
        float sF = sin(flukeAngle);
        flukePos = float2(cF * flukePos.x - sF * flukePos.y, sF * flukePos.x + cF * flukePos.y);
        float flukeDist = length(flukePos / float2(12.0f, 4.0f)) - 1.0f;
        flukeDist *= 4.0f;

        // Dorsal fin (small bump)
        float2 dorsalPos = localPos2D - float2(10.0f, -10.0f);
        float dorsalDist = length(dorsalPos / float2(6.0f, 4.0f)) - 1.0f;
        dorsalDist *= 4.0f;

        // Combine shapes with smooth minimum
        float whaleDist = smin(bodyDist, headDist, 10.0f);
        whaleDist = smin(whaleDist, tailStockDist, 8.0f);
        whaleDist = smin(whaleDist, flukeDist, 6.0f);
        whaleDist = smin(whaleDist, dorsalDist, 4.0f);

        if (whaleDist < 3.0f) {
            // Calculate 2D normal for shading
            float eps = 1.0f;
            float dx = smin(smin(smin(smin(
                length((localPos2D + float2(eps, 0)) / bodySize) - 1.0f,
                length(localPos2D + float2(eps, 0) - float2(-42.0f, 2.0f)) - 14.0f, 10.0f),
                length((localPos2D + float2(eps, 0) - float2(40.0f, 0.0f)) / float2(15.0f, 5.0f)) - 1.0f, 8.0f),
                length((localPos2D + float2(eps, 0) - float2(55.0f, -tailLift * 8.0f)) / float2(12.0f, 4.0f)) - 1.0f, 6.0f),
                length((localPos2D + float2(eps, 0) - float2(10.0f, -10.0f)) / float2(6.0f, 4.0f)) - 1.0f, 4.0f) - whaleDist;
            float dy = smin(smin(smin(smin(
                length((localPos2D + float2(0, eps)) / bodySize) - 1.0f,
                length(localPos2D + float2(0, eps) - float2(-42.0f, 2.0f)) - 14.0f, 10.0f),
                length((localPos2D + float2(0, eps) - float2(40.0f, 0.0f)) / float2(15.0f, 5.0f)) - 1.0f, 8.0f),
                length((localPos2D + float2(0, eps) - float2(55.0f, -tailLift * 8.0f)) / float2(12.0f, 4.0f)) - 1.0f, 6.0f),
                length((localPos2D + float2(0, eps) - float2(10.0f, -10.0f)) / float2(6.0f, 4.0f)) - 1.0f, 4.0f) - whaleDist;

            float3 normal = normalize(float3(dx, dy, 0.3f));

            // Skin pattern using 2D position
            float3 localPos3D = float3(localPos2D, 0.0f);
            float skinPattern = whaleSkinPattern(localPos3D, time);

            // Base color with belly gradient
            float bellyFactor = smootherstep(5.0f, -8.0f, localPos2D.y);
            float3 backColor = interpolateOklab(WHALE_BODY_DARK, WHALE_BODY_MID, skinPattern);
            float3 baseColor = interpolateOklab(backColor, WHALE_BELLY, bellyFactor);

            // Time-of-day tinting
            float3 sunriseTint = float3(1.05f, 0.95f, 0.90f);
            float3 daytimeTint = float3(1.0f, 1.0f, 1.02f);
            float3 sunsetTint = float3(1.08f, 0.92f, 0.95f);
            float3 nightTint = float3(0.7f, 0.75f, 0.85f);
            float3 dayTint = blendTimeOfDay(sunriseTint, daytimeTint, sunsetTint, sunriseWeight, daytimeWeight, sunsetWeight);
            float3 tint = mix(dayTint, nightTint, isNight);
            baseColor *= tint;

            // Simple lighting
            float3 lightDir = normalize(float3((sunX - 0.5f) * 2.0f, -sin(sunAltitude * M_PI_F / 180.0f), 1.0f));
            float diffuse = max(0.3f, dot(normal, lightDir) * 0.5f + 0.5f);

            // Wet skin highlight (Fresnel-like rim)
            float rim = 1.0f - abs(normal.z);
            rim = pow(rim, 3.0f) * 0.3f;

            float3 whaleColor = baseColor * diffuse + WHALE_HIGHLIGHT * rim;

            // Depth effects - shift color toward deep water blue
            whaleColor = interpolateOklab(whaleColor, DEEP_WATER_COLOR, depthFactor * 0.7f);

            // Reduce contrast at depth (colors converge toward mid-tones)
            float3 midTone = float3(0.15f);
            whaleColor = mix(whaleColor, midTone, depthFactor * 0.3f);

            // Alpha from SDF with depth-based edge softening
            float edgeSoftness = 3.0f + depthFactor * 4.0f;
            float whaleAlpha = smootherstep(edgeSoftness, -1.0f, whaleDist) * whaleOpacity;

            // For whale body, replace rather than blend - whale is solid
            result.rgb = whaleColor;
            result.a = whaleAlpha;
        }
    }

    // === LAYER 4: Water Drips (during emergence) ===
    if (phaseIndex > 0.5f && phaseIndex < 2.5f && distToWhale < maxRadius * 2.0f) {
        float drip = waterDrip(position, whaleCenter, whaleScale, phaseProgress, time);
        if (drip > 0.01f) {
            float dripAlpha = drip * 0.6f * whaleOpacity;
            // Standard alpha blend: drips over result
            result.rgb = SPOUT_CORE * dripAlpha + result.rgb * (1.0f - dripAlpha);
            result.a = dripAlpha + result.a * (1.0f - dripAlpha);
        }
    }

    // === LAYER 5: Spout (Hero Feature) ===
    if (spoutIntensity > 0.01f) {
        // Blowhole position (top of whale head, well above water)
        float2 blowholePos = whaleCenter + float2(-35.0f * whaleScale, -25.0f * whaleScale);

        // === Vapor cloud as density field ===
        float density = spoutDensity(position, blowholePos, spoutProgress, time,
                                      windDir, windSpeed, whaleScale);
        if (density > 0.01f) {
            // Subtle translucent mist color - blend spout over current result
            float spoutAlpha = density * spoutIntensity * whaleOpacity * 0.5f;
            float3 spoutColor = SPOUT_MIST;
            // Standard alpha blend: result = spout over result
            result.rgb = spoutColor * spoutAlpha + result.rgb * (1.0f - spoutAlpha);
            result.a = spoutAlpha + result.a * (1.0f - spoutAlpha);
        }
    }

    // Apply adaptive dithering
    if (result.a > 0.01f) {
        float3 dither = adaptiveDither(position, time, result.a);
        result.rgb += dither;
    }

    // Only return color if we have visible alpha, otherwise fully transparent
    if (result.a < 0.001f) {
        return half4(0.0h);
    }

    // Return whale result directly - the layer compositing handles blending
    return half4(half3(saturate(result.rgb)), half(saturate(result.a)));
}
