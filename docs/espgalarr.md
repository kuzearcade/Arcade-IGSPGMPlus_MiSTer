# Espgaluda Arrange conversion (espgalarr) core

This branch builds a core for the Espgaluda Arrange conversion (the PS2 Arrange mode on a PGM
DDP2 cartridge set, made by the espgalarr tool). It matches MAME's `espgalarr` machine (the
tool's `patches/mame/enhanced-sprites.diff`). It is installed under its own name so it never
replaces the stock PGM core:

- RBF: `IGSPGMPlus_<date>.rbf` in `_Arcade/cores` (the stock core is `IGSPGM_<date>.rbf`).
- Core name `IGSPGMPlus` (CONF_STR), so settings, NVRAM and savestates are kept apart.
- MRA: `releases/espgalarr/Espgaluda Arrange (espgalarr conversion).mra`, `<rbf>IGSPGMPlus</rbf>`,
  ROMs from `espgalarr.zip` (the tool's `dropin/espgalarr.zip`).

## Hardware differences (GAME_ESPGALARR = 30)

- **RAM at 0xd00000-0xd0ffff (64KB):** the DDP2 cartridge's ARM shared-RAM window, used as plain
  RAM for the bullet pool and the extended sprite list. It is block RAM with a second port for
  the sprite DMA (`xram_d` in `PGM.sv`).
- **RAM at 0xe00000-0xe1ffff (128KB):** extra work RAM. It is DDR-backed through two
  `share_cache` chips (`rtl/espgalarr_xram.sv`), on the DDR ports the ARM uses in other games.
  A cache miss stalls the 68k, as the type-2 ARM shared RAM does.
- **Extended sprite list:** if the 256-entry list at 0x800000 has no terminator, the sprite
  DMA continues with up to 1400 more entries from 0xd0c840 (5 words each), until a zero size
  word. The 68k stays off the bus until the whole list is read, matching MAME's single
  snapshot. That gives 1656 sprites.
- **Program and sound ROMs:** a plain 4MB program ROM and a 12MB sample ROM (ICS 0x400000+).
  No protection chip.

## Sprite engine (`igs023_sprite.sv`, `igs023_buffer.sv`, `igs023_brom_cache.sv`)

- **List storage:** the sprite list and per-sprite drawing state are in block RAMs with 2048
  entries (the old 256-entry arrays are gone).
- **Per-line drawing:** the old engine searched every sprite on every line, which is two
  cycles per sprite. That is too slow for 1656 sprites. Now the prescan files each visible
  sprite under its first screen line. Each line merges the sprites still drawing from the
  previous line with that line's new ones, in list order, so the drawing order is unchanged.
  A line costs time only for the sprites on it.
- **A-ROM (colour) cache:** indexed by address (2048 x 64-bit lines) instead of by sprite
  slot, so sprites sharing graphics share lines.
- **B-ROM (mask) cache:** 1024 x 64-bit lines, address-indexed, in front of SDRAM.

Other games keep their behaviour: the extension is enabled only for GAME_ESPGALARR.

## ESPGALARR_CORE (set in the .qsf)

The block RAM does not fit alongside the protection hardware, so this build leaves out the
IGS027A ARM, the IGS022 and their DDR caches. Their savestate slots report empty, and other
protected games will not run on this RBF. The sprite line-buffer queue is 1024 entries
(4096 otherwise).

Quartus 17.0 fit, 2026-11-05: 25,756 / 41,910 ALMs (61%) and 553 / 553 RAM blocks. Timing
was met on every clock (worst setup slack +0.464 ns).

## Tested on the board (192.168.1.138, 2026-11-05)

- **Boot:** the core boots to the attract demo with the Arrange title, HUD and sprites.
- **Normal play:** coin and start work, and a game starts.
- **Stage 6 stress test:** a test ROM forced to stage 6 with invincible players (the tool's
  `ESPGAL_FORCE_STAGE=5 ESPGAL_INVINCIBLE=1`) draws full screens of hundreds of bullets plus the
  boss and its parts. In the busy opening stretch the HUD disappears in some screenshots; MAME
  running the same ROM hides it in the same scenes, so this is the game's own behaviour.
- **Not checked yet:** savestates, and audio over a long run.
