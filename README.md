# PCFE 3D World

A tribute to a 3D world shown on a BTEC National Diploma **Advanced Programming** course, around 2001–2003.

It may have been a sample that shipped with DirectX, or the lecturer may have written it. Nothing in the DirectX 7 / 8 / 9 sample lists is a confident match for the whole picture, so this is a reconstruction of the memory rather than a port of a named SDK demo: one world, a moon, a man-made satellite, a camera that moves left and right around it, and a zoom that travels a **banana-shaped** curve instead of a straight line.

The world can be shown two ways, because both stuck: **rust-red and rough**, or **smooth and brown**. Press **B** to switch. The meshes do not change.

Written in **C++17** and **Objective-C++**, drawn with **Metal**. There is no game engine and no texture bitmap. The surfaces are computed in the shader from the position on the sphere, so the close end of the banana stays sharp.

How the pieces fit together (same split as the other tributes): `WORKINGS.md` for the camera, the orbits, and the shading, `EXECUTION_FLOW.md` for a frame-by-frame trace.

## Requirements

- macOS 14 (Sonoma) or newer
- Xcode Command Line Tools, so `clang++` and `xcrun metal` are on your `PATH`

This tree was built on an M1 Mac. The same `make` also builds and runs on a late Intel Mac, on the machine itself. Sonoma still supports these Intel models: MacBook Air and MacBook Pro from 2018, Mac mini from 2018, iMac from 2019, iMac Pro from 2017, and Mac Pro from 2019. That includes the last Intel Macs (2020 iMac, 2020 13-inch MacBook Pro, 2019 Mac Pro).

Copy the source folder across and run `make` there. The `.app` produced on an M1 is Apple Silicon only, so it will not launch on an Intel Mac.

```bash
xcode-select --install
```

No Homebrew packages. Metal, Cocoa, and QuartzCore are already on the machine.

## Run

From the project root:

```bash
make
make run
```

That compiles the shader to `build/World.metallib`, links `build/PCFE3DWorld.app`, and opens it. The window is a normal app with a Dock icon.

```bash
make test    # camera, orbits, and mesh winding, no window
make clean   # remove build/
```

`make test` does not need a display. It checks that the zoom path bows out like a banana, that a stalled frame cannot fling the moon, and that every triangle faces the same way as its normals.

## Using it

1. The window opens on a rust-red world. For a few seconds the camera slides in along the banana and drifts to the right. That opening shot stops on its own, or as soon as you steer.
2. **Left / Right** (or **A / D**, or drag sideways) orbit horizontally around the world. The banana turns with you.
3. **Up / Down** (or **W / S**, scroll, or drag up and down) travel along the banana: in toward the world, or back out. **Shift** moves faster.
4. **B** switches rust-red rough and smooth brown. **O** shows or hides the two orbit lines (warm for the moon, cool for the satellite). **Space** pauses the orbits and the planet's day. The camera still moves.
5. **H** hides the key strip. The status line stays. **F** is full screen; **Esc** or **Ctrl-Cmd-F** leaves it. **Cmd-Q** or closing the window quits.

**PCFE 3D World → About** says the same thing as this page: a memory of a lecture, not a claim about a particular DirectX binary.

## Project layout

```
src/main.mm          Cocoa window, Metal draw, keyboard and mouse
src/world_sim.hpp    clocks, banana camera, moon and satellite poses
src/world_sim.cpp
src/mesh.hpp         sphere, satellite parts, orbit ribbons
src/mesh.cpp
src/math3d.hpp       column-major matrices, Metal projection
src/body_kind.h      body ids shared with the shader
src/world_test.cpp   headless checks
shaders/World.metal  sky, world, moon, craft, air
bundle/Info.plist
Makefile
.gitignore           build/, Metal .air / .metallib, Mac and editor noise
```

`build/` is generated. The `.gitignore` keeps the app bundle, the compiled shader, and Xcode's user files out of git. `shaders/World.metal` is the source; the `.metallib` inside the app is produced by `make`.
