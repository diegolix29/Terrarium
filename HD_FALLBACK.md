# HD 2D fallback (National Dex 1-493)

Animated HD sheets for Pokemon that have **no 3D model**. Stadium/Colosseum
models still win wherever they exist; this only fills the gap.

## What draws it
| Seam | File | Notes |
|---|---|---|
| Billboard cards (all overworld/Platinum battles) | `lib/OverworldBattle.lua` `textures()` -> `HDPokemonSheets.applyToTextures` | Primary. Independent of the Colosseum disc. A side with no sheet keeps the native pic. |
| `CurrentSpriteModels` `battleSprites` v1 | `main.lua` registration + `spriteApi` | Only when the Colosseum build is ready. |

`CurrentSpriteModels` gets one narrow exception: for a species the Colosseum
actor catalog cannot model (dex 387-493) *that has a sheet installed*, the
"CBE owns the battle, never draw 2D" rule is lifted. Nothing else changes.

## Getting sheets

**One tap (needs the new `network` permission):** OPTIONS -> mod menu -> **HD SHEETS**.
Press it to download and install; press it again while downloading to cancel.
The value column shows `DOWNLOAD 43%`, `UNPACK 120/893`, then `N/493` = how many
Pokemon have both a front and a back sheet. It is pumped every frame from
`input.step`, works without the Colosseum disc, and resumes safely (files already
installed at the same size are skipped).

`lib/HDSheetInstaller.lua` streams each release ZIP with the engine's `Fetch`,
reads it directly and copies **only** `assets/battle/hd-pokemon/<front|back>/<normal|shiny>/NNN[-x].png`
for **dex 1-493** into `mod.cache` (`hd_sheets/...`). Files for 494+ are never
written, and nothing assumes the pack stops at 386. The log line at the end
reports 1-386 and 387-493 coverage separately.

Default source: `HaseoSora/Kanto-in-Motion-Assets` v1.0.0 (what KIM downloads).
**I could not check from here what that release contains above dex 386.** If it
has none, the row will read `386/493`-ish; add a Gen 4 pack as a second entry in
`HDSheetInstaller.config.sources` (same folder layout) and it is fetched in the
same run.

**Geometry for 387-493.** KIM's tables (ported) stop at 386, so a downloaded
387-493 sheet has no row and draws as ONE static frame at the default scale. To
animate it, run `tools/build_gen4_sheets.py` on your GIFs (it writes the row into
`data/hd_sheet_meta_gen4.lua`), or hand-write the row
`["400"] = {frameW, frameH, columns, frames, displayScale}`.

**By hand:** sheets are found by file existence, in this order:
1. `mod.cache`: `hd_sheets/<front|back>/<normal|shiny>/<stem>.png`
2. the mod: `assets/hd-pokemon/<front|back>/<normal|shiny>/<stem>.png`

`<stem>` is `NNN`, `NNN-m` / `NNN-f` (gender) or `NNN-<form>` (e.g. `487-origin`).
To build sheets from GIFs: `python tools/build_gen4_sheets.py <gifs-or-zip> --out hd-pokemon`
(names: `400-front-n.gif`, `400-back-s.gif`, `403-front-n-m.gif`, `487-origin-front-n.gif`).

A missing file, or a form with no file (e.g. Giratina-Origin), leaves the native
Platinum art. Anything above dex 493 is ignored.

## If the HD SHEETS row errors

The full reason is in the game log (`[error] ... HD sheet installer: ...`).
The installer picks a route by what your engine build offers:

1. the engine's `ModUpdate` release checker (what KIM uses);
2. else `Fetch.download` + GitHub's release list, picked by the installer itself
   (older engines, e.g. below KIM's `>=0.1.69`);
3. else it stops and the log lists which engine functions exist and which are
   missing (`src.mods.ModUpdate`, `src.net.Fetch`).

**Manual route (no network, works on any engine):** download the release ZIP from
`https://github.com/HaseoSora/Kanto-in-Motion-Assets/releases` in a browser, save it
as `terrarium_hd_sheets_pack.zip` in the game's save folder (the log prints the
path), press the HD SHEETS row. It is validated and installed exactly like a
download, and your ZIP is never deleted. It needs the engine's random-access save
filesystem (not portable mode).

If you changed permissions, restart the game / re-enable the mod so `network` is
granted.

## Toggle
Battle menu -> **HD 2D FALLBACK ON/OFF** (`terrariumBattle.hdSheetsEnabled`).

## Sizing (tunable)
* Billboard path: `cardW/H = frame * displayScale` (KIM's HD px -> GB px), so
  per-species size matches KIM. Sheets with no metadata row use 0.33 front /
  0.315 back; override per species with `--scales scales.json`.
* CSM path: CSM normalises to one slot height, so frames are top-padded to keep
  KIM's ratio. Tune `HDPokemonSheets.config.slotFront / slotBack` (90 / 112).

## Not changed (deliberately)
`ColosseumDex*` (`MAX_DEX = 386`) is a species-definition registry with save
data, not an art cap. `StadiumWilds` 386 checks gate the Colosseum actor.
`Stadium.dexOf` / `OverworldColosseum` were already 493.

## Known limits
* The billboard swap replaces the engine-baked pic, so the engine's faint
  slide / blink / squish are not applied to HD-swapped species (hit flash is).
* Verified with mocks (`texlua tests/hd_sheets_test.lua` 72 checks,
  `texlua tests/hd_installer_test.lua` 61 checks, incl. real ZIP + DEFLATE):
  **not verified in the running game, and the real GitHub download was never run.**

## Credits
Sheet geometry ported from *Kanto in Motion* v1.6.0 (HaseoSora). HD art:
JDChaos, *Battle Sprites Reloded*. KIM ships no license file; the loader here is
written independently and only KIM's dimension data is carried over. Please
confirm reuse terms with the KIM author before redistributing.
