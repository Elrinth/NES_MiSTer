#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
out="${TMPDIR:-/tmp}/nes-mapper682-board"
python3 tests/mapper682/prepare_board.py "$out/src"
# run_cpu.sh prepares this synthesized production T65.
cpu="${TMPDIR:-/tmp}/nes-mapper682-cpu/ghdl/T65.v"
test -f "$cpu"
verilator --binary --timing -Wno-fatal -Wno-PROCASSWIRE -Wno-BLKANDNBLK \
 --top-module tb_board --Mdir "$out/obj" -j 4 \
 rtl/regs_savestates.sv tests/mapper682/models.sv "$cpu" \
 rtl/mappers/VRC.sv rtl/mappers/Mapper682.sv rtl/ppu.sv rtl/apu.sv \
 rtl/cheatcodes.sv "$out/src/nes_sim.sv" "$out/src/cart_sim.sv" \
 tests/mapper682/tb_mapper682_board.sv > "$out/compile.log" 2>&1
if [ "${1:-}" = "--sweep" ]; then
 for p in 0 1 2 3 4 5 6 7 8 9 10 11; do
  "$out/obj/Vtb_board" +phase="$p"
  "$out/obj/Vtb_board" +phase="$p" +dejitter
 done
elif [ "$#" -gt 0 ]; then
 "$out/obj/Vtb_board" "$@"
else
"$out/obj/Vtb_board"
"$out/obj/Vtb_board" +scenario=1
"$out/obj/Vtb_board" +region=1
"$out/obj/Vtb_board" +region=2
fi
