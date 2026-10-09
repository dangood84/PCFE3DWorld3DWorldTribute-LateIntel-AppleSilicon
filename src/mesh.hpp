#pragma once

#include "math3d.hpp"

#include <cstdint>
#include <vector>

// Interleaved to match the Metal vertex descriptor: position, normal, uv.
struct Vertex {
    float px, py, pz;
    float nx, ny, nz;
    float u, v;
};

static_assert(sizeof(Vertex) == 32, "Metal vertex stride is 32 bytes");

struct Mesh {
    std::vector<Vertex> vertices;
    std::vector<std::uint32_t> indices;
};

Mesh makeSphere(int stacks, int slices);
Mesh makeBox();
Mesh makeDish(int rings, int segments);
Mesh makeOrbitRibbon(float radius, float inclination, float halfWidth, int segments);

// True when every non-degenerate triangle's edge order agrees with the
// vertex normals. The rasterizer culls from the winding; the shader lights
// from the normals. They have to describe the same side of the surface.
bool windingMatchesNormals(const Mesh& mesh);
