// https://gist.githubusercontent.com/krank56/212c1d1ffbfd1c0b1d878a59da2177a5/raw/60be8720d3b3fefd1cfff63fb23d61709115b959/tesla_coil.glsl

// ============================================================================
// Animation Behavior Parameters - Tweak these to customize the effect
// ============================================================================
const float DURATION = 0.8;                    // Total animation duration in seconds
const float ARC_NOISE_TIME_SCALE = 3.0;       // Lower = slower, smoother noise (was 10.0)
const float ARC_NOISE_SPACE_SCALE = 8.0;      // Spatial frequency of noise (was 10.0)
const float ARC_OFFSET_AMPLITUDE = 0.08;      // Amplitude of arc waviness (was 0.1)
const float BRANCH_TIME_SCALE = 8.0;          // Branch animation speed (was 15.0)
const float BRANCH_FREQUENCY = 3.0;           // Branch frequency - lower = fewer branches (was 5.0)
const float BRANCH_OFFSET_AMPLITUDE = 0.02;   // Branch offset strength (was 0.03)
const float ARC_THICKNESS_BASE = 0.005;       // Base thickness of the arc line
const float ARC_THICKNESS_PULSE = 0.003;      // Pulsation amount
const float ARC_PULSE_SPEED = 30.0;           // How fast the thickness pulses
const float ARC_COLOR_PULSE_SPEED = 20.0;     // How fast the color shifts
const float CURSOR_OPACITY = 0.5;             // Cursor transparency (0.0 = invisible, 1.0 = opaque)

// ============================================================================
// Color Configuration
// ============================================================================
const vec4 TRAIL_COLOR = vec4(1.0, 0.2, 0.2, 1.0); // Red
const vec4 CURRENT_CURSOR_COLOR = TRAIL_COLOR;
const vec4 PREVIOUS_CURSOR_COLOR = TRAIL_COLOR;
const vec4 TRAIL_COLOR_ACCENT = vec4(1.0, 0.5, 0.5, 1.0); // Brighter red
const vec4 ELECTRIC_COLOR = vec4(1.0, 0.3, 0.3, 1.0); // Electric red color
const float GLOW_INTENSITY = 0.3;              // Glow blend intensity (0.0 - 1.0)
// ============================================================================

float ease(float x) {
     return pow(1.0 - x, 3.0);
}

float sdBox(in vec2 p, in vec2 xy, in vec2 b) {
    vec2 d = abs(p - xy) - b;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

float getSdfRectangle(in vec2 p, in vec2 xy, in vec2 b) {
    vec2 d = abs(p - xy) - b;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

// Based on Inigo Quilez's 2D distance functions article: https://iquilezles.org/articles/distfunctions2d/
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

float blend(float t) {
    float sqr = t * t;
    return sqr / (2.0 * (sqr - t) + 1.0);
}

float antialising(float distance) {
    return 1. - smoothstep(0., normalize(vec2(2., 2.), 0.).x, distance);
}

float determineStartVertexFactor(vec2 a, vec2 b) {
    float condition1 = step(b.x, a.x) * step(a.y, b.y);
    float condition2 = step(a.x, b.x) * step(b.y, a.y);
    return 1.0 - max(condition1, condition2);
}

vec2 getRectangleCenter(vec4 rectangle) {
    return vec2(rectangle.x + (rectangle.z / 2.), rectangle.y - (rectangle.w / 2.));
}

// Tesla coil effect functions
float random(vec2 st) {
    return fract(sin(dot(st.xy, vec2(12.9898, 78.233))) * 43758.5453123);
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

float fbm(vec2 p) {
    float value = 0.0;
    float amplitude = 0.5;
    for (int i = 0; i < 4; i++) {
        value += amplitude * noise(p);
        p *= 2.0;
        amplitude *= 0.5;
    }
    return value;
}

// Function to create electric arc effect
float electricArc(vec2 p, vec2 a, vec2 b, float time, float progress) {
     vec2 dir = normalize(b - a);
     vec2 perp = vec2(-dir.y, dir.x);
     float dist = distance(a, b);
     
     // Base arc with noise for tesla coil effect
     float t = clamp(dot(p - a, dir) / dist, 0.0, 1.0);
     vec2 projected = a + dir * t * dist;
     // Use ARC_NOISE_SPACE_SCALE and ARC_NOISE_TIME_SCALE for animation
     vec2 offset = perp * (fbm(vec2(t * ARC_NOISE_SPACE_SCALE, time * ARC_NOISE_TIME_SCALE)) - 0.5) * ARC_OFFSET_AMPLITUDE * progress;
     
     // Main arc
     float d = length(p - (projected + offset));
     
     // Add branching effects
     float branch = 0.0;
     if (progress > 0.5) {
         // Use BRANCH_TIME_SCALE for smoother branch animation
         float branchTime = time * BRANCH_TIME_SCALE;
         vec2 branchOffset = perp * (sin(t * BRANCH_FREQUENCY + branchTime) * BRANCH_OFFSET_AMPLITUDE * progress);
         branch = length(p - (projected + branchOffset));
         d = min(d, branch);
     }
     
     return d;
}

const float OPACITY = .001;
const float TAIL_EXTENSION = 1.5;

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    #if !defined(WEB)
    fragColor = texture(iChannel0, fragCoord.xy / iResolution.xy);
    #endif
    
    // Normalization for fragCoord to a space of -1 to 1;
    vec2 vu = normalize(fragCoord, 1.);
    vec2 offsetFactor = vec2(-.5, 0.5);
    
    // Normalization for cursor position and size;
    vec4 currentCursor = vec4(normalize(iCurrentCursor.xy, 1.), normalize(iCurrentCursor.zw, 0.));
    vec4 previousCursor = vec4(normalize(iPreviousCursor.xy, 1.), normalize(iPreviousCursor.zw, 0.));
    
    vec2 centerCC = getRectangleCenter(currentCursor);
    vec2 centerCP = getRectangleCenter(previousCursor);
    vec2 centerCP_new = centerCP + (centerCP - centerCC) * TAIL_EXTENSION;
    
    float progress = blend(clamp((iTime - iTimeCursorChange) / DURATION, 0.0, 1));
    float easedProgress = ease(progress);
    
    float lineLength = distance(centerCC, centerCP_new);
    float distanceToEnd = distance(vu.xy, centerCC);
    float alphaModifier = distanceToEnd / (lineLength * easedProgress);
    if (alphaModifier > 1.0) {
        alphaModifier = 1.0;
    }
    
    // Enhanced tapering with smoothstep for smoother opacity falloff towards tail end
    float trailOpacity = 1.0 - smoothstep(0.0, 1.0, alphaModifier);
    
     // Create electric arc effect
     float arcThickness = ARC_THICKNESS_BASE + ARC_THICKNESS_PULSE * sin(iTime * ARC_PULSE_SPEED);
     float arc = electricArc(vu, centerCC, centerCP_new, iTime, easedProgress);
     float arcAlpha = 1.0 - smoothstep(arcThickness * 0.5, arcThickness, arc);
     
     // Add glow effect
     float glow = 1.0 - smoothstep(arcThickness, arcThickness * 2.0, arc);
     
     vec4 newColor = fragColor;
     
     // Apply electric arc with glow
     if (arcAlpha > 0.0) {
         vec4 arcColor = mix(ELECTRIC_COLOR, TRAIL_COLOR_ACCENT, 
                           0.5 + 0.5 * sin(iTime * ARC_COLOR_PULSE_SPEED)); // Pulsating color
         newColor = mix(newColor, arcColor, arcAlpha * trailOpacity);
         newColor = mix(newColor, ELECTRIC_COLOR * 0.5, glow * trailOpacity * GLOW_INTENSITY);
     }
     
      // Draw cursor with semi-transparency to show character underneath
      float sdfCursor = getSdfRectangle(vu, currentCursor.xy - (currentCursor.zw * offsetFactor), currentCursor.zw * 0.5);
      float cursorAlpha = 1.0 - smoothstep(0.0, 0.01, sdfCursor);
      newColor = mix(newColor, CURRENT_CURSOR_COLOR, cursorAlpha * CURSOR_OPACITY);
    
    fragColor = newColor;
}
