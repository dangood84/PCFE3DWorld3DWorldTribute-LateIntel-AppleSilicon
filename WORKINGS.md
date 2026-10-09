# How PCFE 3D World works

This note is for someone who wants to **build and run** the tribute, and to see how a small Metal desktop scene is split up: what is simulated, what is only a mesh, and what the shader invents per pixel.

You do not need to have used DirectX. The ideas are the ones a 2001 graphics lab would have drawn on the board: a world matrix, a view matrix, a projection matrix, and a hierarchy (moon and satellite are placed relative to the world, then the whole scene is viewed from the camera).

## Build / run

Work from the project root. `clang++` and `xcrun` must be on `PATH`. Output always lands in `build/` (gitignored).

| What you want | Command | What you get |
|---------------|---------|--------------|
| The app | `make` then `make run` | `build/PCFE3DWorld.app`, opened |
| Headless checks | `make test` | prints `ok` lines; non-zero if the banana, the pause, or a mesh winding is wrong |
| Start over | `make clean` | deletes `build/` |

`make` does three things:

1. `xcrun metal` compiles `shaders/World.metal` to `build/World.air`
2. `xcrun metallib` links that into `build/World.metallib`
3. `clang++` links `src/main.mm`, `world_sim.cpp`, and `mesh.cpp`, then copies the binary and the metallib into the `.app` and ad-hoc signs it

The shader and the CPU share body ids through `src/body_kind.h`. The Metal compile is given `-Isrc` so that include works. If you add a body, add the id in that header and a branch in `worldFragment`.

## What this is remembering

DirectX 7 (1999) through DirectX 9 (2002) did ship sphere and bump-mapped Earth samples. Those are a textured ball, sometimes spinning, with a key to pause. They do not add a moon, a separate man-made satellite, and a curved zoom.

A lot of college labs from the same years built exactly this hierarchy, because it is the smallest scene that needs more than one transform: the world spins, the moon orbits, and a satellite — a box with panels, not another ball — orbits on a different ring. BRender's tutorial of that era even names the three actors planet, moon, and satellite.

The banana is the part that feels specific. A stock sample dollies in a straight line or spins on a circle. Here, zoom is a curve with a sideways belly. Left and right spin that whole curve around the world, so the two gestures stay independent.

Both surface memories are kept. **B** flips `SurfaceStyle` between rust-red rough and smooth brown. That flag never moves a vertex.

## Mental model

```
main
  → AppDelegate builds the window and WorldView
       → CADisplayLink on the main run loop (~the display refresh)
            → WorldSim::update(dt)     clocks and the banana
            → WorldRenderer draws      meshes × model matrices × one shader
            → the drawable is presented
```

| Layer | File | What it owns |
|-------|------|----------------|
| Entry, window, input | `src/main.mm` | Metal device, pipelines, key flags, the HUD |
| Simulation | `src/world_sim.cpp` | The only place a clock or a camera target changes |
| Meshes | `src/mesh.cpp` | Unit sphere, box, dish, orbit ribbons. No time in here |
| Shade | `shaders/World.metal` | Colour, bumps, the lamp flash, the sky |

Input does not teleport the camera. Keys set `orbitAxis` / `zoomAxis`, or a one-shot toggle. `update` consumes those and eases `azimuth` and `travel` toward their targets. The picture is whatever `eyeTarget` and `poses` return at the end of that function.

## The banana

`travel` is 0 at the far pose and 1 at the near pose. The three control points live in `world_sim.hpp`:

```
far    (0, 2.6, 10.2)     high and well back
belly  (3.1, 4.0, 6.6)    pushed out on +X, and up
near   (0, 0.72, 2.85)    low and close
```

Far and near have X = 0. A straight lerp between them would stay in that plane. The belly's X is the bow. At `travel` 0.5 the quadratic Bezier sits more than one world-radius out to the side. `make test` checks that.

```
        belly
       /     \
   far        near
                 o  world
```

From above, that is a banana. `azimuth` then rotates the whole thing around Y:

```
eye = rotateY( bezier(far, belly, near, travel), azimuth )
```

Left/right changes `azimuth`. Up/down changes `travel`. Shift scales the rate (`rateScale`), it does not add a third mode.

The look-at point is not quite the origin when you are far away. It sits a little above the centre (`y` 0.18, easing toward 0.02 up close) so the world rests low in the frame and the moon has sky over it.

The opening shot is the same path, scripted. `intro` writes `travelTarget` and `azimuthTarget` for 3.6 seconds. The first steer, drag, or scroll clears `intro`. When the script finishes, `intro` clears itself and the camera holds.

## Two clocks

`paused` (Space) stops `planetSpin`, `moonOrbit`, `satOrbit`, and `lampTime`.

It does not stop the camera. You can pause the lecture animation and still walk the banana around a frozen world. A frame slower than 50 ms is clamped, so a stall cannot add ten seconds of orbit in one tick.

The moon's yaw is not its own clock. `poses` sets it from `moonOrbit`, one turn per orbit, so the same face stays toward the world. The satellite's nose is the tangent of its ring: local +Z follows the direction of travel, which is why the dish leads and the panels stay flat.

| Body | Ring radius | Tilt of the ring | What you should notice |
|------|-------------|------------------|------------------------|
| Moon | 2.85 | 0.20 rad | A grey ball, slower |
| Satellite | 1.78 | 0.62 rad | Gold bus, blue panels, flashing lamp, quicker |

The rings are different colours in the shader (warm, cool) so the eye can separate them. **O** skips those two draws. The bodies keep moving.

Sizes are lecture-demo sizes. A real satellite at that distance would be a speck. This one is big enough to read from the opening shot, and its wings still clear the world's surface.

The world's axis is tipped by `kPlanetTilt` (about 24°) **after** the daily spin. The tilt does not rotate with the day.

## Drawing

One vertex shader, one fragment shader, two pipelines (opaque and additive). Cull mode is set per draw, because the sky and the atmosphere are the *inside* of a sphere (cull the outward faces) and the world is the outside (cull the inward faces).

Metal treats clockwise as the front face unless told otherwise. The meshes are counter-clockwise from the outside, so the encoder sets counter-clockwise as front. `make test` checks that each triangle's winding agrees with its stored normals. If those two disagree, the rasterizer shows you the unlit side.

Order in a frame:

1. Sky sphere, centred on the camera, depth test off. The shader colours by direction: stars, a milky band, a sun disc if the light is in front of you.
2. World, moon, and the satellite parts. These write depth. The light sits over the camera's shoulder so the near face is a gibbous day side with a terminator, which is what makes the ball read as a world in a still picture.
3. Atmosphere: a sphere at radius 1.08, additive, front faces culled, depth test on, depth write off. The front of that shell is hidden by the world. The limb is closer than the empty background and survives. That ring is the air.
4. Orbit ribbons, then the lamp's halo, both additive and both tested against the depth from step 2.

The satellite bus is a non-uniform scale. A normal that is only multiplied by that matrix would be skewed, so each draw also uploads the inverse-transpose (`normalMatrixOf`). The shader normalises the result.

There is no texture file. Rust, craters, clay, foil, and panel grids are noise in the fragment shader, sampled from the position on the mesh. Zooming in along the banana does not magnify a 256×256 bitmap the way a DirectX 7 sample often did.

The lamp flash is `beaconPulse` on `lampTime`. The core and the halo use the same function, so they flash together. Pause freezes `lampTime` with the other world clocks.

## State the host is allowed to poke

`WorldView` writes these. `WorldSim::update` is what turns them into a new picture.

| Field | Who sets it | What changes |
|-------|-------------|--------------|
| `orbitAxis`, `zoomAxis` | Held keys | Targets, each frame, while not in the intro |
| `rateScale` | Shift | Multiplies those rates |
| `pointerOrbit` | Drag, scroll | Adds to the targets and ends the intro immediately |
| `togglePause`, `toggleStyle`, `toggleOrbits`, `toggleHelp` | Space, B, O, H | Consumed once, then cleared |

`azimuth`, `travel`, the three orbit angles, `lampTime`, `paused`, `style`, and `intro` are not written from the view except through those doors.
