`timescale 1ns/1ps
module tb_mapper682;
 reg clk=0;
 always #5 clk=~clk;
 reg ce=0, enable=0, paused=0;
 reg [15:0] cpu_addr=0;
 reg cpu_read=0, cpu_write=0;
 reg [7:0] cpu_data=0;
 reg [13:0] ppu_addr=0, real_ppu_addr=0;
 reg ppu_read=0, ppu_write=0, extra=0, rendering=0;
 reg [8:0] dot=0,line=0;
 reg [7:0] ppu_data=0;
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
 integer checks=0;
 task check(input bit ok,input string msg);
   begin checks=checks+1; if(!ok) $fatal(1,"%s (line %0d dot %0d)",msg,line,dot); end
 endtask
 task clocks(input integer n);
   repeat(n) begin @(posedge clk); #1; end
 endtask
 task write_cpu(input [15:0] a,input [7:0] d);
   begin
    @(negedge clk); cpu_addr=a; cpu_data=d;cpu_write=1;
    clocks(4); @(negedge clk);ce=1;clocks(1);
    @(negedge clk);ce=0;cpu_write=0;clocks(2);
   end
 endtask
 task fetch(input integer ln,input integer dt,input [13:0] addr);
   begin
    @(negedge clk);line=ln;dot=dt;ppu_addr=addr;real_ppu_addr=addr;
    ppu_read=(dt%2==0);clocks(6);
   end
 endtask
 task cpu_tick;
  begin @(negedge clk);ce=1;clocks(1);@(negedge clk);ce=0;clocks(2);end
 endtask
 integer x,y,f,p,b,scan,d,phase,idx;
 integer prev,edges,n,last_edge;
 reg [7:0] ext;
 reg [63:0] snapshot[0:63];
 initial begin
  clocks(4);enable=1;clocks(2);
  cpu_addr=16'hfffc;#1;check(prg_out==25'h0807ffc,"reset vector must remain in first 32K bank");
  write_cpu('h4100,2);write_cpu('h411e,127);
  cpu_addr='he123;#1;check(prg_out==25'h08fe123,"Alucard engine high PRG bank");
  write_cpu('h4100,0);
  // CIRAM+8x8 extended attributes, deliberately different controls per NT.
  write_cpu('h4120,3);write_cpu('h4121,2);
  write_cpu('h412a,3);write_cpu('h412b,7);
  write_cpu('h412c,0);write_cpu('h412d,0);
  for(idx=0;idx<1024;idx=idx+1) begin
   write_cpu(16'h5000+idx,8'hc5);write_cpu(16'h5400+idx,8'h89);
  end
  rendering=1;
  // Scroll through all four pattern-address quadrants, both NT pages, every
  // fine Y, including coarse Y 30/31 (NT addresses in $23C0-$23FF).
  for(y=28;y<32;y=y+1) for(p=0;p<2;p=p+1)
  for(b=0;b<4;b=b+1) for(f=0;f<8;f=f+1) begin
   ext=p==0?8'hc5:8'h89;
   fetch(80,1,14'h2000+p*1024+y*32+31);
   fetch(80,2,14'h2000+p*1024+y*32+31);
   check(dut.ext_tile_addr==y*32+31,"NT phase, including coarse Y 30/31");
   fetch(80,3,14'h23c0+p*1024+(y/4)*8+7);
   // Read unrelated CPU FPGA-RAM while the PPU fetches attributes.
   cpu_addr='h5fff;cpu_read=1;
   fetch(80,4,14'h23c0+p*1024+(y/4)*8+7);
   check(ppu_out=={4{ext[7:6]}},"CPU read must not corrupt attribute fetch");
   cpu_read=0;
   fetch(80,5,b*1024+16+f);fetch(80,6,b*1024+16+f);
   check(chr_out==(25'h1080000+(ext[5:0]*4096)+b*1024+16+f),"latched BG bank must survive pattern NT-page bits");
   fetch(80,7,b*1024+24+f);fetch(80,8,b*1024+24+f);
   check(chr_out==(25'h1080000+(ext[5:0]*4096)+b*1024+24+f),"high pattern plane + fine Y");
  end
  $display("PASS: scrolling, coarse/fine Y, CHR banks, concurrent RAM reads");
  // Writes stream through port A while B supplies PPU attributes.
  fetch(80,1,'h2000);fetch(80,2,'h2000);fetch(80,3,'h23c0);
  dot=4;ppu_read=1;write_cpu('h5fff,'h33);
  check(ppu_out=='hff,"CPU streaming write must not steal PPU attributes");
  cpu_addr='h5fff;cpu_read=1;clocks(4);cpu_tick();
  check(cpu_out=='h33 && !prg_allow && flags[1],"CPU bus selects internal FPGA-RAM");cpu_read=0;
  write_cpu('h5001,'h12);write_cpu('h5002,'h34);
  write_cpu('h415c,0);write_cpu('h415d,1);write_cpu('h415e,1);
  cpu_addr='h415f;cpu_read=1;clocks(4);cpu_tick();
  check(cpu_out=='h12 && dut.fpga_auto_addr==2,"auto read holds old byte until T65 sampling");
  cpu_read=0;clocks(4);cpu_read=1;clocks(4);cpu_tick();
  check(cpu_out=='h34 && dut.fpga_auto_addr==3,"consecutive auto reads increment once");cpu_read=0;
  // HUD page 2, ext page 3. Give every tile its own byte to detect drift.
  rendering=0;ppu_read=0;
  for(idx=0;idx<1024;idx=idx+1) begin
   write_cpu(16'h5800+idx,idx%251);write_cpu(16'h5c00+idx,0);
  end
  write_cpu('h4120,'h13);write_cpu('h412e,2);write_cpu('h412f,'h8f);
  write_cpu('h4172,0);write_cpu('h4173,32);
  rendering=1;
  for(y=0;y<32;y=y+1) begin
   for(x=0;x<32;x=x+1) begin
    scan=x<2 ? (y==0?511:y-1) : y;
    d=x<2?321+x*8:1+(x-2)*8;
    fetch(scan,d,'h2abc);fetch(scan,d+1,'h2abc);
    check(ppu_out==((y/8)*32+x)%251,"fixed HUD tile alignment, including prefetch");
    fetch(scan,d+2,'h2beb);fetch(scan,d+3,'h2beb);
    fetch(scan,d+4,'h1237);fetch(scan,d+5,'h1237);
    check(chr_out==25'h1080230+(y%8),"HUD uses screen fine Y independent of world Y");
   end
  end
  fetch(31,321,'h2000);check(!dut.in_split,"first playfield line prefetch exits HUD");
  fetch(32,1,'h2000);check(!dut.in_split,"HUD bottom boundary");
  // Full-height split with scrolling that overflows an 8-bit addition.
  write_cpu('h4173,240);write_cpu('h4175,200);
  fetch(100,1,'h2000);fetch(100,2,'h2000);
  check(dut.split_tile_addr==7*32+2,"split Y wraps at 240, not 256");
  fetch(100,5,'h1000);check(chr_out[2:0]==4,"wrapped split fine Y");
  // Normal and optional extra sprites keep ordinary CHR banking.
  write_cpu('h4144,37);
  fetch(100,261,'h1003);fetch(100,262,'h1003);
  check(chr_out==25'h1009403,"sprite pattern must bypass split and BG bank");
  extra=1;fetch(100,3,'h1003);
  check(chr_out==25'h1009403,"extra sprite must bypass split and BG bank");extra=0;
  $display("PASS: HUD window, prefetch boundaries, Y wrap, sprite isolation");
  // Real held /RD strobes across a frame; no repeated-address scanline clock.
  write_cpu('h4150,40);write_cpu('h4153,135);write_cpu('h4151,0);
  for(scan=0;scan<240;scan=scan+1) begin
   for(d=0;d<=340;d=d+1) begin
    phase=d%8;
    fetch(scan,d,phase<=4?'h2000:'h1000);
    check(dut.ppu_scanline==scan,"held /RD must not advance scanline");
    check(dut.ppu_in_hblank==(d>=257),"HBlank transition at actual dot 257");
    if(scan==40 && d==268) check(!irq,"IRQ must not fire early");
    if(scan==40 && d==270) check(irq,"IRQ offset 135 at dot 270");
   end
  end
  rendering=0;fetch(241,4,'h2000);
  check(!dut.ppu_in_frame && !dut.ppu_in_hblank,"manual $2007 reads do not start rendering");
  $display("PASS: 240 scanlines, held read strobes, HBlank and IRQ timing");
  // All three Rainbow EXP6 channels. Pulse period=(timer+1)*16 CPU cycles.
  write_cpu('h41a0,'h7f);write_cpu('h41a1,3);write_cpu('h41a2,'h80);
  check(audio==16'h2000,"EXP6 is master-muted after reset");
  write_cpu('h41a9,1);
  prev=dut.pulse1;n=0;last_edge=-1;
  for(idx=0;idx<260;idx=idx+1) begin
   cpu_tick();
   if(dut.pulse1!=prev) begin
    if(last_edge>=0) check(idx-last_edge==32,"pulse half-period is 32 CPU cycles");
    last_edge=idx;n=n+1;prev=dut.pulse1;
   end
  end
  check(n>=7,"pulse oscillator advances");
  write_cpu('h41a2,0);
  write_cpu('h41a3,'h8b);write_cpu('h41a4,7);write_cpu('h41a5,'h80);
  check(dut.pulse2==11 && audio>16'h2000,"second pulse constant volume mode");
  write_cpu('h41aa,0);check(audio==16'h2000,"volume zero mutes expansion, preserves APU");
  write_cpu('h41aa,15);write_cpu('h41a5,0);
  write_cpu('h41a6,32);write_cpu('h41a7,0);write_cpu('h41a8,'h80);
  n=0;prev=dut.saw;
  for(idx=0;idx<70;idx=idx+1) begin
   cpu_tick();check((^audio)!==1'bx,"mixed audio must be fully initialized");
   if(dut.saw!=prev) n=n+1;prev=dut.saw;
  end
  check(n>25,"saw channel produces ramp");
  // Snapshot round-trip includes audio phase, auto pointer and ext latches.
  write_cpu('h415c,'h13);write_cpu('h415d,'hfe);write_cpu('h415e,3);
  for(idx=0;idx<16;idx=idx+1)write_cpu('h4130+idx,'h20+idx);
  write_cpu('h4241,5);write_cpu('h4243,16);
  paused=1;
  for(idx=32;idx<=49;idx=idx+1) begin ss_addr=idx;#1;snapshot[idx]=ss_out; end
  enable=0;clocks(3);enable=1;
  for(idx=32;idx<=49;idx=idx+1) begin
   @(negedge clk);ss_addr=idx;ss_in=snapshot[idx];ss_write=1;clocks(1);
  end
  @(negedge clk);ss_write=0;ss_load=1;clocks(1);
  @(negedge clk);ss_load=0;
  for(idx=32;idx<=49;idx=idx+1) begin
   ss_addr=idx;#1;check(ss_out===snapshot[idx],$sformatf("savestate register %0d",idx));
  end
  check(dut.fpga_auto_addr=='h13fe && dut.audio_ctrl==1,"state restores auto reader and audio enable");
  for(idx=0;idx<16;idx=idx+1)check(dut.chr_hi[idx]==('h20+idx),"state restores sixth CHR bank bit");
  check(dut.oam_page==5 && dut.oam_limit==16,"state restores executable OAM controls");
  $display("PASS: EXP6 pulse periods, both pulses, saw, mute, volume and state round-trip");
  $display("ALL PASS: %0d assertions",checks);$finish;
 end
 initial begin #100000000;$fatal(1,"test timeout");end
endmodule
