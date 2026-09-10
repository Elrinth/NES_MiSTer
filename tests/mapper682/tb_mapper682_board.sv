// Original ROM boot, NMI, APU and DMA; menu dispatch is patched to the selected test.
// External RAM is a synchronous model, not the physical SDRAM controller.
`timescale 1ns/1ps
module tb_board;
reg clk=0; always #5 clk=~clk;reg reset=1; reg [1:0] region=0; integer scenario=0,stage=0,reset_phase=0; reg dejitter=0; string fixture="tests/mapper682/prg_first32k.hex";
reg [7:0] cpu_data=0,ppu_data=0;
wire [24:0] ca,pa;wire cr,cw,pr,pw;wire [7:0] co,po;
NES nes(.clk(clk),
.reset_nes(reset),
.ppu_rst_behavior('0),
.cold_reset(reset),
.pausecore('0),
.sys_type(region),
.vs_dip_switches('0),
.mapper_flags(64'h400aa),
.joypad1_data('0),
.joypad2_data('0),
.fds_busy('0),
.fds_eject('0),
.fds_auto_eject('0),
.max_diskside('0),
.fds_fast('0),
.audio_channels(5'h1f),
.ex_sprites('0),
.mask('0),
.dejitter_timing(dejitter),
.cpumem_din(cpu_data),
.ppumem_din(ppu_data),
.prg_mask(12'hfff),
.chr_mask(12'hfff),
.bram_din('0),
.int_audio(1'b1),
.ext_audio(1'b1),
.gg(1'b1),
.gg_code('0),
.gg_reset('0),
.debug_dots('0),
.increaseSSHeaderCount('0),
.save_state('0),
.load_state('0),
.savestate_number('0),
.Savestate_SDRAMReadData('0),
.SaveStateExt_Dout('0),
.SAVE_out_Dout('0),
.SAVE_out_done('0),.cpumem_addr(ca),.cpumem_read(cr),.cpumem_write(cw),.cpumem_dout(co),.ppumem_addr(pa),.ppumem_read(pr),.ppumem_write(pw),.ppumem_dout(po));
reg [7:0] mem[0:33554431];reg [7:0] rom[0:32767];integer i,t; integer chr_cases=0; reg [7:0] chr_snapshot[0:32767]; integer changed=0;
always @(posedge clk)begin
 if(cr)cpu_data<=mem[ca];if(cw)mem[ca]<=co;
 if(pr)ppu_data<=mem[pa];if(pw)mem[pa]<=po;
end
initial begin
 if($value$plusargs("romhex=%s",fixture))begin end
 $readmemh(fixture,rom);
 for(i=0;i<32768;i=i+1)mem['h800000+i]=rom[i];
 // Run the real menu initialization before selecting the vector test.
 mem['h80775e]=8'h4c;mem['h80775f]=8'h64;mem['h807760]=8'hf7;
 mem['h80776a]=8'h4c;mem['h80776b]=8'hed;mem['h80776c]=8'hce;
 if($value$plusargs("region=%d",scenario))region=scenario;
 scenario=0;
 if($value$plusargs("scenario=%d",scenario) && scenario==1)begin
 mem['h80776b]=8'h14;mem['h80776c]=8'h99;
 mem['h807e08]=8'h4c;mem['h807e09]=8'hed;mem['h807e0a]=8'hce;
 end
 if(scenario>=2)begin
 mem['h80776b]=8'h0d;mem['h80776c]=8'h8a;
 end
 if(scenario>=3)begin
 mem['h80776b]=8'h0b;mem['h80776c]=8'hd0;
 mem['h8050c7]=8'ha9;mem['h8050c8]=8'h08;
 end
 if($value$plusargs("phase=%d",reset_phase))begin end
 if($test$plusargs("dejitter"))dejitter=1;
 repeat(200+reset_phase)@(negedge clk);reset=0;
 for(t=0;t<15000000;t=t+1)begin
 @(negedge clk);
 if(scenario>=3 && nes.cpu_ce && nes.cpu_addr==16'hd00b)
 for(i=0;i<32768;i=i+1)chr_snapshot[i]=mem['h300000+i];
 if(scenario>=3 && nes.cpu_ce && nes.cpu_addr==16'hd0cd)begin
 for(i=0;i<32768;i=i+1)begin
 if(chr_snapshot[i]!=mem['h300000+i])changed=changed+1;
 if(scenario==4)mem['h300000+i]=chr_snapshot[i];
 end
 $display("Window Split changed %0d CHR RAM bytes; restore=%b",changed,scenario==4);
 mem['h80776b]=8'h0d;mem['h80776c]=8'h8a;
 end
 if(scenario>=2 && nes.cpu_ce && nes.cpu_addr==16'h8b87)
 $fatal(1,"CHR RAM failure bank=%h%h mode=%h",mem['h38000c],mem['h38000b],mem['h38000a]);
 if(scenario>=2 && nes.cpu_ce && nes.cpu_addr==16'h8b81)chr_cases=chr_cases+1;
 if(nes.cpu_addr==16'hfe08 && nes.cpu_ce)begin
 if(scenario>=2)begin
 if(chr_cases!=31)$fatal(1,"wrong CHR test count %0d",chr_cases);
 $display("PASS original CHR RAM %0d cases",chr_cases);$finish;
 end else begin
 if(scenario==1 && mem['h3800b9]!=8'h55)stage=1;
 else begin
 if(mem['h3800b9]!=8'h55)$fatal(1,"wrong result");
 if(fixture!="tests/mapper682/prg_first32k.hex" && (mem['h3807ff]!=4 || mem['h3a00e2]!=8'h34))$fatal(1,"Diagnostic marker was not displayed");
 $display("PASS integrated vector test scenario=%0d region=%0d phase=%0d dejitter=%b",scenario,region,reset_phase,dejitter);$finish;end end end
 end
 $fatal(1,"Board timeout CPU=%h IRQ=%b APU=%b frame=%h result=%h",nes.cpu_addr,nes.mapper_irq,nes.apu_irq,mem['h38001a],mem['h3800b9]);
end
endmodule
