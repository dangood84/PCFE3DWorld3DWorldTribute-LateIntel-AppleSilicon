#include "world_sim.hpp"

#include <cmath>

namespace {

constexpr float kDtCap = 0.05f;
constexpr float kOrbitRate = 0.90f;
constexpr float kZoomRate = 0.42f;
constexpr float kCameraEase = 12.f;
constexpr float kPlanetSpinRate = 0.07f;
constexpr float kMoonRate = 0.18f;
constexpr float kSatRate = 0.48f;
constexpr float kIntroSeconds = 3.6f;

void approach(float& current, float target, float dt, float responsiveness) {
    float blend = 1.f - std::exp(-responsiveness * dt);
    current += (target - current) * blend;
}

}  // namespace

Vec3 bananaLocal(float travel) {
    return bezierQuadratic(kBananaFar, kBananaBelly, kBananaNear, clampf(travel, 0.f, 1.f));
}

Vec3 bananaEye(float travel, float azimuth) {
    // Interesting: left/right does not rebuild the curve. It spins the same
    // banana around Y, so zoom and orbit stay independent.
    return rotateYVec(bananaLocal(travel), azimuth);
}

void WorldSim::pointerOrbit(float dAzimuth, float dTravel) {
    // State change: the scripted opening shot ends. The targets are the user's.
    intro = false;
    azimuthTarget += dAzimuth;
    travelTarget = clampf(travelTarget + dTravel, 0.f, 1.f);
}

void WorldSim::update(float dt) {
    // A stalled frame must not fling the moon across the sky.
    if (dt > kDtCap) {
        dt = kDtCap;
    }
    if (dt < 0.f) {
        dt = 0.f;
    }

    if (togglePause) {
        // State change: the world clock stops or starts. The camera block below
        // still runs, so you can study the banana while the orbits hold still.
        paused = !paused;
        togglePause = false;
    }
    if (toggleStyle) {
        // State change: same sphere, different surface. The shader reads `style`.
        style = (style == SurfaceStyle::RusticRed) ? SurfaceStyle::SmoothBrown
                                                    : SurfaceStyle::RusticRed;
        toggleStyle = false;
    }
    if (toggleOrbits) {
        showOrbits = !showOrbits;
        toggleOrbits = false;
    }
    if (toggleHelp) {
        showHelp = !showHelp;
        toggleHelp = false;
    }

    bool steering = std::fabs(orbitAxis) > 0.f || std::fabs(zoomAxis) > 0.f;
    if (steering) {
        // State change: a held key takes the camera off the opening path.
        intro = false;
    }

    if (intro) {
        introTime += dt;
        float u = clampf(introTime / kIntroSeconds, 0.f, 1.f);
        float eased = u * u * (3.f - 2.f * u);
        travelTarget = lerp(0.04f, 0.40f, eased);
        azimuthTarget = lerp(0.15f, 0.78f, eased);
        if (u >= 1.f) {
            // State change: the establishing shot has arrived and now holds.
            intro = false;
        }
    } else if (steering) {
        azimuthTarget += orbitAxis * kOrbitRate * rateScale * dt;
        travelTarget = clampf(travelTarget + zoomAxis * kZoomRate * rateScale * dt, 0.f, 1.f);
    }

    approach(azimuth, azimuthTarget, dt, kCameraEase);
    approach(travel, travelTarget, dt, kCameraEase);

    if (!paused) {
        planetSpin += dt * kPlanetSpinRate;
        moonOrbit += dt * kMoonRate;
        satOrbit += dt * kSatRate;
        lampTime += dt;
    }
}

void WorldSim::eyeTarget(Vec3& eye, Vec3& target) const {
    eye = bananaEye(travel, azimuth);
    // Far out, look a little above the centre so the world sits low and the
    // moon has sky around it. Close in, look at the world itself.
    target = {0.f, lerp(0.18f, 0.02f, travel), 0.f};
}

ScenePoses WorldSim::poses() const {
    ScenePoses scene;
    // Spin in the world's own axes, then tip the axis. The tilt stays put
    // while the day turns — the seasons idea, not a wobble.
    scene.planet = mul(rotateX(kPlanetTilt), rotateY(planetSpin));

    Vec3 moonPos = orbitOnInclinedCircle(moonOrbit, kMoonOrbitRadius, kMoonInclination);
    // Tidal lock is derived, not a second clock: one yaw per orbit, so the
    // same face keeps looking at the world.
    Mat4 moonOrient = rotateY(moonOrbit);
    scene.moon = mul(translate(moonPos), mul(moonOrient, scaleUniform(kMoonRadius)));
    scene.moonPosition = moonPos;

    Vec3 satPos = orbitOnInclinedCircle(satOrbit, kSatOrbitRadius, kSatInclination);
    Vec3 ahead = orbitOnInclinedCircle(satOrbit + 0.05f, kSatOrbitRadius, kSatInclination);
    Vec3 forward = normalize(ahead - satPos);
    Vec3 upRef{0.f, 1.f, 0.f};
    if (std::fabs(dot(forward, upRef)) > 0.96f) {
        upRef = {1.f, 0.f, 0.f};
    }
    Vec3 right = normalize(cross(upRef, forward));
    Vec3 up = cross(forward, right);
    // Columns are right, up, forward. The dish sits on local +Z, so it points
    // along the orbit instead of tumbling.
    scene.satellite = basis(right, up, forward, satPos);
    scene.satellitePosition = satPos;
    return scene;
}
