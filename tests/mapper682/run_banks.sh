#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
out="${TMPDIR:-/tmp}/nes-mapper682-banks.vvp"
iverilog -g2012 -s tb_mapper682_banks -o "$out" \
 rtl/regs_savestates.sv tests/mapper682/models.sv \
 rtl/mappers/VRC.sv rtl/mappers/Mapper682.sv tests/mapper682/tb_mapper682_banks.sv
vvp "$out"
