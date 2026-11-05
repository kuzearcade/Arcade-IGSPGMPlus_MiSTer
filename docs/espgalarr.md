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

## Clocks: 60 MHz system, 40 MHz 68k in its own domain (espgalarr only)

The arcade 68k (20 MHz) overruns its frame in busy scenes: MAME lags 23-38% of the frames in
stages 2-6, the PS2 0.6-1.8%. The game paces itself on vblank, so a faster 68k only removes
those lag frames; the logic per step is unchanged (MAME with the 68k scaled 1.5x and 2x gives
the same bullet samples in stages 3-6 as at 1x).

- **PLL:** SDRAM 120 MHz, system (clk_sys) 60 MHz, CPU (clk_cpu) 80 MHz, all from one VCO.
- **ce_50m:** a 50 MHz enable (5 clocks in 6) that every system timing is derived from: pixel
  clock, ICS2115, Z80, RTC, the IGS027A.
- **CPU_ISLAND (rtl/cpu_island.sv, qsf macro):**
  - **Clocking:** fx68k runs on clk_cpu, one phase per clock, so the 68k is at 40 MHz. Other
    games take a phase every other clock (20 MHz).
  - **Fast memories on the CPU clock, zero-wait:** the program ROM cache (2048 x 8-byte lines,
    looked up every clock, SDRAM channel 3 behind it), and the CPU ports of the work RAM and the
    0xd00000 RAM. Both RAMs are m68k_ram_dp2, one clock per port. Their 60 MHz ports serve the
    sprite DMA and savestates.
  - **NVRAM:** loads and saves use the work RAM's CPU port in the clocks the CPU leaves free.
  - **Bridge for every other access:** a request toggle carries the bus cycle to the 60 MHz
    side, which replays it as a 68k bus cycle (the cpu_* signals in PGM.sv). So the IGS023, I/O,
    Z80 latch, the DDR-backed 0xe00000 RAM and the savestate hooks are unchanged.
  - **Bridge return path:** the read data comes back with an acknowledge toggle. The CPU
    waits on DTACK, or VPA for an interrupt acknowledge.
  - **Constraints:** the toggles cross through two-flop synchronisers (timed). The payloads are
    false paths in Arcade-IGSPGM.sdc.
  - **Savestate hooks:** the sequencer's "supervisor program read" checks also take the
    ROM-cache fetches, which the CPU signals with `sv_fetch`.
- **SDRAM controller:** 3 clocks ACTIVE->READ/WRITE (tRCD); 7 clocks READ->ACTIVE (tRP after
  the auto-precharge); 6 clocks WRITE->ACTIVE; 9 clocks REFRESH->ACTIVE (tRFC).
- **Fit (2026-11-05):** timing met in every corner (worst setup +0.48 ns on clk_cpu), 553/553
  RAM blocks, 61% ALMs.

**Measured speed.** One full attract cycle (three demos and the logo screens), MAME with the
68k scaled vs the board (one screenshot a second, 13-14 cycles):

| 68k | MAME 1x | 1.25x | 1.5x | 1.75x | 2x | board 30 MHz build | board 40 MHz (island) |
|---|---|---|---|---|---|---|---|
| cycle | 181.8 s | 168.5 s | 164.5 s | 162.6 s | 161.9 s | 165.8 s (about 1.4x) | 162.8 s (about 1.7x) |

The island loses about 15% to its bridged accesses: about 3 extra clocks a cycle, mostly to
the 0xe00000 RAM. MAME lag by stage: at 1.5x stages 2-6 lag 2.9 / 4.0 / 10.1 / 9.4 / 10.5% of
the frames; at 2x 1.0 / 1.7 / 6.2 / 3.9 / 4.1%.

The sim builds the island with `make CPU_ISLAND=1` (clk_cpu = the system clock there).

## Tested on the board (192.168.1.138, 2026-11-05)

- **Boot:** the core boots to the attract demo with the Arrange title, HUD and sprites.
- **Normal play:** coin and start work, and a game starts.
- **Stage 6 stress test:** a test ROM forced to stage 6 with invincible players (the tool's
  `ESPGAL_FORCE_STAGE=5 ESPGAL_INVINCIBLE=1`) draws full screens of hundreds of bullets plus the
  boss and its parts. In the busy opening stretch the HUD disappears in some screenshots; MAME
  running the same ROM hides it in the same scenes, so this is the game's own behaviour.
- **40 MHz island core:** boots and runs the attract loop (above for its speed); a full game,
  savestates and NVRAM saving are not checked yet on it.
- **Enemy silhouettes:** solid black/blue silhouettes and garbled strips on some Arrange enemies (stage 1 demo, the stage 2 train) are
  in MAME too, frame for frame: the conversion's ROM data, not the core.
- **Not checked yet:** savestates, and audio over a long run.
