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
- **BGM stream player (lossless BGM):** Z80 I/O 0x8800-0x880F; see below.

## Lossless BGM (`rtl/adx_stream.sv`)

With an espgalarr ROM set (the build's default, `--bgm adx`) the soundtrack is the PS2's own: its
Arrange ADX streams, verbatim (`espgalarr_bgm.bin`, 129 MB), played at 48 kHz stereo, full
length, with the tracks' loop points. The release MRA (releases/espgalarr) loads it; a
`--bgm ulaw` build (music in the sample ROM, for plain PGM hardware) has no espgalarr_bgm.bin, so
its MRA must leave out the `<rom index="2">` element.

- **Loading:** a second MRA `<rom index="2" address="0x34000000">` element: Main_MiSTer writes the
  blob straight into DDR3 (about 11 s more per boot); the core ignores download index 2. The
  main stream must stay below 128 MiB (hps_io keeps 27 bits of the length).
- **Registers (Z80 I/O):** 0x8800 W track / R status (bit 0 playing, 1 looped, 2 paused);
  0x8801 W command (1 play, 2 stop, 3 pause, 4 resume, 5 fade out); 0x8802 / 0x8803 W volume
  left / right (0x80 = unity). The Z80 driver writes them (espgalarr asm/z80/adxstream.z80).
- **Decoder:** the PS2's arithmetic (CRI ADXB): `s = clamp16(((7400 h1 - 3342 h2) >> 12) +
  nibble * ((word & 0x1FFF) + 1))`, a 4-cycle pipeline, one stereo sample per 1250 clocks
  (clk_sys / 1250 = 48 kHz, locked to the MiSTer audio clock). At the loop end the history saved
  at the loop start is restored; the loop end is exclusive. The loop start's frame is kept in a
  register, so the jump never waits on DDR.
- **Volume and fades:** the PS2's stream manager's: game volume 220 of 256 (-1 dB), a fade
  takes 4 off it every 800 samples in whole dB (CRI's Q12 gain table: -1 dB = 3648 / 4096),
  a play request while a stream plays fades it out and then starts the new track. All of it is
  bit-exact against PCSX2's SPU2 input (espgalarr spec/lossless-bgm.md).
- **DDR:** `adx_stream_ddr` is the last leaf of the DDR mux (single-beat reads, about 54 KB/s).
- **Mix:** each side = the ICS2115's (L + R) / 4 + the BGM x volume x 286 / 0x10000 (0.5586 at
  the driver's 0x80), saturated; OSD Stereo Mix (status[52:51]). That gain matches the PS2's
  BGM : SFX ratio: 4.53 on the board against the PS2's 4.59 over the same no-input stretch of
  stage 1 (HDMI capture, the BGM separated by its reference decode; PCSX2 SPU2 dump).
- **Savestates:** slot SSIDX_BGM: the stream's position, histories, fade state and the port
  registers; the frames are fetched again after a restore.
- **Tests:** sim/adx_tb (Verilator): `make`, `make LOOP_RESTORE=0`, `make LOOP_END_INCL=1`,
  `make ddr`; espgalarr's work/scratch/audiospike/adxcmp.py compares a track against the
  reference decoder (all 11 tracks bit-exact through their loops, savestate restore, fades).

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
  - **Fast memories on the CPU clock, zero-wait on a hit:**
    - The program ROM cache (2048 x 8-byte lines, looked up every clock, SDRAM channel 3
      behind it).
    - The CPU ports of the work RAM and the 0xd00000 RAM. Both RAMs are m68k_ram_dp2, one clock
      per port. Their 60 MHz ports serve the sprite DMA and savestates.
    - The 0xe00000 RAM's write-back cache (rtl/xram_e_island.sv: one ram_cache, 512 x 32-byte
      lines). Its misses reach DDR through ddr_cdc; savestate accesses cross as toggles.
  - **NVRAM:** loads and saves use the work RAM's CPU port in the clocks the CPU leaves free.
  - **Bridge for every other access:** a request toggle carries the bus cycle to the 60 MHz
    side, which replays it as a 68k bus cycle (the cpu_* signals in PGM.sv). So the IGS023, I/O,
    Z80 latch and the savestate hooks are unchanged.
  - **Bridge return path:** the read data comes back with an acknowledge toggle. The CPU
    waits on DTACK, or VPA for an interrupt acknowledge.
  - **Constraints:** the clocks share a VCO, so each toggle crossing is a timed
    register-to-register path. The bridge and ROM handshakes use the first synchroniser stage
    directly; the 60 MHz side holds a replayed cycle two clocks before taking DTACK. The
    payloads are false paths in Arcade-IGSPGM.sdc.
  - **Savestate hooks:** the sequencer's "supervisor program read" checks also take the
    ROM-cache fetches, which the CPU signals with `sv_fetch`.
- **SDRAM controller:** 3 clocks ACTIVE->READ/WRITE (tRCD); 7 clocks READ->ACTIVE (tRP after
  the auto-precharge); 6 clocks WRITE->ACTIVE; 9 clocks REFRESH->ACTIVE (tRFC).
- **Fit (2026-11-05):** timing met in every corner (worst setup +0.13 ns on clk_cpu), 553/553
  RAM blocks, 60% ALMs.

**Measured speed.** One full attract cycle (three demos and the logo screens), MAME with the
68k scaled vs the board (one screenshot a second, 13-14 cycles):

| Run | Cycle | Effective 68k speed |
|---|---|---|
| MAME 1x / 1.25x / 1.5x / 1.75x / 2x | 181.8 / 168.5 / 164.5 / 162.6 / 161.9 s | |
| Board, 20 MHz build | 184.1 s | about 0.95x |
| Board, 30 MHz build | 165.8 s | about 1.4x |
| Board, island, 0xe00000 bridged | 162.8 s | about 1.7x |
| Board, island, 0xe00000 on the CPU clock | 162.4 s | 1.8x or more |

The demos barely lag above 1.75x, so this test cannot tell 1.8x from 2x. MAME lag by stage: at 1.5x stages 2-6 lag 2.9 / 4.0 / 10.1 / 9.4 / 10.5% of
the frames; at 2x 1.0 / 1.7 / 6.2 / 3.9 / 4.1%.

The sim does not build the island: CPU_ISLAND needs ESPGALARR_CORE, which the sim's C++ does not
support (it reads the IGS022).

## Tested on the board (192.168.1.138, 2026-11-05)

- **Boot:** the core boots to the attract demo with the Arrange title, HUD and sprites.
- **Normal play:** coin and start work, and a game starts.
- **Stage 6 stress test:** a test ROM forced to stage 6 with invincible players (the tool's
  `ESPGAL_FORCE_STAGE=5 ESPGAL_INVINCIBLE=1`) draws full screens of hundreds of bullets plus the
  boss and its parts. In the busy opening stretch the HUD disappears in some screenshots; MAME
  running the same ROM hides it in the same scenes, so this is the game's own behaviour.
- **40 MHz island core:** boots and runs the attract loop (above for its speed) and a game.
- **Sound:** the 60 MHz builds before the ICS2115 enable fix were silent (HDMI capture RMS 0;
  the 20 MHz core and the fixed build about 1600 in the attract demo). The ICS2115 had to run on
  every clock, not on ce_50m.
- **Savestates (2026-11-06, fixed build):** Alt+F1 saves and F1 restores the saved scene. The
  game keeps running after both, and the .ss file is written to savestates/Arcade/. Before the
  fix a save hung on the ICS2115 slot (the 20 MHz core was fine).
- **NVRAM:** OSD "Save Backup RAM" writes config/nvram/<mra name>.nvm (128KB, the work RAM, low
  byte first per word; it matches MAME's work RAM layout). The core boots with it present.
- **Enemy silhouettes:** solid black/blue silhouettes and garbled strips on some Arrange enemies (stage 1 demo, the stage 2 train) are
  in MAME too, frame for frame: the conversion's ROM data, not the core.
- **Lossless BGM (2026-11-06):** with the lossless MRA the title track plays after a coin,
  sample-locked to the reference decode (HDMI capture, constant alignment over 33 s; through
  MiSTer's default output filter). The normal (u-law) entry sounds as before on this core.
- **Lossless BGM fades and savestates (2026-11-06):** the title fades out over 0.9 s in whole-dB
  steps when a game starts and stage 1's track follows; a savestate saved while the title plays
  restores to the saved position and plays on (Alt+F1 / F1); the title loops at its seam.
- **Not checked yet:** audio over a long run.
