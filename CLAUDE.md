# Hex Planet Generator — Developer Notes

## Project overview

Godot 4 procedural planet generator. A sphere is tiled with a Goldberg polyhedra hex grid (dual of a subdivided icosahedron). Terrain is generated via a tectonic plate simulation (Voronoi plates, domain-warped boundaries, Bellman-Ford elevation propagation) and coloured using a 19-biome classification system driven by latitude, altitude, temperature, and moisture. Four pre-generated LOD levels swap in and out based on camera distance. At LOD 3 cells are interactively selectable; pressing **E** on a selected cell occupies it and opens a 2D local-map panel showing the surrounding ring of neighbours.

---

## File responsibilities

| File | Role |
|------|------|
| `IcoSphere.gd` | Pure data. Builds a subdivided icosahedron aligned so one pentagon pair lands at local ±Y (the planet's geographic poles). |
| `HexPlanet.gd` | Pure data. Builds the dual mesh and runs two generation passes. Pass 1: tectonic simulation (`_build_tectonic_heights`) → per-cell height and type. Pass 2: climate (temperature, moisture) → 19-biome classification. Also runs a flood-fill lake-detection pass between the two. Each cell dict has keys `position`, `polygon`, `height`, `type`, `pentagon`, `temperature`, `moisture`, `biome`, `plate_id`, `plate_oceanic`. Exposes `biome_name(biome)` as the single authoritative int→String mapping used by LocalMap and HexMap2D. |
| `HexMap2D.gd` | 2D `Control` panel. Procedurally generates a flat hex minimap for the local area around the selected cell, using the same `_classify_biome` and `terrain_color` functions as the planet surface. Panel title comes from `HexPlanet.biome_name` applied to the pre-computed biome passed via `setup()`. Static `_UNIT_HEX_OFFSETS` and `_SLOT_DIRS` are precomputed once to avoid per-frame trig and per-tile sqrt calls. |
| `PlanetMesh.gd` | Stateless static builder. Converts HexPlanet cells to an ArrayMesh via SurfaceTool. Exposes `terrain_color()` and `_biome_color()` as public statics so `LocalMap` and `HexMap2D` share the same colour palette. Supports `debug_plates` mode to colour by tectonic plate. |
| `PlanetGridmap.gd` | Cell picking, hover/select outlines, occupation (fill meshes), and neighbour graph. Only active at LOD 3. Builds the adjacency graph from shared polygon vertices once per `setup()` call. |
| `LocalMap.gd` | 2D CanvasLayer panel. Shows a flat-top hex minimap of the ring-1 (and optionally ring-N) neighbours around an occupied cell. Orientation is always aligned with the camera view. |
| `OrbitCamera.gd` | Node3D with Camera3D child. Mouse-drag orbit, scroll zoom, idle auto-orbit, and north-roll correction that keeps orbital north (world Y) at the top of the screen. |
| `Main.gd` | Scene controller. Owns LOD mesh/cell arrays, planet spin (explicit basis rebuild each frame), atmosphere + axis display, LOD switching, and local-map wiring. `@tool` for in-editor preview. |
| `Sun.gd` | `@tool` Node3D that manages the emissive sun sphere, OmniLight3D, and orbital position computation. Exposes `get_planet_position()` which Main reads each frame to move `_planet_pivot`. The sun stays at world origin; only the planet pivot moves. |
| `shaders/HorizonMask.gdshader` | `blend_mix` sphere at 1.025× radius. Covers polygon edges at the silhouette so flat hex tiles don't appear to float past the horizon. |
| `shaders/Atmosphere.gdshader` | `blend_add` sphere at 1.08× radius. Soft rim glow beyond the planet disc. |

---

## Critical invariants — do not break these

### 1. Polygon winding — sort DESCENDING not ascending

`HexPlanet._sort_around()` sorts by **descending** atan2 angle. This produces counter-clockwise vertex order when viewed from outside the sphere, which gives outward-facing normals and makes the mesh front-facing from outside.

Changing to ascending order reverses the winding. The triangles become back-faces, Godot culls them, and the planet appears invisible (or, with a negative `planet_radius`, the inside-out geometry accidentally becomes front-facing and appears correct in the editor but invisible in-game).

### 2. `blend_mix` not `blend_alpha` for transparency shaders

In Godot 4, `blend_alpha` is not a valid spatial render mode. The correct name is `blend_mix`. Using `blend_alpha` causes the shader to fail silently — the material falls back to opaque rendering. When this happens to the HorizonMask sphere, it renders as a solid opaque sphere slightly larger than the planet, completely covering it.

### 3. `preload()` for shader constants — never `load()` inside static functions

`load()` called inside a `static func` can return `null` at runtime in tool-script contexts. Always use class-level `const` with `preload()` and annotate the type explicitly:

```gdscript
const _HORIZON_SHADER: Shader = preload("res://shaders/HorizonMask.gdshader")
```

`:=` on a `preload()` result infers `Variant` and is a compile error when warnings are treated as errors. Explicit `: Shader =` is required.

### 4. Adaptive sea level — `ocean_fraction` percentile of tectonic heights

After `_build_tectonic_heights()` returns the per-vertex elevation array, `generate()` sorts it and picks the `ocean_fraction` percentile as `land_threshold`. This guarantees the target ocean/land ratio regardless of seed, plate count, or convergence strength. `land_threshold` is stored on the `HexPlanet` instance and used by both biome classification and `PlanetMesh.terrain_color()`.

### 5. SurfaceTool drops ARRAY_COLOR when all vertex colors are identical

If `SurfaceTool.set_color()` is called with the same `Color` for every vertex, Godot drops the color array from the committed mesh. The `COLOR` built-in in the fragment shader then defaults to white, making the planet appear uniformly white.

### 6. Per-cell flat normals, not per-vertex sphere normals

`PlanetMesh.build()` calls `st.set_normal(cell_normal)` once per cell. All triangles in a cell share the cell-centre sphere normal, giving each hex tile consistent flat-facet shading.

### 7. Camera min_distance must exceed planet_radius

`OrbitCamera.set_distance_limits()` is called with `planet_radius * 1.1` as the minimum. If the camera enters the planet sphere, the atmosphere/mask spheres' front faces become visible from inside and the rim effects cover the entire view.

### 8. HorizonMask depth interaction

The HorizonMask sphere sits at `1.025 × planet_radius`. `depth_draw_never` means it reads but does not write depth. At the screen centre `facing ≈ 1` → `ALPHA ≈ 0`, so it is transparent and the planet shows through. Only near the silhouette (facing → 0) does the mask become opaque. Do not increase the mask radius much beyond 1.025 or it will intrude into the visible planet body.

### 9. Outline nodes must be children of the planet mesh node

`PlanetGridmap._hover_mi` and `_select_mi` are reparented under `planet_mesh_instance` in `setup()`. This ensures they inherit the planet's rotation and stay visually glued to the selected tile.

### 10. Raycast uses planet-local space — `affine_inverse()` not `basis.inverse()`

`_raycast()` converts the camera ray into the planet node's local coordinate frame using `global_transform.affine_inverse()` before solving the ray-sphere equation. Using only `basis.inverse()` fails if the planet node has a non-zero world origin.

### 11. `_cell_positions` and `_outline_cache` must be rebuilt in `setup()`; hover is throttled to `_process`

`_cell_positions` (a `PackedVector3Array`) is extracted from the new cell array so the raycast loop iterates contiguous floats instead of making dictionary lookups. `_outline_cache` is cleared so stale outline meshes from the previous LOD level are not reused.

`MouseMotion` events only store `_pending_mouse_pos` and set a dirty flag; the actual `_raycast` call happens once per `_process` frame.

### 12. Camera lock-on stores direction in planet-local space

`Main._lock_cell_local` is the selected cell's `"position"` vector (unit sphere, planet-local). Each frame in `_process`, it is multiplied by `planet_mesh_instance.global_transform.basis` to get the current world-space direction, from which pitch/yaw are extracted. Storing the world-space direction instead would require updating it every frame.

### 13. Planet spin uses an explicit basis rebuild each frame

`Main._process()` computes `planet_mesh_instance.basis = _tilt_basis * Basis(Vector3.UP, _spin_angle)` from scratch each frame. This avoids floating-point drift from incremental rotations and guarantees the spin axis is provably aligned with the `RotationAxis` line. `_tilt_basis` is pre-computed once in `_ready()` from `axial_tilt`.

### 14. Tilemap orientation uses camera-relative north, not geographic north

`LocalMap._build_region()` receives `cam_up_local` = orbital north (world Y) in planet-local space at the current spin moment, computed by `Main._cam_up_local()`. This keeps the tilemap aligned with the camera view regardless of the planet's axial tilt or current spin angle. Using a fixed planet-local Y instead would cause the tilemap to be systematically misrotated relative to what the user sees on screen, by up to ±axial_tilt degrees.

### 15. `PlanetMesh.terrain_color()` is the single authoritative colour ramp

Both `PlanetMesh.build()` and `LocalMap._draw()` call `PlanetMesh.terrain_color()`. Do not duplicate this function. The public static signature takes `(height, type, land_threshold, highlight_pentagon)` — individual values, not a cell dictionary.

`HexPlanet.biome_name(biome)` is the single authoritative biome int→String mapping. Both `LocalMap._cell_description()` and `HexMap2D.setup()` call it. Do not add a third copy of the `match biome:` block.

### 16. Occupation radius equals map_rings

`planet_gridmap.occupation_radius` and `_local_map.rings` are both set from `Main.map_rings`. This enforces that two occupied cells are always at least `map_rings` hops apart (guaranteeing no overlap in their displayed local maps). Keep these in sync.

### 17. `_planet_pivot` owns all planet visuals; `sun_orbit_speed` is derived

`_planet_pivot` is created in `Main._ready()` and is the parent of all planet visuals (mesh, atmosphere, axis lines, orbit camera). Moving `_planet_pivot` moves everything uniformly. Every frame `Main._process()` calls `_sun.get_planet_position()` and assigns the result to `_planet_pivot.position`, so the planet orbits the stationary sun at world origin.

`_sun.sun_orbit_speed` is set from `rotation_speed / days_per_orbit` so spin and orbit are always proportional — one full orbit takes exactly `days_per_orbit` planet rotations. Do not set `sun_orbit_speed` independently; always derive it via this ratio.

---

## Generation pipeline

```
Main._generate_planet()
  └─ _make_noise()                       FastNoiseLite (seed, freq, octaves)
  └─ for sub in [2, 3, 4, 5]:
       IcoSphere.generate(sub)           icosahedron + sub subdivision passes
       HexPlanet.generate(ico, noise, …)
         ├─ _build_tectonic_heights()    plates → Bellman-Ford elevation
         ├─ sorted percentile → land_threshold
         ├─ pass 1: height / type / polygon per cell
         ├─ flood-fill lake detection    (PackedInt32Array BFS)
         └─ pass 2: temperature / moisture / biome per cell
       PlanetMesh.build(planet, r)       SurfaceTool → ArrayMesh
       _lod_cells.append(planet.cells)
```

LOD switching is purely mesh-swapping on `planet_mesh_instance.mesh`; the four meshes are held in `_lod_meshes: Array[ArrayMesh]` and the four cell arrays in `_lod_cells: Array` (plain untyped array — see gotcha below). Neither is regenerated at runtime. LOD switch calls `planet_gridmap.setup()` with real cells only at LOD 3 (empty array otherwise) and clears the local map.

`rotation_speed` and `days_per_orbit` together control both spin and orbit. After generation, `Main` sets `_sun.sun_orbit_speed = rotation_speed / days_per_orbit`. The effective orbit rate is therefore **orbit = rotation_speed / days_per_orbit deg/s** — one full orbit equals exactly `days_per_orbit` axial rotations.

---

## Godot 4 gotchas encountered

- **`clamp()` returns `Variant`** in GDScript 4 strict mode. Always write `var x: float = clamp(...)`, never `var x := clamp(...)`.
- **Typed for-loop variables** (`for v: Vector3 in array`) require Godot 4.3+.
- **`Array[T]` typed arrays cannot be stored in `Array[U]`** without type erasure, and casting back with `as Array[T]` silently returns an empty array rather than failing loudly. Store cell arrays in a plain `Array` (`_lod_cells: Array`) and use explicit `as Dictionary` / `as Vector3` casts at each access site. Corollary: function parameters that receive arrays flowing out of `_lod_cells` must also be `Array`, not `Array[Dictionary]` — otherwise Godot throws "Trying to assign an array of type Array to a variable of type Array[Dictionary]" at the call site.
- **`emit_signal("name", ...)`** is the old API. Prefer `signal_name.emit(...)`.
- **`@export_tool_button`** requires Godot 4.3+.
- **`Color.opaque` does not exist** in Godot 4. To strip alpha from a color use `Color(c.r, c.g, c.b, 1.0)`.

---

## Biome system

`HexPlanet._classify_biome()` (static, called from `generate()`, `HexMap2D`, and `LocalMap`) maps each cell to one of 19 constants:

**Ocean** — `BIOME_DEEP_OCEAN`, `BIOME_SHALLOW_OCEAN`, `BIOME_TROPICAL_OCEAN`, `BIOME_ICY_OCEAN`, `BIOME_COASTAL_OCEAN`, `BIOME_LAKE`

**Hot zone** (temperature > 0.60) — `BIOME_BEACH`, `BIOME_TROPICAL_RAINFOREST`, `BIOME_SAVANNA`, `BIOME_SHRUBLAND`, `BIOME_DESERT`

**Temperate zone** — `BIOME_BEACH`, `BIOME_GRASSLAND`, `BIOME_SHRUBLAND`, `BIOME_TEMPERATE_FOREST`, `BIOME_TEMPERATE_RAINFOREST`

**Cold zone** — `BIOME_BOREAL_FOREST`, `BIOME_TUNDRA`

**Alpine** — `BIOME_MOUNTAIN`, `BIOME_SNOW`, `BIOME_ICE`

Moisture thresholds:

**Temperate zone** (0.38 ≤ temperature < 0.60):

| Biome | Moisture range |
|-------|---------------|
| Shrubland | < 0.22 |
| Grassland | 0.22 – 0.38 |
| Temperate forest | 0.38 – 0.72 |
| Temperate rainforest | > 0.72 |

**Hot zone** (temperature ≥ 0.60):

| Biome | Moisture range |
|-------|---------------|
| Desert | < 0.34 |
| Shrubland | 0.34 – 0.38 |
| Savanna | 0.38 – 0.43 |
| Tropical rainforest | > 0.43 |

Savanna and shrubland are intentionally narrow bands so rainforest and desert each cover roughly a third of the hot-zone moisture range.

Key rules:
- Deep ocean is suppressed when `near_land` (ocean cell adjacent to land) — prevents dark navy touching the coastline.
- `_classify_biome` accepts an optional `near_land: bool = false` parameter. `HexMap2D._map_title` passes `near_land = (moisture > 0.5)` as a proxy for coastal ocean cells (coastal moisture boost lifts them above 0.5) so the panel title matches the rendered tile colour.
- Snow/ice never border the ocean — coastal high-altitude cells become `BIOME_MOUNTAIN`.
- Lakes are disconnected ocean regions smaller than `n_verts / 40` cells.
