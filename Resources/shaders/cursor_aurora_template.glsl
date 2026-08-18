// Aurora: Theme-aware glow with color-shifting trail
// Colors are injected from the active theme palette at generation time.
// -- CONFIGURATION --
const float DURATION = 0.35;
const float TRAIL_LENGTH = 0.5;
const float BLUR = 2.0;
const float GLOW_RADIUS_1 = 0.012;
const float GLOW_RADIUS_2 = 0.03;
const float GLOW_RADIUS_3 = 0.055;
const float GLOW_INTENSITY_1 = 0.85;
const float GLOW_INTENSITY_2 = 0.45;
const float GLOW_INTENSITY_3 = 0.2;
const float COLOR_SHIFT_SPEED = 4.0;
const float SHIMMER_SPEED = 12.0;
const float SHIMMER_SCALE = 40.0;
const float SHIMMER_INTENSITY = 0.15;

// Theme-injected colors (replaced at generation time)
const vec4 COLOR_A = {{COLOR_A}};
const vec4 COLOR_B = {{COLOR_B}};

const float PI = 3.14159265359;

// EaseOutCirc
float ease(float x) {
    return sqrt(1.0 - pow(x - 1.0, 2.0));
}

float getSdfRectangle(in vec2 p, in vec2 xy, in vec2 b) {
    vec2 d = abs(p - xy) - b;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

float seg(in vec2 p, in vec2 a, in vec2 b, inout float s, float d) {
    vec2 e = b - a;
    vec2 w = p - a;
    vec2 proj = a + e * clamp(dot(w, e) / dot(e, e), 0.0, 1.0);
    float segd = dot(p - proj, p - proj);
    d = min(d, segd);
    float c0 = step(0.0, p.y - a.y);
    float c1 = 1.0 - step(0.0, p.y - b.y);
    float c2 = 1.0 - step(0.0, e.x * w.y - e.y * w.x);
    float allCond = c0 * c1 * c2;
    float noneCond = (1.0 - c0) * (1.0 - c1) * (1.0 - c2);
    float flip = mix(1.0, -1.0, step(0.5, allCond + noneCond));
    s *= flip;
    return d;
}

float getSdfParallelogram(in vec2 p, in vec2 v0, in vec2 v1, in vec2 v2, in vec2 v3) {
    float s = 1.0;
    float d = dot(p - v0, p - v0);
    d = seg(p, v0, v3, s, d);
    d = seg(p, v1, v0, s, d);
    d = seg(p, v2, v1, s, d);
    d = seg(p, v3, v2, s, d);
    return s * sqrt(d);
}

vec2 normalize(vec2 value, float isPosition) {
    return (value * 2.0 - (iResolution.xy * isPosition)) / iResolution.y;
}

float antialising(float distance) {
    return 1. - smoothstep(0., normalize(vec2(BLUR, BLUR), 0.).x, distance);
}

float getTopVertexFlag(vec2 a, vec2 b) {
    float condition1 = step(b.x, a.x) * step(a.y, b.y);
    float condition2 = step(a.x, b.x) * step(b.y, a.y);
    return 1.0 - max(condition1, condition2);
}

// Value noise for shimmer
float random(vec2 st) {
    return fract(sin(dot(st, vec2(12.9898, 78.233))) * 43758.5453123);
}

float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    float a = random(i);
    float b = random(i + vec2(1.0, 0.0));
    float c = random(i + vec2(0.0, 1.0));
    float d = random(i + vec2(1.0, 1.0));
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    #if !defined(WEB)
    fragColor = texture(iChannel0, fragCoord.xy / iResolution.xy);
    #endif

    vec2 vu = normalize(fragCoord, 1.);
    vec2 offsetFactor = vec2(-.5, 0.5);

    vec4 currentCursor = vec4(normalize(iCurrentCursor.xy, 1.), normalize(iCurrentCursor.zw, 0.));
    vec4 previousCursor = vec4(normalize(iPreviousCursor.xy, 1.), normalize(iPreviousCursor.zw, 0.));

    vec2 centerCC = currentCursor.xy - (currentCursor.zw * offsetFactor);
    vec2 centerCP = previousCursor.xy - (previousCursor.zw * offsetFactor);

    float sdfCurrentCursor = getSdfRectangle(vu, centerCC, currentCursor.zw * 0.5);

    float lineLength = distance(centerCC, centerCP);
    float minDist = currentCursor.w * 1.5;
    float progress = clamp((iTime - iTimeCursorChange) / DURATION, 0.0, 1.0);

    vec4 newColor = fragColor;

    if (lineLength > minDist) {
        float shrinkFactor = ease(progress);

        // Detect straight moves
        vec2 delta = abs(centerCC - centerCP);
        float threshold = 0.001;
        float isHorizontal = step(delta.y, threshold);
        float isVertical = step(delta.x, threshold);
        float isStraightMove = max(isHorizontal, isVertical);

        // Parallelogram SDF (diagonal moves)
        float topVertexFlag = getTopVertexFlag(currentCursor.xy, previousCursor.xy);
        float bottomVertexFlag = 1.0 - topVertexFlag;
        vec2 v0 = vec2(currentCursor.x + currentCursor.z * topVertexFlag, currentCursor.y - currentCursor.w);
        vec2 v1 = vec2(currentCursor.x + currentCursor.z * bottomVertexFlag, currentCursor.y);
        vec2 v2_full = vec2(previousCursor.x + currentCursor.z * bottomVertexFlag, previousCursor.y);
        vec2 v3_full = vec2(previousCursor.x + currentCursor.z * topVertexFlag, previousCursor.y - previousCursor.w);

        vec2 v2_start = mix(v1, v2_full, TRAIL_LENGTH);
        vec2 v3_start = mix(v0, v3_full, TRAIL_LENGTH);
        vec2 v2_anim = mix(v2_start, v1, shrinkFactor);
        vec2 v3_anim = mix(v3_start, v0, shrinkFactor);

        float sdfTrail_diag = getSdfParallelogram(vu, v0, v1, v2_anim, v3_anim);

        // Rectangle SDF (straight moves)
        vec2 min_center = min(centerCP, centerCC);
        vec2 max_center = max(centerCP, centerCC);

        vec2 bBoxSize_full = (max_center - min_center) + currentCursor.zw;
        vec2 bBoxCenter_full = (min_center + max_center) * 0.5;

        vec2 bBoxSize_start = mix(currentCursor.zw, bBoxSize_full, TRAIL_LENGTH);
        vec2 bBoxCenter_start = mix(centerCC, bBoxCenter_full, TRAIL_LENGTH);

        vec2 animSize = mix(bBoxSize_start, currentCursor.zw, shrinkFactor);
        vec2 animCenter = mix(bBoxCenter_start, centerCC, shrinkFactor);

        float sdfTrail_rect = getSdfRectangle(vu, animCenter, animSize * 0.5);

        // Select trail SDF
        float sdfTrail = mix(sdfTrail_diag, sdfTrail_rect, isStraightMove);

        float d = max(sdfTrail, 0.0);

        // Spatial color gradient: primary near cursor, secondary toward tail
        vec2 trailDir = centerCP - centerCC;
        float spatialT = clamp(dot(vu - centerCC, trailDir) / (dot(trailDir, trailDir) + 1e-6), 0.0, 1.0);

        // Temporal oscillation
        float temporalT = 0.5 + 0.5 * sin(iTime * COLOR_SHIFT_SPEED);

        // Blend: head stays close to COLOR_A, tail drifts toward COLOR_B
        float colorMix = mix(temporalT * 0.3, 0.5 + temporalT * 0.5, spatialT);
        vec4 trailColor = mix(COLOR_A, COLOR_B, colorMix);

        // Glow parameters
        float glowScale = 1.0 - ease(progress) * 0.7;
        float fadeOut = 1.0 - progress;

        // Core trail fill
        float coreAlpha = antialising(sdfTrail);
        newColor = mix(newColor, trailColor, coreAlpha * fadeOut);

        // Layer 1: tight inner glow
        float glow1 = smoothstep(GLOW_RADIUS_1 * glowScale, 0.0, d) * GLOW_INTENSITY_1 * fadeOut;
        newColor = mix(newColor, trailColor, glow1);

        // Layer 2: medium bloom with shimmer
        float glow2 = smoothstep(GLOW_RADIUS_2 * glowScale, 0.0, d) * GLOW_INTENSITY_2 * fadeOut;
        float shimmerNoise = noise(vu * SHIMMER_SCALE + vec2(iTime * SHIMMER_SPEED, iTime * SHIMMER_SPEED * 0.7));
        float edgeMask = smoothstep(GLOW_RADIUS_1 * glowScale, GLOW_RADIUS_2 * glowScale, d)
                       * (1.0 - smoothstep(GLOW_RADIUS_2 * glowScale, GLOW_RADIUS_3 * glowScale, d));
        float shimmer = shimmerNoise * edgeMask * SHIMMER_INTENSITY * fadeOut;
        newColor = mix(newColor, trailColor, glow2 + shimmer);

        // Layer 3: outer aura
        float glow3 = smoothstep(GLOW_RADIUS_3 * glowScale, 0.0, d) * GLOW_INTENSITY_3 * fadeOut;
        newColor = mix(newColor, trailColor, glow3);

        // Punch hole for cursor
        newColor = mix(newColor, fragColor, step(sdfCurrentCursor, 0.));
    }

    fragColor = newColor;
}
