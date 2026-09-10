`timescale 1ns/1ps
module tb_mapper682_cpu;
 reg clk=0;
 always #5 clk=~clk;
 wire ce; reg enable=0, paused=0;
 wire [15:0] cpu_addr=cpu_a[15:0];
 wire cpu_read=rwn && div>=6 && div<=10; wire cpu_write=!rwn && div>=6 && div<=10;
 wire [7:0] cpu_data;
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

reg [3:0] div=1;
always @(posedge clk) div<=div==12?1:div+1;
assign ce=div==10;
wire [23:0] cpu_a;
wire rwn;
reg reset_n=0;
reg [7:0] mem_data=0;
wire [7:0] din=!rwn?cpu_data:(cpu_addr<8192 || cpu_addr>=65532 || prg_allow)?mem_data:cpu_out;
wire [63:0] regs;
T65 cpu(.Mode(2'b00),.BCD_en(1'b0),.Res_n(reset_n),.Pwr_n(reset_n),
 .Enable(div==12),.Clk(clk),.Rdy(1'b1),.Abort_n(1'b1),.IRQ_n(1'b1),.NMI_n(1'b1),.SO_n(1'b1),
 .DI(din),.DO(cpu_data),.A(cpu_a),.R_W_n(rwn),.Regs(regs),
 .SaveStateBus_Din(64'd0),.SaveStateBus_Adr(10'd0),.SaveStateBus_wren(1'b0),
 .SaveStateBus_rst(1'b0),.SaveStateBus_load(1'b0));
reg [7:0] ram[0:2047],signature[0:22527],codebytes[0:77],testtable[0:230];
integer t,i,j,offset,cycles,done=0;
always @(posedge clk)begin
 if(div==6) begin
  if(rwn)begin
   if(cpu_addr==65532)mem_data<=0;
   else if(cpu_addr==65533)mem_data<=3;
   else if(cpu_addr<8192)mem_data<=ram[cpu_addr%2048];
   else if(prg_allow)begin
    offset=prg_out-'h800000;
    if(offset>=0&&offset<8388608&&offset%4096<11)mem_data<=signature[(offset/4096)*11+offset%4096];
    else mem_data<=0;
   end
  end else begin
   if(cpu_addr<8192)ram[cpu_addr%2048]<=cpu_data;
   if(cpu_addr=='h4000)ram[2047]<=cpu_data+1;
   if(cpu_addr=='h2003)begin ram[2044]<=cpu_data;ram[2045]<=0;end
   if(cpu_addr=='h2004)begin
    if(cpu_data !== (ram[2044]^8'hA7))$fatal(1,"OAM byte %d mismatch %h",ram[2044],cpu_data);
    ram[2044]<=ram[2044]+1;ram[2045]<=ram[2045]+1;
   end
  end
 end
end
initial begin
 $readmemh("tests/mapper682/prg_signatures.hex",signature);
 $readmemh("tests/mapper682/prg_test_code.hex",codebytes);
 $readmemh("tests/mapper682/prg_test_table.hex",testtable);
 for(t=0;t<21;t=t+1)begin
  reset_n=0;enable=0;repeat(36)@(negedge clk);
  for(i=0;i<2048;i=i+1)ram[i]=0;
  for(i=0;i<78;i=i+1)ram['h480+i]=codebytes[i];
  // SEI / LDX #FF / TXS / JSR $0480 / LDA #0 / ROL / STA $4000 / loop
  {ram['h300],ram['h301],ram['h302],ram['h303],ram['h304],ram['h305],ram['h306],ram['h307],ram['h308],ram['h309],ram['h30a],ram['h30b],ram['h30c],ram['h30d],ram['h30e],ram['h30f]}=128'h78a2ff9a208004a9002a8d00404c0d03;
  ram[10]=testtable[t*11];ram[13]=testtable[t*11+1];ram[14]=testtable[t*11+2];
  ram[4]=testtable[t*11+3];ram[5]=testtable[t*11+4];ram[2]=testtable[t*11+5];ram[3]=testtable[t*11+6];
  ram[6]=testtable[t*11+7];ram[7]=testtable[t*11+8];ram[8]=10;ram[9]=ram[7];ram[16]='h4f;
  done=0;enable=1;reset_n=1;cycles=0;
  while(ram[2047]==0&&cycles<4000000)begin @(negedge clk);cycles=cycles+1;end
  if(ram[2047]!=2)$fatal(1,"T65 bank test %0d FAILED bank %h%h regs%h",t,ram[12],ram[11],regs);
  $display("PASS T65 ROM test %0d mode%0d window%h",t,ram[10],ram[7]);
 end
 for(t=0;t<8;t=t+1)begin
  reset_n=0;enable=0;repeat(36)@(negedge clk);
  for(i=0;i<2048;i=i+1)ram[i]=0;
  for(i=0;i<256;i=i+1)dut.fpga_ram.mem['h1800+t*256+i]=i^'ha7;
  // Set page/limit, preserve X/Y across JSR $4280, report success.
  {ram['h300],ram['h301],ram['h302],ram['h303],ram['h304],ram['h305],ram['h306],ram['h307],ram['h308],ram['h309],ram['h30a],ram['h30b],ram['h30c],ram['h30d],ram['h30e],ram['h30f],ram['h310],ram['h311],ram['h312],ram['h313],ram['h314],ram['h315],ram['h316],ram['h317],ram['h318],ram['h319],ram['h31a],ram['h31b],ram['h31c]}=232'h78a2ff9aa9008d4142a93f8d4342a255a0aa208042a9018d00404c1a03;
  ram['h305]=t;
  ram['h30a]=t==0?0:t==1?16:63;
  enable=1;reset_n=1;cycles=0;
  while(ram[2047]==0&&cycles<100000)begin @(negedge clk);cycles=cycles+1;end
  if(ram[2047]!=2 || regs[23:8]!=16'haa55)$fatal(1,"OAM failed to return with X/Y intact");
  if(ram[2045]!==((t==0?4:t==1?68:256)&255))$fatal(1,"Wrong OAM length");
  $display("PASS executable OAM page %0d, limit %0d",t,ram['h30a]);
 end
 $finish;
end
endmodule
