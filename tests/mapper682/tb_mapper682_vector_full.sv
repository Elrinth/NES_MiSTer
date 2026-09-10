`timescale 1ns/1ps
module tb_mapper682_vector_full;
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
reg [7:0] mem_data=0; reg nmi_enabled=0;
wire [7:0] din=!rwn?cpu_data:(cpu_addr<8192 || cpu_addr=='h2002 || cpu_addr=='h4015 || cpu_addr=='h4016 || prg_allow)?mem_data:cpu_out;
wire [63:0] regs;
T65 cpu(.Mode(2'b00),.BCD_en(1'b0),.Res_n(reset_n),.Pwr_n(reset_n),
 .Enable(div==12),.Clk(clk),.Rdy(1'b1),.Abort_n(1'b1),.IRQ_n(~irq),.NMI_n(!(nmi_enabled && line==241)),.SO_n(1'b1),
 .DI(din),.DO(cpu_data),.A(cpu_a),.R_W_n(rwn),.Regs(regs),
 .SaveStateBus_Din(64'd0),.SaveStateBus_Adr(10'd0),.SaveStateBus_wren(1'b0),
 .SaveStateBus_rst(1'b0),.SaveStateBus_load(1'b0));
reg [7:0] ram[0:2047],signature[0:22527],codebytes[0:77],testtable[0:230];
integer t,i,j,offset,cycles,done=0;
reg [7:0] romcode[0:32767];
reg [1:0] pd=0;
always @(posedge clk)begin
 pd<=pd+1;
 if(pd==3)begin
  if(dot==340)begin dot<=0;line<=line==261?0:line+1;end
  else dot<=dot+1;
 end
 ppu_read<=rendering && line<240 && dot!=0 && !dot[0];
end
always @(posedge clk)begin
 if(div==6) begin
  if(rwn)begin
   if(cpu_addr=='h2002)mem_data<=line>=241 ? 8'h80 : 0;
   else if(cpu_addr=='h4015 || cpu_addr=='h4016)mem_data<=0;
   else if(cpu_addr<8192)mem_data<=ram[cpu_addr%2048];
   else if(prg_allow)begin
    offset=prg_out-'h800000;
    if(offset>=0&&offset<32768)mem_data<=romcode[offset];
    else if(offset>=0&&offset<8388608&&offset%4096<11)mem_data<=signature[(offset/4096)*11+offset%4096];
    else mem_data<=0;
   end
  end else begin
   if(cpu_addr<8192)ram[cpu_addr%2048]<=cpu_data;
   if(cpu_addr=='h2000)nmi_enabled<=cpu_data[7];
   if(cpu_addr=='h4000)ram[2047]<=cpu_data+1;
   if(cpu_addr=='h2003)begin ram[2044]<=cpu_data;ram[2045]<=0;end
   if(cpu_addr=='h2004)begin

    ram[2044]<=ram[2044]+1;ram[2045]<=ram[2045]+1;
   end
  end
 end
end


initial begin
 $readmemh("tests/mapper682/prg_first32k.hex",romcode);
 // Redirect the menu only, preserving original reset, NMI, display and test code.
 romcode['h76fe]=8'h4c;romcode['h76ff]=8'hed;romcode['h7700]=8'hce;
 reset_n=0;enable=0;repeat(36)@(negedge clk);
 for(i=0;i<2048;i=i+1)ram[i]=0;
 enable=1;reset_n=1;
 cycles=0;
 while(regs[63:48]!=16'hfe08 && cycles<10000000)begin @(negedge clk);cycles=cycles+1;end
 if(regs[63:48]!=16'hfe08 || ram['hb9]!=8'h55)$fatal(1,"Full vector test stalled PC=%h result=%h en=%b pending=%b nmi=%b",regs[63:48],ram['hb9],dut.cpu_irq_en,dut.cpu_irq_pending,nmi_enabled);
 $display("PASS original reset, NMI and IRQ redirect sequence through UI return");$finish;
end
endmodule
