`timescale 1ns/1ps
module tb_mapper682_ppu;
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
 integer i,frames=0,checks=0,tx,ty,at_index;
 reg [7:0] expected_tile,expected_ext,expected_nt;
 reg [24:0] expected_pattern;
 reg [7:0] expected_lo,expected_hi;
 reg was_hud;
 task check(input bit ok,input string message);
  begin checks=checks+1;if(!ok)$fatal(1,"%s: frame %0d line %0d dot %0d addr %h got %h",message,frames,line,dot,ppu_addr,chr_out);end
 endtask
 initial begin
  for(i=0;i<2048;i=i+1) ciram[i]=8'hc3;
  repeat(8) @(negedge clk);
  reset=0;enable=1;
  @(negedge clk);
  // Test setup: the real PPU runs freely; only its initial state is seeded.
  ppu.enable_playfield=1;ppu.enable_objects=1;ppu.playfield_clip=1;ppu.object_clip=1;
  ppu.obj_patt=1;
  ppu.vram0.vram_t=15'h53df; // NT0 coarse Y30 X31, fine Y5
  ppu.vram0.vram_v=15'h53df;
  ppu.vram0.vram_x=3'd3;
  for(i=0;i<256;i=i+1) ppu.spriteeval.oam[i]=8'h00;
  dut.chr_mode_reg=8'h13;dut.bg_ext_upper=2;
  dut.nt_ctrl[0]=3;dut.nt_ctrl[1]=7;dut.nt_ctrl[2]=0;dut.nt_ctrl[3]=0;
  dut.split_bank=2;dut.split_ctrl='h8f;
  dut.split_x0=0;dut.split_x1=31;dut.split_y0=0;dut.split_y1=32;
  dut.split_sx=0;dut.split_sy=0;
  for(i=0;i<1024;i=i+1) begin
   dut.fpga_ram.mem[i]=((i%4)<<6) | ((i%31)+1);
   dut.fpga_ram.mem[1024+i]=(((i+1)%4)<<6) | ((i%29)+32);
   dut.fpga_ram.mem[2048+i]=i%251;
   dut.fpga_ram.mem[3072+i]=((i%4)<<6);
  end
  dut.fpga_ram.mem[4095]='hdd;
  run_ppu=1;
 end
 // Exercise simultaneous CPU reads without stealing real PPU fetches.
 always @(negedge clk) if(run_ppu) begin
  cpu_addr='h5fff;cpu_read=(dot[2:0]==4);ce=divider==2;
 end
 always @(posedge clk) if(ppu_ce) begin
  if(line==241 && dot==0) begin
   frames=frames+1;
   if(frames==2) extra_enabled=1;
   if(frames==3) begin
    $display("PASS: real PPU, 3 frames, %0d fetch/latch assertions, extra sprites off/on",checks);
    $finish;
   end
  end
  // Skip startup without pre-render; following frames include both prefetches.
  if(frames>0 && ((line<240)||(line==511 && dot>=321)) &&
     ((dot>=1 && dot<=256)||(dot>=321 && dot<=336))) begin
   if(dot[2:0]==2) begin
    tx=dot>=321 ? (dot-321)/8 : ((dot-1)/8+2)%32;
    ty=dot>=321 ? (line==511?0:line+1) : line;
    was_hud=ty<32;
    if(was_hud) begin
     expected_tile=((ty/8)*32+tx)%251;
     expected_ext=dut.fpga_ram.mem[3072+(ty/8)*32+tx];
    end else begin
     expected_tile=8'hc3;
     at_index=real_ppu_addr[11:10]*1024+real_ppu_addr[9:0];
     expected_ext=real_ppu_addr[11]?0:dut.fpga_ram.mem[at_index];
    end
    check(ppu_input===expected_tile,"PPU sees correct nametable byte");
   end
   if(dot[2:0]==4) begin
    check(ppu.bg_name_table===expected_tile,"PPU name latch");
    if(!real_ppu_addr[11] || was_hud)
      check(ppu_input==={4{expected_ext[7:6]}},"PPU sees correct extended palette");
   end
   if(dot[2:0]==6 || dot[2:0]==0) begin
    expected_pattern=25'h1080000+expected_ext[5:0]*4096+expected_tile*16+
       (dot[2:0]==0?8:0)+(was_hud?ty%8:real_ppu_addr[2:0]);
    if(!ppu.vram[11] || was_hud) begin
     check(chr_out===expected_pattern,"PPU sees correct pattern bank, tile, plane, fine Y");
     if(dot[2:0]==6) expected_lo=pattern_byte(expected_pattern);
     else begin
      check(ppu.bg_painter.bg0===expected_lo,"PPU pattern latch");
     end
    end
   end
  end
 end
 initial begin #15000000;$fatal(1,"real PPU test timeout");end
endmodule

