"""Generate simulator adapters; gameplay datapaths come from production RTL.
Only inactive save/load controllers and non-Rainbow mappers are omitted.
The testbench models external RAM synchronously, not physical SDRAM timing.
"""
from pathlib import Path
import re
import sys
root = Path(__file__).resolve().parents[2]
out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
s = (root / "rtl/nes.v").read_text()
a = s.index("savestates savestates (")
b = s.index("assign sleep_savestate", a)
s = s[:a] + """
assign reset_ss=reset_nes; assign reset_delay=reset_nes;
assign SaveStateBus_Din=0; assign SaveStateBus_Adr=0; assign SaveStateBus_wren=0;
assign SaveStateBus_rst=cold_reset; assign loading_savestate=0; assign saving_savestate=0;
assign sleep_savestates=0; assign sleep_rewind=0;
assign Savestate_RAMAddr=0;assign Savestate_RAMRdEn=0;assign Savestate_RAMWrEn=0;
assign Savestate_RAMWriteData=0;assign Savestate_RAMType=0;
""" + s[b:]
a = s.index("T65 cpu("); b = s.index(");", a)+2
cpu = s[a:b]
for old,new in {"mode":"Mode","res_n":"Res_n","pwr_n":"Pwr_n","clk":"Clk","enable":"Enable","rdy":"Rdy"}.items():
    cpu = re.sub(r"\."+old+r"\b", "."+new, cpu)
s = s[:a]+cpu+s[b:]
s = s.replace("PPU ppu(", "wire [1:0] sim_ppu_type=sys_type;\nPPU ppu(")
s = s.replace(".sys_type         (sys_type)", ".sys_type         (sim_ppu_type)")
(out/"nes_sim.sv").write_text(s)
s = (root/"rtl/cart.sv").read_text()
a = s.index("wire [24:0] rainbow"); b = s.index("\n);",a)+3
inst = s[a:b].replace("me[682]", "1'b1").replace("SaveStateBus_wired_or[41]", "SaveStateBus_Dout").replace("SaveStateRAM_wired_or[4]", "Savestate_MAPRAMReadData")
head = s[:s.index("wire [2:0] prg_aoute")]
(out/"cart_sim.sv").write_text(head+inst+"""
always @* begin
prg_aout=prg_ain<16'h2000 ? {11'b11100000000,prg_ain[10:0]} : rainbow_prg_address;
chr_aout=vram_ce_b ? {11'b11101000000,vram_a10_b,chr_ain[9:0]} : rainbow_chr_address;
prg_allow=prg_allow_b || prg_ain<16'h2000; chr_allow=chr_allow_b;
prg_dout=prg_dout_b;chr_dout=chr_dout_b;vram_ce=vram_ce_b;vram_a10=vram_a10_b;
prg_bus_write=flags_out_b[1];has_chr_dout=flags_out_b[0];has_savestate=1;
prg_conflict=0;prg_conflict_d0=0;has_flashsaves=0;
mapper_addr=0;mapper_data_out=0;mapper_prg_write=0;mapper_ovr=0;diskside=0;
irq=irq_b;audio=audio_out_b;
end
endmodule
""")
