# Execution flow: from `main` to a frame of the world

A step-by-step trace of what happens from process start through the first picture, then what one display refresh does, and where a key press changes state.

`make run` opens **PCFE 3D World**. `make test` never reaches this file: it links `world_sim.cpp` and `mesh.cpp` only.

The trace is the same on Apple Silicon and on a late Intel Mac. Sonoma (macOS 14) still runs on MacBook Air and MacBook Pro from 2018, Mac mini from 2018, iMac from 2019, iMac Pro from 2017, and Mac Pro from 2019. Build with `make` on that Mac. The binary records the CPU it was compiled for, so an M1 `.app` will not start on Intel.

One thread does the work after startup:

- **main** — `NSApplication`, the window, `CADisplayLink`, input, and the Metal submit

The display link is added to the main run loop, same idea as the timer in the other tributes. There is no second simulation thread. The GPU runs the shader after `commit`, and the completed handler only signals a semaphore.

---

## Phase A — process entry

**1.** The OS loads `PCFE3DWorld.app/Contents/MacOS/PCFE3DWorld`.

**2.** `main` makes a regular app (Dock icon, Cmd-Tab) and hands the run loop to Cocoa.

```objc
NSApplication *app = NSApplication.sharedApplication;
[app setActivationPolicy:NSApplicationActivationPolicyRegular];
app.delegate = delegate;
[app run];
```

`applicationDidFinishLaunching` runs. `run` does not return until Quit.

---

## Phase B — window and Metal setup

**3.** The window is 1120×720 points, titled, resizable, and allowed to go full screen. The background is near-black so a resize does not flash white.

**4.** `WorldView` installs a `CAMetalLayer` (sRGB, opaque) and constructs `WorldRenderer`.

**5.** The renderer asks for the system Metal device. On an M1 that is the Apple GPU. On a late Intel Mac it is that machine's Intel or AMD GPU, which is enough for this scene. It then loads `World.metallib` from the bundle's Resources. If that file is missing, `ready` stays false and an alert explains that `make` has to be run. The shader is not compiled at launch; `make` already ran `metal` and `metallib`.

**6.** Two pipelines are built from `worldVertex` and `worldFragment`: one opaque, one additive. Both sample at 4× if the device allows it, and both write depth as 32-bit float. Three depth states exist: always (sky), less-and-write (solid bodies), less-and-read (air, ribbons, halo).

**7.** Meshes are built on the CPU and uploaded once: a sphere (world, moon, sky, lamp, halo), a box (bus, panels, mast, horn), a dish, and two ribbons. Nothing in those buffers changes later. Motion is a matrix.

**8.** The HUD is a text field *beside* the Metal view, not inside the shader. The view calls `chromeChanged` when the status string changes. **H** only shortens that field. It does not remove the world.

**9.** The menus are About and Quit, plus View → Full Screen (Ctrl-Cmd-F). The window is centred, made key, and the view becomes first responder so arrows work before the first click.

**10.** `viewDidMoveToWindow` starts a `CADisplayLink` on the main run loop. The first `step:` can run before layout has a real size. `frame:` returns immediately when `drawableSize` is still empty, and it does not touch the in-flight semaphore in that case.

---

## Phase C — one refresh

**11.** `step:` reads the link's duration. A nonsense interval (zero, or over a tenth of a second) is replaced with the link's own duration, usually a 60 Hz or ProMotion tick.

**12.** `WorldSim::update` runs first.

- `dt` is capped at 0.05 s.
- One-shot toggles are consumed. Space flips `paused`. B flips `style`. O flips `showOrbits`. H flips `showHelp`. Each flag is cleared in the same call so a held key cannot flip twice. Repeats of those keys are ignored in `keyDown`.
- If a steer key is down, `intro` becomes false. Otherwise, while `intro` is still true, the targets are written from a smoothstep over 3.6 s: travel 0.04 → 0.40, azimuth 0.15 → 0.78.
- `azimuth` and `travel` ease toward those targets. That ease is why a click does not jump along the banana.
- If `paused` is false, the world clock advances: planet spin, moon angle, satellite angle, lamp time. If it is true, those four numbers are not touched. The camera ease above already happened.

**13.** The renderer waits on a semaphore of 3, then picks the uniform buffer that the GPU has finished with. Three frames may be in flight. The wait is what stops the CPU writing a buffer the GPU is still reading.

**14.** `nextDrawable` may be nil (occluded, or the layer is busy). The wait is then signalled and the frame is dropped. Otherwise the MSAA colour and depth textures are rebuilt if the pixel size changed — that is the resize path, including full screen.

**15.** `eyeTarget` turns `travel` and `azimuth` into an eye and a look-at point. `poses` turns the orbit angles into the world matrix, the moon matrix, and the satellite's right/up/forward basis. Those are pure reads. They do not advance time.

**16.** The pass clears colour to a dark navy and depth to 1. The draws are the order in `WORKINGS.md`: sky, world, moon, satellite parts, atmosphere, ribbons, halo. Each draw copies one 256-byte `FrameUniforms` into the buffer at a 256-byte stride (Metal's constant-buffer alignment) and sets:

- `viewProj`, camera, light, time, style, viewport — the same for every draw
- `model` and the normal matrix — different per draw
- `params0.z` — the body id from `body_kind.h`

**17.** `presentDrawable` and `commit`. The completed handler signals the semaphore. `publishChrome` updates the HUD and the window title if the words changed ("Rust-red world" / "Smooth brown world", the banana percent, paused or moving).

---

## Phase D — a state change you can see

**Orbit.** Key-down on Left, Right, A, or D sets a held flag. `syncAxes` writes `orbitAxis` to -1, 0, or +1. The next `update` adds `orbitAxis × 0.90 × rateScale × dt` to `azimuthTarget`, then eases `azimuth` toward it. `bananaEye` rotates the same Bezier. The world does not spin to fake the orbit; the eye moves.

**Banana zoom.** Up, Down, W, S, the scroll wheel, or a vertical drag write `zoomAxis` or call `pointerOrbit`. `travelTarget` is clamped to 0…1. `pointerOrbit` also sets `intro` false immediately, before the next tick, so the script cannot overwrite the drag in the same frame.

**Surface.** B sets `toggleStyle`. `update` swaps `SurfaceStyle` and clears the flag. The next draw puts 0 or 1 in `params0.y`. `planetHeight` and `planetAlbedo` branch on it. No matrix changes.

**Pause.** Space sets `togglePause`. `update` flips `paused`. Later in the same function the world-clock block is skipped. The ease of `azimuth` and `travel` is not in that block.

**Full screen.** F, the green button, or the View menu calls `toggleFullScreen:`. Esc leaves full screen and does not quit. Resize lands in `syncDrawableSize` (points × backing scale) and then in `ensureTargets`, which drops the old MSAA textures.

**Quit.** The last window closing returns YES from `applicationShouldTerminateAfterLastWindowClosed`. The display link is invalidated when the view leaves the window, so a closed window does not keep submitting frames.

---

## What `make test` is doing instead

`world_test` never opens a window. It checks the decisions this trace depends on:

- the mid-zoom point is more than one unit off the straight chord (the banana)
- half a turn of azimuth flips that bow to the other side
- the view matrix puts the eye at the origin and the world in front (negative view Z)
- Metal's 0…1 depth is nearer for a closer point
- a non-uniform scale's normal matrix is the inverse scale
- pause freezes `moonOrbit`, and a 10 second `dt` does not
- sphere, box, dish, and ribbon windings match their normals
