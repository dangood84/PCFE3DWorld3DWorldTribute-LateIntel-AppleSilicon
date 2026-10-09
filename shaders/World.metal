#include <metal_stdlib>
#include "body_kind.h"

using namespace metal;

// Same layout as FrameUniforms in src/main.mm. 64 floats, 256 bytes.
struct FrameUniforms {
    float4x4 viewProj;
    float4x4 model;
    float4x4 normalMat;
    float4 camera;
    float4 light;
    float4 params0;  // time, style (0 rust / 1 smooth brown), body kind, unused
    float4 params1;  // viewport width, height, travel, paused
};

struct VertexIn {
    float3 position [[attribute(0)]];
    float3 normal [[attribute(1)]];
    float2 uv [[attribute(2)]];
};

struct VertexOut {
    float4 position [[position]];
    float3 worldPos;
    float3 objectPos;
    float3 normal;
    float2 uv;
};

vertex VertexOut worldVertex(VertexIn in [[stage_in]], constant FrameUniforms &u [[buffer(1)]]) {
    VertexOut out;
    float4 world = u.model * float4(in.position, 1.0);
    out.worldPos = world.xyz;
    out.objectPos = in.position;
    out.position = u.viewProj * world;
    // normalMat is the inverse-transpose. Normalise because the satellite
    // bus is scaled differently on each axis.
    out.normal = normalize((u.normalMat * float4(in.normal, 0.0)).xyz);
    out.uv = in.uv;
    return out;
}

float hash13(float3 p) {
    p = fract(p * 0.1031);
    p += dot(p, p.zyx + 31.32);
    return fract((p.x + p.y) * p.z);
}

float noise3(float3 p) {
    float3 i = floor(p);
    float3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float n000 = hash13(i);
    float n100 = hash13(i + float3(1.0, 0.0, 0.0));
    float n010 = hash13(i + float3(0.0, 1.0, 0.0));
    float n110 = hash13(i + float3(1.0, 1.0, 0.0));
    float n001 = hash13(i + float3(0.0, 0.0, 1.0));
    float n101 = hash13(i + float3(1.0, 0.0, 1.0));
    float n011 = hash13(i + float3(0.0, 1.0, 1.0));
    float n111 = hash13(i + float3(1.0, 1.0, 1.0));
    float x00 = mix(n000, n100, f.x);
    float x10 = mix(n010, n110, f.x);
    float x01 = mix(n001, n101, f.x);
    float x11 = mix(n011, n111, f.x);
    return mix(mix(x00, x10, f.y), mix(x01, x11, f.y), f.z);
}

float fbm(float3 p) {
    float value = 0.0;
    float amplitude = 0.5;
    for (int octave = 0; octave < 5; ++octave) {
        value += amplitude * noise3(p);
        p = p * 2.03 + float3(1.7, 9.2, 2.4);
        amplitude *= 0.5;
    }
    return value;
}

// Interesting: colour comes from the position on the sphere, not from a bitmap.
// A DirectX-era texture would blur when the banana zoom comes in close. This
// stays sharp, and there is no seam where a texture's edges would meet.
float planetHeight(float3 p, float style) {
    if (style < 0.5) {
        float broad = fbm(p * 3.2);
        float crater = fbm(p * 6.5 + 4.0);
        float bowl = smoothstep(0.58, 0.40, crater);
        float rim = smoothstep(0.45, 0.56, crater) * smoothstep(0.72, 0.58, crater);
        return broad * 0.45 - bowl * 0.9 + rim * 1.15;
    }
    return fbm(p * 1.25) * 0.4 + fbm(p * 2.4 + 1.7) * 0.15;
}

float3 planetAlbedo(float3 p, float style, float height) {
    float pole = smoothstep(0.78, 0.97, abs(p.y));
    if (style < 0.5) {
        float broad = fbm(p * 2.1);
        float3 rock = float3(0.20, 0.07, 0.04);
        float3 rust = float3(0.64, 0.24, 0.09);
        float3 ochre = float3(0.80, 0.50, 0.22);
        float3 dust = float3(0.88, 0.72, 0.50);
        float3 albedo = mix(rock, rust, smoothstep(0.30, 0.58, broad));
        albedo = mix(albedo, ochre, smoothstep(0.48, 0.75, fbm(p * 4.6 + 2.0)));
        albedo = mix(albedo, dust, saturate(height * 0.5 + 0.2) * 0.35);
        float streaks = fbm(float3(p.x * 1.5, p.y * 7.5, p.z * 1.5));
        albedo = mix(albedo, albedo * float3(1.22, 0.90, 0.72), smoothstep(0.55, 0.82, streaks) * 0.3);
        albedo *= 0.70 + 0.30 * smoothstep(-0.5, 0.7, height);
        albedo = mix(albedo, float3(0.78, 0.72, 0.64), pole * 0.4);
        return albedo;
    }
    float soft = fbm(p * 1.1);
    float3 cocoa = float3(0.28, 0.15, 0.08);
    float3 clay = float3(0.50, 0.31, 0.16);
    float3 tan = float3(0.72, 0.54, 0.34);
    float3 albedo = mix(cocoa, clay, smoothstep(0.22, 0.72, soft));
    albedo = mix(albedo, tan, smoothstep(0.55, 0.88, fbm(p * 1.9 + 1.2)));
    albedo = mix(albedo, float3(0.88, 0.80, 0.68), pole * 0.8);
    return albedo;
}

float3 bumpedNormal(float3 n, float style, float strength) {
    float3 tangent = normalize(cross(n, abs(n.y) > 0.92 ? float3(1.0, 0.0, 0.0) : float3(0.0, 1.0, 0.0)));
    float3 bitangent = cross(n, tangent);
    float e = 0.04;
    float h = planetHeight(n, style);
    float hx = planetHeight(normalize(n + tangent * e), style);
    float hy = planetHeight(normalize(n + bitangent * e), style);
    return normalize(n + tangent * ((h - hx) / e) * strength + bitangent * ((h - hy) / e) * strength);
}

float3 atmosphereTint(float style) {
    if (style < 0.5) {
        return float3(0.95, 0.48, 0.22);
    }
    return float3(0.78, 0.58, 0.36);
}

float beaconPulse(float time) {
    // A short flash, then a long rest, so it reads as a lamp and not a throb.
    float phase = fract(time * 0.8);
    float flash = smoothstep(0.0, 0.02, phase) * smoothstep(0.18, 0.05, phase);
    return 0.18 + flash;
}

float starsLayer(float3 dir, float scale, float threshold, float time) {
    float3 p = dir * scale;
    float3 cell = floor(p);
    float3 f = fract(p) - 0.5;
    float h = hash13(cell);
    float spark = step(threshold, h);
    float body = smoothstep(0.16, 0.0, length(f)) * spark;
    float twinkle = 0.55 + 0.45 * sin(time * (2.2 + h * 7.0) + h * 40.0);
    return body * twinkle;
}

float3 skyColour(float3 dir, float3 light, float time) {
    float3 colour = float3(0.006, 0.007, 0.014);
    float milky = exp(-pow(dir.y * 0.85 + dir.x * 0.22, 2.0) * 22.0);
    float dust = fbm(dir * 3.5);
    colour += float3(0.22, 0.24, 0.42) * milky * (0.12 + 0.4 * dust);
    colour += float3(0.45, 0.30, 0.18) * milky * dust * 0.08;

    colour += starsLayer(dir, 70.0, 0.972, time) * 1.1;
    colour += starsLayer(dir, 130.0, 0.984, time) * 0.7;

    // A few hand-placed bright stars so the sky is not only a hash grid.
    float3 anchors[6] = {
        float3(0.4, 0.8, 0.2),
        float3(-0.6, 0.3, 0.5),
        float3(0.2, -0.4, 0.8),
        float3(-0.3, 0.7, -0.4),
        float3(0.8, 0.1, -0.3),
        float3(-0.2, -0.6, 0.4),
    };
    for (int i = 0; i < 6; ++i) {
        float d = length(dir - normalize(anchors[i]));
        colour += float3(0.95, 0.94, 0.88) * smoothstep(0.012, 0.0, d);
        colour += float3(0.55, 0.62, 0.85) * smoothstep(0.05, 0.0, d) * 0.25;
    }

    float sun = saturate(dot(dir, light));
    colour += float3(1.0, 0.96, 0.88) * pow(sun, 1400.0) * 4.0;
    colour += float3(1.0, 0.72, 0.38) * pow(sun, 8.0) * 0.35;
    return colour;
}

float3 grade(float3 colour, float2 frag, float2 viewport) {
    float2 uv = frag / viewport - 0.5;
    float vignette = dot(uv * float2(1.15, 1.0), uv * float2(1.15, 1.0));
    colour *= 1.0 - saturate(vignette) * 0.42;
    return colour;
}

fragment float4 worldFragment(VertexOut in [[stage_in]], constant FrameUniforms &u [[buffer(1)]]) {
    int kind = int(u.params0.z + 0.5);
    float time = u.params0.x;
    float style = u.params0.y;
    float3 light = normalize(u.light.xyz);
    float3 view = normalize(u.camera.xyz - in.worldPos);
    float3 normal = normalize(in.normal);
    float3 colour = float3(0.0);

    if (kind == BODY_SKY) {
        colour = skyColour(normalize(in.worldPos - u.camera.xyz), light, time);
    } else if (kind == BODY_ATMOSPHERE) {
        // Drawn from the inside of a slightly larger sphere, after the world
        // has written depth. Only the limb survives the depth test, which is
        // why this reads as air rather than a second ball.
        float fresnel = pow(1.0 - saturate(dot(normal, view)), 2.6);
        float day = saturate(dot(normal, light));
        colour = atmosphereTint(style) * fresnel * (0.25 + 1.15 * day);
    } else if (kind == BODY_ORBIT_MOON) {
        colour = float3(0.62, 0.46, 0.28) * 0.55;
    } else if (kind == BODY_ORBIT_SAT) {
        colour = float3(0.45, 0.62, 0.78) * 0.5;
    } else if (kind == BODY_BEACON_HALO) {
        float fresnel = pow(1.0 - saturate(dot(normal, view)), 1.5);
        colour = float3(1.0, 0.22, 0.08) * fresnel * beaconPulse(time) * 1.6;
    } else if (kind == BODY_BEACON) {
        float pulse = beaconPulse(time);
        colour = float3(1.0, 0.16, 0.07) * (0.35 + pulse * 5.0);
    } else if (kind == BODY_HORN) {
        colour = float3(1.0, 0.86, 0.55) * (0.7 + 1.6 * saturate(dot(normal, light)));
    } else if (kind == BODY_PANEL) {
        float grid = step(0.86, fract(in.uv.x * 12.0)) + step(0.86, fract(in.uv.y * 8.0));
        float3 cell = float3(0.04, 0.10, 0.26);
        float3 line = float3(0.72, 0.80, 0.88);
        float3 albedo = mix(cell, line, saturate(grid));
        float facing = saturate(dot(normal, light));
        colour = albedo * (0.15 + facing);
        colour += float3(0.10, 0.28, 0.55) * facing * facing;
        colour += float3(0.03, 0.06, 0.12);
    } else if (kind == BODY_DISH) {
        float radial = in.uv.y;
        float3 metal = mix(float3(0.90, 0.92, 0.95), float3(0.22, 0.24, 0.28), smoothstep(0.02, 0.28, radial));
        float3 halfVec = normalize(light + view);
        float spec = pow(saturate(dot(normal, halfVec)), 50.0) * saturate(dot(normal, light));
        colour = metal * (0.12 + saturate(dot(normal, light)) * 0.7) + float3(1.0) * spec;
        colour += float3(1.0, 0.9, 0.7) * smoothstep(0.18, 0.0, radial) * 0.8;
    } else if (kind == BODY_METAL) {
        // Gold-foil patchiness, plus the panel lines from the box UVs.
        // Local position, so the pattern stays on the bus as it flies.
        float foil = fbm(in.objectPos * 9.0 + 3.0);
        float3 cloth = mix(float3(0.55, 0.54, 0.50), float3(0.86, 0.68, 0.32), smoothstep(0.35, 0.72, foil));
        float seam = step(0.93, fract(in.uv.x * 6.0)) + step(0.93, fract(in.uv.y * 4.0));
        cloth *= 1.0 - 0.45 * saturate(seam);
        float3 halfVec = normalize(light + view);
        float ndl = saturate(dot(normal, light));
        float spec = pow(saturate(dot(normal, halfVec)), 36.0) * ndl;
        colour = cloth * (0.18 + ndl * 0.85) + spec * float3(1.0, 0.95, 0.8);
    } else {
        // Planet or moon. The moon reuses the smooth, low-relief path with a grey tint.
        float bodyStyle = (kind == BODY_MOON) ? 1.0 : style;
        float strength = 0.04;
        if (kind == BODY_PLANET && style < 0.5) {
            strength = 0.28;
        } else if (kind == BODY_MOON) {
            strength = 0.12;
        }
        float3 n = bumpedNormal(normal, bodyStyle, strength);
        float height = planetHeight(normal, bodyStyle);
        float3 albedo = planetAlbedo(normal, bodyStyle, height);
        if (kind == BODY_MOON) {
            albedo = mix(float3(0.28, 0.27, 0.26), float3(0.62, 0.60, 0.56), albedo.r);
            albedo = mix(albedo, float3(0.45, 0.38, 0.32), 0.25);
        }
        float ndl = dot(n, light);
        float lit = saturate(ndl);
        float wrap = saturate(ndl * 0.5 + 0.5);
        float3 sun = float3(1.05, 0.97, 0.90);
        colour = albedo * sun * (lit * 0.82 + wrap * wrap * 0.16);
        colour += albedo * float3(0.02, 0.022, 0.035);
        colour += albedo * float3(0.055, 0.028, 0.016) * saturate(-ndl);
        float3 halfVec = normalize(light + view);
        float specPower = (kind == BODY_PLANET && style >= 0.5) ? 26.0 : 80.0;
        float specGain = (kind == BODY_PLANET && style >= 0.5) ? 0.14 : 0.06;
        colour += sun * pow(saturate(dot(n, halfVec)), specPower) * specGain * lit;
        if (kind == BODY_PLANET) {
            float rim = pow(1.0 - saturate(dot(n, view)), 3.2);
            colour += atmosphereTint(style) * rim * 0.38;
        }
    }

    colour = grade(colour, in.position.xy, max(u.params1.xy, float2(1.0)));
    return float4(max(colour, float3(0.0)), 1.0);
}
