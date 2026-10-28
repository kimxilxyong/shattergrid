<div align="center">
  <img src="icon.svg" width="96" alt="Shattergrid">
  <h1>Shattergrid</h1>
  <p>Destructible voxel sandbox for Godot 4, with a dedicated DDA renderer and Jolt physics.</p>

  <p>
    <img src="https://img.shields.io/badge/Godot-4.7-478CBF?logo=godot-engine&amp;logoColor=white" alt="Godot 4.7">
    <img src="https://img.shields.io/badge/C++-17-00599C?logo=cplusplus&amp;logoColor=white" alt="C++ 17">
    <img src="https://img.shields.io/badge/renderer-Vulkan%20DDA-6D5DFB" alt="Vulkan DDA">
    <img src="https://img.shields.io/badge/license-Apache--2.0-D22128" alt="Apache License 2.0">
  </p>
</div>

> Technical research prototype focused on destruction, physical coherence, and large-scale
> performance. This is neither a port nor a redistribution of Teardown.

## Features

- Voxel rendering via `CompositorEffect`, GPU BVH, and DDA with 8³ macrocell skipping.
- Material-based destruction and exact six-neighbor connectivity.
- Spatially partitioned Jolt collision, safe static-to-dynamic handoff, and adaptive CCD.
- Content revisions, physics generations, and `COHERENT / PENDING / DESYNC` diagnostics.
- Grabbable props, destructible doors, joints, Verlet ropes, and bidirectional impact damage.
- Batched water with refraction, SSR, foam, waves, splashes, buoyancy, and swimming.
- Imported vehicles with suspension, exterior/cabin camera, and working lights.
- Optional XML/VOX scene importer for local testing with user-provided data.

Subsystem descriptions, ownership, invariants, and measurements are documented in
[ARCHITECTURE.md](ARCHITECTURE.md).

## Requirements

- macOS or Windows x86_64 (the GDExtension descriptor publishes native targets for both).
- Godot 4.7 with Forward+ and Jolt Physics.
- CMake 3.22+, a C++17 compiler, and Ninja recommended (on Windows, MSVC 2019+ or MinGW-w64).

`godot-cpp` is downloaded at the revision pinned by CMake; dependencies, binaries, and build
caches are not checked in.

## Getting started

```bash
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
godot --editor --path .
```

After importing the project, run `main.tscn`. If no external map is configured, the small scenario
included in `assets/models/` loads automatically.

## Optional external maps

Teardown maps, models, and textures are not part of this repository. The importer expects a
converted `main.xml` alongside its `vox/` folder. You can provide a path in three ways:

```bash
# Runtime argument
godot --path . -- --teardown-map=/ruta/al/mapa/main.xml

# Environment variable
SHATTERGRID_MAP=/ruta/al/mapa/main.xml godot --path .

# Conventional local path for the editor and integration probes
mkdir -p external/teardown_maps
ln -s /ruta/a/la/carpeta/del/mapa external/teardown_maps/lee
```

`external/`, compiled maps, and local reference assets are covered by `.gitignore` to prevent
accidental publication.

## Controls

| Input | Action |
|---|---|
| `WASD` | Walk or drive |
| `Shift` | Run |
| `Espacio` | Jump / handbrake |
| Left click | Destructive shot |
| Right click | Grab a door, prop, or fragment |
| `G` / middle click | Throw a bomb |
| `E` | Enter or exit a vehicle |
| Mouse wheel | Vehicle camera zoom |
| `R` | Restart the scene |
| `Esc` | Release the cursor |

## Tests

Self-contained regression tests do not require external data:

```bash
godot --headless --path . --script res://tests/native/core_selftest.gd
godot --headless --path . --script res://tests/selftest/teardown_architecture_selftest.gd
godot --headless --path . --script res://tests/selftest/physics_budget_selftest.gd
godot --headless --path . --script res://tests/selftest/water_system_selftest.gd
```

Each test inherits from `tests/selftest/selftest.gd`, which provides the `failures` counter,
`_check()`, `make_world()`, and `make_box_body()`. Define `_run()` and finish with
`quit(1 if failures > 0 else 0)`; do not override `_init`, since the base implementation already
defers `_run`.

Probes whose names start with `map_`, as well as Lee censuses and full vehicle tests, require
`SHATTERGRID_MAP` or the local map at
`external/teardown_maps/lee`.

## Structure

| Path | Contents |
|---|---|
| `native/` | C++ GDExtension: voxel data, bricks, palettes, and compute-intensive operations |
| `scripts/` | World, physics, importing, renderer, and gameplay systems |
| `shaders/` | DDA, regional uploads, water, and ropes |
| `tests/` | Self-tests, physics probes, and reproducible benchmarks |
| `prototype/` | Isolated renderer experiments |
| `assets/models/` | Included voxel scenario and models with documented attribution |

## License

Unless otherwise noted, the project's original code and materials are distributed under the
[Apache License 2.0](LICENSE). Copyright © 2026
[JulianDr14](https://github.com/JulianDr14).

Apache 2.0 permits using, modifying, and distributing the project, including commercially, without
royalties. Redistributions must retain the license, applicable notices, and attribution in
[NOTICE](NOTICE). Third-party assets listed there retain their respective licenses and are not
relicensed under the project's primary license.

## External data and credits

This project implements publicly documented `Body / Shape / Joint` representation concepts; it
contains no proprietary Teardown code or content. Teardown is owned by Tuxedo Labs and is used only
as a technical reference with files each user provides locally.

`casa_barrio.vox`, `casa_dos_plantas.vox`, and `casa_garaje.vox` are from
[Mini Mike's Metro Minis](https://github.com/mikelovesrobots/mmmm) by Mike Judge, under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) by Mike Judge. The source files are unmodified; axis
and scale conversion takes place during loading.

`icon.svg` adapts the Godot Engine logo, Copyright © 2017 Andrea Calabró, under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). It was adapted as a rounded-square icon
for this project. Details and source links are preserved in [NOTICE](NOTICE).
