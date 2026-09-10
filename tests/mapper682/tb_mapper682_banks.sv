`timescale 1ns/1ps
module tb_mapper682_banks;
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

reg [27:0] vectors[0:1893172-1];
reg [7:0] prg_sig[0:22527],chr_sig[0:180223];
integer i,k,got,off,errors=0;
task clocks(input integer n); repeat(n) begin @(posedge clk);#1;end endtask
initial begin
 $readmemh("tests/mapper682/bank_vectors.hex",vectors);
 $readmemh("tests/mapper682/prg_signatures.hex",prg_sig);
 $readmemh("tests/mapper682/chr_signatures.hex",chr_sig);
 clocks(4);enable=1;clocks(4);
 for(i=0;i<1893172;i=i+1) begin
  @(negedge clk);
  if(vectors[i][27:24]==0)begin
   cpu_addr=vectors[i][23:8];cpu_data=vectors[i][7:0];cpu_write=1;
   clocks(4);@(negedge clk);ce=1;clocks(1);@(negedge clk);ce=0;cpu_write=0;clocks(2);
  end else begin
   if(vectors[i][27:24]==1)begin
    cpu_addr=vectors[i][23:8];cpu_read=1;#1;off=prg_out-'h800000;
    got=(off>=0&&off<8388608&&(off%4096)<11&&prg_allow)?prg_sig[(off/4096)*11+off%4096]:-1;
   end else begin
    ppu_addr=vectors[i][23:8];ppu_read=1;#1;off=chr_out-'h1000000;
    got=(off>=0&&off<8388608&&(off%512)<11)?chr_sig[(off/512)*11+off%512]:-1;
   end
   if(got!=vectors[i][7:0])begin
    if(errors<12)$display("FAIL vector %0d type%0d cpu%h ppu%h prg%h chr%h got%h expected%h",i,vectors[i][27:24],cpu_addr,ppu_addr,prg_out,chr_out,got,vectors[i][7:0]);
    errors=errors+1;
   end
   clocks(4);cpu_read=0;ppu_read=0;
  end
 end
 if(errors)$fatal(1,"%0d signature mismatches",errors);
 $display("PASS %0d actual test-ROM signature transactions",1893172);$finish;
end
endmodule
