#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
out="${TMPDIR:-/tmp}/nes-mapper682-test.vvp"
iverilog -g2012 -s tb_mapper682 -o "$out" \
  rtl/regs_savestates.sv tests/mapper682/models.sv \
  rtl/mappers/VRC.sv rtl/mappers/Mapper682.sv tests/mapper682/tb_mapper682.sv
vvp "$out"
