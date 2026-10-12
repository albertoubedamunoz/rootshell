// Weather.metal
// rootshell
// Live Weather: a single-scattering sky, ray-marched clouds with temporal
// accumulation, an analytic sun and moon, catalogue stars, and GPU-only rain,
// snow, and lightning. The sky and cloud passes run offscreen at low,
// independent rates; the per-frame composite is a handful of texture reads.
// World space: x east, y up, z south; kilometres.

#include <metal_stdlib>
using namespace metal;

struct WXUniforms {
    float4 cameraForward;   // xyz, tan(half width)
    float4 cameraRight;     // xyz, tan(half height)
    float4 cameraUp;        // xyz, animation phase (s)
    float4 sunDirection;    // xyz, altitude (rad)
    float4 moonDirection;   // xyz, visible illuminated fraction
    float4 sunRadiance;     // rgb, disc radius (rad)
    float4 keyLight;        // xyz light on the clouds, moon disc radius (rad)
    float4 keyColor;        // rgb, exposure
    float4 clouds;          // low cover, high cover, density, towering
    float4 precipitation;   // rain, snow, sleet mix, gustiness
    float4 atmosphere;      // fog, haze, flash, star visibility
    float4 hazeTint;        // rgb, Milky Way strength
    float4 wind;            // cloud drift x, z (km), screen-space wind, strength
    float4 cloudShift;      // uv shift xy, jitter frame, history valid
    float4 strike;          // uv xy, glow radius, glow
    float4 viewport;        // width, height, 1/width, 1/height
    float4 composition;     // intensity, reading protection, light theme, sun and moon
    float4 equatorialX;
    float4 equatorialY;
    float4 equatorialZ;
    float4 galaxy;          // galactic north pole, cloud steps
    float4 galaxyCenter;
    float4 rainColor;
    float4 snowColor;
};
struct WXStar { float4 equatorial; float4 color; };
struct WXBoltSegment { float4 ends; float4 style; };
struct WXScreen { float4 position [[position]]; float2 uv; };

constant float wxPi = 3.14159265f;
constant float wxCloudBase = 1.4f;
constant float wxEarthRadius = 6360.0f;
constant float wxAtmosphereRadius = 6420.0f;
constant float3 wxRayleigh = float3(5.802e-3f, 13.558e-3f, 33.1e-3f);   // per km
constant float wxMie = 3.996e-3f;
constant float wxMieExtinction = 4.440e-3f;
constant float3 wxOzone = float3(0.650e-3f, 1.881e-3f, 0.085e-3f);
constant float3 wxLuma = float3(0.2126f, 0.7152f, 0.0722f);
// Light from towns below, lighting the horizon and cloud bases at night.
constant float3 wxSkyglow = float3(0.0023f, 0.0020f, 0.0017f);

// MARK: - Hashes and tileable noise

static float wxHash11(float p) {
    p = fract(p * 0.1031f);
    p *= p + 33.33f;
    p *= p + p;
    return fract(p);
}
static float wxHash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031f);
    p3 += dot(p3, p3.yzx + 33.33f);
    return fract((p3.x + p3.y) * p3.z);
}
static float3 wxHash33(float3 p) {
    p = fract(p * float3(0.1031f, 0.1030f, 0.0973f));
    p += dot(p, p.yxz + 33.33f);
    return fract((p.xxy + p.yxx) * p.zyx);
}
// Interleaved gradient noise: a cheap, well-spread per-pixel ray offset.
static float wxIGN(float2 pixel, float frame) {
    pixel += 5.588238f * fmod(frame, 64.0f);
    return fract(52.9829189f * fract(0.06711056f * pixel.x + 0.00583715f * pixel.y));
}
static float3 wxWrap(float3 cell, float period) { return cell - period * floor(cell / period); }

static float wxWorley(float3 p, float period) {
    float3 q = p * period;
    float3 cell = floor(q), f = fract(q);
    float best = 1.0f;
    for (int z = -1; z <= 1; ++z)
    for (int y = -1; y <= 1; ++y)
    for (int x = -1; x <= 1; ++x) {
        float3 o = float3(x, y, z);
        float3 r = o + wxHash33(wxWrap(cell + o, period) + 0.5f) - f;
        best = min(best, dot(r, r));
    }
    return 1.0f - saturate(sqrt(best));
}
static float wxGradient(float3 cell, float3 corner, float3 f, float period) {
    float3 g = wxHash33(wxWrap(cell + corner, period) + 0.37f) * 2.0f - 1.0f;
    return dot(g / max(length(g), 1e-3f), f - corner);
}
static float wxPerlin(float3 p, float period) {
    float3 q = p * period;
    float3 i = floor(q), f = fract(q);
    float3 u = f * f * f * (f * (f * 6.0f - 15.0f) + 10.0f);
    float n000 = wxGradient(i, float3(0, 0, 0), f, period), n100 = wxGradient(i, float3(1, 0, 0), f, period);
    float n010 = wxGradient(i, float3(0, 1, 0), f, period), n110 = wxGradient(i, float3(1, 1, 0), f, period);
    float n001 = wxGradient(i, float3(0, 0, 1), f, period), n101 = wxGradient(i, float3(1, 0, 1), f, period);
    float n011 = wxGradient(i, float3(0, 1, 1), f, period), n111 = wxGradient(i, float3(1, 1, 1), f, period);
    return mix(mix(mix(n000, n100, u.x), mix(n010, n110, u.x), u.y),
               mix(mix(n001, n101, u.x), mix(n011, n111, u.x), u.y), u.z);
}

kernel void weatherShapeNoise(texture3d<half, access::write> out [[texture(0)]],
                              uint3 gid [[thread_position_in_grid]]) {
    uint size = out.get_width();
    if (gid.x >= size || gid.y >= size || gid.z >= size) return;
    float3 p = (float3(gid) + 0.5f) / float(size);
    float perlin = 0.0f, amplitude = 1.0f, total = 0.0f;
    for (int octave = 0; octave < 4; ++octave) {
        perlin += wxPerlin(p, 4.0f * float(1 << octave)) * amplitude;
        total += amplitude;
        amplitude *= 0.5f;
    }
    perlin = saturate(perlin / total * 0.9f + 0.5f);
    float billows = wxWorley(p, 4) * 0.625f + wxWorley(p, 8) * 0.25f + wxWorley(p, 16) * 0.125f;
    float perlinWorley = billows + perlin * (1.0f - billows);
    float fbm = wxWorley(p, 8) * 0.625f + wxWorley(p, 16) * 0.25f + wxWorley(p, 32) * 0.125f;
    // Stretch each channel over its measured 1st-99th percentile so coverage
    // thresholds map roughly linearly to sky area.
    out.write(half4(half(saturate((perlinWorley - 0.53f) / 0.37f)), half(saturate((fbm - 0.21f) / 0.54f)), 0.0h, 1.0h), gid);
}

kernel void weatherDetailNoise(texture3d<half, access::write> out [[texture(0)]],
                               uint3 gid [[thread_position_in_grid]]) {
    uint size = out.get_width();
    if (gid.x >= size || gid.y >= size || gid.z >= size) return;
    float3 p = (float3(gid) + 0.5f) / float(size);
    float fbm = wxWorley(p, 4) * 0.625f + wxWorley(p, 8) * 0.25f + wxWorley(p, 16) * 0.125f;
    out.write(half4(half(saturate((fbm - 0.22f) / 0.53f)), 0.0h, 0.0h, 1.0h), gid);
}

// MARK: - Shared helpers

vertex WXScreen weatherScreenVertex(uint vid [[vertex_id]]) {
    float2 uv = float2((vid << 1) & 2, vid & 2);
    WXScreen out;
    out.position = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
    out.uv = uv;
    return out;
}

static float3 wxRay(float2 uv, constant WXUniforms &u) {
    float2 ndc = float2(uv.x * 2.0f - 1.0f, 1.0f - uv.y * 2.0f);
    return normalize(u.cameraForward.xyz + u.cameraRight.xyz * (ndc.x * u.cameraForward.w)
                     + u.cameraUp.xyz * (ndc.y * u.cameraRight.w));
}

static float wxHG(float c, float g) {
    float g2 = g * g;
    return (1.0f - g2) / (4.0f * wxPi * pow(max(1.0f + g2 - 2.0f * g * c, 1e-4f), 1.5f));
}

static float3 wxToneMap(float3 x) {
    return saturate((x * (2.51f * x + 0.03f)) / (x * (2.43f * x + 0.59f) + 0.14f));
}
static float3 wxSRGB(float3 linear) {
    return select(1.055f * pow(max(linear, 0.0f), float3(1.0f / 2.4f)) - 0.055f, 12.92f * linear, linear <= 0.0031308f);
}

/// Opacity of the effect over the terminal: intensity, with a quiet centre
/// behind the text when reading protection is on.
static float wxCoverage(float2 uv, constant WXUniforms &u) {
    float2 q = (uv - float2(0.48f, 0.42f)) * float2(2.0f, 1.65f);
    return u.composition.x * (1.0f - u.composition.y * exp(-dot(q, q) * 2.0f) * 0.78f);
}
/// Stars and streaks cover little area, so they follow the square root of intensity.
static float wxPointCoverage(float2 uv, constant WXUniforms &u) {
    return wxCoverage(uv, u) * rsqrt(max(u.composition.x, 0.01f));
}

/// RootShell blends effects with plusLighter on dark themes and multiply on
/// light ones; lifting toward white keeps multiply from muddying text.
static float3 wxThemeColor(float3 display, constant WXUniforms &u) {
    return u.composition.z > 0.5f ? mix(float3(1.0f), saturate(display * 0.88f + 0.035f), 0.82f) : display;
}

/// Under a heavy overcast the clear-sky gradient seen through gaps and at the
/// horizon turns a dim, desaturated grey.
/// 1 once the sun is 12° down, 0 above -4°.
static float wxNight(constant WXUniforms &u) {
    return 1.0f - smoothstep(-0.21f, -0.07f, u.sunDirection.w);
}
static float wxOvercastAmount(constant WXUniforms &u) {
    return u.clouds.x * u.clouds.x * smoothstep(0.45f, 0.85f, u.clouds.z);
}
static float3 wxOvercast(float3 sky, constant WXUniforms &u) {
    float overcast = wxOvercastAmount(u);
    float luminance = dot(sky, wxLuma);
    return mix(sky, float3(luminance) * float3(0.94f, 0.97f, 1.0f), overcast * 0.8f) * (1.0f - overcast * 0.65f);
}

// MARK: - Sky (offscreen, refreshed every few seconds)

static float2 wxSphere(float3 o, float3 d, float r) {
    float b = dot(o, d);
    float c = dot(o, o) - r * r;
    float h = b * b - c;
    if (h < 0.0f) return float2(-1.0f);
    h = sqrt(h);
    return float2(-b - h, -b + h);
}
static float3 wxExtinction(float h) {
    return wxRayleigh * exp(-h / 8.0f) + wxMieExtinction * exp(-h / 1.2f)
         + wxOzone * max(0.0f, 1.0f - abs(h - 25.0f) / 15.0f);
}
static float3 wxTransmittance(float3 p, float3 l) {
    if (wxSphere(p, l, wxEarthRadius).x > 0.0f) return float3(0.0f);
    float dt = wxSphere(p, l, wxAtmosphereRadius).y / 6.0f;
    float3 depth = 0.0f;
    for (int i = 0; i < 6; ++i) {
        float3 q = p + l * ((float(i) + 0.5f) * dt);
        depth += wxExtinction(length(q) - wxEarthRadius) * dt;
    }
    return exp(-depth);
}
static float3 wxScatter(float3 d, float3 l, float3 radiance) {
    float3 o = float3(0.0f, wxEarthRadius + 0.2f, 0.0f);
    float2 ground = wxSphere(o, d, wxEarthRadius);
    float pathLength = ground.x > 0.0f ? ground.x : wxSphere(o, d, wxAtmosphereRadius).y;
    float dt = pathLength / 12.0f;
    float c = dot(d, l);
    float rayleighPhase = 3.0f / (16.0f * wxPi) * (1.0f + c * c);
    float miePhase = wxHG(c, 0.8f);
    float3 depth = 0.0f, sum = 0.0f;
    for (int i = 0; i < 12; ++i) {
        float3 p = o + d * ((float(i) + 0.5f) * dt);
        float h = length(p) - wxEarthRadius;
        float3 extinction = wxExtinction(h);
        float3 view = exp(-(depth + extinction * dt * 0.5f));
        depth += extinction * dt;
        float3 scattering = wxRayleigh * exp(-h / 8.0f) * rayleighPhase + wxMie * exp(-h / 1.2f) * miePhase;
        sum += view * wxTransmittance(p, l) * scattering * dt;
    }
    return sum * radiance;
}

static float3 wxMilkyWay(float3 d, constant WXUniforms &u, texture3d<half> shape) {
    constexpr sampler rep(coord::normalized, address::repeat, filter::linear);
    float3 pole = u.galaxy.xyz, center = u.galaxyCenter.xyz;
    float b = asin(clamp(dot(d, pole), -1.0f, 1.0f));
    float l = atan2(dot(d, cross(pole, center)), dot(d, center));
    // A band that thickens toward the core, with star clouds and a dark rift
    // sampled in galactic coordinates so they run along the plane.
    float width = 0.12f * (1.0f + 0.7f * exp(-l * l / 0.5f));
    float band = exp(-(b * b) / (width * width));
    float core = exp(-(l * l) / 0.3f - (b * b) / 0.05f);
    float2 g = float2(l * 0.9f, b * 3.2f);
    float clouds = float(shape.sample(rep, float3(g, 0.11f)).r);
    float knots = float(shape.sample(rep, float3(g * 1.8f, 0.71f)).r);
    float rift = smoothstep(0.5f, 0.85f, float(shape.sample(rep, float3(g * float2(1.6f, 1.4f), 0.47f)).r))
               * exp(-(b * b) / 0.004f);
    float glow = (band * (0.35f + 0.9f * clouds * clouds + 0.25f * knots) + core * 1.1f) * (1.0f - rift * 0.55f);
    return float3(0.00105f, 0.0011f, 0.0013f) * glow * smoothstep(0.0f, 0.3f, d.y);
}

fragment half4 weatherSky(WXScreen in [[stage_in]], constant WXUniforms &u [[buffer(2)]],
                          texture3d<half> shape [[texture(0)]]) {
    float3 d = wxRay(in.uv, u);
    float below = saturate(-d.y * 14.0f);
    float3 dir = normalize(float3(d.x, max(d.y, 0.0015f), d.z));
    float sunAltitude = u.sunDirection.w;
    float night = wxNight(u);
    float3 sky = 0.0f;
    if (sunAltitude > -0.32f) sky += wxScatter(dir, u.sunDirection.xyz, float3(20.0f));
    float moon = u.moonDirection.w;
    if (moon > 0.0f && night > 0.0f) sky += wxScatter(dir, u.moonDirection.xyz, float3(20.0f * 0.00055f * moon)) * night;
    // Airglow, starlight, and a skyglow dome, lifted well past physical levels
    // so a moonless sky still reads as sky behind the text.
    float horizon = 1.0f - dir.y;
    sky += (float3(0.0010f, 0.0014f, 0.0032f) + float3(0.0018f, 0.0018f, 0.0020f) * horizon * horizon * horizon
            + wxSkyglow * exp(-dir.y * 7.0f)) * night;
    sky += wxMilkyWay(dir, u, shape) * u.hazeTint.w;
    sky *= mix(1.0f, 0.4f, below);
    return half4(half3(sky), 1.0h);
}

// MARK: - Clouds (offscreen at half resolution, a few times a second)

struct WXCloudLayer {
    float bottom;
    float thickness;
    float extinction;   // per km at full density
    float stratus;      // 0 heaped cumulus, 1 a continuous sheet
};

static WXCloudLayer wxCloudLayer(constant WXUniforms &u) {
    float cover = u.clouds.x, density = u.clouds.z, towering = u.clouds.w;
    WXCloudLayer layer;
    layer.bottom = wxCloudBase;
    layer.stratus = saturate((cover - 0.6f) * 2.5f) * (1.0f - towering);
    // Overcast rain cloud is deep; storms tower.
    layer.thickness = 0.8f + 2.4f * cover * cover * density + 4.5f * towering;
    layer.extinction = mix(14.0f, 48.0f, density);
    return layer;
}

static float wxCloudDensity(float3 p, constant WXUniforms &u, WXCloudLayer layer,
                            texture3d<half> shape, texture3d<half> detail, bool erode) {
    constexpr sampler rep(coord::normalized, address::repeat, filter::linear);
    float h = (p.y - layer.bottom) / layer.thickness;
    if (h <= 0.0f || h >= 1.0f) return 0.0f;
    float cover = u.clouds.x;
    // Cumulus: flat bases and rounded tops. Sheets: soft edges top and bottom.
    float cumulus = smoothstep(0.0f, 0.07f, h) * (1.0f - smoothstep(0.3f, 1.0f, h));
    float sheet = smoothstep(0.0f, 0.12f, h) * (1.0f - smoothstep(0.55f, 1.0f, h));
    float profile = mix(cumulus, sheet, layer.stratus);
    float evolve = u.cameraUp.w * 0.0008f;
    float3 q = float3(p.x - u.wind.x, p.z - u.wind.y, p.y);
    float2 n = float2(shape.sample(rep, q * 0.11f + float3(0.0f, 0.0f, evolve)).rg);
    float base = n.x * 0.75f + n.y * 0.25f;
    // Coverage picks the area; strong cells grow tall, weak ones stay thin.
    float coverage = saturate((base - (1.0f - cover * 0.85f)) / max(cover * 0.45f, 0.05f));
    // Keep some texture in a full overcast instead of a flat sheet.
    float density = saturate(coverage - (1.0f - profile)) * mix(1.0f, 0.45f + 0.55f * base, cover);
    if (erode && density > 0.0f) {
        float edge = float(detail.sample(rep, q * 1.1f + float3(evolve * 3.0f)).r);
        density = saturate(density - edge * 0.45f * (1.0f - density));
    }
    return density;
}

fragment half4 weatherClouds(WXScreen in [[stage_in]], constant WXUniforms &u [[buffer(2)]],
                             texture3d<half> shape [[texture(0)]], texture3d<half> detail [[texture(1)]],
                             texture2d<half> sky [[texture(2)]], texture2d<half> history [[texture(3)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    constexpr sampler rep(coord::normalized, address::repeat, filter::linear);
    float3 d = wxRay(in.uv, u);
    float cover = u.clouds.x;
    float3 zenith = float3(sky.sample(s, float2(0.5f, 0.02f)).rgb);
    float3 horizon = float3(sky.sample(s, float2(in.uv.x, 0.9f)).rgb);
    float3 key = u.keyLight.xyz;
    float cosKey = dot(d, key);
    // Forward lobe for silver linings, a back lobe so the far side isn't flat.
    float phase = mix(wxHG(cosKey, 0.7f), wxHG(cosKey, -0.2f), 0.3f) + 0.02f;
    float jitter = wxIGN(in.position.xy, u.cloudShift.z);
    // A full overcast runs nearly to the horizon; broken cloud thins out sooner.
    float horizonFade = smoothstep(0.0f, mix(0.07f, 0.015f, wxOvercastAmount(u)), d.y);
    float3 light = 0.0f;
    float transmittance = 1.0f;
    float cloudDistance = 0.0f;

    if (horizonFade > 0.0f && cover > 0.003f) {
        WXCloudLayer layer = wxCloudLayer(u);
        float top = layer.bottom + layer.thickness;
        float dy = max(d.y, 0.03f);
        float t0 = layer.bottom / dy;
        float t1 = min(top / dy, t0 + 24.0f);
        int steps = int(u.galaxy.w);
        float dt = (t1 - t0) / float(steps);
        cloudDistance = t0;
        // The sky above an overcast is hidden from the cloud's own underside.
        float3 skyLight = zenith * 1.6f * (1.0f - 0.7f * cover);
        float3 groundLight = horizon * 0.35f;
        float3 glowLight = wxSkyglow * 2.2f * wxNight(u) * (1.0f - 0.6f * u.moonDirection.w);
        // Broken cloud lets light around it; only a deck shadows itself throughout.
        float meanDensity = cover * cover * 0.35f;
        for (int i = 0; i < steps && transmittance > 0.02f; ++i) {
            float3 p = d * (t0 + (float(i) + jitter) * dt);
            float density = wxCloudDensity(p, u, layer, shape, detail, true);
            if (density <= 0.002f) continue;
            float sigma = density * layer.extinction;
            float depth = 0.0f, stepLength = 0.08f;
            float3 lp = p;
            for (int j = 0; j < 3; ++j) {
                lp += key * stepLength;
                depth += wxCloudDensity(lp, u, layer, shape, detail, false) * layer.extinction * stepLength;
                stepLength *= 2.2f;
            }
            // Past the short march, assume the layer's average density.
            float rest = key.y >= 0.0f ? (top - lp.y) / max(key.y, 0.08f) : (lp.y - layer.bottom) / max(-key.y, 0.08f);
            depth += clamp(rest, 0.0f, 4.0f) * layer.extinction * meanDensity;
            // Beer plus a softer term standing in for multiple scattering.
            float beer = exp(-depth) * 0.7f + 0.3f * exp(-depth * 0.08f);
            // Powder: wisps facing the light scatter less back toward the viewer.
            float powder = 1.0f - exp(-sigma * 0.15f);
            float h = saturate((p.y - layer.bottom) / layer.thickness);
            float3 direct = u.keyColor.rgb * beer * phase * mix(0.35f, 1.0f, powder);
            // Light bounced around inside the cloud fills its core.
            float3 ambient = mix(groundLight, skyLight, h) * (0.35f + 0.65f * h) + u.keyColor.rgb * 0.015f * (0.4f + 0.6f * h)
                           + glowLight * (1.0f - h);
            float3 scatter = (direct + ambient) * sigma;
            float stepTransmittance = exp(-sigma * dt);
            light += transmittance * (scatter - scatter * stepTransmittance) / max(sigma, 1e-4f);
            transmittance *= stepTransmittance;
        }
        // Storm decks read darker than physics alone gives a thin slab, and a
        // thick base shows broad undulations rather than a flat sheet.
        light *= mix(1.0f, 0.5f, saturate((u.clouds.z - 0.65f) * 3.0f));
        float3 entry = d * t0;
        float mottle = float(shape.sample(rep, float3(entry.x - u.wind.x, entry.z - u.wind.y, 0.5f) * 0.22f).r);
        light *= mix(1.0f, 0.6f + 0.8f * mottle, wxOvercastAmount(u));
    }

    if (u.clouds.y > 0.003f && d.y > 0.02f) {
        float tc = 8.0f / d.y;
        if (tc < 90.0f) {
            float3 pc = d * tc;
            float2 w = float2(pc.x - u.wind.x * 1.8f, pc.z - u.wind.y * 1.8f);
            float evolve = u.cameraUp.w * 0.0008f;
            float n = float(shape.sample(rep, float3(w.x * 0.018f, w.y * 0.03f, 0.37f + evolve)).r);
            float fine = float(detail.sample(rep, float3(w.x * 0.07f, w.y * 0.12f, 0.61f)).r);
            float c = saturate((n * 0.75f + fine * 0.25f - (1.0f - u.clouds.y)) / max(u.clouds.y * 0.8f, 0.08f));
            // Unlit cirrus at night would read as scratches across the stars.
            float lit = saturate(dot(u.keyColor.rgb, wxLuma) * 0.5f);
            c *= 0.55f * mix(0.3f, 1.0f, lit) * smoothstep(0.02f, 0.15f, d.y);
            float3 color = u.keyColor.rgb * (wxHG(cosKey, 0.6f) * 0.5f + 0.04f) + zenith * 1.3f;
            light += transmittance * color * c;
            transmittance *= 1.0f - c;
            cloudDistance = cloudDistance > 0.0f ? cloudDistance : tc;
        }
    }

    float opacity = (1.0f - transmittance) * horizonFade;
    light *= horizonFade;
    // Aerial perspective: distant clouds fade into the sky behind them.
    float3 behind = wxOvercast(float3(sky.sample(s, in.uv).rgb), u);
    light = mix(light, behind * opacity, 1.0f - exp(-cloudDistance / 40.0f));
    float4 result = float4(light, opacity);
    if (u.cloudShift.w > 0.5f) {
        float4 previous = float4(history.sample(s, in.uv - u.cloudShift.xy));
        result = mix(previous, result, 0.3f);
    }
    return half4(result);
}

// MARK: - Composite (every displayed frame)

static float3 wxSun(float3 d, constant WXUniforms &u) {
    float radius = u.sunRadiance.w;
    float angle = acos(clamp(dot(d, u.sunDirection.xyz), -1.0f, 1.0f));
    if (angle > radius * 10.0f) return 0.0f;
    float r = angle / radius;
    float disc = 1.0f - smoothstep(0.94f, 1.0f, r);
    float limb = 0.4f + 0.6f * pow(sqrt(saturate(1.0f - r * r)), 0.55f);
    float aureole = exp(-max(r - 1.0f, 0.0f) * 1.6f) * 0.06f;
    return u.sunRadiance.rgb * (disc * limb * 3.0f + aureole);
}

static float3 wxMoon(float3 d, constant WXUniforms &u, texture3d<half> shape) {
    constexpr sampler rep(coord::normalized, address::repeat, filter::linear);
    float illumination = u.moonDirection.w;
    if (illumination <= 0.0f) return 0.0f;
    float3 m = u.moonDirection.xyz;
    float radius = u.keyLight.w;
    float angle = acos(clamp(dot(d, m), -1.0f, 1.0f));
    float3 color = float3(0.80f, 0.86f, 1.0f) * exp(-angle / (radius * 1.6f)) * 0.0025f * illumination;
    if (angle < radius * 1.02f) {
        float3 axis = abs(m.y) > 0.98f ? float3(1.0f, 0.0f, 0.0f) : float3(0.0f, 1.0f, 0.0f);
        float3 mx = normalize(cross(axis, m));
        float3 my = cross(m, mx);
        float2 local = float2(dot(d, mx), dot(d, my)) / sin(radius);
        float rr = dot(local, local);
        // The visible hemisphere faces back toward the viewer; the sun lights
        // it from its true direction, so the phase and bright limb are exact.
        float3 n = normalize(local.x * mx + local.y * my - sqrt(saturate(1.0f - rr)) * m);
        float lit = saturate(dot(n, u.sunDirection.xyz) * 1.05f + 0.02f);
        float maria = float(shape.sample(rep, float3(local * 0.3f + 0.31f, 0.67f)).r);
        float albedo = mix(0.52f, 1.0f, smoothstep(0.3f, 0.75f, maria));
        float edge = 1.0f - smoothstep(0.97f, 1.0f, sqrt(rr));
        color += float3(1.0f, 0.97f, 0.93f) * albedo * (lit * 0.07f + 0.004f) * edge;
    }
    return color * smoothstep(-0.01f, 0.02f, d.y);
}

fragment half4 weatherComposite(WXScreen in [[stage_in]], constant WXUniforms &u [[buffer(2)]],
                                texture2d<half> sky [[texture(0)]], texture2d<half> clouds [[texture(1)]],
                                texture3d<half> shape [[texture(2)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    constexpr sampler rep(coord::normalized, address::repeat, filter::linear);
    float2 uv = in.uv;
    float3 d = wxRay(uv, u);
    float phase = u.cameraUp.w;
    float3 color = wxOvercast(float3(sky.sample(s, uv).rgb), u);
    if (u.composition.w > 0.5f) color += (wxSun(d, u) + wxMoon(d, u, shape)) * (1.0f - wxOvercastAmount(u) * 0.8f);

    // Clouds drift between their re-renders by reprojecting the last one.
    float4 cloud = float4(clouds.sample(s, uv - u.cloudShift.xy));
    color = color * (1.0f - cloud.a) + cloud.rgb;

    // Thin cloud over the moon scatters it into a soft corona.
    if (u.composition.w > 0.5f && u.moonDirection.w > 0.0f) {
        float angle = acos(clamp(dot(d, u.moonDirection.xyz), -1.0f, 1.0f));
        float thin = saturate(cloud.a * (1.0f - cloud.a) * 4.0f);
        color += float3(0.80f, 0.86f, 1.0f) * exp(-angle / (u.keyLight.w * 6.0f)) * 0.012f * u.moonDirection.w * thin;
    }

    if (u.strike.w > 0.0f) {
        float2 delta = (uv - u.strike.xy) * float2(u.viewport.x * u.viewport.w, 1.0f);
        // The flash lights the cloud mass unevenly around the stroke.
        float glow = exp(-length(delta) / u.strike.z);
        float mass = float(shape.sample(rep, float3(uv * float2(2.4f, 1.6f), 0.83f)).r);
        glow *= 0.25f + 1.1f * mass * mass;
        color += float3(0.70f, 0.76f, 1.0f) * u.strike.w * (glow * (0.1f + cloud.a * 0.8f) + 0.04f);
    }

    float rain = u.precipitation.x;
    if (rain > 0.01f) {
        // Distant rain shafts: vertically stretched cells sliding down, slanted by the wind.
        float slant = u.wind.z * 0.35f;
        float streak = float(shape.sample(rep, float3((uv.x + uv.y * slant) * 4.0f, uv.y * 0.5f - phase * 0.3f, 0.21f)).g);
        float curtain = smoothstep(0.55f, 1.0f, streak) * rain * 0.22f * smoothstep(0.05f, 0.45f, uv.y);
        color = mix(color, float3(dot(color, wxLuma)) * 0.8f, curtain);
    }

    float fog = u.atmosphere.x;
    float haze = u.atmosphere.y;
    if (fog > 0.001f || haze > 0.001f) {
        float3 horizon = wxOvercast(float3(sky.sample(s, float2(uv.x, 0.96f)).rgb), u);
        float luminance = dot(horizon, wxLuma);
        if (fog > 0.001f) {
            float3 fogColor = mix(float3(luminance), horizon, 0.3f) * 0.5f
                + u.sunRadiance.rgb * 0.002f * pow(saturate(dot(d, u.sunDirection.xyz)), 6.0f);
            float n = float(shape.sample(rep, float3(uv.x * 1.3f + phase * 0.006f + u.wind.x * 0.02f, uv.y * 0.6f, phase * 0.003f)).r);
            // Thickest near the ground, thinning overhead.
            float density = fog * (0.2f + 0.8f * exp(-(1.0f - uv.y) * 3.0f)) * (0.7f + 0.6f * n);
            color = mix(color, fogColor, saturate(density) * 0.85f);
        }
        if (haze > 0.001f) {
            // Smoke and dust both veil the sky and stain the light passing through.
            float own = max(dot(color, wxLuma), 0.0005f);
            color = mix(color, u.hazeTint.rgb * own, saturate(haze * 1.5f * (0.75f + 0.25f * uv.y)));
            color *= mix(float3(1.0f), u.hazeTint.rgb * 0.75f, haze * 0.8f);
        }
    }

    float3 display = wxSRGB(wxToneMap(color * u.keyColor.w));
    display = wxThemeColor(display, u);
    float alpha = wxCoverage(uv, u);
    // A tiny deterministic dither stops banding in dark gradients.
    display = saturate(display + (wxHash12(in.position.xy) - 0.5f) / 255.0f);
    return half4(half3(display * alpha), half(alpha));
}

// MARK: - Stars (instanced, additive, only on dark themes)

struct WXStarOut {
    float4 position [[position]];
    float2 local;
    float3 color;
    float2 cloudUV;
    float2 uv;
};

vertex WXStarOut weatherStarVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                   const device WXStar *stars [[buffer(0)]], constant WXUniforms &u [[buffer(2)]]) {
    WXStar star = stars[iid];
    float3 e = star.equatorial.xyz;
    float3 w = float3(dot(u.equatorialX.xyz, e), dot(u.equatorialY.xyz, e), dot(u.equatorialZ.xyz, e));
    float z = dot(w, u.cameraForward.xyz);
    float2 center = float2(dot(w, u.cameraRight.xyz) / (max(z, 1e-3f) * u.cameraForward.w),
                           dot(w, u.cameraUp.xyz) / (max(z, 1e-3f) * u.cameraRight.w));
    float magnitude = star.equatorial.w;
    float elevation = saturate(w.y / 0.3f);
    // Perceptual compression keeps faint stars visible but subordinate.
    float brightness = pow(clamp(pow(10.0f, -0.4f * (magnitude - 1.5f)), 0.0f, 3.0f), 0.34f) * mix(0.3f, 1.0f, elevation);
    float seed = star.color.w;
    float t = u.cameraUp.w;
    float scintillation = 0.16f + 0.3f * (1.0f - elevation);
    float twinkle = 1.0f + scintillation * sin(t * (3.0f + seed * 4.0f) + seed * 80.0f) * sin(t * (1.3f + seed) + seed * 12.0f);
    float size = (1.5f + max(0.0f, 2.5f - magnitude) * 0.8f) * max(u.viewport.y / 900.0f, 0.8f);
    float2 corner = float2((vid & 1u) ? 1.0f : -1.0f, (vid & 2u) ? 1.0f : -1.0f);
    bool visible = z > 0.05f && w.y > -0.02f && u.atmosphere.w > 0.0f;
    WXStarOut out;
    out.position = visible ? float4(center + corner * size * 2.0f * u.viewport.zw * 2.0f, 0.0f, 1.0f) : float4(2.0f, 2.0f, 0.0f, 1.0f);
    out.local = corner * 2.0f;
    out.color = star.color.rgb * brightness * twinkle * u.atmosphere.w;
    out.uv = float2(center.x * 0.5f + 0.5f, 0.5f - center.y * 0.5f);
    out.cloudUV = out.uv - u.cloudShift.xy;
    return out;
}

fragment half4 weatherStarFragment(WXStarOut in [[stage_in]], constant WXUniforms &u [[buffer(2)]],
                                   texture2d<half> clouds [[texture(1)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float r2 = dot(in.local, in.local);
    float core = exp(-r2 * 2.2f) + 0.12f * exp(-r2 * 0.6f);
    float clear = 1.0f - float(clouds.sample(s, in.cloudUV).a);
    float3 color = in.color * core * clear * (1.0f - u.atmosphere.x * 0.9f) * (1.0f - u.atmosphere.y * 0.6f);
    return half4(half3(saturate(color) * wxPointCoverage(in.uv, u)), 0.0h);
}

// MARK: - Lightning channel (dark themes)

struct WXBoltOut {
    float4 position [[position]];
    float2 pixel;
    float2 a [[flat]];
    float2 b [[flat]];
    float width [[flat]];
    float brightness [[flat]];
    float2 uv;
};

vertex WXBoltOut weatherBoltVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                   constant WXBoltSegment *segments [[buffer(0)]], constant WXUniforms &u [[buffer(2)]]) {
    WXBoltSegment segment = segments[iid];
    float2 size = u.viewport.xy;
    float2 a = segment.ends.xy * size, b = segment.ends.zw * size;
    float width = segment.style.x * max(size.y / 900.0f, 0.8f);
    float reach = width * 8.0f;
    float2 axis = b - a;
    float2 dir = length(axis) > 1e-3f ? normalize(axis) : float2(0.0f, 1.0f);
    float2 side = float2(-dir.y, dir.x);
    float2 corner = float2((vid & 1u) ? 1.0f : -1.0f, (vid & 2u) ? 1.0f : -1.0f);
    float2 p = (corner.y > 0.0f ? b : a) + dir * corner.y * reach + side * corner.x * reach;
    WXBoltOut out;
    out.position = float4(p.x / size.x * 2.0f - 1.0f, 1.0f - p.y / size.y * 2.0f, 0.0f, 1.0f);
    out.pixel = p;
    out.a = a;
    out.b = b;
    out.width = width;
    out.brightness = segment.style.y;
    out.uv = p / size;
    return out;
}

fragment half4 weatherBoltFragment(WXBoltOut in [[stage_in]], constant WXUniforms &u [[buffer(2)]]) {
    float2 pa = in.pixel - in.a, ba = in.b - in.a;
    float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-4f));
    float gap = length(pa - ba * h);
    float core = exp(-(gap * gap) / (in.width * in.width));
    float glow = exp(-gap / (in.width * 3.0f)) * 0.25f;
    float3 color = float3(0.86f, 0.90f, 1.0f) * (core + glow) * in.brightness * u.atmosphere.z;
    return half4(half3(saturate(color) * wxCoverage(in.uv, u)), 0.0h);
}

// MARK: - Precipitation (instanced; positions are a pure function of time)

struct WXParticle {
    float4 position [[position]];
    float2 local;
    float3 color;
    float alpha;
    float softness [[flat]];
    float snow [[flat]];
    float2 uv;
};

/// params: kind (0 rain, 1 snow, 2 pellets), instance count, unused, unused.
vertex WXParticle weatherParticleVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                        constant WXUniforms &u [[buffer(2)]], constant float4 &params [[buffer(3)]]) {
    float kind = params.x;
    float index = float(iid);
    float h1 = wxHash11(index * 1.37f + kind * 17.1f + 0.5f);
    float h2 = wxHash11(index * 2.71f + kind * 3.3f + 3.3f);
    float h3 = wxHash11(index * 0.613f + kind * 5.9f + 7.7f);
    float h4 = wxHash11(index * 5.17f + kind * 1.3f + 1.9f);
    uint layer = iid % 3u;
    float depth = layer == 0u ? 0.55f : (layer == 1u ? 0.8f : 1.15f);
    float t = u.cameraUp.w;
    float aspect = u.viewport.x * u.viewport.w;
    float pixelScale = max(u.viewport.y / 900.0f, 0.6f);
    float windX = u.wind.z * (1.0f + u.precipitation.w * 0.45f * sin(t * 0.7f + h3 * 6.283f));
    bool snow = kind > 0.5f && kind < 1.5f;
    bool pellet = kind > 1.5f;

    float2 center, along;
    float lengthPx, widthPx, alpha, softness = 0.0f;
    float3 color;
    if (snow) {
        float speed = 0.075f * depth * (0.8f + 0.4f * h2) * (1.0f + u.wind.w * 0.4f);
        float y = fract(h1 + t * speed / 1.2f) * 1.2f - 0.1f;
        float sway = sin(t * (0.5f + h4 * 0.7f) + h1 * 31.0f) * 0.012f * depth;
        center = float2(fract(h3 + windX * 0.3f * y / aspect + sway), y);
        along = float2(0.0f, 1.0f);
        float size = (layer == 0u ? 1.6f : (layer == 1u ? 2.6f : 4.6f)) * (0.75f + 0.5f * h4) * pixelScale;
        lengthPx = size * 2.0f;
        widthPx = size * 2.0f;
        softness = layer == 0u ? 0.3f : (layer == 1u ? 0.45f : 0.75f);
        alpha = (layer == 2u ? 0.75f : 0.6f) * (0.85f + 0.15f * sin(t * 2.3f + h2 * 40.0f));
        color = u.snowColor.rgb;
    } else {
        float speed = (pellet ? 0.9f : 1.25f) * depth * (0.9f + 0.2f * h2);
        float y = fract(h1 + t * speed / 1.25f) * 1.25f - 0.12f;
        float slant = windX * 0.42f;
        center = float2(fract(h3 + slant * y / aspect), y);
        along = normalize(float2(slant, 1.0f));
        lengthPx = (pellet ? 10.0f : 34.0f) * depth * pixelScale * (0.8f + 0.4f * h4);
        widthPx = (pellet ? 2.2f : 1.15f) * (0.7f + 0.5f * depth) * pixelScale;
        alpha = (pellet ? 0.55f : 0.30f) * (0.45f + 0.55f * depth);
        color = u.rainColor.rgb;
    }
    // Instances fade in as the count rises, so intensity changes never pop.
    alpha *= saturate(params.y - index);

    float2 corner = float2((vid & 1u) ? 1.0f : -1.0f, (vid & 2u) ? 1.0f : -1.0f);
    float2 side = float2(-along.y, along.x);
    float halfLength = lengthPx * 0.5f + 1.0f, halfWidth = widthPx * 0.5f + 1.0f;
    float2 offset = along * corner.y * halfLength + side * corner.x * halfWidth;
    WXParticle out;
    out.position = float4(center.x * 2.0f - 1.0f + offset.x * 2.0f * u.viewport.z,
                          1.0f - center.y * 2.0f - offset.y * 2.0f * u.viewport.w, 0.0f, 1.0f);
    out.local = float2(corner.x * halfWidth / max(widthPx * 0.5f, 0.5f), corner.y * halfLength / max(lengthPx * 0.5f, 0.5f));
    out.color = color;
    out.alpha = alpha;
    out.softness = softness;
    out.snow = snow ? 1.0f : 0.0f;
    out.uv = center;
    return out;
}

fragment half4 weatherParticleFragment(WXParticle in [[stage_in]], constant WXUniforms &u [[buffer(2)]]) {
    float shape;
    if (in.snow > 0.5f) {
        shape = 1.0f - smoothstep(1.0f - in.softness, 1.0f, length(in.local));
    } else {
        // A thin motion-blurred streak, brighter at its leading (lower) end.
        float across = 1.0f - smoothstep(0.35f, 1.0f, abs(in.local.x));
        float along = 1.0f - smoothstep(0.55f, 1.0f, abs(in.local.y));
        shape = across * along * mix(0.35f, 1.0f, in.local.y * 0.5f + 0.5f);
    }
    float alpha = shape * in.alpha * wxPointCoverage(in.uv, u);
    return half4(half3(wxThemeColor(in.color, u) * alpha), half(alpha));
}
