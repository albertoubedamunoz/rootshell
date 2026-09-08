// Silk: a fine, theme-colored ribbon with a soft pearlescent edge.
// Keep this literal declaration: Ghostty reads it to schedule a finite animation.
const float DURATION = 0.24;
const float MAX_TRAIL_LENGTH = 6.0; // Units of the cursor's larger dimension.
const float RIBBON_WIDTH = 0.30;
const float CURVATURE = 0.20;
const float BODY_OPACITY = 0.18;
const float PEARL_OPACITY = 0.32;
const float GLOW_OPACITY = 0.08;

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    fragColor = texture(iChannel0, fragCoord / iResolution.xy);

    float age = iTime - iTimeCursorChange;
    if (age < 0.0 || age >= DURATION ||
        min(iCurrentCursor.z, iCurrentCursor.w) <= 0.0 ||
        min(iPreviousCursor.z, iPreviousCursor.w) <= 0.0) {
        return;
    }

    // Match Ghostty's shader rectangles: x..x+width and y-height..y.
    vec2 halfSize = iCurrentCursor.zw * 0.5;
    vec2 center = iCurrentCursor.xy + vec2(halfSize.x, -halfSize.y);
    vec2 previousCenter = iPreviousCursor.xy +
                          iPreviousCursor.zw * vec2(0.5, -0.5);
    // Use origin displacement to avoid triggering on cursor shape changes alone.
    vec2 movement = iPreviousCursor.xy - iCurrentCursor.xy;
    if (dot(movement, movement) < 0.25) return;

    vec2 delta = previousCenter - center;
    float distanceMoved = length(delta);
    if (distanceMoved < 0.5) return;

    vec2 p = fragCoord - center;
    vec2 cursorDistance = abs(p) - halfSize;
    // Preserve the entire cursor rectangle, including text and hollow interiors.
    if (max(cursorDistance.x, cursorDistance.y) <= 0.0) return;

    float unit = max(iCurrentCursor.z, iCurrentCursor.w);
    vec2 along = delta / distanceMoved;
    vec2 across = vec2(-along.y, along.x);
    float x = dot(p, along);
    float y = dot(p, across);
    float progress = age / DURATION;
    float remaining = 1.0 - progress;
    float contraction = remaining * remaining * remaining;
    float fade = 1.0 - smoothstep(0.0, 1.0, progress);
    float strength = mix(0.28, 1.0, smoothstep(0.0, 3.0, distanceMoved / unit));

    // Contract toward the trailing edge, so thin and block cursors both have
    // a delicate finish instead of swallowing the ribbon midway through a move.
    vec2 edgeDistances = halfSize / max(abs(along), vec2(0.0001));
    float attachment = min(edgeDistances.x, edgeDistances.y);
    float reach = max(min(distanceMoved, MAX_TRAIL_LENGTH * unit) - attachment, 0.0);
    if (reach <= 0.0) return;
    float ribbonLength = max(reach * contraction, 0.001);
    x -= attachment;

    // One physical pixel of antialiasing; no derivatives or screen-sized bloom.
    float aa = 1.0;
    float glowRadius = max(1.0, unit * 0.12);
    float halfWidth = unit * RIBBON_WIDTH * 0.5 * strength;
    float bend = min(unit * CURVATURE, ribbonLength * 0.20) * strength;
    float margin = halfWidth + bend + glowRadius + aa;
    if (x < -margin || x > ribbonLength + margin || abs(y) > margin) return;

    float t = clamp(x / ribbonLength, 0.0, 1.0);
    // A single arch, tangent-controlled at the head and tapering to a fine tip.
    // Its changing amplitude gives the suggestion of silk settling, without noise.
    float arch = 4.0 * t * (1.0 - t);
    float centerline = bend * arch;
    float slope = 4.0 * bend * (1.0 - 2.0 * t) / ribbonLength;
    float perpendicular = (y - centerline) / sqrt(1.0 + slope * slope);
    float width = halfWidth * (1.0 - t) * (0.65 + 0.35 * arch);
    float sideDistance = abs(perpendicular) - width;
    float endDistance = max(-x, x - ribbonLength);
    vec2 outside = max(vec2(endDistance, sideDistance), vec2(0.0));
    float ribbonDistance = length(outside) + min(max(endDistance, sideDistance), 0.0);

    // Fade the last few pixels as geometry collapses rather than leaving a dot.
    float envelope = fade * strength * smoothstep(0.0, 2.0 * aa, ribbonLength);
    float body = (1.0 - smoothstep(-aa, aa, ribbonDistance)) * BODY_OPACITY;
    float glow = (1.0 - smoothstep(0.0, glowRadius, max(ribbonDistance, 0.0))) * GLOW_OPACITY;

    // Only one edge catches the light. The highlight rolls softly along the
    // ribbon as it contracts, and tapers away at both ends.
    float edgeDistance = abs(perpendicular - width * 0.65);
    float pearlWidth = max(0.5, unit * 0.025);
    float pearl = (1.0 - smoothstep(0.0, pearlWidth + aa, edgeDistance)) *
                  arch * (1.0 - smoothstep(0.0, aa, endDistance)) * PEARL_OPACITY;

    vec3 color = clamp(iCurrentCursorColor.rgb, 0.0, 1.0);
    vec3 pearlColor = mix(color, vec3(1.0), 0.22);
    // The terminal texture is premultiplied. Preserve its alpha (and transparent
    // pixels) while tinting, so this pass also composes with background effects.
    float opacity = clamp(iCurrentCursorColor.a, 0.0, 1.0) * envelope;
    fragColor.rgb = mix(fragColor.rgb, color * fragColor.a, glow * opacity);
    fragColor.rgb = mix(fragColor.rgb, color * fragColor.a, body * opacity);
    fragColor.rgb = mix(fragColor.rgb, pearlColor * fragColor.a, pearl * opacity);
}
