# Stadium 2 Port Notes

## Overview
This document describes the integration of Pokemon Stadium 2 support into the Terrarium Advance Mod, extending the existing Stadium 1 implementation (151 Pokemon) to support all 251 Pokemon with shiny variants.

## What Was Ported

### Core Stadium 2 Files
- **StadiumRom2.lua**: ROM reader for Pokemon Stadium 2 (US) cartridge
- **Stadium2Pack.lua**: Pack loader for Stadium 2 models (DSM4 format)
- **Stadium2Install.lua**: Installation system for Stadium 2 models
- **Stadium2Animations.lua**: Animation decoder for Stadium 2 skeletal animations
- **Stadium2Palette.lua**: Palette system for Stadium 2 shiny variants
- **Stadium2RomPick.lua**: ROM import interface with file picker
- **Stadium2Integration.lua**: Unified interface for both Stadium 1 and Stadium 2
- **Stadium2Setting.lua**: Settings module for Stadium 2 control and status display
- **Stadium2Screen.lua**: Build progress screen for Stadium 2 model extraction

### Integration Points
- **Stadium.lua**: Modified to use Stadium2Pack for Gen 2 Pokemon (152-251)
- **StadiumMon.lua**: Updated to load from appropriate pack based on species number
- **ShinyPalette.lua**: Extended with Stadium 2 shiny palette support
- **ShinyBattle.lua**: Integrated with Stadium2Integration for unified access
- **SettingsMenu.lua**: Added Stadium 2 ROM import row
- **main.lua**: Added Stadium 2 model building and ROM polling
- **Stadium2Setting.lua**: New module for Stadium 2 settings and status display

## Key Differences from Stadium 1

### ROM Structure
- **Stadium 1**: Single archive with 151 Pokemon models
- **Stadium 2**: Dual archive system (282 entries each)
  - Model archive at 0x027ED000
  - Animation bank archive at 0x02D7D000
  - National Dex 1-251 map to archive entries 1-251

### Model Format
- **Stadium 1**: DSM3 format
- **Stadium 2**: DSM4 format (extended with animation routing data)

### Animation System
- **Stadium 1**: Packed per-frame streams for 146 species, hermite-keyframe for 5 species
- **Stadium 2**: Separate animation banks with auxiliary animation support

### Shiny System
- **Stadium 1**: HSL slide per species, 5 species with explicit LUTs
- **Stadium 2**: Rare colour operation in species metadata, dedicated texture support

## Species Numbering

The system automatically routes to the appropriate pack loader:
- **1-151**: Stadium 1 (Gen 1 Pokemon) - uses existing StadiumPack
- **152-251**: Stadium 2 (Gen 2 Pokemon) - uses new Stadium2Pack

## User Workflow

### First-Time Setup
1. Player places Pokemon Stadium (US) 1.0 ROM in baseroms/ for Gen 1 support
2. Player places Pokemon Stadium 2 (US) ROM in baseroms/ for Gen 2 support
3. Or uses the OPTIONS menu file pickers to import ROMs
4. Models are built automatically on first run
5. Both ROMs can be present simultaneously

### ROM Validation
- **Stadium 1**: MD5 `ed1378bc12115f71209a77844965ba50`
- **Stadium 2**: MD5 `1561c75d11cedf356a8ddb1a4a5f9d5d`

## Compatibility Notes

### Save Games
- Stadium 1 and Stadium 2 models are cached separately
- Marker files: `pack.info` (Stadium 1) and `pack2.info` (Stadium 2)
- ROM swapping is detected via MD5 comparison

### Backward Compatibility
- Existing Stadium 1 setups continue to work unchanged
- Stadium 2 is completely optional
- System gracefully falls back to sprites when models unavailable

### Performance
- Stadium 2 models are loaded on-demand (LRU cache)
- Animation decoding is lazy (only loaded when played)
- Shiny variants use palette conversion rather than separate models

## Testing Notes

### Manual Testing Checklist
- [ ] Stadium 1 ROM import works (Gen 1 Pokemon)
- [ ] Stadium 2 ROM import works (Gen 2 Pokemon)
- [ ] Gen 1 Pokemon (1-151) use Stadium 1 models
- [ ] Gen 2 Pokemon (152-251) use Stadium 2 models
- [ ] Shiny variants work for both generations
- [ ] Battle animations play correctly
- [ ] Faint animations work properly
- [ ] Model scaling and positioning is correct
- [ ] ROM swap detection works
- [ ] Cache invalidation on format changes

### Known Limitations
- Stadium 2 animation routing table not fully mapped (uses generic routing)
- Some Stadium 2 animation features may be simplified
- Stadium 2 specific effect callbacks not fully implemented
- Build process is simplified compared to full Voxel Ultimate implementation

## Future Enhancements

### Priority 1 (Core Functionality)
- Complete Stadium 2 animation routing table
- Implement Stadium 2 effect callback system
- Add Stadium 2 texture animation support

### Priority 2 (Enhanced Features)
- Stadium 2 boss room support
- Stadium 2 trainer portrait system
- Stadium 2 announcer audio system
- Stadium 2 move-specific animations

### Priority 3 (Optimization)
- Shared texture cache between Stadium 1 and 2
- Unified model loading system
- Memory usage optimization for large Pokemon counts

## Troubleshooting

### Stadium 2 Models Not Loading
1. Check ROM MD5 matches expected hash
2. Verify ROM is Pokemon Stadium 2 (US), not Japanese version
3. Check baseroms/ directory exists and is writable
4. Check pack2.info marker file exists
5. Look for build errors in console output

### Gen 2 Pokemon Showing as Sprites
1. Verify Stadium 2 ROM is present
2. Check Stadium 2 models have been built
3. Confirm species number is in 152-251 range
4. Check Stadium2Pack.available() returns true

### Shiny Variants Not Working
1. Verify shiny palette data is available
2. Check ShinyPalette.stadium2Palette() returns valid data
3. Confirm Pokemon DVs indicate shiny
4. Check Stadium2Pack.load() with shiny=true works

## Credits

### Original Voxel Ultimate
- Stadium 2 implementation based on Voxel Ultimate mod's StadiumBattleFX 2.1.7
- ROM layout information from pret/pokestadiumgs decompilation project
- Animation system research from StadiumBattleFX217 module

### Integration Work
- Ported and adapted for Terrarium Advance Mod architecture
- Integrated with existing Stadium 1 infrastructure
- Added unified loading system for both Stadium versions