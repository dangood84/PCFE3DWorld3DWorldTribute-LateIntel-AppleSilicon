#pragma once

#include "math3d.hpp"

// Two memories of the same lecture: a rust-red rough world, or a smooth brown one.
// Geometry does not change. The fragment shader reads this and builds a different surface.
enum class SurfaceStyle {
    RusticRed = 0,
    SmoothBrown = 1,
};

// World radius is 1. The moon and the satellite are deliberately large enough
// to read from the opening shot — a lecture demo, not a scale model of orbit.
constexpr float kPlanetTilt = 0.42f;
constexpr float kMoonRadius = 0.28f;
constexpr float kMoonOrbitRadius = 2.85f;
constexpr float kMoonInclination = 0.20f;
constexpr float kSatOrbitRadius = 1.78f;
constexpr float kSatInclination = 0.62f;

// The zoom is not a straight line at the world. It is a quadratic Bezier.
// Far and near sit in the plane X = 0. The belly is pushed out on +X, so the
// path bows sideways as well as dipping — the banana, seen from above.
constexpr Vec3 kBananaFar{0.f, 2.6f, 10.2f};
constexpr Vec3 kBananaBelly{3.1f, 4.0f, 6.6f};
constexpr Vec3 kBananaNear{0.f, 0.72f, 2.85f};

struct ScenePoses {
    Mat4 planet;
    Mat4 moon;
    Mat4 satellite;
    Vec3 moonPosition;
    Vec3 satellitePosition;
};

// Clocks and the camera. The host (the Cocoa view) writes the axis and toggle
// fields; update() is the only place those become a new state.
struct WorldSim {
    float azimuth = 0.15f;
    float azimuthTarget = 0.15f;
    float travel = 0.04f;
    float travelTarget = 0.04f;
    bool intro = true;
    float introTime = 0.f;

    float planetSpin = 0.85f;
    float moonOrbit = 0.55f;
    float satOrbit = 2.35f;
    float lampTime = 0.f;
    bool paused = false;

    SurfaceStyle style = SurfaceStyle::RusticRed;
    bool showOrbits = true;
    bool showHelp = true;

    // Held keys. -1, 0, or +1, multiplied by rateScale (shift).
    float orbitAxis = 0.f;
    float zoomAxis = 0.f;
    float rateScale = 1.f;

    // One-shot edges. update() consumes them and clears them.
    bool togglePause = false;
    bool toggleStyle = false;
    bool toggleOrbits = false;
    bool toggleHelp = false;

    void pointerOrbit(float dAzimuth, float dTravel);
    void update(float dt);
    void eyeTarget(Vec3& eye, Vec3& target) const;
    ScenePoses poses() const;
};

// Travel 0 is the far pose, travel 1 is the near pose, in the approach plane
// before azimuth spins it around the world.
Vec3 bananaLocal(float travel);
Vec3 bananaEye(float travel, float azimuth);
