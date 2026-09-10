`timescale 1ns/1ps
module tb_mapper682_sprites;
 reg clk=0;
 always #5 clk=~clk;
 reg ce=0, enable=0, paused=0;
 reg [15:0] cpu_addr=0;
 reg cpu_read=0, cpu_write=0;
 reg [7:0] cpu_data=0;
 wire [5:0] origin,origin_ex; wire large_sprite;
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
  .sprite_oam_index(extra ? origin_ex : origin),.sprite_size_16(large_sprite),
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
  .sprite_oam_index(origin),.sprite_oam_index_ex(origin_ex),.sprite_size_16(large_sprite),
  .extra_sprites(extra_enabled),.mask(2'b00),.render_ena_out(rendering),
  .SaveStateBus_Din(64'd0),.SaveStateBus_Adr(10'd0),.SaveStateBus_wren(1'b0),
  .SaveStateBus_rst(1'b0),.SaveStateBus_load(1'b0),
  .Savestate_OAMAddr(8'd0),.Savestate_OAMRdEn(1'b0),.Savestate_OAMWrEn(1'b0),
  .Savestate_OAMWriteData(8'd0)
 );

 integer i,frames=0,checks=0,slot,index,bank,offset;
 reg [24:0] expected;
 initial begin
  for(i=0;i<2048;i=i+1)ciram[i]=0;
  repeat(8)@(negedge clk); reset=0;enable=1;@(negedge clk);
  ppu.enable_playfield=1;ppu.enable_objects=1;ppu.playfield_clip=1;ppu.object_clip=1;
  ppu.obj_patt=1;ppu.obj_size=0;
  dut.chr_mode_reg='h23;dut.sprite_ext_bank=2;
  for(i=0;i<8192;i=i+1)dut.fpga_ram.mem[i]=(i&255)^(i>>8);
  for(i=0;i<64;i=i+1)begin
   ppu.spriteeval.oam[i*4]=i%2?40:255;
   ppu.spriteeval.oam[i*4+1]=i;
   ppu.spriteeval.oam[i*4+2]=(i%4)*64;
   ppu.spriteeval.oam[i*4+3]=i*4;
   dut.sprite_ext[i]=i*7;
  end
  extra_enabled=1;run_ppu=1;
 end
 always @(posedge clk)if(ppu_ce)begin
  if(line==241 && dot==0)begin
   frames=frames+1;
   ppu.obj_size=frames>=2;
   if(frames==3)dut.chr_mode_reg='h63;
   if(frames==4)dut.chr_mode_reg='ha3;
   if(frames==5)dut.chr_mode_reg='he3;
   if(frames==6)begin
    if(checks<90)$fatal(1,"Insufficient sprite fetch coverage: %0d",checks);
    $display("PASS %0d real PPU sprite fetches: skipped OAM entries, normal/extra sprites, 8x8/8x16, ROM/RAM",checks);
    $finish;
   end
  end
  if(frames>0 && line==42 && dot>=257 && dot<320 && ppu_read && !ppu_addr[13])begin
   // The existing core's optional extra-sprite evaluator begins after seven
   // matches (its three-bit spr_counter saturates at seven). Follow the
   // actual evaluated sprite, including its duplicated eighth sprite.
   slot=(dot-256)/8;index=slot*2+1+(extra?14:0);bank=(index*7)&255;
   if((extra?origin_ex:origin)!==index)$fatal(1,"Wrong sprite origin: slot%0d extra%b got%0d expected%0d",slot,extra,extra?origin_ex:origin,index);
   offset=(2*(large_sprite?2097152:1048576)+bank*(large_sprite?8192:4096)+(ppu_addr&(large_sprite?8191:4095)))&'h7fffff;
   expected=frames==3?'h300000+(offset&'h7fff):'h1000000+offset;
   if(frames<4)begin
    if(chr_out!==expected)$fatal(1,"Sprite bank mismatch: %h expected%h",chr_out,expected);
   end else if(!flags[0] || ppu_out!==(((offset&8191)&255)^((offset&8191)>>8)))
    $fatal(1,"FPGA sprite data mismatch at %h got %h",offset,ppu_out);
   checks=checks+1;
  end
 end
 initial begin #28000000;$fatal(1,"Sprite test timeout");end
endmodule
