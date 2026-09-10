#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
out="${TMPDIR:-/tmp}/nes-mapper682-sprites"
verilator --binary --timing -Wno-fatal -Wno-PROCASSWIRE -Wno-BLKANDNBLK \
 --top-module tb_mapper682_sprites --Mdir "$out" -j 4 \
 rtl/regs_savestates.sv tests/mapper682/models.sv rtl/ppu.sv \
 rtl/mappers/VRC.sv rtl/mappers/Mapper682.sv tests/mapper682/tb_mapper682_sprites.sv \
 > "$out.log" 2>&1
"$out/Vtb_mapper682_sprites"
