//
//  Birds.metal
//  rootshell
//
//  Shader for realistic bird migration flocks in the Solar ocean effect.
//  Features Boids-inspired flocking physics, species-specific formations,
//  wing animation with glide periods, and time-of-day silhouette colors.
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// MARK: - Constants

// Bird silhouette sizes (pixels at scale 1.0)
constant float PELICAN_WINGSPAN = 32.0f;
constant float GULL_WINGSPAN = 18.0f;
constant float CORMORANT_WINGSPAN = 24.0f;

// Formation spacing (pixels)
constant float PELICAN_SPACING = 40.0f;
constant float GULL_SPACING = 28.0f;
constant float CORMORANT_SPACING = 26.0f;

// Bird silhouette colors (dark against sky)
constant float3 BIRD_SILHOUETTE_DAY = float3(0.06f, 0.07f, 0.10f);
constant float3 BIRD_SILHOUETTE_SUNRISE = float3(0.08f, 0.05f, 0.06f);
constant float3 BIRD_SILHOUETTE_SUNSET = float3(0.05f, 0.03f, 0.07f);

// MARK: - Hash/Noise Functions

static float hash(float n) {
    return fract(sin(n) * 43758.5453f);
}

// MARK: - SDF Primitives

/// Signed distance to an axis-aligned ellipse
static float ellipseSDF(float2 p, float2 radii) {
    // Normalize to unit circle space
    float2 p_norm = p / radii;
    float len = length(p_norm);
    // Approximate SDF (exact for points not too close to surface)
    return (len - 1.0f) * min(radii.x, radii.y);
}

/// Signed distance to a tapered line segment (varying thickness)
static float taperedSegmentSDF(float2 p, float2 a, float2 b, float thicknessA, float thicknessB) {
    float2 pa = p - a;
    float2 ba = b - a;
    float h = saturate(dot(pa, ba) / dot(ba, ba));
    float thickness = mix(thicknessA, thicknessB, h);
    return length(pa - ba * h) - thickness;
}

// MARK: - Smoothstep

static float smootherstep(float edge0, float edge1, float x) {
    x = saturate((x - edge0) / (edge1 - edge0));
    return x * x * x * (x * (x * 6.0f - 15.0f) + 10.0f);
}

// MARK: - Boids Flocking Position

/// Calculate position of bird within flock using simplified Boids rules
/// Returns position offset from flock center
/// All movements are very gentle and smooth - birds flying at distance appear calm
static float2 boidPosition(int birdIndex, int birdCount, float seed, float speciesIndex, float time) {
    // Deterministic random values for this bird
    float birdSeed = hash(float(birdIndex) + seed * 0.001f);
    float birdSeed2 = hash(float(birdIndex) * 7.13f + seed * 0.002f);

    float2 offset;

    if (speciesIndex < 0.5f) {
        // Pelican: diagonal line formation (like their actual flight pattern)
        float linePos = float(birdIndex) - float(birdCount) * 0.5f;
        offset.x = linePos * PELICAN_SPACING * (0.8f + birdSeed * 0.4f);
        // Staggered altitude within line
        offset.y = linePos * PELICAN_SPACING * 0.3f * (birdSeed2 > 0.5f ? 1.0f : -1.0f);
        // Very gentle drift - slow and small amplitude
        offset += float2(
            sin(time * 0.08f + birdSeed * 6.28f) * 3.0f,
            cos(time * 0.06f + birdSeed2 * 6.28f) * 2.0f
        );
    } else if (speciesIndex < 1.5f) {
        // Gull: loose scattered formation - but still calm at distance
        float angle = birdSeed * 6.28f;
        float radius = sqrt(birdSeed2) * GULL_SPACING * 1.5f;
        offset = float2(cos(angle), sin(angle)) * radius;
        // Gentle wandering movement - much slower than before
        offset += float2(
            sin(time * 0.15f + birdSeed * 6.28f) * 4.0f,
            cos(time * 0.12f + birdSeed2 * 6.28f) * 3.0f
        );
    } else {
        // Cormorant: tight V-formation with point facing forward (direction of flight)
        // Bird 0 is the leader at the front, others trail behind in V shape
        int side = birdIndex % 2;
        int posInLine = (birdIndex + 1) / 2;
        float vAngle = 0.35f; // V angle in radians (~20 degrees)
        // Negative X so birds trail BEHIND the leader (leader is at front)
        offset.x = -float(posInLine) * CORMORANT_SPACING * cos(vAngle);
        offset.y = float(posInLine) * CORMORANT_SPACING * sin(vAngle) * (side == 0 ? 1.0f : -1.0f);
        // Very subtle formation drift
        offset += float2(
            sin(time * 0.1f + birdSeed * 6.28f) * 2.0f,
            cos(time * 0.08f + birdSeed2 * 6.28f) * 1.5f
        );
    }

    return offset;
}

// MARK: - Wing Animation

/// Calculate wing angle for a bird at given time
/// Returns -1 (down) to 1 (up)
/// Wing motion is smooth and gentle - distant birds have subtle flapping
static float wingAngle(int birdIndex, float seed, float speciesIndex, float time) {
    float birdSeed = hash(float(birdIndex) + seed * 0.001f);

    // Phase offset per bird for natural variation
    float phaseOffset = birdSeed * 6.28f;

    // Slower frequencies for calmer appearance at distance
    float freq;
    if (speciesIndex < 0.5f) {
        freq = 0.4f;  // Pelicans: very slow, mostly gliding
    } else if (speciesIndex < 1.5f) {
        freq = 0.8f;  // Gulls: moderate flapping
    } else {
        freq = 0.6f;  // Cormorants: steady rhythm
    }

    // Smooth sinusoidal flapping - reduced amplitude for subtlety
    float flap = sin(time * freq * 6.28f + phaseOffset) * 0.7f;

    return flap;
}

// MARK: - Bird Silhouette SDF

/// Signed distance to a line segment with thickness
static float segmentSDF(float2 p, float2 a, float2 b, float thickness) {
    float2 pa = p - a;
    float2 ba = b - a;
    float h = saturate(dot(pa, ba) / dot(ba, ba));
    return length(pa - ba * h) - thickness;
}

// MARK: - Pelican Silhouette

/// Pelican: Large pouched bill, heavy body, broad wings with subtle finger feathers
/// Features smooth slow gliding motion - majestic and unhurried
static float pelicanSDF(float2 p, float wingspan, float wingAngle, float time, float birdSeed) {
    // Pelican proportions
    float bodyRadiusX = wingspan * 0.08f;   // Elongated body
    float bodyRadiusY = wingspan * 0.055f;
    float wingThickness = max(1.2f, wingspan * 0.028f);

    // Pelicans glide for long stretches, but occasionally do short bursts of faster flapping.
    // Keep the overall motion smooth so distant birds don't strobe.
    float baseFlapFreq = 0.15f + birdSeed * 0.05f;  // 0.15-0.20 Hz - slow glide rhythm
    float basePhase = time * baseFlapFreq * 6.2831853f + birdSeed * 6.2831853f;
    float baseRaw = sin(basePhase);

    // Burst schedule: a short flap-heavy window every ~35-60 seconds (per-bird offset).
    float burstRate = 0.017f + birdSeed * 0.010f; // ~0.017-0.027 Hz
    float burstCycle = fract(time * burstRate + birdSeed * 3.7f);
    float burstEnv = smootherstep(0.00f, 0.06f, burstCycle) * (1.0f - smootherstep(0.16f, 0.24f, burstCycle));

    float burstFlapFreq = 0.85f + birdSeed * 0.25f; // 0.85-1.10 Hz
    float burstPhase = time * burstFlapFreq * 6.2831853f + birdSeed * 17.0f;
    float burstRaw = sin(burstPhase);

    float rawFlap = clamp(baseRaw + burstEnv * burstRaw * 0.9f, -1.0f, 1.0f);
    float amplitude = 0.32f + burstEnv * 0.22f;
    float bias = -0.12f + burstEnv * 0.05f;
    float flapAngle = rawFlap * amplitude + bias;

    // === BODY: Elliptical torso ===
    float body = ellipseSDF(p, float2(bodyRadiusX, bodyRadiusY));

    // === NECK & HEAD: Short thick neck with large pouched bill ===
    float2 neckBase = float2(bodyRadiusX * 0.7f, 0.0f);
    float2 headPos = float2(bodyRadiusX * 1.4f, wingspan * 0.015f);
    float neckThickness = wingspan * 0.035f;
    float neck = segmentSDF(p, neckBase, headPos, neckThickness);

    // Head (small circle)
    float headRadius = wingspan * 0.04f;
    float head = length(p - headPos) - headRadius;

    // Bill - large distinctive pouch shape extending forward
    float2 billBase = headPos + float2(headRadius * 0.5f, -wingspan * 0.01f);
    float2 billTip = headPos + float2(wingspan * 0.12f, wingspan * 0.025f);
    float2 billPouch = headPos + float2(wingspan * 0.06f, wingspan * 0.04f);
    float billUpper = segmentSDF(p, billBase, billTip, wingspan * 0.012f);
    float billLower = segmentSDF(p, billBase + float2(0.0f, wingspan * 0.015f),
                                  billPouch, wingspan * 0.018f);
    float bill = min(billUpper, billLower);

    // === WINGS: Broad with gentle droop and tapered tips ===
    float wingSpan = wingspan * 0.50f;
    float wristPos = 0.45f;

    // Wing positions - smooth motion
    float wingTipY = flapAngle * wingspan * 0.16f;
    float wristY = flapAngle * wingspan * 0.05f - wingspan * 0.03f;  // Slight droop at wrist

    // Left wing - broad tapered shape
    float2 leftWrist = float2(-wingSpan * wristPos, wristY);
    float2 leftTip = float2(-wingSpan, wingTipY - wingspan * 0.02f);  // Tips droop slightly

    float leftInner = taperedSegmentSDF(p, float2(-bodyRadiusX * 0.3f, 0.0f), leftWrist,
                                        wingThickness * 1.3f, wingThickness * 1.0f);
    float leftOuter = taperedSegmentSDF(p, leftWrist, leftTip,
                                        wingThickness * 1.0f, wingThickness * 0.4f);

    // Subtle primary feather suggestion - just slight spreading at tip, not separate fingers
    // Create a slightly wider tip area instead of individual feathers
    float2 leftTipWide1 = leftTip + float2(-wingspan * 0.025f, wingspan * 0.015f);
    float2 leftTipWide2 = leftTip + float2(-wingspan * 0.025f, -wingspan * 0.012f);
    float leftTipFeather1 = taperedSegmentSDF(p, leftTip, leftTipWide1, wingThickness * 0.35f, wingThickness * 0.15f);
    float leftTipFeather2 = taperedSegmentSDF(p, leftTip, leftTipWide2, wingThickness * 0.35f, wingThickness * 0.15f);

    float leftWing = min(leftInner, min(leftOuter, min(leftTipFeather1, leftTipFeather2)));

    // Right wing (mirror)
    float2 rightWrist = float2(wingSpan * wristPos, wristY);
    float2 rightTip = float2(wingSpan, wingTipY - wingspan * 0.02f);

    float rightInner = taperedSegmentSDF(p, float2(bodyRadiusX * 0.3f, 0.0f), rightWrist,
                                         wingThickness * 1.3f, wingThickness * 1.0f);
    float rightOuter = taperedSegmentSDF(p, rightWrist, rightTip,
                                         wingThickness * 1.0f, wingThickness * 0.4f);

    float2 rightTipWide1 = rightTip + float2(wingspan * 0.025f, wingspan * 0.015f);
    float2 rightTipWide2 = rightTip + float2(wingspan * 0.025f, -wingspan * 0.012f);
    float rightTipFeather1 = taperedSegmentSDF(p, rightTip, rightTipWide1, wingThickness * 0.35f, wingThickness * 0.15f);
    float rightTipFeather2 = taperedSegmentSDF(p, rightTip, rightTipWide2, wingThickness * 0.35f, wingThickness * 0.15f);

    float rightWing = min(rightInner, min(rightOuter, min(rightTipFeather1, rightTipFeather2)));

    // === TAIL: Short squared ===
    float2 tailBase = float2(-bodyRadiusX * 0.8f, 0.0f);
    float2 tailEnd = float2(-bodyRadiusX * 1.3f, 0.0f);
    float tail = taperedSegmentSDF(p, tailBase, tailEnd, wingThickness * 0.9f, wingThickness * 0.6f);

    // Combine all parts
    float result = body;
    result = min(result, neck);
    result = min(result, head);
    result = min(result, bill);
    result = min(result, leftWing);
    result = min(result, rightWing);
    result = min(result, tail);

    return result;
}

// MARK: - Gull Silhouette

/// Gull: Streamlined body, elegant swept-back wings, slightly forked tail
/// Features graceful flapping with smooth wrist articulation
static float gullSDF(float2 p, float wingspan, float wingAngle, float time, float birdSeed) {
    // Gull proportions - streamlined teardrop body
    float bodyRadiusX = wingspan * 0.065f;
    float bodyRadiusY = wingspan * 0.045f;
    float wingThickness = max(1.0f, wingspan * 0.024f);

    // Graceful flapping - moderate speed, smooth motion
    float flapFreq = 0.5f + birdSeed * 0.15f;  // 0.5-0.65 Hz
    float flapPhase = time * flapFreq * 6.28f + birdSeed * 6.28f;

    // Smooth flapping with slight asymmetry (faster downstroke)
    float rawFlap = sin(flapPhase);
    float flapAngle = rawFlap * 0.7f;

    // === BODY: Streamlined teardrop ===
    float body = ellipseSDF(p, float2(bodyRadiusX, bodyRadiusY));

    // === HEAD: Small rounded head flowing from body ===
    float headRadius = wingspan * 0.032f;
    float2 headPos = float2(bodyRadiusX * 0.9f, 0.0f);
    float head = length(p - headPos) - headRadius;

    // Neat pointed beak
    float2 beakBase = headPos + float2(headRadius * 0.7f, 0.0f);
    float2 beakTip = headPos + float2(headRadius * 2.2f, 0.0f);
    float beak = taperedSegmentSDF(p, beakBase, beakTip, wingspan * 0.014f, wingspan * 0.003f);

    // === WINGS: Elegant swept-back shape with smooth curves ===
    float wingSpan = wingspan * 0.48f;
    float wristPos = 0.40f;

    // Wrist flex creates natural wing bend during flap
    float innerFlapScale = 0.5f;   // Inner wing moves less
    float outerFlapScale = 0.9f;   // Outer wing moves more

    // Slight upward angle at rest (dihedral)
    float restAngle = wingspan * 0.02f;

    // Left wing - elegant swept shape
    float2 leftShoulder = float2(-bodyRadiusX * 0.4f, 0.0f);
    float2 leftWrist = float2(-wingSpan * wristPos,
                               flapAngle * wingspan * 0.10f * innerFlapScale + restAngle);
    float2 leftTip = float2(-wingSpan * 0.98f,
                             flapAngle * wingspan * 0.14f * outerFlapScale + restAngle * 0.3f);

    // Broader inner wing, elegantly tapered outer
    float leftInner = taperedSegmentSDF(p, leftShoulder, leftWrist,
                                        wingThickness * 1.2f, wingThickness * 0.85f);
    float leftOuter = taperedSegmentSDF(p, leftWrist, leftTip,
                                        wingThickness * 0.85f, wingThickness * 0.25f);
    float leftWing = min(leftInner, leftOuter);

    // Right wing (mirror)
    float2 rightShoulder = float2(bodyRadiusX * 0.4f, 0.0f);
    float2 rightWrist = float2(wingSpan * wristPos,
                                flapAngle * wingspan * 0.10f * innerFlapScale + restAngle);
    float2 rightTip = float2(wingSpan * 0.98f,
                              flapAngle * wingspan * 0.14f * outerFlapScale + restAngle * 0.3f);

    float rightInner = taperedSegmentSDF(p, rightShoulder, rightWrist,
                                         wingThickness * 1.2f, wingThickness * 0.85f);
    float rightOuter = taperedSegmentSDF(p, rightWrist, rightTip,
                                         wingThickness * 0.85f, wingThickness * 0.25f);
    float rightWing = min(rightInner, rightOuter);

    // === TAIL: Slightly forked, elegant ===
    float2 tailBase = float2(-bodyRadiusX * 0.8f, 0.0f);
    float tailLength = wingspan * 0.07f;
    float forkSpread = 0.15f;

    // Three tail feathers - center and two slightly spread
    float2 tailCenter = tailBase + float2(-tailLength, 0.0f);
    float2 tailLeft = tailBase + float2(-tailLength * 0.85f, tailLength * forkSpread);
    float2 tailRight = tailBase + float2(-tailLength * 0.85f, -tailLength * forkSpread);

    float tailC = taperedSegmentSDF(p, tailBase, tailCenter, wingThickness * 0.6f, wingThickness * 0.25f);
    float tailL = taperedSegmentSDF(p, tailBase, tailLeft, wingThickness * 0.5f, wingThickness * 0.2f);
    float tailR = taperedSegmentSDF(p, tailBase, tailRight, wingThickness * 0.5f, wingThickness * 0.2f);
    float tail = min(tailC, min(tailL, tailR));

    // Combine
    float result = body;
    result = min(result, head);
    result = min(result, beak);
    result = min(result, leftWing);
    result = min(result, rightWing);
    result = min(result, tail);

    return result;
}

// MARK: - Cormorant Silhouette

/// Cormorant: Long sinuous neck, hooked head, angular crooked wings, wedge tail
/// Features steady deep wing beats at consistent rhythm
static float cormorantSDF(float2 p, float wingspan, float wingAngle, float time, float birdSeed) {
    // Cormorant proportions - elongated body
    float bodyRadiusX = wingspan * 0.09f;
    float bodyRadiusY = wingspan * 0.04f;
    float wingThickness = max(0.9f, wingspan * 0.02f);

    // Steady deep wing beats - no variation
    float flapPhase = time * 0.7f * 6.28f + birdSeed * 6.28f;
    float flapAngle = sin(flapPhase) * 0.95f;  // Deep strokes

    // === BODY: Long cigar-shaped ===
    float body = ellipseSDF(p, float2(bodyRadiusX, bodyRadiusY));

    // === NECK: Long sinuous S-curve extending forward ===
    // Use two segments to create gentle S-curve
    float2 neckBase = float2(bodyRadiusX * 0.6f, 0.0f);
    float2 neckMid = float2(bodyRadiusX * 1.3f, wingspan * 0.025f);
    float2 neckEnd = float2(bodyRadiusX * 1.9f, wingspan * 0.01f);

    float neckThickness = wingspan * 0.022f;
    float neck1 = taperedSegmentSDF(p, neckBase, neckMid, neckThickness * 1.1f, neckThickness);
    float neck2 = taperedSegmentSDF(p, neckMid, neckEnd, neckThickness, neckThickness * 0.85f);
    float neck = min(neck1, neck2);

    // === HEAD: Small with hooked bill profile ===
    float headRadius = wingspan * 0.028f;
    float2 headPos = neckEnd + float2(headRadius * 0.5f, 0.0f);
    float head = length(p - headPos) - headRadius;

    // Hooked bill
    float2 billBase = headPos + float2(headRadius * 0.7f, wingspan * 0.005f);
    float2 billMid = billBase + float2(wingspan * 0.04f, 0.0f);
    float2 billHook = billMid + float2(wingspan * 0.012f, -wingspan * 0.015f);
    float billMain = segmentSDF(p, billBase, billMid, wingspan * 0.01f);
    float billTip = segmentSDF(p, billMid, billHook, wingspan * 0.008f);
    float bill = min(billMain, billTip);

    // === WINGS: Angular crooked shape with distinct bend ===
    float wingSpan = wingspan * 0.44f;
    float wristPos = 0.48f;

    // Wing crook angle - maintained throughout stroke
    float crookAngle = 0.4f;  // ~23 degrees permanent bend
    float wingTipY = flapAngle * wingspan * 0.2f;  // Deep stroke
    float wristY = flapAngle * wingspan * 0.08f + wingspan * 0.02f;

    // Left wing - crooked shape
    float2 leftWrist = float2(-wingSpan * wristPos, wristY);
    // Tip angled relative to wrist (crook maintained)
    float2 leftTip = leftWrist + float2(-wingSpan * (1.0f - wristPos),
                                         (wingTipY - wristY) + wingspan * crookAngle * 0.08f);

    float leftInner = taperedSegmentSDF(p, float2(-bodyRadiusX * 0.2f, 0.0f), leftWrist,
                                        wingThickness * 1.15f, wingThickness * 0.85f);
    float leftOuter = taperedSegmentSDF(p, leftWrist, leftTip,
                                        wingThickness * 0.85f, wingThickness * 0.35f);
    float leftWing = min(leftInner, leftOuter);

    // Right wing
    float2 rightWrist = float2(wingSpan * wristPos, wristY);
    float2 rightTip = rightWrist + float2(wingSpan * (1.0f - wristPos),
                                          (wingTipY - wristY) + wingspan * crookAngle * 0.08f);

    float rightInner = taperedSegmentSDF(p, float2(bodyRadiusX * 0.2f, 0.0f), rightWrist,
                                         wingThickness * 1.15f, wingThickness * 0.85f);
    float rightOuter = taperedSegmentSDF(p, rightWrist, rightTip,
                                         wingThickness * 0.85f, wingThickness * 0.35f);
    float rightWing = min(rightInner, rightOuter);

    // === TAIL: Long wedge-shaped (wider at base) ===
    float2 tailBase = float2(-bodyRadiusX * 0.7f, 0.0f);
    float tailLength = wingspan * 0.16f;
    float tailSpread = 0.18f;

    // Central tail feather
    float2 tailCenter = tailBase + float2(-tailLength, 0.0f);
    float tailC = taperedSegmentSDF(p, tailBase, tailCenter, wingThickness * 0.9f, wingThickness * 0.4f);

    // Side tail feathers (wedge shape)
    float2 tailLeft = tailBase + float2(-tailLength * 0.9f, tailLength * tailSpread);
    float2 tailRight = tailBase + float2(-tailLength * 0.9f, -tailLength * tailSpread);
    float tailL = taperedSegmentSDF(p, tailBase, tailLeft, wingThickness * 0.7f, wingThickness * 0.3f);
    float tailR = taperedSegmentSDF(p, tailBase, tailRight, wingThickness * 0.7f, wingThickness * 0.3f);

    float tail = min(tailC, min(tailL, tailR));

    // Combine
    float result = body;
    result = min(result, neck);
    result = min(result, head);
    result = min(result, bill);
    result = min(result, leftWing);
    result = min(result, rightWing);
    result = min(result, tail);

    return result;
}

// MARK: - Species Dispatcher

/// Route to species-specific SDF based on index
/// Includes time and per-bird seed for animation variation
static float birdSDF(float2 p, float wingspan, float wingAngle, float speciesIndex, float time, float birdSeed) {
    if (speciesIndex < 0.5f) {
        return pelicanSDF(p, wingspan, wingAngle, time, birdSeed);
    } else if (speciesIndex < 1.5f) {
        return gullSDF(p, wingspan, wingAngle, time, birdSeed);
    } else {
        return cormorantSDF(p, wingspan, wingAngle, time, birdSeed);
    }
}

// MARK: - Main Bird Shader

[[ stitchable ]] half4 birds(
    float2 position,
    half4 color,
    // View parameters
    float sizeX,
    float sizeY,
    float time,
    // Flock state
    float birdCount,
    float seed,
    float speciesIndex,
    float progress,        // 0-1+ across screen
    float altitude,        // 0-1 vertical position (0 = bottom, 1 = top of sky area)
    float baseDirection,   // radians
    float entryFromLeft,   // 0 = left entry, 1 = right entry
    // Wind
    float windDirX,
    float windDirY,
    // Environment
    float sunriseWeight,
    float daytimeWeight,
    float sunsetWeight,
    float isNight
) {
    // Early exit if flock not visible
    if (progress < -0.15f || progress > 1.15f) {
        return half4(0.0h);
    }

    float2 size = float2(sizeX, sizeY);
    int numBirds = int(birdCount);

    // Calculate flock center position
    float2 flockCenter;
    if (entryFromLeft < 0.5f) {
        // Flying left to right
        flockCenter.x = -size.x * 0.15f + progress * size.x * 1.3f;
    } else {
        // Flying right to left
        flockCenter.x = size.x * 1.15f - progress * size.x * 1.3f;
    }
    // Altitude maps to vertical position in sky (inverted: 0 = horizon level, higher = up).
    // Most flocks fly well above the horizon, but some pelican launches skim low in a straight line,
    // then climb together after a short "water skim" segment.
    float effectiveAltitude = altitude;
    float altitudeScale = 0.85f;
    float skimEnv = 0.0f; // 1 = full skim, 0 = normal flight
    if (speciesIndex < 0.5f) {
        float skimChance = hash(seed * 0.0041f);
        if (skimChance < 0.32f) {
            float skimAltitude = hash(seed * 0.0083f) * 0.05f; // extremely near horizon
            // Hold the skim long enough to be noticeable on screen, then climb as a group.
            float climbT = smootherstep(0.28f, 0.55f, progress);
            skimEnv = 1.0f - climbT;
            effectiveAltitude = mix(skimAltitude, altitude, climbT);
            altitudeScale = mix(0.98f, 0.85f, climbT);
        }
    }
    effectiveAltitude = clamp(effectiveAltitude, 0.0f, 1.0f);
    flockCenter.y = size.y * (1.0f - effectiveAltitude) * altitudeScale;

    // Very gentle vertical undulation - subtle and slow.
    // Use a small hashed phase instead of adding a large seed term directly;
    // large phases lose float precision and can cause visible stepping.
    float undulationFreq = 0.8f + hash(seed * 0.0001f) * 0.4f;
    float undulationPhase = hash(seed * 0.00023f) * 6.2831853f; // 0..2π
    float skimLine = skimEnv * skimEnv; // keep skim "locked" longer, then release
    float undulationAmp = size.y * 0.02f * (1.0f - skimLine);
    flockCenter.y += sin(progress * 3.14159f * undulationFreq + undulationPhase) * undulationAmp;

    // Get species-specific parameters
    float wingspan;
    if (speciesIndex < 0.5f) {
        wingspan = PELICAN_WINGSPAN;
    } else if (speciesIndex < 1.5f) {
        wingspan = GULL_WINGSPAN;
    } else {
        wingspan = CORMORANT_WINGSPAN;
    }

    // Scale by "distance" (altitude affects perceived size - higher = further = smaller)
    // But also scale by view size for responsiveness
    float viewScale = min(size.x, size.y) / 800.0f;
    float distanceScale = (0.5f + (1.0f - effectiveAltitude) * 0.6f) * viewScale;
    wingspan *= distanceScale;

    // Silhouette color based on time of day
    float3 silhouetteColor;
    float totalWeight = sunriseWeight + daytimeWeight + sunsetWeight;
    if (totalWeight < 0.01f || isNight > 0.5f) {
        // Night or very dark - birds wouldn't be visible anyway
        return half4(0.0h);
    }

    // Normalize weights
    float normSunrise = sunriseWeight / totalWeight;
    float normDaytime = daytimeWeight / totalWeight;
    float normSunset = sunsetWeight / totalWeight;

    // Blend colors based on time of day
    silhouetteColor = BIRD_SILHOUETTE_SUNRISE * normSunrise +
                      BIRD_SILHOUETTE_DAY * normDaytime +
                      BIRD_SILHOUETTE_SUNSET * normSunset;

    // Accumulated result
    float maxAlpha = 0.0f;

    // Render each bird (max 20 for performance)
    for (int i = 0; i < numBirds && i < 20; i++) {
        // Get bird position within flock
        float2 birdOffset = boidPosition(i, numBirds, seed, speciesIndex, time);

        // Apply flock direction rotation
        float c = cos(baseDirection);
        float s = sin(baseDirection);
        birdOffset = float2(c * birdOffset.x - s * birdOffset.y,
                           s * birdOffset.x + c * birdOffset.y);

        // Skim launches: keep the flock in a straight low line for a while,
        // then gradually allow the normal formation height differences back in.
        if (skimLine > 0.001f) {
            birdOffset.y = mix(birdOffset.y, 0.0f, skimLine);
        }

        // Scale offset by distance
        birdOffset *= distanceScale;

        float2 birdPos = flockCenter + birdOffset;

        // Transform pixel position to bird-local coordinates
        float2 localPos = position - birdPos;

        // Rotate to face flight direction
        localPos = float2(c * localPos.x + s * localPos.y,
                         -s * localPos.x + c * localPos.y);

        // Early skip if far from bird (optimization)
        if (length(localPos) > wingspan * 1.5f) {
            continue;
        }

        // Get wing angle for this bird
        float wing = wingAngle(i, seed, speciesIndex, time);

        // Per-bird seed for animation variation
        float birdSeed = hash(float(i) + seed * 0.001f);

        // SDF evaluation with species-specific rendering
        float dist = birdSDF(localPos, wingspan, wing, speciesIndex, time, birdSeed);

        // Soft edge rendering with anti-aliasing
        float alpha = smootherstep(1.5f, -0.5f, dist);

        // Slight opacity variation per bird for depth perception
        float birdOpacity = 0.82f + hash(float(i) + seed * 0.003f) * 0.18f;
        alpha *= birdOpacity;

        // Track max alpha (overlapping birds blend via max, not add)
        maxAlpha = max(maxAlpha, alpha);
    }

    // Distance-based fade (further = more transparent for atmospheric perspective)
    float distanceFade = 0.55f + (1.0f - effectiveAltitude) * 0.45f;
    maxAlpha *= distanceFade;

    // Smooth edge fade as flock enters/exits screen
    float edgeFade = smootherstep(-0.05f, 0.12f, progress) *
                     (1.0f - smootherstep(0.88f, 1.05f, progress));
    maxAlpha *= edgeFade;

    // Only return color if we have visible alpha, otherwise fully transparent
    if (maxAlpha < 0.001f) {
        return half4(0.0h);
    }

    // Blend bird color over input color using standard alpha blending
    half4 birdColor = half4(half3(silhouetteColor), half(saturate(maxAlpha)));
    half3 blended = birdColor.rgb * birdColor.a + color.rgb * (1.0h - birdColor.a);
    half blendedAlpha = birdColor.a + color.a * (1.0h - birdColor.a);

    return half4(blended, blendedAlpha);
}
