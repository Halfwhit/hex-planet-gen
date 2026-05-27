# Hex Planet Generator

A procedural solar system simulator built in Godot 4. Multiple planets orbit a central sun, each tiled with a hexagonal grid (Goldberg polyhedra), shaped by a tectonic plate simulation, and coloured with a 19-biome climate system. Rendered with atmospheric glow, distance-dependent soft terminators, and PCSS planet-on-planet shadows.

## Requirements

Godot 4.3 or later (uses `@export_tool_button` and typed for-loop variables).

## Running

Open `project.godot` in Godot 4 and press **Play** (F5).

## Controls

| Input | Action |
|-------|--------|
| Left-drag | Orbit camera |
| Scroll wheel | Zoom in / out |
| Click a planet (solar view) | Enter focus mode — camera follows that planet |
| Escape | Return to solar view |
| Hover over tile (LOD 3, focus mode) | White outline highlights the tile |
| Click tile (LOD 3, focus mode) | Blue outline selects the tile; camera locks on and tracks it as the planet rotates |
| Left-drag (while locked) | Unlocks camera and resumes free orbit |
| **E** on selected tile | Occupy the tile; opens the local-map panel |

## Inspector properties

Properties are set per planet node (**Planet1**–**Planet4**) and on the **Sun** node.

### Orbit

| Property | Description |
|----------|-------------|
| `orbit_distance` | Distance from the sun (world origin) to the planet centre |
| `orbit_speed` | Degrees per second around the sun |
| `orbit_inclination` | Tilt of the orbital plane in degrees (0 = flat X/Z plane) |
| `orbit_phase` | Starting angle in degrees — staggers planets around the system |

### Planet

| Property | Description |
|----------|-------------|
| `planet_radius` | Radius of the sphere in world units |
| `sun_radius` | Visual radius of the sun sphere — used to compute `sun_angular_size = sun_radius / orbit_distance`, which sets how wide the soft terminator is |
| `ocean_fraction` | Target fraction of the surface covered by ocean (0–1) |
| `noise_seed` | RNG seed — change to get a different planet |
| `noise_scale` | Spatial scale of the detail noise layer |
| `axial_tilt` | Degrees the rotation axis is tilted from vertical |
| `rotation_speed` | Degrees per second of axial spin |

### Tectonics

| Property | Description |
|----------|-------------|
| `num_plates` | Number of tectonic plates (4–32) |
| `oceanic_plate_fraction` | Fraction of plates that are oceanic (low-lying) |
| `mountain_height` | Elevation multiplier for continental collision zones |
| `detail_noise_strength` | Strength of fine noise blended on top of tectonic heights |

### Atmosphere

| Property | Description |
|----------|-------------|
| `atmosphere_color` | Colour of the rim glow |
| `atmosphere_power` | Controls how tight the glow ring is |
| `horizon_mask_color` | Should match the scene background so polygon edges at the silhouette dissolve into it |

### Sun

| Property | Description |
|----------|-------------|
| `sun_size` | Radius of the visible sun sphere in world units |
| `sun_light_energy` | OmniLight3D brightness |
| `sun_color` | Colour of the sun light and emissive sphere |
| `shadow_blur` | PCSS light-source size — higher values make planet-on-planet shadows softer, with the penumbra growing naturally with blocker-to-receiver distance |

### Editor preview

With the scene open, select a Planet node in the scene tree and click **Generate Planet** in the Inspector to preview without running the game. `editor_preview_subdivisions` sets the LOD level used (default 3 = 642 cells). Enable `debug_plates` to colour each tectonic plate instead of biomes.

## Terrain generation

Each planet is generated in three stages:

1. **Tectonic simulation** — N plates are seeded with random positions, types (oceanic/continental), and drift vectors. Plate boundaries are domain-warped to avoid straight arcs. Convergent boundaries build mountains; divergent boundaries form rifts. A Bellman-Ford relaxation propagates these effects inland.

2. **Sea level** — The `ocean_fraction` percentile of all cell heights is used as `land_threshold`, guaranteeing the target ocean/land ratio regardless of seed or plate configuration.

3. **Climate and biomes** — Temperature is driven by latitude and altitude. Moisture follows a Hadley-circulation curve perturbed by noise and a coastal boost. Each cell is classified into one of 19 biomes.

## Lighting

The sun uses an `OmniLight3D` at world origin. Two distance-dependent effects are applied:

- **Soft terminator** (`Planet.gdshader`): the day/night boundary is widened proportionally to `sun_radius / orbit_distance`. Inner planets see a large sun disc and have a broad twilight zone; outer planets see a small disc and have a sharp terminator.
- **PCSS shadows**: `shadow_blur > 0` activates Percentage Closer Soft Shadows in Godot's Forward+ renderer. Shadow penumbra width scales with the distance between the casting and receiving planet — conjunctions of close planets produce hard shadows, while distant pairs produce soft diffuse ones.

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

Four LOD levels are generated at startup per planet. The active level switches automatically based on camera distance from the planet.

| LOD | Subdivisions | Cells | Switch distance |
|-----|-------------|-------|----------------|
| 0 | 2 | 162 | > 3.5× radius |
| 1 | 3 | 642 | > 2.5× radius |
| 2 | 4 | 2 562 | > 2.0× radius |
| 3 | 5 | 10 242 | ≤ 2.0× radius |

Cell picking, hover/select outlines, and tile occupation are only active at LOD 3.
