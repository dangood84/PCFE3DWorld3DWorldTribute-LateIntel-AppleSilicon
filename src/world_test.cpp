#include "mesh.hpp"
#include "world_sim.hpp"

#include <cmath>
#include <cstdio>

static int gFailures = 0;

#define EXPECT(cond)                                                                 \
    do {                                                                             \
        if (!(cond)) {                                                               \
            std::fprintf(stderr, "fail %s:%d: %s\n", __FILE__, __LINE__, #cond);     \
            ++gFailures;                                                             \
        } else {                                                                     \
            std::printf("ok %s\n", #cond);                                           \
        }                                                                            \
    } while (0)

struct Clip {
    float x, y, z, w;
};

static Clip transformClip(const Mat4& m, Vec3 v) {
    return {
        m.m[0] * v.x + m.m[4] * v.y + m.m[8] * v.z + m.m[12],
        m.m[1] * v.x + m.m[5] * v.y + m.m[9] * v.z + m.m[13],
        m.m[2] * v.x + m.m[6] * v.y + m.m[10] * v.z + m.m[14],
        m.m[3] * v.x + m.m[7] * v.y + m.m[11] * v.z + m.m[15],
    };
}

static void testBanana() {
    Vec3 far = bananaLocal(0.f);
    Vec3 near = bananaLocal(1.f);
    Vec3 mid = bananaLocal(0.5f);
    Vec3 chord = (far + near) * 0.5f;
    // The belly is the banana. A straight zoom would keep this difference at 0.
    EXPECT(mid.x - chord.x > 1.f);
    EXPECT(length(far) > length(near));

    Vec3 spun = bananaEye(0.5f, kPi);
    EXPECT(mid.x > 1.f);
    EXPECT(spun.x < -1.f);
}

static void testCameraMath() {
    Mat4 view = lookAt({0.f, 0.f, 5.f}, {0.f, 0.f, 0.f}, {0.f, 1.f, 0.f});
    Vec3 eye = transformPoint(view, {0.f, 0.f, 5.f});
    EXPECT(std::fabs(eye.x) < 1e-4f && std::fabs(eye.y) < 1e-4f && std::fabs(eye.z) < 1e-4f);
    Vec3 ahead = transformPoint(view, {0.f, 0.f, 0.f});
    EXPECT(ahead.z < 0.f);

    Mat4 proj = perspectiveMetal(60.f * kPi / 180.f, 1.f, 0.1f, 100.f);
    Mat4 viewProj = mul(proj, view);
    Clip centre = transformClip(viewProj, {0.f, 0.f, 0.f});
    EXPECT(centre.w > 0.f);
    EXPECT(std::fabs(centre.x / centre.w) < 1e-4f);
    EXPECT(std::fabs(centre.y / centre.w) < 1e-4f);
    float centreZ = centre.z / centre.w;
    EXPECT(centreZ > 0.f && centreZ < 1.f);

    Clip right = transformClip(viewProj, {1.f, 0.f, 0.f});
    Clip up = transformClip(viewProj, {0.f, 1.f, 0.f});
    Clip closer = transformClip(viewProj, {0.f, 0.f, 4.f});
    EXPECT(right.x / right.w > 0.f);
    EXPECT(up.y / up.w > 0.f);
    EXPECT(closer.z / closer.w < centreZ);
}

static void testNormals() {
    Mat4 scaled = scale(2.f, 1.f, 1.f);
    Mat4 normals = normalMatrixOf(scaled);
    Vec3 nx = transformVector(normals, {1.f, 0.f, 0.f});
    Vec3 ny = transformVector(normals, {0.f, 1.f, 0.f});
    EXPECT(std::fabs(nx.x - 0.5f) < 1e-4f);
    EXPECT(std::fabs(ny.y - 1.f) < 1e-4f);

    Mat4 turned = normalMatrixOf(rotateY(kPi * 0.5f));
    Vec3 spun = transformVector(turned, {1.f, 0.f, 0.f});
    EXPECT(std::fabs(spun.x) < 1e-4f);
    EXPECT(std::fabs(spun.z + 1.f) < 1e-4f);
}

static void testOrbitsAndPause() {
    Vec3 moon = orbitOnInclinedCircle(1.2f, kMoonOrbitRadius, kMoonInclination);
    EXPECT(std::fabs(length(moon) - kMoonOrbitRadius) < 1e-3f);

    WorldSim sim;
    sim.intro = false;
    ScenePoses poses = sim.poses();
    EXPECT(std::fabs(length(poses.moonPosition) - kMoonOrbitRadius) < 1e-3f);
    EXPECT(std::fabs(length(poses.satellitePosition) - kSatOrbitRadius) < 1e-3f);

    Vec3 right{poses.satellite.m[0], poses.satellite.m[1], poses.satellite.m[2]};
    Vec3 up{poses.satellite.m[4], poses.satellite.m[5], poses.satellite.m[6]};
    Vec3 forward{poses.satellite.m[8], poses.satellite.m[9], poses.satellite.m[10]};
    EXPECT(std::fabs(length(right) - 1.f) < 1e-4f);
    EXPECT(std::fabs(dot(right, up)) < 1e-4f);
    EXPECT(std::fabs(dot(cross(right, up), forward) - 1.f) < 1e-3f);

    float moonBefore = sim.moonOrbit;
    sim.togglePause = true;
    sim.update(0.05f);
    EXPECT(sim.paused);
    EXPECT(sim.moonOrbit == moonBefore);
    sim.update(0.05f);
    EXPECT(sim.moonOrbit == moonBefore);
    sim.togglePause = true;
    sim.update(0.05f);
    EXPECT(!sim.paused);
    EXPECT(sim.moonOrbit > moonBefore);

    WorldSim flung;
    flung.intro = false;
    float before = flung.moonOrbit;
    flung.update(10.f);
    EXPECT(flung.moonOrbit - before < 0.02f);
}

static void testInputState() {
    WorldSim sim;
    sim.pointerOrbit(0.2f, 0.1f);
    EXPECT(!sim.intro);
    EXPECT(sim.azimuthTarget > 0.3f);
    EXPECT(sim.travelTarget > 0.1f);

    WorldSim keys;
    keys.intro = false;
    float azimuth = keys.azimuthTarget;
    keys.orbitAxis = 1.f;
    keys.update(0.05f);
    EXPECT(keys.azimuthTarget > azimuth);

    keys.toggleStyle = true;
    keys.update(0.05f);
    EXPECT(keys.style == SurfaceStyle::SmoothBrown);

    WorldSim opening;
    for (int i = 0; i < 120; ++i) {
        opening.update(0.05f);
    }
    EXPECT(!opening.intro);
    EXPECT(opening.travel > 0.3f);
}

static void testMeshes() {
    EXPECT(windingMatchesNormals(makeSphere(16, 24)));
    EXPECT(windingMatchesNormals(makeBox()));
    EXPECT(windingMatchesNormals(makeDish(8, 16)));
    EXPECT(windingMatchesNormals(makeOrbitRibbon(kMoonOrbitRadius, kMoonInclination, 0.03f, 48)));
}

int main() {
    testBanana();
    testCameraMath();
    testNormals();
    testOrbitsAndPause();
    testInputState();
    testMeshes();
    if (gFailures != 0) {
        std::fprintf(stderr, "%d failed\n", gFailures);
        return 1;
    }
    std::printf("all ok\n");
    return 0;
}
