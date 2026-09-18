// Aquarium.metal
// rootshell
// HDR forward renderer: deformed meshes, soft shadows, water caustics, thin fins,
// particulate scattering, quarter-resolution bloom, and theme-aware compositing.
// All temporal frequencies are integer multiples of 1/256. The Swift clock can
// wrap at 512*pi without a discontinuity or loss of long-session float precision.

#include <metal_stdlib>
using namespace metal;

struct AQVertex { float4 position; float4 normal; float4 uv; };
struct AQInstance { float4x4 model; float4 parameters; float4 tint; };
struct AQUniforms {
    float4x4 viewProjection;
    float4x4 lightProjection;
    float4 cameraTime;
    float4 lightDirection;
    float4 lightColor;
    float4 waterColor;
    float4 fillColor;
    float4 viewport;
    float4 optics;
    float4 composition;
    float4 environment;
};
struct AQSurface {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float3 local;
    float2 uv;
    float4 parameters [[flat]];
    float4 tint [[flat]];
    float part [[flat]];
};
struct AQScreen { float4 position [[position]]; float2 uv; };

static float aqHash(float3 p) {
    p = fract(p * 0.1031f);
    p += dot(p, p.yzx + 33.33f);
    return fract((p.x + p.y) * p.z);
}
static float aqNoise(float3 p) {
    float3 i = floor(p), f = fract(p);
    f = f * f * (3.0f - 2.0f * f);
    return mix(mix(mix(aqHash(i), aqHash(i + float3(1,0,0)), f.x),
                   mix(aqHash(i + float3(0,1,0)), aqHash(i + float3(1,1,0)), f.x), f.y),
               mix(mix(aqHash(i + float3(0,0,1)), aqHash(i + float3(1,0,1)), f.x),
                   mix(aqHash(i + float3(0,1,1)), aqHash(i + float3(1,1,1)), f.x), f.y), f.z);
}
static float aqBand(float x, float center, float width, float feather) {
    return 1.0f - smoothstep(width, width + feather, abs(x - center));
}
static float aqCaustics(float3 world, float t) {
    float2 p = world.xz * 2.2f + world.y * float2(0.35f, 0.24f);
    p += float2(sin(t * 0.125f), cos(t * 0.0625f)) * 0.65f;
    float a = sin(p.x + 0.78f * sin(p.y + t * 0.1875f));
    float b = sin(p.y - 0.70f * cos(p.x - t * 0.125f));
    float line = pow(saturate(1.0f - abs(a + b)), 15.0f);
    float second = pow(saturate(1.0f - abs(sin(p.x * 1.73f - t * 0.0625f)
                       + sin(p.y * 1.61f + t * 0.125f))), 19.0f);
    return line * 0.70f + second * 0.30f;
}

// Both color and shadow passes call exactly the same deformation function.
static void aqDeform(thread float3 &p, thread float3 &n, AQVertex inputVertex,
                     AQInstance instance, constant AQUniforms &u) {
    int kind = int(instance.parameters.x + 0.5f);
    if (kind < 5) {
        float tail = clamp((0.55f - p.x) / 1.90f, 0.0f, 1.25f);
        float wave = p.x * 3.8f + instance.parameters.z;
        float amplitude = 0.24f * tail * tail;
        float derivative = -0.48f * tail / 1.90f * sin(wave) + amplitude * 3.8f * cos(wave);
        p.z += amplitude * sin(wave);
        // Inverse-transpose Jacobian of z += f(x), not the undeformed normals.
        n.x -= derivative * n.z;
        if (inputVertex.position.w > 0.5f && inputVertex.position.w < 1.5f) {
            float flutterPhase = instance.parameters.z * 2.0f + p.x * 8.0f + p.y * 6.0f;
            float flutterAmplitude = 0.027f * inputVertex.uv.y;
            p.z += sin(flutterPhase) * flutterAmplitude;
            n.xy -= cos(flutterPhase) * flutterAmplitude * float2(8,6) * n.z;
        }
    } else if (kind == 6) {
        float y = max(p.y, 0.0f);
        float t = u.cameraTime.w;
        float phase = instance.parameters.y;
        float strength = instance.parameters.w;
        float bend = y * y * 0.027f;
        float a = t * 0.4375f + y * 0.67f + phase;
        float b = t * 0.75f + y * 1.7f + phase * 1.3f;
        float dx = strength * (bend * sin(a) + 0.022f * y * sin(b));
        float dz = strength * bend * 0.60f * cos(t * 0.3125f + y * 0.81f + phase);
        float dxdy = strength * (0.054f * y * sin(a) + bend * 0.67f * cos(a)
                                 + 0.022f * sin(b) + 0.0374f * y * cos(b));
        float zPhase = t * 0.3125f + y * 0.81f + phase;
        float dzdy = strength * 0.60f * (0.054f * y * cos(zPhase) - bend * 0.81f * sin(zPhase));
        p.x += dx; p.z += dz;
        n.y -= dxdy * n.x + dzdy * n.z;
    }
}

vertex AQSurface aquariumVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                               const device AQVertex *vertices [[buffer(0)]],
                               const device AQInstance *instances [[buffer(1)]],
                               constant AQUniforms &u [[buffer(2)]]) {
    AQVertex v = vertices[vid];
    AQInstance instance = instances[iid];
    float3 p = v.position.xyz, n = v.normal.xyz;
    aqDeform(p, n, v, instance, u);
    float3 world = (instance.model * float4(p, 1)).xyz;
    float3 x = instance.model[0].xyz, y = instance.model[1].xyz, z = instance.model[2].xyz;
    float3 normal = normalize(x * n.x / max(dot(x,x), 1e-6f)
                            + y * n.y / max(dot(y,y), 1e-6f)
                            + z * n.z / max(dot(z,z), 1e-6f));
    if (instance.parameters.x >= 8.0f) {
        // Camera-facing billboards. The camera is fixed; its vertical tilt is 1.65/13.
        float3 up = normalize(float3(0, 13, -1.65f));
        world = instance.model[3].xyz + float3(1,0,0) * p.x * length(x) + up * p.y * length(y);
        normal = normalize(u.cameraTime.xyz - world);
    }
    AQSurface out;
    out.position = u.viewProjection * float4(world, 1);
    out.world = world; out.normal = normal; out.local = v.position.xyz;
    out.uv = v.uv.xy; out.parameters = instance.parameters; out.tint = instance.tint; out.part = v.position.w;
    return out;
}

vertex float4 aquariumShadowVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                   const device AQVertex *vertices [[buffer(0)]],
                                   const device AQInstance *instances [[buffer(1)]],
                                   constant AQUniforms &u [[buffer(2)]]) {
    AQVertex v = vertices[vid];
    AQInstance instance = instances[iid];
    float3 p = v.position.xyz, n = v.normal.xyz;
    aqDeform(p, n, v, instance, u);
    return u.lightProjection * instance.model * float4(p, 1);
}

vertex AQScreen aquariumScreenVertex(uint vid [[vertex_id]]) {
    float2 uv = float2((vid << 1) & 2, vid & 2);
    AQScreen out;
    out.position = float4(uv * float2(2,-2) + float2(-1,1), 0, 1);
    out.uv = uv;
    return out;
}

static float aqShadow(float3 world, float nDotL, depth2d<float> shadow, constant AQUniforms &u) {
    constexpr sampler compareSampler(coord::normalized, address::clamp_to_edge, filter::linear, compare_func::less_equal);
    float4 light = u.lightProjection * float4(world, 1);
    float3 ndc = light.xyz / light.w;
    float2 uv = ndc.xy * float2(0.5f, -0.5f) + 0.5f;
    if (any(uv < 0) || any(uv > 1) || ndc.z < 0 || ndc.z > 1) return 1;
    float bias = max(0.00045f, 0.0018f * (1 - nDotL));
    float value = 0;
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            value += shadow.sample_compare(compareSampler, uv + float2(x,y) * u.environment.y, ndc.z - bias);
        }
    }
    return value / 9;
}

struct AQMaterial { float3 albedo; float roughness; float metallic; float transmission; float alpha; float emission; };

static AQMaterial aqMaterial(AQSurface in) {
    AQMaterial m = {float3(0.4f), 0.38f, 0.03f, 0.0f, 1.0f, 0.0f};
    int kind = int(in.parameters.x + 0.5f);
    float3 p = in.local;
    if (kind < 5) {
        if (kind == 0) {
            m.albedo = float3(0.95f, 0.20f, 0.019f);
            float bars = max(aqBand(p.x, 0.42f, 0.095f, 0.012f),
                         max(aqBand(p.x + p.y * 0.24f, -0.18f, 0.095f, 0.016f), aqBand(p.x, -0.69f, 0.06f, 0.012f)));
            float edges = max(aqBand(p.x, 0.42f, 0.132f, 0.014f),
                          max(aqBand(p.x + p.y * 0.24f, -0.18f, 0.136f, 0.015f), aqBand(p.x, -0.69f, 0.089f, 0.012f)));
            m.albedo = mix(m.albedo, float3(0.013f,0.019f,0.022f), edges);
            m.albedo = mix(m.albedo, float3(0.94f,0.91f,0.74f), bars);
        } else if (kind == 1) {
            m.albedo = float3(0.012f, 0.11f, 0.72f);
            float patch = smoothstep(-0.65f, -0.1f, p.x) * (1 - smoothstep(0.25f,0.50f,p.x));
            patch *= smoothstep(-0.1f, 0.04f, p.y - 0.14f * sin(p.x * 4));
            float rim = aqBand(p.y, 0.38f, 0.065f, 0.06f);
            m.albedo = mix(m.albedo, float3(0.008f,0.019f,0.045f), max(patch, rim) * 0.96f);
            if (p.x < -0.89f) m.albedo = float3(0.98f,0.76f,0.024f);
        } else if (kind == 2) {
            m.albedo = mix(float3(0.96f,0.57f,0.018f), float3(0.88f,0.87f,0.45f), smoothstep(-0.25f,0.4f,p.y));
            float eyeBand = aqBand(p.x + 0.12f * p.y, 0.57f, 0.10f, 0.025f);
            float rear = aqBand(p.x, -0.64f, 0.056f, 0.015f);
            m.albedo = mix(m.albedo, float3(0.018f,0.024f,0.022f), max(eyeBand, rear));
            float chevron = 0.90f + 0.10f * sin((p.x + abs(p.y) * 0.43f) * 64);
            m.albedo *= chevron;
        } else if (kind == 3) {
            m.albedo = mix(float3(0.59f,0.65f,0.62f), float3(0.71f,0.49f,0.22f), smoothstep(0.25f,0.82f,p.x) * 0.6f);
            float bands = pow(saturate(0.5f + 0.5f * sin((p.x + 0.16f) * 12.0f)), 5.0f);
            m.albedo = mix(m.albedo, float3(0.017f,0.027f,0.027f), bands * 0.94f);
            m.metallic = 0.23f;
        } else {
            m.albedo = float3(0.15f,0.23f,0.16f);
            float cyan = aqBand(p.y - 0.03f * sin(p.x * 2), 0.055f, 0.046f, 0.016f);
            float red = (1 - smoothstep(-0.03f,0.03f,p.y)) * (1 - smoothstep(0.15f,0.35f,p.x));
            m.albedo = mix(m.albedo, float3(0.81f,0.012f,0.034f), red);
            m.albedo = mix(m.albedo, float3(0.025f,0.73f,0.98f), cyan);
            m.metallic = 0.20f; m.emission = cyan * 0.075f;
        }
        // Pigment is darker dorsally and pearlescent toward the belly.
        m.albedo *= mix(1.08f, 0.69f, smoothstep(-0.1f,0.42f,p.y));
        float2 scaleUV = in.uv * float2(54, 28);
        scaleUV.x += step(0.5f, fract(floor(scaleUV.y) * 0.5f)) * 0.5f;
        float2 cell = fract(scaleUV) - 0.5f;
        float scaleEdge = smoothstep(0.31f, 0.48f, length(cell * float2(1, 1.6f)));
        float resolved = 1 - smoothstep(0.18f, 0.75f, max(fwidth(scaleUV.x), fwidth(scaleUV.y)));
        m.albedo *= 1 - scaleEdge * 0.085f * resolved;
        m.roughness = 0.25f + scaleEdge * 0.13f;
        // A curved operculum just behind the eye.
        float gill = aqBand(p.x + 0.45f * p.y * p.y, 0.32f, 0.008f, 0.013f)
                   * (1 - smoothstep(0.24f,0.38f,abs(p.y)));
        m.albedo *= 1 - gill * 0.32f;
        if (in.part > 0.5f && in.part < 1.5f) {
            float rib = pow(saturate(0.5f + 0.5f * sin(in.uv.y * 115 + in.uv.x * 12)), 8.0f);
            m.albedo = mix(m.albedo, float3(0.70f,0.76f,0.61f), 0.16f);
            if (kind == 0 && p.x < -0.88f) m.albedo = float3(0.76f,0.24f,0.041f);
            m.alpha = 0.54f + 0.31f * rib;
            m.transmission = 0.60f; m.roughness = 0.43f;
        } else if (in.part > 1.5f && in.part < 2.5f) {
            m.albedo = float3(0.003f,0.008f,0.013f); m.roughness = 0.075f; m.metallic = 0.0f;
        } else if (in.part > 2.5f) {
            m.albedo = float3(0.58f,0.37f,0.11f); m.roughness = 0.23f; m.metallic = 0.24f;
        }
    } else if (kind == 5) {
        float grain = aqNoise(in.world * 28);
        float ripple = sin(in.world.x * 13 + sin(in.world.z * 2) * 2.7f) * 0.5f + 0.5f;
        m.albedo = mix(float3(0.24f,0.25f,0.19f), float3(0.43f,0.40f,0.27f), grain * 0.6f + ripple * 0.4f);
        m.roughness = 0.86f; m.metallic = 0;
    } else if (kind == 6) {
        float variation = 0.5f + 0.5f * sin(in.parameters.y * 3.1f);
        m.albedo = mix(float3(0.055f,0.15f,0.023f), float3(0.22f,0.25f,0.040f), variation);
        m.albedo *= 0.83f + 0.17f * sin(in.uv.x * 54 + in.uv.y * 8);
        float vein = aqBand(in.uv.y,0.5f,0.018f,0.025f);
        m.albedo += vein * float3(0.037f,0.050f,0.011f);
        m.transmission = 0.43f; m.roughness = 0.34f;
    } else {
        float n = aqNoise(in.local * 7) * 0.65f + aqNoise(in.local * 19) * 0.35f;
        m.albedo = mix(float3(0.075f,0.11f,0.12f),float3(0.29f,0.31f,0.25f),n);
        float moss = smoothstep(0.2f,0.8f,in.normal.y) * smoothstep(0.40f,0.7f,n);
        m.albedo = mix(m.albedo,float3(0.073f,0.13f,0.036f),moss * 0.65f);
        m.roughness = 0.84f; m.metallic = 0;
    }
    m.albedo *= in.tint.rgb;
    return m;
}

fragment half4 aquariumSurfaceFragment(AQSurface in [[stage_in]],
                                      constant AQUniforms &u [[buffer(2)]],
                                      depth2d<float> shadow [[texture(0)]]) {
    AQMaterial m = aqMaterial(in);
    float3 N = normalize(in.normal);
    float3 V = normalize(u.cameraTime.xyz - in.world);
    // Double-sided fins and kelp have physically meaningful back lighting.
    if ((int(in.parameters.x) == 6 || in.part == 1) && dot(N,V) < 0) N = -N;
    float3 L = normalize(u.lightDirection.xyz);
    float3 H = normalize(L + V);
    float nDotL = saturate(dot(N,L)), nDotV = max(saturate(dot(N,V)),0.001f);
    float nDotH = saturate(dot(N,H)), vDotH = saturate(dot(V,H));
    float a = max(m.roughness * m.roughness,0.015f), a2 = a*a;
    float denominator = nDotH*nDotH*(a2-1)+1;
    float D = a2 / max(M_PI_F * denominator * denominator,1e-5f);
    float k = (m.roughness + 1)*(m.roughness + 1)/8;
    float G = nDotV/(nDotV*(1-k)+k) * nDotL/(nDotL*(1-k)+k);
    float3 F0 = mix(float3(0.045f),m.albedo,m.metallic);
    float3 F = F0 + (1-F0)*pow(1-vDotH,5.0f);
    float3 specular = D * G * F / max(4*nDotV*nDotL,0.001f);
    float visibility = aqShadow(in.world,nDotL,shadow,u);
    float caustic = aqCaustics(in.world,u.cameraTime.w) * u.optics.x;
    float3 irradiance = u.lightColor.rgb * u.lightDirection.w * (2.4f + caustic*3.0f);
    float3 diffuse = m.albedo * (1-F) * (1-m.metallic) / M_PI_F;
    float3 color = (diffuse + specular) * irradiance * nDotL * mix(0.16f,1.0f,visibility);
    float ambient = 0.65f + 0.35f * saturate(N.y*0.5f+0.5f);
    color += m.albedo * (u.fillColor.rgb * 1.65f + u.lightColor.rgb*0.11f) * ambient;
    color += m.albedo * u.lightColor.rgb * m.transmission * pow(saturate(dot(-N,L)),1.5f) * 0.55f;
    color += m.albedo * m.emission;
    // Blue-green rim reflection off the front glass/water interface.
    color += u.fillColor.rgb * pow(1-nDotV,4.0f) * 0.23f;
    float distance = max(length(u.cameraTime.xyz-in.world)-7.0f,0.0f);
    float transmission = exp(-distance * (0.024f + u.optics.y*0.105f));
    float3 fog = u.waterColor.rgb * 0.65f + u.fillColor.rgb * 0.065f;
    color = mix(fog,color,transmission);
    float alpha = m.alpha * in.tint.a;
    return half4(half3(max(color,0.0f)*alpha),half(alpha));
}

fragment half4 aquariumWaterFragment(AQScreen in [[stage_in]], constant AQUniforms &u [[buffer(2)]]) {
    float2 uv = in.uv;
    float t = u.cameraTime.w;
    float depth = smoothstep(0.02f,1.0f,uv.y);
    float3 color = u.waterColor.rgb * mix(1.25f,0.19f,depth) + u.fillColor.rgb * 0.017f;
    // Broad scattering cones with narrow internal shafts. This is an analytic
    // background approximation, not an expensive per-pixel volume ray march.
    float source = 0.43f + u.lightDirection.x*0.20f;
    float spread = 0.12f + uv.y*0.56f;
    float cone = exp(-pow((uv.x-source+uv.y*u.lightDirection.x*0.18f)/spread,2.0f)*1.9f);
    float rays = 0;
    for (int i=0;i<6;++i) {
        float f = float(i);
        float center = source + (f-2.5f)*0.063f + uv.y*(f-2.7f)*0.052f;
        center += sin(t*0.125f + f*2.1f + uv.y*2.0f)*0.012f;
        float width = 0.005f + uv.y*0.019f;
        rays += exp(-pow((uv.x-center)/width,2.0f)) * (0.7f+0.3f*sin(f*4.0f));
    }
    color += u.lightColor.rgb * u.lightDirection.w * (cone*0.055f + rays*0.072f)
           * exp(-uv.y*2.5f) * (0.4f + u.optics.y*0.6f);
    float ripple = pow(saturate(sin(uv.x*34 + sin(uv.x*17+t*0.25f)*1.7f)),8.0f);
    color += u.lightColor.rgb * ripple * exp(-uv.y*30) * u.optics.x * 0.075f;
    return half4(half3(max(color,0.0f)),1);
}

fragment half4 aquariumParticleFragment(AQSurface in [[stage_in]], constant AQUniforms &u [[buffer(2)]]) {
    float2 p = in.uv*2-1;
    float radius = length(p);
    if (radius > 1) discard_fragment();
    float alpha;
    float3 color;
    if (in.parameters.x < 8.5f) {
        float edge = pow(saturate(radius),7.0f) * (1-smoothstep(0.90f,1.0f,radius));
        float glint = exp(-dot(p-float2(-0.32f,0.42f),p-float2(-0.32f,0.42f))*52.0f);
        float lower = exp(-dot(p-float2(0.32f,-0.55f),p-float2(0.32f,-0.55f))*80.0f);
        alpha = (edge*0.63f + glint*0.82f + lower*0.23f) * in.tint.a;
        color = u.lightColor.rgb * (0.72f + glint*2.5f) + u.fillColor.rgb*0.3f;
    } else {
        alpha = exp(-radius*radius*5.0f)*(1-smoothstep(0.7f,1.0f,radius))*in.tint.a;
        color = u.lightColor.rgb*0.42f + u.fillColor.rgb*0.26f;
    }
    float fog = exp(-max(length(u.cameraTime.xyz-in.world)-7.0f,0.0f)*(0.04f+u.optics.y*0.12f));
    alpha *= fog;
    return half4(half3(color*alpha),half(alpha));
}

fragment half4 aquariumBloomThreshold(AQScreen in [[stage_in]], texture2d<half> source [[texture(0)]]) {
    constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
    float2 pixel = 1.0f / float2(source.get_width(),source.get_height());
    float3 color = float3(0);
    for (int y=-1;y<=1;y+=2) for (int x=-1;x<=1;x+=2)
        color += float3(source.sample(s,in.uv+float2(x,y)*pixel*1.1f).rgb)*0.25f;
    float luminance = max(color.r,max(color.g,color.b));
    float knee = smoothstep(0.45f,1.1f,luminance);
    return half4(half3(color*knee),1);
}

fragment half4 aquariumBloomBlur(AQScreen in [[stage_in]], texture2d<half> source [[texture(0)]],
                                constant float4 &direction [[buffer(0)]]) {
    constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
    float2 offset = direction.xy;
    half3 color = source.sample(s,in.uv).rgb*half(0.227027f);
    color += (source.sample(s,in.uv+offset*1.384615f).rgb+source.sample(s,in.uv-offset*1.384615f).rgb)*half(0.316216f);
    color += (source.sample(s,in.uv+offset*3.230769f).rgb+source.sample(s,in.uv-offset*3.230769f).rgb)*half(0.070270f);
    return half4(color,1);
}

static float3 aqToneMap(float3 x) {
    return saturate((x*(2.51f*x+0.03f))/(x*(2.43f*x+0.59f)+0.14f));
}
static float3 aqSRGB(float3 linear) {
    return select(1.055f*pow(max(linear,0.0f),float3(1.0f/2.4f))-0.055f,12.92f*linear,linear<=0.0031308f);
}

fragment half4 aquariumComposite(AQScreen in [[stage_in]], constant AQUniforms &u [[buffer(2)]],
                                texture2d<half> scene [[texture(0)]], texture2d<half> bloom [[texture(1)]]) {
    constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
    float2 uv = in.uv;
    // The tiny refractive drift affects only the aquarium, never terminal glyphs.
    float2 distortion = float2(sin(uv.y*18+u.cameraTime.w*0.1875f),cos(uv.x*17-u.cameraTime.w*0.125f));
    distortion *= 0.0009f * u.environment.z;
    float3 color = float3(scene.sample(s,clamp(uv+distortion,0.0f,1.0f)).rgb);
    color += float3(bloom.sample(s,uv).rgb)*u.composition.w*0.65f;
    color *= exp2(u.optics.z);
    color = aqSRGB(aqToneMap(color));
    float luminance = dot(color,float3(0.2126f,0.7152f,0.0722f));
    color = max(mix(float3(luminance),color,u.optics.w),0.0f);
    float vignette = 1-smoothstep(0.30f,0.85f,length((uv-0.5f)*float2(0.85f,1.0f)))*0.32f;
    color *= vignette;
    // RootShell uses plusLighter on dark themes and multiply on light themes.
    // Neutral black/white and premultiplied alpha keep both paths predictable.
    if (u.composition.z > 0.5f) color = mix(float3(1),saturate(color*0.88f+0.035f),0.82f);
    float quietCenter = exp(-dot((uv-float2(0.48f,0.42f))*float2(2.0f,1.65f),
                                (uv-float2(0.48f,0.42f))*float2(2.0f,1.65f))*2.0f);
    float alpha = u.composition.x * (1-u.composition.y*quietCenter*0.78f);
    // Small deterministic dither avoids banding in dark water; never adds noise to text.
    float dither = (aqHash(float3(in.position.xy,0.0f))-0.5f)/255.0f;
    color = saturate(color+dither);
    return half4(half3(color*alpha),half(alpha));
}
