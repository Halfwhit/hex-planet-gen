# Hex Planet Generator

A procedural planet generator built in Godot 4. Planets are tiled with a hexagonal grid (Goldberg polyhedra) and rendered with noise-driven terrain, an atmospheric glow, and a smooth horizon fade.

## Requirements

Godot 4.3 or later (uses `@export_tool_button` and typed for-loop variables).

## Running

Open `project.godot` in Godot 4 and press **Play** (F5).

## Controls

| Input | Action |
|-------|--------|
| Left-drag | Orbit camera |
| Scroll wheel | Zoom in / out |

## Inspector properties

All properties are live on the **Main** node.

| Property | Description |
|----------|-------------|
| `planet_radius` | Radius of the sphere in world units |
| `ocean_fraction` | Target fraction of the surface covered by ocean (0–1). Sea level is computed adaptively from the noise distribution so this stays accurate across seeds. |
| `noise_scale` | Spatial scale of the noise sampling |
| `noise_seed` | RNG seed — change to get a different planet shape |
| `atmosphere_color` | Colour of the rim glow |
| `atmosphere_power` | Controls how tight the glow ring is |
| `horizon_mask_color` | Should match the scene background colour so the polygon edges at the silhouette dissolve into it |
| `rotation_speed` | Degrees per second of axial spin |
| `axial_tilt` | Degrees the rotation axis is tilted from vertical |

### Editor preview

With the scene open, select **Main** in the scene tree and click **Generate Planet** in the Inspector to preview the planet without running the game. The `editor_preview_subdivisions` property controls the LOD level used for this preview (default 3 = 642 cells, faster than the full LOD 5).

## Level of detail

Four LOD levels are generated at startup. The active level switches automatically based on camera distance.

| LOD | Subdivisions | Cells | Switch distance |
|-----|-------------|-------|----------------|
| 0 | 2 | 162 | > 7.0 |
| 1 | 3 | 642 | > 5.0 |
| 2 | 4 | 2 562 | > 3.0 |
| 3 | 5 | 10 242 | ≤ 3.0 |

## Planned steps

- **Step 2** — Tectonic plates and realistic continental shapes
- **Step 3** — Biome simulation (temperature, precipitation)
- **Step 4** — River and erosion simulation
- **Step 5** — Vegetation and natural resources
