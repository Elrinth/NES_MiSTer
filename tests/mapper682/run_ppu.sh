#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
out="${TMPDIR:-/tmp}/nes-mapper682-ppu"
# The existing PPU uses Quartus's procedural-wire extension. No PPU logic is
# changed for simulation; these switches accept those declarations and the
# bench's initial state seeding. Inspect the saved compile log on a failure.
verilator --binary --timing -Wno-fatal -Wno-PROCASSWIRE -Wno-BLKANDNBLK \
  --top-module tb_mapper682_ppu --Mdir "$out" -j 8 \
  rtl/regs_savestates.sv tests/mapper682/models.sv rtl/ppu.sv \
  rtl/mappers/VRC.sv rtl/mappers/Mapper682.sv tests/mapper682/tb_mapper682_ppu.sv \
  > "${out}.log" 2>&1
"$out/Vtb_mapper682_ppu"
