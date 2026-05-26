# Hex Planet Generator

A procedural planet generator built in Godot 4. Planets are tiled with a hexagonal grid (Goldberg polyhedra), shaped by a tectonic plate simulation, and coloured with a 19-biome climate system. Rendered with an atmospheric glow and a smooth horizon fade.

## Requirements

Godot 4.3 or later (uses `@export_tool_button` and typed for-loop variables).

## Running

Open `project.godot` in Godot 4 and press **Play** (F5).

## Controls

| Input | Action |
|-------|--------|
| Left-drag | Orbit camera |
| Scroll wheel | Zoom in / out |
| Hover over tile (LOD 3 only) | White outline highlights the tile |
| Click tile (LOD 3 only) | Blue outline selects the tile; camera locks on and tracks it as the planet rotates |
| Left-drag (while locked) | Unlocks camera and resumes free orbit |
| **E** on selected tile | Occupy the tile; opens the local-map and 2D minimap panels |
| — | Sun/orbit happens automatically — the planet orbits the sun at a rate proportional to its spin speed |

## Inspector properties

All properties are live on the **Main** node.

### Planet

| Property | Description |
|----------|-------------|
| `planet_radius` | Radius of the sphere in world units |
| `ocean_fraction` | Target fraction of the surface covered by ocean (0–1). Sea level is the `ocean_fraction` percentile of the tectonic height distribution. |
| `noise_scale` | Spatial scale of the detail noise layer |
| `noise_seed` | RNG seed — change to get a different planet |

### Tectonics

| Property | Description |
|----------|-------------|
| `num_plates` | Number of tectonic plates (4–32) |
| `oceanic_plate_fraction` | Fraction of plates that are oceanic (low-lying). The rest are continental. |
| `mountain_height` | Elevation multiplier for continental collision zones |
| `detail_noise_strength` | Strength of the fine noise blended on top of tectonic heights |

### Atmosphere

| Property | Description |
|----------|-------------|
| `atmosphere_color` | Colour of the rim glow |
| `atmosphere_power` | Controls how tight the glow ring is |
| `horizon_mask_color` | Should match the scene background so polygon edges at the silhouette dissolve into it |

### Rotation

| Property | Description |
|----------|-------------|
| `rotation_speed` | Degrees per second of axial spin |
| `axial_tilt` | Degrees the rotation axis is tilted from vertical |
| `days_per_orbit` | How many full planet rotations make one orbit. Sets `sun_orbit_speed = rotation_speed / days_per_orbit` automatically. |

### Sun

| Property | Description |
|----------|-------------|
| `sun_distance` | Distance from the planet centre to the sun in world units |
| `sun_orbit_speed` | Orbit speed in degrees per second (set automatically from `rotation_speed / days_per_orbit`; do not override manually) |
| `sun_size` | Radius of the visible sun sphere in world units |
| `sun_light_energy` | OmniLight3D brightness |
| `sun_color` | Colour of the sun light and emissive sphere |
| `sun_inclination` | Tilt of the orbital plane in degrees (0 = flat X/Z plane; 23.5 = Earth-like) |

### Editor preview

With the scene open, select **Main** in the scene tree and click **Generate Planet** in the Inspector to preview without running the game. `editor_preview_subdivisions` sets the LOD level used (default 3 = 642 cells). Enable `debug_plates` to colour each tectonic plate instead of biomes.

## Terrain generation

Each planet is generated in three stages:

1. **Tectonic simulation** — N plates are seeded with random positions, types (oceanic/continental), and drift vectors. Plate boundaries are domain-warped to avoid straight arcs. Convergent boundaries build mountains; divergent boundaries form rifts and mid-ocean ridges. A Bellman-Ford relaxation propagates these effects inland.

2. **Sea level** — The `ocean_fraction` percentile of all cell heights is used as `land_threshold`. This guarantees the target ocean/land ratio regardless of seed or plate configuration.

3. **Climate and biomes** — Temperature is driven by latitude and altitude. Moisture follows a Hadley-circulation curve (equatorial wet → subtropical dry → mid-latitude moderate → polar dry), perturbed by noise and a small coastal boost. Each cell is classified into one of 19 biomes.

## Biomes

| Zone | Biomes | Moisture split (low → high) |
|------|--------|-----------------------------|
| Ocean | Deep ocean, Shallow ocean, Tropical ocean, Icy ocean, Coastal ocean, Lake | — |
| Hot (temp > 0.60) | Beach, Desert, Shrubland, Savanna, Tropical rainforest | <0.34 / 0.34 / 0.38 / 0.43 |
| Temperate | Beach, Shrubland, Grassland, Temperate forest, Temperate rainforest | <0.22 / 0.22 / 0.38 / 0.72 |
| Cold | Boreal forest, Tundra | — |
| Alpine | Mountain, Snow, Ice | — |

Lakes are disconnected ocean regions smaller than 2.5 % of the planet surface.

## Level of detail

Four LOD levels are generated at startup. The active level switches automatically based on camera distance.

| LOD | Subdivisions | Cells | Switch distance |
|-----|-------------|-------|----------------|
| 0 | 2 | 162 | > 7.0 |
| 1 | 3 | 642 | > 5.0 |
| 2 | 4 | 2 562 | > 4.0 |
| 3 | 5 | 10 242 | ≤ 4.0 |

Cell picking, hover/select outlines, and tile occupation are only active at LOD 3.
