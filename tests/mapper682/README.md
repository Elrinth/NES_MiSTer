# Rainbow / Mapper 682 regression tests

These tests cover the MiSTer implementation, rather than substituting a software mapper.

The timing defect was also reproduced against the starting mapper: 32 background tile fetches from one physical scanline advanced its scanline counter to 63. It was counting multiple master-clock samples of each PPU read as separate reads. The corrected mapper uses actual PPU dot/scanline timing; the full-frame regression checks this on every dot.

- `run.sh`: FPGA-RAM CPU/PPU arbitration, auto-reader timing at the CPU sampling edge, scroll fine/coarse Y, background extended banks, HUD window coordinates, frame prefetch, IRQ/HBlank timing, EXP6 audio and savestate round-trips. Uses Icarus Verilog.
- `run_ppu.sh`: connects the actual `rtl/ppu.sv` to Mapper682 and checks nametable bytes, extended palettes, CHR addresses and PPU data latches over three frames. Checked frames use extra sprites both disabled and enabled. Uses Verilator 5 with the same procedural-wire declarations that Quartus accepts.
- `run_roms.sh`: feeds the actual `GameLoader` all twelve supplied Rainbow NES 2.0 headers and the current SotN header, then checks every supported PRG/CHR bank in all five modes. It also checks RAM mirroring, the highest background extended bank, and unchanged NROM/MMC3 loader addresses. Uses Icarus Verilog.

Run from the repository root:

```sh
sh tests/mapper682/run.sh
sh tests/mapper682/run_ppu.sh
sh tests/mapper682/run_roms.sh
```

`models.sv` provides simulation equivalents of the existing VHDL block RAM and savestate bus register. Synthesis uses the original VHDL/Altera RAM. The PPU source is not modified for these tests. `run_roms.sh` extracts the original GameLoader module from `NES.sv` for standalone simulation.

To refresh the header fixtures on Windows:

```powershell
python tests/mapper682/prepare_rom_headers.py L:/dev/mapper682_test_roms L:/dev/nes_sotn/web/sotn.nes
```

`rom_inventory.json` records source filenames, full-ROM SHA-256 hashes, sizes, and headers. Only the 16-byte headers are included in fixtures. The loader test fast-forwards payload byte counters to check section transitions; it does not execute the test ROM programs or replace an interactive hardware test of their menu pages.

## Memory layout

Mapper 682 uses SDRAM `$0800000-$0FFFFFF` for PRG-ROM and `$1000000-$17FFFFF` for CHR-ROM, each up to 8MiB. PRG-RAM uses `$03C0000-$03FFFFF`; CHR-RAM uses `$0300000-$033FFFF`. Each RAM region is masked to its declared size. CPU RAM, CIRAM, savestate memory and all other mappers retain their existing addresses. Six upper CHR-bank bits are retained, matching Mesen and the 8MiB ROM signature tests in 512-byte mode. The earlier documentation-based five-bit limit was incorrect for those tests.

## Hardware validation still required

Start with a normal ROM boot using the newly compiled RBF. Old experimental-core save states lack the new audio/mapper latches and use the previous memory layout.

Check SotN's opening stairs while scrolling both ways, the HUD, room transitions, file-select audio and Dracula battle music. Then load the twelve Rainbow ROM variants and exercise their banking, FPGA-RAM, scanline, window and audio pages.

This work does not implement Wi-Fi/ESP, self-flashing, IPCM or EPSM. Those optional pages are not certified as passing. EXP6 and EXP9 select the same VRC6 waveform output, as specified by the Rainbow documentation; they are not separate sets of oscillators.

Reference: https://github.com/BrokeStudio/rainbow-net/blob/master/NES/mapper-doc.md

## 2026-09-10 hardware test follow-up

Before running the new bank/CPU tests, generate their fixtures from the original ROM:

```powershell
python tests/mapper682/prepare_bank_signatures.py L:/dev/mapper682_test_roms/rnbw-mapper-test-8192-chr-rom.nes
```

The user confirmed CHR-RAM tests pass with a CHR-RAM ROM. No CHR-RAM mapping change was made.

Fixed: 512-byte CHR banks now reach the upper 4MiB, and JSR $4280 executes the Slow OAM routine. It supports $4241 shadow page and $4243 last-sprite limit; X/Y remain intact. New controls and CHR bit 13 are included in save states.

- run_banks.sh replays the four original PRG/CHR test tables and checks embedded ROM bank signatures (1,893,172 bus transactions).
- run_cpu.sh executes the original relocated PRG test loop on the actual T65 RTL and checks all 21 test cases. It then executes the generated OAM instructions on T65, checks every output byte, all source pages, selected sprite limits, X/Y preservation and RTS return. Requires GHDL and Verilator.
- run_irq.sh uses the actual PPU to exercise every IRQ offset (0..170), alternating target lines, acknowledge and HBlank waits.
- run_cpu.sh also executes all three original ROM IRQ handlers on T65 using synthetic raster timing. Each handler changes colors across successive frames and returns to a running mainline. This complements the separate real-PPU test; it is not a full-board simulation.

PRG failures and the IRQ-screen freeze reported on hardware have NOT been reproduced in these simulations, and are NOT claimed fixed. CPU tests use a simulated external-memory bus, not a physical SDRAM chip or the complete board top. Hardware confirmation remains required. Slow OAM is implemented; extended OAM update and clear remain unsupported.

## Second hardware follow-up: services revision

The historical paragraph above describes the `testfix` release. The services revision adds:

- NMI/IRQ vector redirection using $416B-$416F, with disabled vectors falling through to the selected PRG bank. NMI vector fetches acknowledge pending scanline IRQs, matching Mesen.
- Executable OAM clear ($4286) and extended-bank update ($4282), including entry-point locking so a running routine does not change when it fetches across another entry point. $4242 selects the 64-byte extended-data page; $4243 limits both update routines.
- Sprite extended banks ($4200-$4240 and $4120.5). The PPU retains each evaluated sprite's original OAM index, including optional extra sprites, so offscreen sprites do not shift bank selection. Both 8x8 and 8x16 sprites are supported with ROM, RAM and FPGA-RAM sources.
- Save-state coverage for new registers, sprite banks and evaluated OAM indices. New PPU state uses slots 13/14; mapper state uses 44 and 54..61, avoiding VRC6 audio state slots 48/49.

`run_cpu.sh` now also runs `tb_mapper682_services.sv`: actual T65 execution of all three service entries, all 32 extended-data pages, selected limits, X/Y behavior, RTS/RTI returns, and redirected IRQ/BRK/NMI handlers.

`run_sprites.sh` exercises the real PPU with alternating visible/offscreen OAM entries, flipping, 8x8/8x16 size, ordinary/extra sprites, and all extended graphics sources. The existing optional extra-sprite evaluator starts after seven matches; the test follows its actual OAM selection without changing that existing behavior. Use **Extra Sprites: Off** when comparing to Mesen with the normal NES sprite limit.

The user confirmed PRG passes in both diagnostic ROM variants using `testfix`. Both local 8MiB originals are accepted by `prepare_bank_signatures.py`; their original PRG test loop and IRQ handlers pass the CPU simulation. `releases/rnbw-mapper-test-8192-rom-ram-diagnostic.nes` applies the same reporting-only diagnostic patch to the exact ROM+RAM variant. It does not alter bank selection or IRQ logic. The originally reported 8K/4K failures remain unconfirmed on a freshly loaded original ROM; no PRG address mapping was changed in this revision.

The user then isolated the freeze to **CPU Cycle IRQ -> PPU Scanline IRQ**. CPU Cycle IRQ displays the expected value 5. The PPU test enables IRQs before replacing the previous CPU test's handler; that handler cannot acknowledge a PPU interrupt. Mesen clears pending scanline IRQ on NMI vector reads. `testfix` did not, allowing a persistent interrupt to starve the mainline. This revision adds that acknowledgement.

`run_cpu.sh` includes two transition tests. `irq_sequence` executes the original CPU count loop and handler, verifies result 5 and disabled CPU IRQ, then runs the PPU handlers. `irq_transition` additionally reproduces the early PPU IRQ with the old handler and the next NMI. The pre-services mapper fails this regression with **Mainline stopped**; the new mapper passes. The test uses real T65 execution, synthetic raster/NMI timing, and a minimal NMI handler in place of the UI/audio handler. It is a targeted reproduction rather than a complete board simulation. Retest the exact menu sequence on hardware.
