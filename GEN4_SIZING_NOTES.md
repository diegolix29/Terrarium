# Gen 4 native world: Pokemon sizing

One rule decides how tall a Pokemon is on Platinum's NSBMD world, for **every**
renderer (HD cards, Stadium models, Colosseum models; followers, wilds,
roamers and the player's own Pokemon). It lives in `lib/Gen4PokemonScale.lua`.

```
world height = (6.90 / 0.38)                          -- trainer ref, PokemonActors.WORLD_HEIGHT = 18.16
             * PokemonHeights.presentationRelative(dex) -- canonical metres -> curve/floor/ceiling/body shape
             * 1.5                                      -- Gen 4 world factor (same as the trainer model)
```

A 1.70 m Pokemon is 27.2 units; the Gen 4 trainer is 16 * 1.5 = 24. That is the
same 1.135 ratio the voxel worlds have (18.16 vs 16).

## What was wrong

| Renderer | Before |
| --- | --- |
| HD cards (`Gen4HdPokemon`) | `HDPokemonSheets.applyOverworld` scales every frame to `16 / frameH`: **every species exactly one tile tall**. |
| Colosseum models (`OverworldColosseum`, Colosseum branches of `OverworldStadium` / `StadiumFollower` / `RoamerStadium3D`) | Species height was right but in voxel units: **1.5x too small** next to the Gen 4 trainer/terrain. |
| Stadium models (`OverworldStadium`, `StadiumFollower`, `RoamerStadium3D`) | `Config.pokedexScale = false` -> battle-compressed `StadiumMon` size, no height table, no Gen 4 factor. |
| Player's own Pokemon (`PlayerModel`) | Hardcoded `x2.0` (Colosseum) and `x1.5 x1.7` (Stadium) vs `x1.5` for the human: three different Gen 4 factors. |
| `PokemonHeights` | Stopped at #386; HD sheets / Platinum wilds go to #493. |

## What changed

- `lib/PokemonHeights.lua`: heights for #387-#493 (**hand-entered, verify**);
  new `H.presentationRelative(dex)` = the exact curve PokemonActors applies
  (kept in sync by hand, see the comment there).
- `lib/Gen4PokemonScale.lua` (new): `active()`, `targetHeight(dex)`,
  `cardScale(dex, cardH)`, `stadiumMultiplier(model, dex, StadiumMon)`,
  `colosseumMatrix(...)`. Everything is a pass-through off Platinum, so Gen 1-3
  sizing is untouched.
- Callers: `Gen4HdPokemon`, `OverworldColosseum`, `OverworldStadium`
  (`scaleForDex` Gen 4 branch + Colosseum fallback), `StadiumFollower`,
  `RoamerStadium3D`, `PlayerModel`. Each loads the module with `V.optional`
  and falls back to the previous behaviour if it is missing.

## Known limits / things to check in game

- **#387-#493 have no body-shape entry** in `H.SHAPE`, so winged/long Sinnoh
  species (Staraptor, Honchkrow, Togekiss, Yanmega...) get factor 1.0 instead of
  the 0.80 wing rule Gen 1-3 birds get. Add rows to `H.SHAPE` if they look big.
- HD cards are sized by **frame** height. If a sheet has transparent padding
  above/below the Pokemon, that species will read slightly small; tune with
  `H.BATTLE_BODY_FACTOR`-style overrides or crop the sheet.
- The player's own Stadium-model Pokemon no longer carries the extra `x1.5`
  "presence" boost it had on voxel worlds; it now equals the follower size.
- Generic `model3d` actors in `Gen4WorldHost.drawFieldActors` (`mdl.scale or 4.0`)
  are not species-driven and were not touched.
- `OverworldStadiumConfig` small/large species boosts and `heightOverrides`
  are voxel tuning and are bypassed on Platinum.
