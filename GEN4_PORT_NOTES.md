# Terrarium on Gen 4 (Platinum): what is done, what is not

## What the engine already gives us (verified in the engine source)

Gen2Recomped's `main` has a full Gen 4 pipeline (`platinum` in
`src/core/GameVersion.lua`, generation 4, marked experimental). Its overworld is
a real 3D world, not a tilemap:

- `src/render/Gen4Ground.lua` draws terrain chunks and buildings from the
  cartridge's models, with a colour + depth target.
- `src/render/Gen4View.lua` is the camera: `matrix(vw, vh)` (world->clip),
  `project()`, `forward()`, orbit / zoom, first and third person, and
  `field3d` (the cartridge camera at a chosen tilt).
- `src/render/Gen4Camera.lua` holds the cartridge's 17 camera types and the
  CAM TILT ladder.
- World space: +x east, +y up, +z south, 1 unit = 1 map pixel, 16 per tile.
  That is the same convention the voxel scene uses.
- Height query: `Gen4Ground:groundY(px, py)`. Matrix origin: `offsetX/offsetY`.

Two facts drove the design:

1. `manifest.json` `generations` gates loading (`ModGens`). It was `[1,2,3]`, so
   the mod did not load on Platinum at all. Now `[1,2,3,4]`.
2. A `drawWorld` render pipeline REPLACES the engine's world pass. Left alone,
   the `voxel` pipeline would swap Platinum's real 3D world for a voxelised
   tilemap. On Gen 4 it now reports `available = false`.

## What is implemented

- `lib/Gen4Bridge.lua`: the scene provider. Wraps `Gen4Ground:endFree()`. In a
  free camera the engine leaves its canvas open (terrain + buildings +
  characters, live depth buffer) until `endFree`, so drawing just before it is
  depth-tested against the real scene. It feeds `Gen4View:matrix()` into
  `Voxel3D`'s existing external-target + explicit-camera modes, so the whole
  shader (wind, water, tint, glass mask, lamps, fog) works unchanged.
  `Bridge.register(name, fn(scene))` adds an effect. Errors are isolated per
  effect. Engine files are not modified.
- `lib/Gen4Grass.lua`: the voxel scene's own authored grass mesh (`Grass3D`, the
  bake under `assets/ground/grass/`), planted on Gen 4 tall grass only. See the
  grass section below.
- `main.lua`: installs the bridge on a Gen 4 cartridge only; `voxel.available`
  stands down on Gen 4.

## TERRARIUM BATTLES on the Gen 4 start menu

Cause: every other version's start menu passes its rows through the engine's
`ui.start_menu.items` hook, which is how `BattleSettings` adds the row.
`src/ui/Gen4StartMenu.lua` builds its rows from the cartridge and never calls
the hook, so the row never appeared on Platinum.

Fix (engine untouched):
- `lib/Gen4StartMenuHook.lua` wraps `Gen4StartMenu.new/select/drawPanel`. It
  inserts the row before OPTIONS, runs it with the same pop-then-onSelect
  contract as Gen 1's menu, widens the panel to the left if the label is wider
  than the icon-to-edge space, and scrolls the list when there are more rows
  than fit (Platinum's panel holds 7; this makes 8).
- `lib/BattleSettings.lua`: the row is now built by `S.startMenuEntry(game)`,
  shared by the Game Boy hook and the Gen 4 wrapper; the "insert before OPTION"
  check also accepts Platinum's "OPTIONS".
- `main.lua`: installs the wrapper on Gen 4 after `BattleSettings.install`.

I did NOT route Gen 4 through the general `ui.start_menu.items` hook: other rows
on it (Kanto fly, Pallet teleport, etc.) are for the Game Boy games.

Not verified in a running game: that the battle settings screen (generic
`Menu`) lays out correctly on Gen 4's 256x192 surface, and the widened panel's
look. Both are visual.

## Grass on Gen 4 (the voxel scene's own mesh)

`Gen4Grass` no longer has a tuft of its own. It stamps the SAME outside mesh the
voxel scene uses (`Grass3D`: `grass.mesh.bin` + `grass.png`), with the same
instance hash (`Grass3D.instanceForTile`), wind (`Wind.amount` / `Wind.load`),
bend height (`Voxel3D.grassH`) and foot-crush (`Grass3D.crushFrame`).

- **Where:** only tile behaviour 2 (tall grass) and 3 (very tall grass), read from
  `Map:blockAt` (on Gen 4 that IS the behaviour byte), and never where
  `Map:isWaterCell` is true. The earlier version used `Map:isEncounterCell`,
  which is "can a wild Pokemon come from here" and includes surfable water --
  that is why grass grew on lakes.
- **Scale:** the bake is authored for the voxel 8 px tile; Gen 4's is 16. Tufts
  are stamped 2x, and `grassH`, the sway reach and the crush radius are doubled.
- **Height:** one small mesh per (8x8-tile chunk, ground height), drawn
  translated to that height like `ChunkMesher.buildGrassMesh`, because the wind
  shader reads a vertex's raw Y as height above its own root.
- **Bake missing, or GRASS row = VOXEL:** draws nothing (no substitute grass).
  Flipping the GRASS row clears the Gen 4 cache too.
- The bake files are NOT in the zip you sent (no `assets/` folder), so I could
  not check the mesh's vertex count or real height. Chunk size (`CHUNK`, 8) and
  draw radius (`RADIUS`, 3 chunks) are guesses; lower them if it stutters.

## 3D battles on Gen 4 (native world + sprite actors)

`lib/Gen4Battle3D.lua`, diverted to from `OverworldBattle.begin` on Gen 4 (the
voxel arena is never built there: it would replace the game's real world).

- **World:** the engine's own. The battle reports `bgMode() == "world"` so the
  overworld keeps drawing under it (`Game.drawBaseInStack`), undimmed
  (`BG_WORLD_DIM = 0`). The engine's 2D field and 2D pics are switched off
  through `BattleState:drawBattleField` / `drawBattlerPic`, or every Pokemon
  would draw twice.
- **Camera:** `Gen4Ground:placeCamera` is wrapped. It starts at the midpoint of
  the two combatants, looking from behind the player toward the foe, and the
  player can move it: orbit a full turn, raise/lower (clamped to the engine's
  own rise range), zoom (clamped to the engine's zoom range). Inputs are the
  Gen 1-3 battle camera's: mouse, right stick, one-finger drag, wheel, Q/E,
  stick clicks, pinch. `lib/CamControl.lua` now routes them to
  `Gen4Battle3D` while a Gen 4 battle is live (`Gen4Battle3D.live()`). Changes
  ease in; each battle starts from the solved shot again. The player's kept
  orbit/zoom/heading are restored after every call, so the overworld camera is
  exactly where they left it. On a CAM TILT rung the view is switched to the
  third-person lens for the fight (a tilt camera is fixed by design) and
  switched back afterwards.
- **Actors:** the engine's own battle pic (`battle:battlerPic`) stood up as a
  camera-facing quad on the terrain (`groundY`), drawn through `Gen4Bridge` so it
  is depth-tested against buildings and trees. Honours the engine's own
  hidden / fainted / ball-absorb state. SPRITES ONLY: COLOSSEUM and STADIUM rungs
  draw sprites on Gen 4 (no Gen 4 3D models in this pipeline).
- **Foe placement:** 3-4 tiles ahead of the player, on walkable cells, within 12
  units of the player's ground height; tries the player's facing first, then the
  sides, then behind.
- **Cast:** NPCs and the player's own sprite are removed from the draw lists for
  the fight (the Pokemon takes the player's place) and restored afterwards.
- **`wantsFront` is false on Gen 4:** the camera is behind the player, so the
  engine's BACK pic is right.

Declines (the standard 2D Sinnoh battle plays, unchanged): default CARTRIDGE
camera, first person, no clear ground, surfing/water (not walkable cells).
Works in third person and the numeric CAM TILT rungs (via the lens switch above).

Known gaps, not verified or not done:
- Move-animation particles, the thrown ball and the healthboxes are Platinum's
  2D layers placed for DS screen slots; they are NOT tracked to the 3D actors.
- The B rungs (discs) and the disc stage are voxel-only; on Gen 4 they play as
  the world battle.
- Sprite scale (`SCALE = 0.5` units/pixel), foe distance, starting zoom/rise and
  the camera-control speeds (`ORBIT_MOUSE`, `ORBIT_DRAG`, ...) are first guesses
  at the top of the file, untested against a real screen or pad.
- The `CamControl` routing (wheel, mouse, stick, touch) was syntax-checked only;
  it needs the engine's `Game`/`TouchControls`, which the stub harness does not
  fake. The camera controller itself (`Gen4Battle3D.mouseOrbit`, `stepZoom`,
  ...) is tested.
- The player character is hidden for the whole fight, including before the
  send-out, so that side is empty until the Pokemon appears.

## Tested vs untested

Also tested with stubs (`texlua`): foe placement and declines, camera override and
exact restore of the player's look, 2D suppression only for the staged battle,
actor placement/facing/hidden/fainted handling, cast restore, auto-finish.

Tested (stubbed harness, `texlua`): hook fires before the engine closes the
canvas; the matrix reaching `Voxel3D` equals `Gen4View:matrix()` exactly; no-op
on Gen 1/2; a throwing effect is disabled and the scene still closes; syntax of
all edited files.

NOT tested: anything in a running LOVE + Platinum. I have no LOVE runtime or
ROM here. First things to check in-game:
- grass appears on the right cells (Gen 4 may need a different predicate than
  `isEncounterCell`; see `collect()` in `Gen4Grass.lua`);
- depth matches (grass hidden behind buildings, feet not sunk in slopes);
- the log line `Gen4Bridge:` on any failure.

## Not done yet

1. **Cartridge (oblique) rung.** Effects draw only in free cameras (first /
   third person and CAM TILT rungs). The default `cartridge` rung bakes chunks
   with its own depth units (`Gen4Ground:beginWorld` / `screenMatrix`); needs a
   second provider. Workaround: set CAM TILT to a numeric rung.
2. **3D battles with Colosseum models.** Not started. Plan: an arena/battler
   effect registered on the bridge, placed with `scene.groundY`, with the battle
   camera driven through `Gen4View` (orbit/zoom API already exists). Needs a
   read of `src/battle/Gen4Battle.lua` and how the Gen 4 battle state hands
   over the frame.
3. **Glass masks.** The voxel glass mask is keyed to voxel faces. Gen 4
   buildings need per-window data (NSBMD materials), so this is its own task.
4. **Water and puddles** (`GroundFX`, `water_*`): need a water-surface source
   from Gen 4's terrain/behaviours, then the same bridge registration.
5. Grass performance: one draw per tuft (capped at 240). Chunk-baking needs the
   shader's sway to read a per-vertex base height.
6. Shadows/day-night: Gen 4 bakes light into vertex colours (`Gen4Shade`); the
   effect meshes use the mod's tint, so match them via `Voxel3D.tint`.

## Colosseum Battle Environments' OVERWORLD arena on Gen 4 (native world)

CBE's OVERWORLD arena (`ArenaCatalog` `liveOverworld`) used to stage the fight
on a voxel snapshot of the map (`ArenaOverworldSnapshot`). Platinum has no
voxel field, so there was nothing to draw and the actors projected through a
stale `Voxel3D.vp`. Now, on a Gen 4 map:

- `ArenaOverworldSnapshot.capture` still caches the same pocket (`BattleArena`),
  but skips the voxel prefetch and no longer needs `Voxel3D.available()`. It
  defaults the pocket to the `wide` camera rig (the telephoto rig stands five
  tiles back, through a wall on a Sinnoh interior); an authored `cam` wins.
- `ArenaOverworldSnapshot.draw` calls `Gen4WorldHost.renderPose`, which draws
  the cartridge's own terrain and buildings through CBE's OWN camera pose. A
  Gen 4 world is map-local space shifted by `(offsetX, offsetY)`, so a camera at
  pose + offset sees what the pose sees; CBE's actors (map-local, projected
  through the pose) therefore line up with no shift.
- `Arena.lua` keeps its pose-built view-projection for the actors when the field
  is native (`ArenaOverworldSnapshot.nativeWorld()`), and calls
  `ArenaOverworldSnapshot.blit` once the arena canvas is rebound.
- `renderPose` hides the overworld cast (entity/ghost lists) for the call so
  followers and NPCs are not drawn a second time next to the CBE actors, takes
  the colour inside `Gen4Bridge.after` (so grass, water and sand are in it),
  reuses one canvas per size, and restores the camera, `cameraPlaced`, a view it
  created, and the cast whether or not the draw worked.
- `Gen4WorldHost` is reached from the snapshot through `voxel()`: that module
  runs in the Colosseum namespace, which has no `V.require`.

Limits (all visual, none checked in a running LOVE + Platinum):
- The world is laid in as COLOUR ONLY. The engine's depth buffer is a different
  attachment, so buildings and trees cannot hide an actor; the pocket is chosen
  clear, but a camera that ends up behind a wall will show the wall's far side.
- CBE models exist for species 1-386 only (`ColosseumDex`); Gen 4 species 387+
  fall back to whatever CBE already did for them.
- The eye height is the rig's. `Gen4WorldHost.renderBattle` raises its eye by 18
  units; this path cannot (the actors use the same pose), so if the camera clips
  terrain, raise the rig, not the lens.

Found while here (not changed): `Gen4Battle3D.begin` has no caller in this
build -- the section above says `OverworldBattle.begin` diverts to it, but
nothing does, so the live-world sprite battle is installed and never staged.
`Gen4WorldHost.renderBattle` allocates a canvas every call and leaves a
`Gen4View` it created on `ground.view3d`.

Tested with stubs (`tools/test_gen4_arena.lua`, run with `texlua` from the mod
root): camera placement and exact restore, cast hiding, hook timing and
removal, canvas reuse, every failure path, capture/draw/blit and the voxel path
staying on for Gen 1-3.
