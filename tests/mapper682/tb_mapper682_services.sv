`timescale 1ns/1ps
module tb_mapper682_services;
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
reg reset_n=0; reg nmi_n=1; integer writes=0;
reg [7:0] mem_data=0;
wire [7:0] din=!rwn?cpu_data:(cpu_addr<8192 || (cpu_addr==65532 || cpu_addr==65533) || prg_allow)?mem_data:cpu_out;
wire [63:0] regs;
T65 cpu(.Mode(2'b00),.BCD_en(1'b0),.Res_n(reset_n),.Pwr_n(reset_n),
 .Enable(div==12),.Clk(clk),.Rdy(1'b1),.Abort_n(1'b1),.IRQ_n(1'b1),.NMI_n(nmi_n),.SO_n(1'b1),
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
   if(cpu_addr=='h2003)ram[2044]<=cpu_data;
   if(cpu_addr=='h2004)begin
    if(cpu_data!==8'hFF || ram[2044]!==((writes*4)&255))$fatal(1,"Clear OAM mismatch");
    writes=writes+1;
   end
   if(cpu_addr>='h4200 && cpu_addr<'h4240)begin
    if(cpu_data!==((cpu_addr-'h4200)^8'hA7))$fatal(1,"Extended OAM byte mismatch");
    writes=writes+1;
   end
  end
 end
end

task boot;
begin
 reset_n=0;enable=0;nmi_n=1;repeat(36)@(negedge clk);
 for(i=0;i<2048;i=i+1)ram[i]=0;
 writes=0;
end endtask
task run_program;
begin
 enable=1;reset_n=1;cycles=0;
 while(ram[2047]==0&&cycles<100000)begin @(negedge clk);cycles=cycles+1;end
 if(ram[2047]!=2)$fatal(1,"Service failed to return: PC%h",regs[63:48]);
end endtask
initial begin
 boot();
 ram['h300]=8'h78;
 ram['h301]=8'ha2;
 ram['h302]=8'hff;
 ram['h303]=8'h9a;
 ram['h304]=8'h20;
 ram['h305]=8'h86;
 ram['h306]=8'h42;
 ram['h307]=8'ha9;
 ram['h308]=8'h01;
 ram['h309]=8'h8d;
 ram['h30a]=8'h00;
 ram['h30b]=8'h40;
 ram['h30c]=8'h4c;
 ram['h30d]=8'h0c;
 ram['h30e]=8'h03;
 run_program(); if(writes!=64 || regs[15:8]!=255)$fatal(1,"Clear length/X"); $display("PASS executable OAM clear: 64 Y coordinates, X=$FF");
 for(t=0;t<32;t=t+1)begin boot();
 for(i=0;i<64;i=i+1)dut.fpga_ram.mem['h1800+t*64+i]=i^'ha7;
 ram['h300]=8'h78;
 ram['h301]=8'ha2;
 ram['h302]=8'hff;
 ram['h303]=8'h9a;
 ram['h304]=8'ha9;
 ram['h305]=8'h00;
 ram['h306]=8'h8d;
 ram['h307]=8'h42;
 ram['h308]=8'h42;
 ram['h309]=8'ha9;
 ram['h30a]=8'h3f;
 ram['h30b]=8'h8d;
 ram['h30c]=8'h43;
 ram['h30d]=8'h42;
 ram['h30e]=8'ha2;
 ram['h30f]=8'h55;
 ram['h310]=8'ha0;
 ram['h311]=8'haa;
 ram['h312]=8'h20;
 ram['h313]=8'h82;
 ram['h314]=8'h42;
 ram['h315]=8'ha9;
 ram['h316]=8'h01;
 ram['h317]=8'h8d;
 ram['h318]=8'h00;
 ram['h319]=8'h40;
 ram['h31a]=8'h4c;
 ram['h31b]=8'h1a;
 ram['h31c]=8'h03;
 ram['h305]=t; ram['h30a]=t==0?0:t==1?16:63; run_program();
 if(writes!=(t==0?1:t==1?17:64) || regs[23:8]!=16'haa55)$fatal(1,"Ext OAM count/X/Y");
 end $display("PASS executable extended OAM: all 32 source pages and sprite limits");
 boot();
 ram['h300]=8'h78;
 ram['h301]=8'ha2;
 ram['h302]=8'hff;
 ram['h303]=8'h9a;
 ram['h304]=8'ha9;
 ram['h305]=8'h03;
 ram['h306]=8'h8d;
 ram['h307]=8'h6c;
 ram['h308]=8'h41;
 ram['h309]=8'h8d;
 ram['h30a]=8'h6e;
 ram['h30b]=8'h41;
 ram['h30c]=8'ha9;
 ram['h30d]=8'ha0;
 ram['h30e]=8'h8d;
 ram['h30f]=8'h6d;
 ram['h310]=8'h41;
 ram['h311]=8'ha9;
 ram['h312]=8'hb0;
 ram['h313]=8'h8d;
 ram['h314]=8'h6f;
 ram['h315]=8'h41;
 ram['h316]=8'ha9;
 ram['h317]=8'h03;
 ram['h318]=8'h8d;
 ram['h319]=8'h6b;
 ram['h31a]=8'h41;
 ram['h31b]=8'h00;
 ram['h31c]=8'hea;
 ram['h31d]=8'ha9;
 ram['h31e]=8'h01;
 ram['h31f]=8'h8d;
 ram['h320]=8'h00;
 ram['h321]=8'h40;
 ram['h322]=8'h4c;
 ram['h323]=8'h22;
 ram['h324]=8'h03;
 ram['h3a0]=8'hee;ram['h3a1]=8'hfd;ram['h3a2]=8'h07;ram['h3a3]=8'h40;
 ram['h3b0]=8'hee;ram['h3b1]=8'hfc;ram['h3b2]=8'h07;ram['h3b3]=8'h40;
 run_program(); if(ram[2044]!=1)$fatal(1,"IRQ/BRK vector did not redirect");
 nmi_n=0;repeat(240)@(negedge clk);nmi_n=1;repeat(1200)@(negedge clk);
 if(ram[2045]!=1)$fatal(1,"NMI vector did not redirect");
 $display("PASS actual T65 IRQ/BRK and NMI vector redirection"); $finish; end endmodule
