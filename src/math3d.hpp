#pragma once

#include <cmath>

// Small column-major maths. Metal multiplies a column vector on the right,
// so a matrix built here can be copied straight into a float4x4.

constexpr float kPi = 3.14159265358979323846f;
constexpr float kTau = 6.28318530717958647692f;

struct Vec3 {
    float x, y, z;
    constexpr Vec3() : x(0.f), y(0.f), z(0.f) {}
    constexpr Vec3(float x, float y, float z) : x(x), y(y), z(z) {}
};

inline Vec3 operator+(Vec3 a, Vec3 b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
inline Vec3 operator-(Vec3 a, Vec3 b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
inline Vec3 operator-(Vec3 a) { return {-a.x, -a.y, -a.z}; }
inline Vec3 operator*(Vec3 a, float s) { return {a.x * s, a.y * s, a.z * s}; }
inline Vec3 operator*(float s, Vec3 a) { return a * s; }

inline float dot(Vec3 a, Vec3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }

inline Vec3 cross(Vec3 a, Vec3 b) {
    return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}

inline float length(Vec3 v) { return std::sqrt(dot(v, v)); }

inline Vec3 normalize(Vec3 v) {
    float len = length(v);
    if (len < 1e-8f) {
        return {0.f, 1.f, 0.f};
    }
    return v * (1.f / len);
}

inline float lerp(float a, float b, float t) { return a + (b - a) * t; }

inline float clampf(float v, float lo, float hi) {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

// A point on a circular orbit, then tipped by `inclination` radians about X.
// Length stays `radius`, so a ribbon and a body that share these arguments
// sit on the same ring.
inline Vec3 orbitOnInclinedCircle(float angle, float radius, float inclination) {
    float x = std::cos(angle) * radius;
    float flatZ = std::sin(angle) * radius;
    float y = flatZ * std::sin(inclination);
    float z = flatZ * std::cos(inclination);
    return {x, y, z};
}

struct Mat4 {
    // Column-major: index = column * 4 + row. m[0], m[5], m[10], m[15] is the diagonal.
    float m[16];
};

inline Mat4 mat4Zero() {
    Mat4 r{};
    return r;
}

inline Mat4 mat4Identity() {
    Mat4 r = mat4Zero();
    r.m[0] = r.m[5] = r.m[10] = r.m[15] = 1.f;
    return r;
}

inline Mat4 mul(const Mat4& a, const Mat4& b) {
    Mat4 o = mat4Zero();
    for (int c = 0; c < 4; ++c) {
        for (int r = 0; r < 4; ++r) {
            float s = 0.f;
            for (int k = 0; k < 4; ++k) {
                s += a.m[k * 4 + r] * b.m[c * 4 + k];
            }
            o.m[c * 4 + r] = s;
        }
    }
    return o;
}

inline Vec3 transformPoint(const Mat4& m, Vec3 v) {
    return {
        m.m[0] * v.x + m.m[4] * v.y + m.m[8] * v.z + m.m[12],
        m.m[1] * v.x + m.m[5] * v.y + m.m[9] * v.z + m.m[13],
        m.m[2] * v.x + m.m[6] * v.y + m.m[10] * v.z + m.m[14],
    };
}

inline Vec3 transformVector(const Mat4& m, Vec3 v) {
    return {
        m.m[0] * v.x + m.m[4] * v.y + m.m[8] * v.z,
        m.m[1] * v.x + m.m[5] * v.y + m.m[9] * v.z,
        m.m[2] * v.x + m.m[6] * v.y + m.m[10] * v.z,
    };
}

inline Mat4 translate(Vec3 t) {
    Mat4 m = mat4Identity();
    m.m[12] = t.x;
    m.m[13] = t.y;
    m.m[14] = t.z;
    return m;
}

inline Mat4 scale(float x, float y, float z) {
    Mat4 m = mat4Zero();
    m.m[0] = x;
    m.m[5] = y;
    m.m[10] = z;
    m.m[15] = 1.f;
    return m;
}

inline Mat4 scaleUniform(float s) { return scale(s, s, s); }

// Positive rotateY carries +Z toward +X. Azimuth uses the same sense,
// so a test that spins the banana by half a turn can check the sign directly.
inline Mat4 rotateY(float radians) {
    float c = std::cos(radians);
    float s = std::sin(radians);
    Mat4 m = mat4Zero();
    m.m[0] = c;
    m.m[2] = -s;
    m.m[5] = 1.f;
    m.m[8] = s;
    m.m[10] = c;
    m.m[15] = 1.f;
    return m;
}

inline Mat4 rotateX(float radians) {
    float c = std::cos(radians);
    float s = std::sin(radians);
    Mat4 m = mat4Zero();
    m.m[0] = 1.f;
    m.m[5] = c;
    m.m[6] = s;
    m.m[9] = -s;
    m.m[10] = c;
    m.m[15] = 1.f;
    return m;
}

inline Vec3 rotateYVec(Vec3 v, float radians) {
    float c = std::cos(radians);
    float s = std::sin(radians);
    return {c * v.x + s * v.z, v.y, -s * v.x + c * v.z};
}

// Columns are the craft's right, up, and forward axes, then its position.
inline Mat4 basis(Vec3 right, Vec3 up, Vec3 forward, Vec3 origin) {
    Mat4 m = mat4Zero();
    m.m[0] = right.x;
    m.m[1] = right.y;
    m.m[2] = right.z;
    m.m[4] = up.x;
    m.m[5] = up.y;
    m.m[6] = up.z;
    m.m[8] = forward.x;
    m.m[9] = forward.y;
    m.m[10] = forward.z;
    m.m[12] = origin.x;
    m.m[13] = origin.y;
    m.m[14] = origin.z;
    m.m[15] = 1.f;
    return m;
}

// Inverse-transpose of the upper 3x3. A non-uniform scale (the satellite bus
// is a stretched box) would otherwise skew the lighting normals.
// The shader normalises the result, but we still divide by the determinant
// so a pure rotation comes back as itself and the tests can check numbers.
inline Mat4 normalMatrixOf(const Mat4& model) {
    Vec3 c0{model.m[0], model.m[1], model.m[2]};
    Vec3 c1{model.m[4], model.m[5], model.m[6]};
    Vec3 c2{model.m[8], model.m[9], model.m[10]};
    float det = dot(c0, cross(c1, c2));
    if (std::fabs(det) < 1e-12f) {
        return mat4Identity();
    }
    float inv = 1.f / det;
    Vec3 i0 = cross(c1, c2) * inv;
    Vec3 i1 = cross(c2, c0) * inv;
    Vec3 i2 = cross(c0, c1) * inv;
    Mat4 n = mat4Identity();
    n.m[0] = i0.x;
    n.m[1] = i0.y;
    n.m[2] = i0.z;
    n.m[4] = i1.x;
    n.m[5] = i1.y;
    n.m[6] = i1.z;
    n.m[8] = i2.x;
    n.m[9] = i2.y;
    n.m[10] = i2.z;
    return n;
}

// Right-handed look-at. The camera looks down -Z in view space.
inline Mat4 lookAt(Vec3 eye, Vec3 target, Vec3 up) {
    Vec3 f = normalize(target - eye);
    Vec3 s = normalize(cross(f, up));
    Vec3 u = cross(s, f);
    Mat4 m = mat4Identity();
    m.m[0] = s.x;
    m.m[4] = s.y;
    m.m[8] = s.z;
    m.m[12] = -dot(s, eye);
    m.m[1] = u.x;
    m.m[5] = u.y;
    m.m[9] = u.z;
    m.m[13] = -dot(u, eye);
    m.m[2] = -f.x;
    m.m[6] = -f.y;
    m.m[10] = -f.z;
    m.m[14] = dot(f, eye);
    return m;
}

// Metal's clip z is 0 at the near plane and 1 at the far plane (not OpenGL's -1..1).
inline Mat4 perspectiveMetal(float fovyRadians, float aspect, float nearZ, float farZ) {
    float ys = 1.f / std::tan(fovyRadians * 0.5f);
    float xs = ys / aspect;
    float zA = farZ / (nearZ - farZ);
    float zB = nearZ * farZ / (nearZ - farZ);
    Mat4 m = mat4Zero();
    m.m[0] = xs;
    m.m[5] = ys;
    m.m[10] = zA;
    m.m[11] = -1.f;
    m.m[14] = zB;
    return m;
}

inline Vec3 bezierQuadratic(Vec3 a, Vec3 b, Vec3 c, float t) {
    float u = 1.f - t;
    return a * (u * u) + b * (2.f * u * t) + c * (t * t);
}
