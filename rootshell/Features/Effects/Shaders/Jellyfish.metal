// Jellyfish.metal
// rootshell
// Translucent mesoglea, radial canals, a folded oral veil, marginal filaments,
// and linear-light bioluminescence. No terminal texture is sampled or warped.

#include <metal_stdlib>
using namespace metal;

struct JFVertex { float4 position; float4 uv; };
struct JFInstance { float4 axisX; float4 axisY; float4 tint; float4 motion; float4 anatomy; };
struct JFUniforms { float4 viewport; float4 composition; };
struct JFSurface {
    float4 position [[position]];
    float3 local;
    float3 normal;
    float2 uv;
    float phase;
};
struct JFScreen { float4 position [[position]]; float2 uv; };

static float jfHash(float n) { return fract(sin(n * 127.1f + 311.7f) * 43758.5453f); }
static float jfLine(float distance, float width) {
    float aa = max(fwidth(distance), 0.001f);
    return 1 - smoothstep(width, width + aa, abs(distance));
}
static float4 jfClip(float2 p, constant JFUniforms &u) {
    return float4(p / u.viewport.xy * float2(2, -2) + float2(-1, 1), 0, 1);
}
static float2 jfWorld(float3 p, constant JFInstance &j) {
    // Oblique view reveals the inside of the bell and its elliptical margin.
    float y = p.y * cos(j.anatomy.x) + p.z * sin(j.anatomy.x);
    return float2(dot(j.axisX.xyz, float3(p.x, y, 1)), dot(j.axisY.xyz, float3(p.x, y, 1)));
}
static float3 jfBell(float2 uv, constant JFInstance &j) {
    float phi = uv.x * 2 * M_PI_F, theta = uv.y * M_PI_F * 0.5f;
    float skirt = pow(saturate(uv.y), 9.0f);
    float lobes = cos(phi * 16 + j.anatomy.y);
    float radius = sin(theta) * (1 + skirt * (0.024f * lobes - 0.035f * j.motion.x));
    float y = -cos(theta) * 0.91f + skirt * (0.035f * lobes + 0.065f * j.motion.x);
    return float3(cos(phi) * radius, y, sin(phi) * radius * 0.72f);
}

vertex JFSurface jellyfishBellVertex(uint vid [[vertex_id]], const device JFVertex *vertices [[buffer(0)]],
                                    constant JFInstance &j [[buffer(1)]], constant JFUniforms &u [[buffer(2)]]) {
    float2 uv = vertices[vid].uv.xy;
    float3 p = jfBell(uv, j);
    float3 du = jfBell(uv + float2(0.0005f, 0), j) - jfBell(uv - float2(0.0005f, 0), j);
    float3 dv = jfBell(uv + float2(0, 0.0005f), j) - jfBell(uv - float2(0, 0.0005f), j);
    float3 n = uv.y < 0.001f ? float3(0, -1, 0) : normalize(cross(dv, du));
    // Inverse-transpose for the pulse squash, followed by the camera tilt.
    float sx = max(length(float2(j.axisX.x, j.axisY.x)) / j.axisX.w, 0.01f);
    float sy = max(length(float2(j.axisX.y, j.axisY.y)) / j.axisX.w, 0.01f);
    n /= float3(sx, sy, sx);
    // Keep lighting in bell space: its shape, not a painted gradient, catches light.
    n = normalize(n);
    JFSurface out;
    out.position = jfClip(jfWorld(p, j), u);
    out.local = p; out.normal = n; out.uv = uv; out.phase = 0;
    return out;
}

fragment half4 jellyfishMembrane(JFSurface in [[stage_in]], bool front [[front_facing]],
                                 constant JFInstance &j [[buffer(1)]], constant JFUniforms &u [[buffer(2)]]) {
    float3 n = normalize(in.normal);
    float3 eye = normalize(float3(0, -sin(j.anatomy.x), cos(j.anatomy.x)));
    float facing = abs(dot(n, eye));
    float fresnel = pow(1 - facing, 3.0f);
    float phi = in.uv.x * 2 * M_PI_F;
    float latitude = in.uv.y;
    float canalPhase = phi * 8 + sin(latitude * 9 + j.anatomy.y) * 0.17f;
    float canals = jfLine(sin(canalPhase), 0.035f) * smoothstep(0.12f, 0.30f, latitude);
    float branches = jfLine(sin(phi * 32 + sin(latitude * 20) * 0.5f), 0.018f);
    branches *= smoothstep(0.53f, 0.85f, latitude) * 0.32f;
    float margin = smoothstep(0.93f, 0.985f, latitude);
    float muscle = jfLine(latitude - 0.875f, 0.007f) * 0.24f;
    float grain = sin(phi * 93 + latitude * 71) * sin(latitude * 151 - phi * 31);
    float caustic = pow(saturate(1 - abs(sin(phi * 5 + latitude * 11 + j.motion.y * 0.18f)
                                     + sin(latitude * 17 - phi * 3 - j.motion.y * 0.13f))), 10.0f);
    float3 light = normalize(float3(-0.45f, -0.80f, 0.65f));
    float diffuse = max(dot(n, light), 0.0f);
    float specular = pow(max(dot(n, normalize(light + eye)), 0.0f), 76.0f);
    float transmission = pow(max(dot(-n, light), 0.0f), 2.0f) * 0.25f;
    float tissue = 0.12f + fresnel * 0.27f + canals * 0.11f + margin * 0.40f + muscle;
    tissue += (grain * 0.008f + caustic * 0.018f) * sin(latitude * M_PI_F);
    float alpha = saturate(tissue) * j.tint.a;
    // A small violet/cyan shift at grazing angles reads as a wet membrane.
    float3 pearl = mix(j.tint.rgb, j.tint.brg, fresnel * 0.30f);
    float pulse = 0.82f + j.motion.x * 0.30f;
    float3 color = pearl * (0.80f + diffuse * 0.60f + transmission);
    color += mix(pearl, float3(0.75f, 0.93f, 1), 0.24f)
             * ((canals * 1.1f + branches * 0.6f + margin * 2.7f) * pulse + fresnel * 0.8f);
    color += float3(specular * 1.8f + caustic * 0.12f);
    if (u.composition.y > 0.5f) {
        color = j.tint.rgb * (0.42f + diffuse * 0.40f);
        alpha *= 0.83f;
    }
    return half4(half3(color * alpha), half(alpha));
}

vertex JFSurface jellyfishRibbonVertex(uint vid [[vertex_id]], const device JFVertex *vertices [[buffer(0)]],
                                      constant JFUniforms &u [[buffer(2)]]) {
    JFVertex v = vertices[vid];
    JFSurface out;
    out.position = jfClip(v.position.xy, u);
    out.local = v.position.xyz; out.normal = float3(0, 0, v.position.w);
    out.uv = v.uv.xy; out.phase = v.uv.z;
    return out;
}

fragment half4 jellyfishRibbon(JFSurface in [[stage_in]], constant JFInstance &j [[buffer(1)]],
                               constant JFUniforms &u [[buffer(2)]]) {
    bool arm = in.normal.z < 1.5f;
    float x = in.uv.x, v = in.uv.y;
    float edge = 1 - smoothstep(1 - max(fwidth(x), 0.08f), 1.0f, abs(x));
    float fade = pow(saturate(1 - v), arm ? 0.65f : 0.55f);
    float wave = v * 52 - j.motion.y * mix(0.8f, 0.12f, j.anatomy.z) + in.phase;
    float ridge = pow(0.5f + 0.5f * cos(x * 9 + sin(wave) * 1.8f), 4.0f);
    float hem = pow(abs(x), 5.0f) * (0.6f + 0.4f * sin(wave));
    float shimmer = exp(-pow((v - j.motion.z) * 14, 2.0f)) * j.motion.w;
    float alpha = edge * fade * j.tint.a * (arm ? 0.22f + ridge * 0.26f + hem * 0.2f : 0.74f);
    float3 color = mix(j.tint.rgb, float3(0.78f, 0.92f, 1), arm ? 0.12f : 0.25f);
    if (arm) color = mix(color, j.tint.brg, v * 0.18f);
    color *= arm ? 0.65f + ridge * 1.2f + hem * 0.7f : 1.25f;
    color += mix(j.tint.rgb, float3(1), 0.55f) * shimmer * 3;
    if (u.composition.y > 0.5f) color = j.tint.rgb * (arm ? 0.55f : 0.35f);
    return half4(half3(color * alpha), half(alpha));
}

static float2 jfCorner(uint vid) {
    constexpr float2 corners[] = {float2(-1,-1), float2(-1,1), float2(1,-1),
                                  float2(1,-1), float2(-1,1), float2(1,1)};
    return corners[vid % 6];
}

vertex JFSurface jellyfishCoreVertex(uint vid [[vertex_id]], constant JFInstance &j [[buffer(1)]],
                                    constant JFUniforms &u [[buffer(2)]]) {
    float2 uv = jfCorner(vid);
    float3 p = float3(uv.x * 0.64f, -0.40f + uv.y * 0.33f, 0);
    JFSurface out;
    out.position = jfClip(jfWorld(p, j), u);
    out.local = p; out.normal = float3(0,0,1); out.uv = uv; out.phase = 0;
    return out;
}

fragment half4 jellyfishCore(JFSurface in [[stage_in]], constant JFInstance &j [[buffer(1)]],
                             constant JFUniforms &u [[buffer(2)]]) {
    float2 p = in.uv * float2(1, 1.15f);
    float tissue = 0, halo = 0;
    // Four horseshoe-shaped gastric pouches, visible through the mesoglea.
    for (int lobe = 0; lobe < 4; ++lobe) {
        float a = float(lobe) * M_PI_F * 0.5f + M_PI_F * 0.25f;
        float2 q = p - float2(cos(a), sin(a)) * 0.36f;
        float r = length(q);
        float ring = jfLine(r - 0.225f, 0.026f);
        float opening = smoothstep(-0.08f, 0.11f, dot(q, float2(cos(a), sin(a))));
        tissue += ring * opening;
        halo += exp(-dot(q,q) * 26) * 0.25f;
    }
    float alpha = saturate(tissue * 0.50f + halo * 0.15f) * j.tint.a;
    float3 color = mix(j.tint.rgb, float3(0.9f, 0.8f, 1), 0.37f) * (1.3f + j.motion.x * 0.25f);
    if (u.composition.y > 0.5f) color = j.tint.rgb * 0.4f;
    return half4(half3(color * alpha), half(alpha));
}

vertex JFSurface jellyfishMoteVertex(uint vid [[vertex_id]], constant JFInstance &j [[buffer(1)]],
                                    constant JFUniforms &u [[buffer(2)]]) {
    float index = float(vid / 6) + j.anatomy.y * 13;
    float2 uv = jfCorner(vid);
    float a = jfHash(index) * 2 * M_PI_F;
    float distance = 1.3f + jfHash(index + 3) * 2.5f;
    float2 center = float2(j.axisX.z, j.axisY.z);
    center += float2(cos(a), sin(a)) * distance * j.axisX.w;
    center += float2(sin(j.motion.y * 0.16f + index), cos(j.motion.y * 0.13f + index)) * j.axisX.w * 0.22f;
    float size = 0.55f + jfHash(index + 7) * 1.4f;
    JFSurface out;
    out.position = jfClip(center + uv * size, u);
    out.local = float3(0); out.normal = float3(0); out.uv = uv;
    out.phase = (0.08f + jfHash(index + 9) * 0.12f) * j.tint.a;
    return out;
}

fragment half4 jellyfishMote(JFSurface in [[stage_in]], constant JFInstance &j [[buffer(1)]],
                             constant JFUniforms &u [[buffer(2)]]) {
    float alpha = exp(-dot(in.uv, in.uv) * 4.0f) * in.phase;
    float3 color = u.composition.y > 0.5f ? j.tint.rgb * 0.5f : j.tint.rgb * 1.5f;
    return half4(half3(color * alpha), half(alpha));
}

vertex JFScreen jellyfishScreenVertex(uint vid [[vertex_id]]) {
    float2 uv = float2((vid << 1) & 2, vid & 2);
    return {float4(uv * float2(2,-2) + float2(-1,1), 0, 1), uv};
}

fragment half4 jellyfishBloomThreshold(JFScreen in [[stage_in]], texture2d<half> source [[texture(0)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 texel = 1.0f / float2(source.get_width(), source.get_height());
    float3 color = 0;
    for (int y = -1; y <= 1; y += 2) for (int x = -1; x <= 1; x += 2)
        color += float3(source.sample(s, in.uv + float2(x,y) * texel).rgb) * 0.25f;
    float brightness = max(color.r, max(color.g, color.b));
    return half4(half3(color * smoothstep(0.16f, 0.85f, brightness)), 1);
}

fragment half4 jellyfishBloomBlur(JFScreen in [[stage_in]], texture2d<half> source [[texture(0)]],
                                 constant float4 &direction [[buffer(0)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 delta = direction.xy;
    half3 color = source.sample(s, in.uv).rgb * half(0.227027f);
    color += (source.sample(s, in.uv + delta * 1.384615f).rgb + source.sample(s, in.uv - delta * 1.384615f).rgb) * half(0.316216f);
    color += (source.sample(s, in.uv + delta * 3.230769f).rgb + source.sample(s, in.uv - delta * 3.230769f).rgb) * half(0.070270f);
    return half4(color, 1);
}

fragment half4 jellyfishComposite(JFScreen in [[stage_in]], constant JFUniforms &u [[buffer(2)]],
                                 texture2d<half> scene [[texture(0)]], texture2d<half> bloom [[texture(1)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float4 tissue = float4(scene.sample(s, in.uv));
    float3 glow = float3(bloom.sample(s, in.uv).rgb) * u.composition.z * 1.3f;
    float coverage = saturate(max(tissue.a, max(glow.r, max(glow.g, glow.b)) * 0.6f));
    float3 color = (tissue.rgb + glow) / max(coverage, 0.00001f);
    if (u.composition.y < 0.5f) color = color / (1 + color); // Preserve saturated emissive tissue.
    color = select(1.055f * pow(max(color, 0.0f), float3(1.0f / 2.4f)) - 0.055f,
                   12.92f * color, color <= 0.0031308f);
    float alpha = coverage * u.composition.x;
    return half4(half3(saturate(color) * alpha), half(alpha));
}
