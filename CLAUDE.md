# Hex Planet Generator — Developer Notes

## Project overview

Godot 4 procedural planet generator. A sphere is tiled with a Goldberg polyhedra hex grid (dual of a subdivided icosahedron), coloured by a single noise layer, and rendered with atmospheric effects. Four pre-generated LOD levels swap in and out based on camera distance. Cells are interactively selectable; clicking a tile locks the camera to track it as the planet rotates.

---

## File responsibilities

| File | Role |
|------|------|
| `IcoSphere.gd` | Pure data. Builds a subdivided icosahedron: 12 vertices → `10·4ⁿ+2` vertices, `20·4ⁿ` faces after `n` subdivisions. No Godot scene deps. |
| `HexPlanet.gd` | Pure data. Takes an IcoSphere and builds the dual mesh: one hex cell per icosphere vertex. Samples FastNoiseLite for terrain height/type. |
| `PlanetMesh.gd` | Stateless static builder. Converts HexPlanet cells to an ArrayMesh via SurfaceTool. |
| `PlanetGridmap.gd` | Cell picking and outline rendering. Only active at LOD 3. Ray-sphere intersection in planet-local space; hover raycast throttled to once per `_process` frame; lazy-cached ArrayMesh outlines per cell; two MeshInstance3D children reparented under the planet node so they spin with it. |
| `OrbitCamera.gd` | Node3D with Camera3D child. Mouse-drag orbit, scroll zoom. Emits `zoom_changed` and `drag_started`. |
| `Main.gd` | Scene controller. Owns LOD mesh/cell arrays, noise/sea-level computation, atmosphere + axis display creation, LOD switching, and camera lock-on tracking. `@tool` so the Inspector button generates a preview in the editor. |
| `shaders/HorizonMask.gdshader` | `blend_mix` sphere at 1.025× radius. Paints the background colour over polygon edges at the silhouette so the flat hex tiles don't appear to float past the horizon. |
| `shaders/Atmosphere.gdshader` | `blend_add` sphere at 1.08× radius. Soft rim glow beyond the planet disc. |
| `shaders/Planet.gdshader` | Currently unused (kept for future per-tile horizon fade experiments). |

---

## Critical invariants — do not break these

### 1. Polygon winding — sort DESCENDING not ascending

`HexPlanet._sort_around()` sorts by **descending** atan2 angle. This produces counter-clockwise vertex order when viewed from outside the sphere, which gives outward-facing normals and makes the mesh front-facing from outside.

Changing to ascending order reverses the winding. The triangles become back-faces, Godot culls them, and the planet appears invisible (or, with a negative `planet_radius`, the inside-out geometry accidentally becomes front-facing and appears correct in the editor but invisible in-game).

### 2. `blend_mix` not `blend_alpha` for transparency shaders

In Godot 4, `blend_alpha` is not a valid spatial render mode. The correct name is `blend_mix`. Using `blend_alpha` causes the shader to fail silently — the material falls back to opaque rendering. When this happens to the HorizonMask sphere, it renders as a solid opaque sphere slightly larger than the planet, completely covering it (which is why the planet appeared uniformly grey/white during development).

### 3. `preload()` for shader constants — never `load()` inside static functions

`load()` called inside a `static func` can return `null` at runtime in tool-script contexts. Always use class-level `const` with `preload()` and annotate the type explicitly:

```gdscript
const _HORIZON_SHADER: Shader = preload("res://shaders/HorizonMask.gdshader")
```

`:=` on a `preload()` result infers `Variant` and is a compile error when warnings are treated as errors. Explicit `: Shader =` is required.

### 4. Adaptive sea level — `ocean_fraction` not a fixed threshold

FastNoiseLite with FBM can be strongly biased toward positive values for a given seed and sampling scale. A fixed `land_threshold = 0.0` may produce an all-land (all-snow) planet. `_compute_sea_level()` samples the noise at a probe sphere (subdivision 3, 642 vertices) and returns the `ocean_fraction` percentile of the height distribution. This guarantees the target ocean/land ratio regardless of seed or scale.

### 5. SurfaceTool drops ARRAY_COLOR when all vertex colors are identical

If `SurfaceTool.set_color()` is called with the same `Color` for every vertex, Godot drops the color array from the committed mesh as an optimization. The `COLOR` built-in in the fragment shader then defaults to white `(1, 1, 1, 1)`, making the planet appear uniformly white regardless of terrain type. This was the root cause of the all-white planet during development — the noise was returning all-positive values, all cells became `LAND`, and all landed in the same snow color bucket.

### 6. Per-cell flat normals, not per-vertex sphere normals

`PlanetMesh.build()` calls `st.set_normal(cell_normal)` once per cell (not per vertex). All triangles in a cell share the cell-centre sphere normal. This gives each hex tile a consistent flat-facet shading and avoids the intra-cell normal interpolation that causes shading artifacts at the sphere's limb where tiles are viewed at grazing angles.

### 7. Camera min_distance must exceed planet_radius

`OrbitCamera.set_distance_limits()` is called in `Main._ready()` with `planet_radius * 1.1` as the minimum. If the camera enters the planet sphere, the atmosphere/mask spheres' front faces become visible from inside, `dot(NORMAL, VIEW)` inverts, and the rim effects cover the entire view.

### 8. HorizonMask depth interaction

The HorizonMask sphere sits at `1.025 × planet_radius`. Because it is larger than the planet, its fragments at the screen centre are closer to the camera than the planet surface. `depth_draw_never` means it reads but does not write depth. At the centre of the disc, `facing ≈ 1` → `ALPHA ≈ 0`, so it is effectively transparent and the planet surface shows through. Only near the silhouette (facing → 0) does the mask become opaque, covering the polygon edges. Do not increase the mask radius much beyond 1.025 or it will intrude into the visible planet body.

### 9. Outline nodes must be children of the planet mesh node

`PlanetGridmap._hover_mi` and `_select_mi` are reparented under `planet_mesh_instance` in `setup()`. This ensures they inherit the planet's rotation and stay visually glued to the selected tile as the planet spins. If they remain under `Main` or `PlanetGridmap`, they stay fixed in world space while the planet rotates beneath them.

### 10. Raycast uses planet-local space — `affine_inverse()` not `basis.inverse()`

`_raycast()` converts the camera ray into the planet node's local coordinate frame using `global_transform.affine_inverse()` before solving the ray-sphere equation. This keeps picking correct when the planet is rotated (or translated). Using only `basis.inverse()` fails if the planet node has a non-zero world origin. The hit direction from the intersection is already in local space and can be compared directly against `_cell_positions`.

### 11. `_cell_positions` and `_outline_cache` must be rebuilt in `setup()`; hover is throttled to `_process`

`_cell_positions` (a `PackedVector3Array`) is extracted from the new cell array so the raycast loop iterates contiguous floats instead of making dictionary lookups. `_outline_cache` is cleared so stale outline meshes from the previous LOD level are not reused.

`MouseMotion` events only store `_pending_mouse_pos` and set a dirty flag; the actual `_raycast` call happens once per `_process` frame. This prevents the O(10 242) linear scan from running at mouse-event rate (120+ Hz) and also ensures the transform computed after `planet_mesh_instance.rotate()` is already up-to-date when picking fires.

### 12. Camera lock-on stores direction in planet-local space

`Main._lock_cell_local` is the selected cell's `"position"` vector (unit sphere, planet-local). Each frame in `_process`, it is multiplied by `planet_mesh_instance.global_transform.basis` to get the current world-space direction, from which pitch/yaw are extracted as `pitch = -asin(y)`, `yaw = atan2(x, z)`. Storing the world-space direction instead would require updating it every frame regardless of spinning, and would break if the planet were also translated.

---

## Generation pipeline

```
Main._generate_planet()
  └─ _make_noise()                  FastNoiseLite, seed/freq/octaves
  └─ _compute_sea_level(noise)      642-vertex probe → ocean_fraction percentile
  └─ for sub in [2, 3, 4, 5]:
	   IcoSphere.generate(sub)      icosahedron + sub subdivision passes
	   HexPlanet.generate(ico, ...) dual mesh + noise sampling
	   PlanetMesh.build(planet, r)  SurfaceTool → ArrayMesh + StandardMaterial3D
	   _lod_cells.append(planet.cells)
```

LOD switching is purely mesh-swapping on `planet_mesh_instance.mesh`; the four meshes are held in `_lod_meshes: Array[ArrayMesh]` and the four cell arrays in `_lod_cells: Array` (plain untyped array — see gotcha below). Neither is regenerated at runtime. LOD switch calls `planet_gridmap.setup()` with real cells only at LOD 3 (empty array otherwise) and clears the camera lock.

LOD 3 (≤ 4.0 distance) also enables surface-relative camera rotation: each frame in `_process` the camera's forward direction (`orbit_camera.global_transform.basis.z`) is rotated by the same `Basis(_spin_axis, delta)` applied to the planet, then pitch/yaw are re-extracted and pushed via `set_angles`. This runs as an `elif` below the tile-lock branch so tile-lock takes priority.

---

## Godot 4 gotchas encountered

- **`clamp()` returns `Variant`** in GDScript 4 strict mode. Always write `var x: float = clamp(...)`, never `var x := clamp(...)`.
- **Typed for-loop variables** (`for v: Vector3 in array`) require Godot 4.3+.
- **`Array[T]` typed arrays cannot be stored in `Array[U]`** without type erasure, and casting back with `as Array[T]` silently returns an empty array rather than failing loudly. Store cell arrays in a plain `Array` (`_lod_cells: Array`) and use explicit `as Dictionary` / `as Vector3` casts at each access site.
- **`emit_signal("name", ...)`** is the old API. Prefer `signal_name.emit(...)`.
- **`@export_tool_button`** requires Godot 4.3+.
- **`Color.opaque` does not exist** in Godot 4. To strip alpha from a color use `Color(c.r, c.g, c.b, 1.0)`.

---

## Terrain colour ramp

| Height range (relative to sea level) | Colour |
|---------------------------------------|--------|
| Ocean deep → shallow | Dark navy `(0.04, 0.12, 0.42)` → sky blue `(0.18, 0.48, 0.72)` |
| Land low (0–50 %) | Dark green → mid green |
| Land mid (50–80 %) | Mid green → rocky grey |
| Land high (80–100 %) | Rocky grey → snow white |
