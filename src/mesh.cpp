#include "mesh.hpp"

#include <cmath>

namespace {

Vertex vertexAt(Vec3 position, Vec3 normal, float u, float v) {
    Vec3 n = normalize(normal);
    Vertex out{};
    out.px = position.x;
    out.py = position.y;
    out.pz = position.z;
    out.nx = n.x;
    out.ny = n.y;
    out.nz = n.z;
    out.u = u;
    out.v = v;
    return out;
}

void addQuad(Mesh& mesh, Vec3 a, Vec3 b, Vec3 c, Vec3 d, Vec3 normal) {
    std::uint32_t base = static_cast<std::uint32_t>(mesh.vertices.size());
    mesh.vertices.push_back(vertexAt(a, normal, 0.f, 0.f));
    mesh.vertices.push_back(vertexAt(b, normal, 1.f, 0.f));
    mesh.vertices.push_back(vertexAt(c, normal, 1.f, 1.f));
    mesh.vertices.push_back(vertexAt(d, normal, 0.f, 1.f));
    mesh.indices.push_back(base);
    mesh.indices.push_back(base + 1);
    mesh.indices.push_back(base + 2);
    mesh.indices.push_back(base);
    mesh.indices.push_back(base + 2);
    mesh.indices.push_back(base + 3);
}

Vec3 positionOf(const Mesh& mesh, std::uint32_t index) {
    const Vertex& v = mesh.vertices[index];
    return {v.px, v.py, v.pz};
}

Vec3 normalOf(const Mesh& mesh, std::uint32_t index) {
    const Vertex& v = mesh.vertices[index];
    return {v.nx, v.ny, v.nz};
}

}  // namespace

Mesh makeSphere(int stacks, int slices) {
    Mesh mesh;
    for (int y = 0; y <= stacks; ++y) {
        float v = static_cast<float>(y) / static_cast<float>(stacks);
        float theta = v * kPi;
        float st = std::sin(theta);
        float ct = std::cos(theta);
        for (int x = 0; x <= slices; ++x) {
            float u = static_cast<float>(x) / static_cast<float>(slices);
            float phi = u * kTau;
            Vec3 p{st * std::cos(phi), ct, st * std::sin(phi)};
            // On a unit sphere the position is already the outward normal.
            mesh.vertices.push_back(vertexAt(p, p, u, 1.f - v));
        }
    }

    int stride = slices + 1;
    for (int y = 0; y < stacks; ++y) {
        for (int x = 0; x < slices; ++x) {
            std::uint32_t i0 = static_cast<std::uint32_t>(y * stride + x);
            std::uint32_t i1 = i0 + 1;
            std::uint32_t i2 = i0 + static_cast<std::uint32_t>(stride);
            std::uint32_t i3 = i2 + 1;
            // i0, i1, i2 winds outward (counter-clockwise from outside).
            mesh.indices.push_back(i0);
            mesh.indices.push_back(i1);
            mesh.indices.push_back(i2);
            mesh.indices.push_back(i1);
            mesh.indices.push_back(i3);
            mesh.indices.push_back(i2);
        }
    }
    return mesh;
}

Mesh makeBox() {
    // The box is -0.5..0.5 on each axis, so a later scale() is the full size
    // of that part of the satellite. Each quad is counter-clockwise from outside.
    Mesh mesh;
    const float h = 0.5f;
    addQuad(mesh, {h, -h, h}, {h, -h, -h}, {h, h, -h}, {h, h, h}, {1, 0, 0});
    addQuad(mesh, {-h, -h, -h}, {-h, -h, h}, {-h, h, h}, {-h, h, -h}, {-1, 0, 0});
    addQuad(mesh, {-h, h, h}, {h, h, h}, {h, h, -h}, {-h, h, -h}, {0, 1, 0});
    addQuad(mesh, {-h, -h, -h}, {h, -h, -h}, {h, -h, h}, {-h, -h, h}, {0, -1, 0});
    addQuad(mesh, {-h, -h, h}, {h, -h, h}, {h, h, h}, {-h, h, h}, {0, 0, 1});
    addQuad(mesh, {h, -h, -h}, {-h, -h, -h}, {-h, h, -h}, {h, h, -h}, {0, 0, -1});
    return mesh;
}

Mesh makeDish(int rings, int segments) {
    // A shallow bowl. The centre is the most forward point (+Z) and the rim
    // sits back, so the concave face — the face we light — points forward.
    Mesh mesh;
    mesh.vertices.push_back(vertexAt({0.f, 0.f, 0.35f}, {0.f, 0.f, 1.f}, 0.5f, 0.f));

    for (int ring = 1; ring <= rings; ++ring) {
        float radius = static_cast<float>(ring) / static_cast<float>(rings);
        float z = 0.35f * (1.f - radius * radius);
        float dzdr = -0.70f * radius;
        for (int s = 0; s < segments; ++s) {
            float phi = static_cast<float>(s) / static_cast<float>(segments) * kTau;
            float c = std::cos(phi);
            float sn = std::sin(phi);
            Vec3 position{radius * c, radius * sn, z};
            Vec3 dr{c, sn, dzdr};
            Vec3 dPhi{-sn, c, 0.f};
            Vec3 normal = cross(dr, dPhi);
            mesh.vertices.push_back(vertexAt(position, normal, phi / kTau, radius));
        }
    }

    auto at = [segments](int ring, int slice) {
        int wrapped = slice % segments;
        if (wrapped < 0) {
            wrapped += segments;
        }
        return 1 + (ring - 1) * segments + wrapped;
    };

    for (int s = 0; s < segments; ++s) {
        mesh.indices.push_back(0);
        mesh.indices.push_back(static_cast<std::uint32_t>(at(1, s)));
        mesh.indices.push_back(static_cast<std::uint32_t>(at(1, s + 1)));
    }
    for (int ring = 1; ring < rings; ++ring) {
        for (int s = 0; s < segments; ++s) {
            std::uint32_t inner0 = static_cast<std::uint32_t>(at(ring, s));
            std::uint32_t inner1 = static_cast<std::uint32_t>(at(ring, s + 1));
            std::uint32_t outer0 = static_cast<std::uint32_t>(at(ring + 1, s));
            std::uint32_t outer1 = static_cast<std::uint32_t>(at(ring + 1, s + 1));
            mesh.indices.push_back(inner0);
            mesh.indices.push_back(outer0);
            mesh.indices.push_back(inner1);
            mesh.indices.push_back(inner1);
            mesh.indices.push_back(outer0);
            mesh.indices.push_back(outer1);
        }
    }
    return mesh;
}

Mesh makeOrbitRibbon(float radius, float inclination, float halfWidth, int segments) {
    Mesh mesh;
    Vec3 sampleA = orbitOnInclinedCircle(0.f, radius, inclination);
    Vec3 sampleB = orbitOnInclinedCircle(0.7f, radius, inclination);
    Vec3 sampleC = orbitOnInclinedCircle(2.4f, radius, inclination);
    Vec3 plane = normalize(cross(sampleB - sampleA, sampleC - sampleA));

    for (int i = 0; i <= segments; ++i) {
        float angle = static_cast<float>(i) / static_cast<float>(segments) * kTau;
        Vec3 position = orbitOnInclinedCircle(angle, radius, inclination);
        Vec3 next = orbitOnInclinedCircle(angle + 0.02f, radius, inclination);
        Vec3 side = normalize(cross(plane, normalize(next - position)));
        float u = static_cast<float>(i) / static_cast<float>(segments);
        mesh.vertices.push_back(vertexAt(position - side * halfWidth, plane, u, 0.f));
        mesh.vertices.push_back(vertexAt(position + side * halfWidth, plane, u, 1.f));
    }

    for (int i = 0; i < segments; ++i) {
        std::uint32_t i0 = static_cast<std::uint32_t>(i * 2);
        std::uint32_t i1 = i0 + 1;
        std::uint32_t i2 = i0 + 2;
        std::uint32_t i3 = i0 + 3;
        mesh.indices.push_back(i0);
        mesh.indices.push_back(i2);
        mesh.indices.push_back(i1);
        mesh.indices.push_back(i1);
        mesh.indices.push_back(i2);
        mesh.indices.push_back(i3);
    }
    return mesh;
}

bool windingMatchesNormals(const Mesh& mesh) {
    int checked = 0;
    for (std::size_t i = 0; i + 2 < mesh.indices.size(); i += 3) {
        Vec3 a = positionOf(mesh, mesh.indices[i]);
        Vec3 b = positionOf(mesh, mesh.indices[i + 1]);
        Vec3 c = positionOf(mesh, mesh.indices[i + 2]);
        Vec3 geometric = cross(b - a, c - a);
        if (length(geometric) < 1e-8f) {
            continue;
        }
        Vec3 stored = normalOf(mesh, mesh.indices[i]) + normalOf(mesh, mesh.indices[i + 1]) +
                      normalOf(mesh, mesh.indices[i + 2]);
        if (dot(geometric, stored) <= 0.f) {
            return false;
        }
        ++checked;
    }
    return checked > 0;
}
