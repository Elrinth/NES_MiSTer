`timescale 1ns/1ps
module tb_mapper682_roms;
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
  .clk(clk),.ce(ce),.enable(enable),.flags(cart_flags),.paused(paused),
  .prg_ain(cpu_addr),.prg_read(cpu_read),.prg_write(cpu_write),.prg_din(cpu_data),
  .prg_aout_b(),.prg_address(prg_out),.prg_rom_mask(prg_mask),.chr_rom_mask(chr_mask),.prg_dout_b(cpu_out),.prg_allow_b(prg_allow),
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

 reg loader_reset=1,downloading=0,data_clk=0;
 reg [7:0] indata=0;
 wire [63:0] cart_flags;
 wire [11:0] prg_mask,chr_mask;
 wire [24:0] load_addr;
 wire load_write,load_done,load_error,load_busy;
 reg [7:0] headers[0:207];
 GameLoader loader(.clk(clk),.reset(loader_reset),.downloading(downloading),
   .filetype(8'd2),.is_bios(1'b0),.indata(indata),.indata_clk(data_clk),
   .clearval(1'b0),.cleardata(8'd0),.mem_addr(load_addr),.mem_write(load_write),
   .mapper_flags(cart_flags),.prg_mask(prg_mask),.chr_mask(chr_mask),
   .busy(load_busy),.done(load_done),.error(load_error));
 integer rom,h,prg_size,chr_size,mode,bank,slot,bs,regidx,offset;
 integer ram_size,chr_ram_size;
 reg [24:0] want;
 reg [7:0] saved_header;
 task stream_byte(input [7:0] b);
  begin
   @(negedge clk);indata=b;data_clk=1;clocks(1);
   @(negedge clk);data_clk=0;clocks(5);
  end
 endtask
 initial begin
  $readmemh("tests/mapper682/rom_headers.hex",headers);
  for(rom=0;rom<13;rom=rom+1) begin
   @(negedge clk);loader_reset=1;enable=0;clocks(4);
   @(negedge clk);loader_reset=0;downloading=1;
   for(h=0;h<16;h=h+1)stream_byte(headers[rom*16+h]);
   clocks(4);enable=1;
   prg_size=(headers[rom*16+4]+(headers[rom*16+9]%16)*256)*16384;
   chr_size=(headers[rom*16+5]+(headers[rom*16+9]/16)*256)*8192;
   ram_size=64 << ((headers[rom*16+10]/16)>(headers[rom*16+10]%16)
      ? (headers[rom*16+10]/16) : (headers[rom*16+10]%16));
   chr_ram_size=(headers[rom*16+11]%16)==0 ? 32768 : 64 << (headers[rom*16+11]%16);
   check(!load_error && load_addr=='h800000,"loader starts PRG in separate aperture");
   check(prg_mask==(prg_size-1)/2048,"NES2 PRG size mask, including high header nibble");
   check(chr_mask==((chr_size>0?chr_size:chr_ram_size)-1)/2048,"NES2 CHR size mask");
   check({cart_flags[18:17],cart_flags[7:0]}==682,"mapper header decode");
   // The loader increments linearly between endpoints. Fast-forward only its
   // byte countdown to exercise the actual PRG->CHR->done state transitions.
   @(negedge clk);loader.bytes_left=1;loader.mem_addr='h800000+prg_size-1;
   stream_byte('ha5);clocks(4);
   check(load_addr=='h1000000,"loader places CHR above the entire PRG aperture");
   if(chr_size>0) begin
    @(negedge clk);loader.bytes_left=1;loader.mem_addr='h1000000+chr_size-1;
    stream_byte('h5a);clocks(4);
   end
   downloading=0;clocks(8);check(load_done && !load_busy,"loader finishes each ROM variant");
   // Exhaust every bank supported by each ROM size, in all five PRG modes.
   for(mode=0;mode<5;mode=mode+1) begin
    write_cpu('h4100,mode);
    for(slot=0;slot<8;slot=slot+1) begin
     if(mode==0)begin regidx=0;bs=32768;end
     else if(mode==1)begin regidx=slot<4?0:4;bs=16384;end
     else if(mode==2)begin regidx=slot<4?0:(slot<6?4:6);bs=slot<4?16384:8192;end
     else if(mode==3)begin regidx=(slot/2)*2;bs=8192;end
     else begin regidx=slot;bs=4096;end
     for(bank=0;bank<prg_size/bs;bank=bank+1) begin
      write_cpu('h4108+regidx,bank>>8);write_cpu('h4118+regidx,bank);
      cpu_addr='h8000+slot*4096+'h321;#1;
      want='h800000+bank*bs+(cpu_addr%bs);
      check(prg_out===want && prg_allow,"all PRG modes/banks preserve high address bits");
     end
    end
   end
   // Preserve six upper bits for all 8MiB in 512-byte mode, like Mesen.
   for(mode=0;mode<5;mode=mode+1) begin
    bs=8192>>mode;
    write_cpu('h4120,mode);
    for(bank=0;bank<(chr_size>0?chr_size:chr_ram_size)/bs && bank<16384;bank=bank+1) begin
     regidx=bank%(8192/bs);
     write_cpu('h4130+regidx,bank>>8);write_cpu('h4140+regidx,bank);
     ppu_addr=regidx*bs+bs-1;#1;
     want='h1000000+bank*bs+bs-1;
     check(chr_out===want,"all CHR-ROM modes/banks preserve high address bits");
    end
   end
   write_cpu('h4120,'h43); // 1KiB CHR RAM banking, independent of ROM mask
   for(bank=0;bank<256;bank=bank+1) begin
    write_cpu('h4140,bank);ppu_addr='h0015;#1;
    check(chr_out==('h300000+(bank*1024+'h15)%chr_ram_size) && chr_allow,"CHR-RAM size mirroring and separate base");
   end
   write_cpu('h4100,0);write_cpu('h4108,'h80);
   for(bank=0;bank<8;bank=bank+1) begin
    write_cpu('h4118,bank);cpu_addr='h8015;#1;
    check(prg_out==('h3c0000+(bank*32768+'h15)%ram_size) && prg_allow,"PRG-RAM high window banking");
   end
   write_cpu('h4106,'h80);write_cpu('h4116,3);cpu_addr='h6021;#1;
   check(prg_out==('h3c0000+(3*8192+'h21)%ram_size),"PRG-RAM low window");
   // Top 256KiB background-ext offset must no longer truncate to 1MiB.
   if(chr_size>=8388608) begin
    write_cpu('h4120,3);write_cpu('h4121,31);write_cpu('h412a,3);
    dut.fpga_ram.mem[0]=63;rendering=1;
    fetch(80,1,'h2000);fetch(80,2,'h2000);fetch(80,3,'h23c0);fetch(80,4,'h23c0);
    fetch(80,5,'h0fff);fetch(80,6,'h0fff);
    check(chr_out=='h17fffff,"BG extended addressing reaches last byte of 8MiB CHR");
    rendering=0;ppu_read=0;
   end
   $display("PASS header %0d: PRG %0dKiB CHR %0dKiB, loader and all bank modes",rom,prg_size/1024,chr_size/1024);
  end
  // Conventional NROM/MMC3 still load into the original low SDRAM regions.
  for(rom=0;rom<2;rom=rom+1) begin
   @(negedge clk);loader_reset=1;enable=0;clocks(4);
   @(negedge clk);loader_reset=0;downloading=1;
   for(h=0;h<16;h=h+1) begin
    saved_header=headers[3*16+h];
    if(h==5)saved_header=1; // Keep CHR load active while checking its start address.
    if(h==6)saved_header=rom==0?0:8'h40;
    if(h==7)saved_header=0;
    if(h>=8)saved_header=0;
    stream_byte(saved_header);
   end
   clocks(4);check(load_addr==0,"legacy mapper PRG base remains zero");
   check(prg_mask==63,"legacy 128KiB PRG mask");
   @(negedge clk);loader.bytes_left=1;loader.mem_addr='h1ffff;
   stream_byte('ha5);clocks(4);
   check(load_addr=='h200000,"legacy mapper CHR base remains 2MiB");
  end
  $display("PASS: 12 test ROMs + SotN + legacy headers, %0d loader/banking assertions",checks);$finish;
 end
 initial begin #1000000000;$fatal(1,"ROM compatibility test timeout");end
endmodule
