#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
out="${TMPDIR:-/tmp}/nes-mapper682-roms"
mkdir -p "$out"
# GameLoader is defined after the board top in NES.sv. Extract the unmodified
# module to avoid compiling unrelated HPS/HDMI IP into this standalone test.
sed -n '/^module GameLoader/,$p' NES.sv > "$out/GameLoader.sv"
iverilog -g2012 -s tb_mapper682_roms -o "$out/test.vvp" \
  rtl/regs_savestates.sv tests/mapper682/models.sv "$out/GameLoader.sv" \
  rtl/mappers/VRC.sv rtl/mappers/Mapper682.sv tests/mapper682/tb_mapper682_roms.sv
vvp "$out/test.vvp"
