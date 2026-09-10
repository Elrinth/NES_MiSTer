`timescale 1ns/1ps
module tb_mapper682_irq;
 reg clk=0;
 always #5 clk=~clk;
 reg ce=0, enable=0, paused=0;
 reg [15:0] cpu_addr=0;
 reg cpu_read=0, cpu_write=0;
 reg [7:0] cpu_data=0;
 wire [13:0] ppu_addr, real_ppu_addr, extra_addr;
 wire ppu_read, ppu_write, extra, rendering;
 wire [8:0] dot,line;
 wire [7:0] ppu_data;
 reg [15:0] apu=16'h4000;
 tri [24:0] prg_out,chr_out;
 tri [7:0] cpu_out,ppu_out;
 tri [15:0] audio,flags;
 tri prg_allow,chr_allow,a10,nt_enable,irq;
 reg [63:0] ss_in=0;
 reg [9:0] ss_addr=0;
 reg ss_write=0,ss_reset=0,ss_load=0;
 wire [63:0] ss_out;
 wire [7:0] ram_out;
 Mapper682 dut(
  .clk(clk),.ce(ce),.enable(enable),.flags(64'd0),.paused(paused),
  .prg_ain(cpu_addr),.prg_read(cpu_read),.prg_write(cpu_write),.prg_din(cpu_data),
  .prg_aout_b(),.prg_address(prg_out),.prg_rom_mask(12'hfff),.chr_rom_mask(12'hfff),.prg_dout_b(cpu_out),.prg_allow_b(prg_allow),
  .chr_ain(ppu_addr),.chr_ain_o(real_ppu_addr),.chr_ex(extra),
  .ppu_dot(dot),.ppu_line(line),.ppu_rendering(rendering),
  .chr_read(ppu_read),.chr_write(ppu_write),.chr_din(ppu_data),
  .chr_aout_b(),.chr_address(chr_out),.chr_dout_b(ppu_out),.chr_allow_b(chr_allow),
  .vram_a10_b(a10),.vram_ce_b(nt_enable),.irq_b(irq),
  .audio_in(apu),.audio_b(audio),.flags_out_b(flags),
  .SaveStateBus_Din(ss_in),.SaveStateBus_Adr(ss_addr),.SaveStateBus_wren(ss_write),
  .SaveStateBus_rst(ss_reset),.SaveStateBus_load(ss_load),.SaveStateBus_Dout(ss_out),
  .Savestate_MAPRAMactive(1'b0),.Savestate_MAPRAMAddr(13'd0),
  .Savestate_MAPRAMRdEn(1'b0),.Savestate_MAPRAMWrEn(1'b0),
  .Savestate_MAPRAMWriteData(8'd0),.Savestate_MAPRAMReadData(ram_out)
 );

 reg [1:0] divider=0;
 reg run_ppu=0,reset=1,extra_enabled=0;
 wire ppu_ce=run_ppu && divider==3;
 always @(posedge clk) divider<=divider+1'b1;
 wire [1:0] system_type=2'b00;
 wire [7:0] ppu_input=flags[0] ? ppu_out :
     nt_enable ? ciram[{a10,ppu_addr[9:0]}] : pattern_byte(chr_out);
 reg [7:0] ciram[0:2047];
 assign ppu_addr=extra ? extra_addr : real_ppu_addr;
 // Distinct bitplanes and fine-Y rows expose one-dot bank/plane slips.
 function [7:0] pattern_byte(input [24:0] address);
  pattern_byte=address[7:0] ^ address[15:8] ^ {2'b0,address[21:16]};
 endfunction
 PPU ppu(
  .clk(clk),.cs(1'b0),.RWn(1'b1),.rst_behavior(1'b0),.ce(ppu_ce),
  .debug_dots(1'b0),.reset(reset),.cold_reset(reset),.sys_type(system_type),
  .vs_ppu_type(4'd0),.din(8'd0),.ain(3'd0),.read(1'b0),.write(1'b0),
  .vram_r(ppu_read),.vram_r_ex(extra),.vram_w(ppu_write),
  .vram_addr(real_ppu_addr),.vram_a_ex(extra_addr),
  .vram_dbus_in(ppu_input),.vram_dout(ppu_data),.scanline(line),.cycle(dot),
  .extra_sprites(extra_enabled),.mask(2'b00),.render_ena_out(rendering),
  .SaveStateBus_Din(64'd0),.SaveStateBus_Adr(10'd0),.SaveStateBus_wren(1'b0),
  .SaveStateBus_rst(1'b0),.SaveStateBus_load(1'b0),
  .Savestate_OAMAddr(8'd0),.Savestate_OAMRdEn(1'b0),.Savestate_OAMWrEn(1'b0),
  .Savestate_OAMWriteData(8'd0)
 );

integer i,j,k,waited;
task clocks(input integer n);repeat(n)begin @(posedge clk);#1;end endtask
task wr(input [15:0] a,input [7:0] d);
 begin @(negedge clk);cpu_addr=a;cpu_data=d;cpu_write=1;clocks(4);
 @(negedge clk);ce=1;clocks(1);@(negedge clk);ce=0;cpu_write=0;clocks(2);end
endtask
task status_read;
 begin @(negedge clk);cpu_addr='h4151;cpu_read=1;clocks(4);
 @(negedge clk);ce=1;clocks(1);@(negedge clk);ce=0;cpu_read=0;clocks(2);end
endtask
task wait_irq;
 begin waited=0;while(!irq&&waited<400000)begin clocks(1);waited=waited+1;end
 if(!irq)$fatal(1,"IRQ wait froze at line%0d dot%0d offset%0d",line,dot,i);end
endtask
initial begin
 for(j=0;j<2048;j=j+1)ciram[j]=0;
 clocks(8);reset=0;enable=1;
 @(negedge clk);ppu.enable_playfield=1;ppu.enable_objects=1;
 ppu.playfield_clip=1;ppu.object_clip=1;
 for(j=0;j<256;j=j+1)ppu.spriteeval.oam[j]=0;
 run_ppu=1;
 // Exercise the ROM's disable/rearm handlers and its BIT $4151 / BPL
 // HBlank wait across every legal IRQ offset, with real PPU read timing.
 for(i=0;i<=170;i=i+1)begin
  wr('h4152,0);wr('h4153,i);wr('h4150,143);wr('h4151,0);
  wait_irq();
  if(line!=143)$fatal(1,"Wrong IRQ line");
  wr('h4152,0);
  waited=0;
  while(!dut.ppu_in_hblank&&waited<4000)begin status_read();waited=waited+12;end
  if(!dut.ppu_in_hblank)$fatal(1,"HBlank wait froze offset%0d line%0d dot%0d render%b waited%0d",i,line,dot,rendering,waited);
  wr('h4150,144);wr('h4151,0);wait_irq();
  status_read();if(irq)$fatal(1,"Status read failed to acknowledge IRQ");
 end
 $display("PASS real PPU: offsets 0..170, alternating scanlines, IRQ ack and HBlank waits");$finish;
end
initial begin #1000000000;$fatal(1,"IRQ test timeout");end
endmodule
