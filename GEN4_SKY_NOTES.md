# Gen 4: the voxel sky, and hiding the engine's horizon image

Files (drop into the mod, same paths):
- `lib/Gen4Sky.lua`        NEW
- `lib/Gen4Bridge.lua`     CHANGED (adds `registerPre` / `runPre`, and installs Gen4Sky). Diff is small.
- `tools/test_gen4_sky.lua` NEW. Run `texlua tools/test_gen4_sky.lua` from the mod root (57 checks).
- `main.lua` needs NO change: `Gen4Bridge.install()` pulls Gen4Sky in.

## What draws
Same modules and same settings as Gen 1-3, in the voxel scene's own order, BEFORE the terrain:
Sky.paint (bands, clouds, glow, sun/moon, stars, fog, rainbow, rain curtain, god rays) -> HorizonArt ->
SkyLayer (star dome, shooting stars, cloud decks, birds, planes, blimps) -> Backdrop -> scenery ring.
Skyline is not drawn (it needs the Gen 1-3 connection graph).

## The seam
`Gen4Model.draw` is wrapped; on the first shape of each `Gen4Ground:drawFree` (canvas bound, depth clear)
the sky is painted, then the engine draws the world over it. Nothing the sky draws can occlude anything.

## Hiding the engine horizon (three nets, I could not see the engine source)
a. the canvas colour is cleared to the haze (depth untouched) before the sky paints;
b. engine functions named draw/paint/render + horizon/sky/backdrop/panorama (Gen4Ground, Tilt, a few
   likely modules) are no-op'd for the length of drawFree, then restored. Log lines: `Gen4Sky: hiding engine call ...`;
c. shapes whose material/texture says skybox/horizon/panorama are skipped.
If the image is still there: `Gen4Sky.LOG_CANDIDATES = true`, read the log, put the name in `Gen4Sky.HIDE_EXTRA`.

## Fixed along the way
`Backdrop.drawOverworldScenery` draws one 200x100 quad at the player's feet and its plane builder is declared
after its use, so it never ran. Gen4Sky replaces it (on Gen 4 only) with a real ring of the scenery image
just inside the panorama. Backdrop.lua itself is untouched, so Gen 1-3 behave as before.

## Knobs (all on the module)
`enabled, sky2d, horizonArt, skyLayer, backdrop, scenery, hideHorizon, autoHide, FAR, FAR_FIT, SCENERY,
SCENERY_HEIGHT, CELL_ROWS, HIDE_EXTRA, SHAPE_WORDS`. `Bridge.setEffect("sky", false)` turns the 3D layers off.

## Not verified (no LOVE, no ROM here)
- Whether the engine's horizon is caught by net a, b or c. This is the one to check first.
- Gen4View's far plane: read from view.far/zFar/farPlane. If none exists the panorama is drawn at radius 900;
  if it does not show, set `Gen4Sky.FAR`.
- Sky mesh tint (Voxel3D.tint) on Gen 4, and the pixel size of the dither grid (`CELL_ROWS`).
- Free cameras only (third/first person, numeric CAM TILT). The default CARTRIDGE rung is not covered.
