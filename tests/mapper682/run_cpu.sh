#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
root="$PWD"
out="${TMPDIR:-/tmp}/nes-mapper682-cpu"
mkdir -p "$out/ghdl"
cd "$out/ghdl"
# GHDL's Verilog net naming collides with the original alu instance and
# ALU_Q signal. Rename only the instance in this temporary simulation copy.
sed 's/alu : entity/cpu_alu_blk : entity/' "$root/rtl/t65/T65.vhd" > cpu.vhd
ghdl -a --std=08 -fsynopsys "$root/rtl/bus_savestates.vhd" \
 "$root/rtl/t65/T65_Pack.vhd" "$root/rtl/t65/T65_ALU.vhd" \
 "$root/rtl/t65/T65_MCode.vhd" cpu.vhd
ghdl --synth --std=08 -fsynopsys --out=verilog T65 > T65.v
sed -i 's/\<break\>/t65_break/g' T65.v
cd "$root"
verilator --binary --timing -Wno-fatal -Wno-BLKANDNBLK \
 --top-module tb_mapper682_cpu --Mdir "$out/obj" -j 4 \
 rtl/regs_savestates.sv tests/mapper682/models.sv "$out/ghdl/T65.v" \
 rtl/mappers/VRC.sv rtl/mappers/Mapper682.sv tests/mapper682/tb_mapper682_cpu.sv \
 > "$out/compile.log" 2>&1
"$out/obj/Vtb_mapper682_cpu"
verilator --binary --timing -Wno-fatal -Wno-BLKANDNBLK \
 --top-module tb_mapper682_irq_cpu --Mdir "$out/irq_obj" -j 4 \
 rtl/regs_savestates.sv tests/mapper682/models.sv "$out/ghdl/T65.v" \
 rtl/mappers/VRC.sv rtl/mappers/Mapper682.sv tests/mapper682/tb_mapper682_irq_cpu.sv \
 > "$out/irq_compile.log" 2>&1
"$out/irq_obj/Vtb_mapper682_irq_cpu"
verilator --binary --timing -Wno-fatal -Wno-BLKANDNBLK \
 --top-module tb_mapper682_services --Mdir "$out/services_obj" -j 4 \
 rtl/regs_savestates.sv tests/mapper682/models.sv "$out/ghdl/T65.v" \
 rtl/mappers/VRC.sv rtl/mappers/Mapper682.sv tests/mapper682/tb_mapper682_services.sv \
 > "$out/services_compile.log" 2>&1
"$out/services_obj/Vtb_mapper682_services"
for bench in irq_sequence irq_transition vector_irq vector_full; do
 verilator --binary --timing -Wno-fatal -Wno-BLKANDNBLK \
  --top-module "tb_mapper682_$bench" --Mdir "$out/${bench}_obj" -j 4 \
  rtl/regs_savestates.sv tests/mapper682/models.sv "$out/ghdl/T65.v" \
  rtl/mappers/VRC.sv rtl/mappers/Mapper682.sv "tests/mapper682/tb_mapper682_$bench.sv" \
  > "$out/${bench}_compile.log" 2>&1
 "$out/${bench}_obj/Vtb_mapper682_$bench"
done
