// Simulation equivalents of rtl/dpram.vhd and rtl/bus_savestates.vhd.
// The synthesis project continues to use the original Altera block RAM.
module dpram #(parameter widthad_a=13, width_a=8)(
 input clock_a, clock_b,
 input [widthad_a-1:0] address_a, address_b,
 input wren_a, wren_b, byteena_a, byteena_b,
 input [width_a-1:0] data_a, data_b,
 output [width_a-1:0] q_a, q_b
);
 reg [width_a-1:0] mem[0:(1<<widthad_a)-1];
 reg [widthad_a-1:0] addr_a, addr_b;
 integer i;
 initial for(i=0;i<(1<<widthad_a);i=i+1) mem[i]=0;
 always @(posedge clock_a) begin
   addr_a <= address_a;
   if(wren_a && byteena_a) mem[address_a] <= data_a;
 end
 always @(posedge clock_b) begin
   addr_b <= address_b;
   if(wren_b && byteena_b) mem[address_b] <= data_b;
 end
 assign q_a=mem[addr_a];
 assign q_b=mem[addr_b];
endmodule

module eReg_SavestateV #(parameter Adr=0, parameter [63:0] def=0)(
 input clk, input [63:0] BUS_Din, input [9:0] BUS_Adr,
 input BUS_wren, BUS_rst, output [63:0] BUS_Dout,
 input [63:0] Din, output reg [63:0] Dout=def
);
 always @(posedge clk)
   if(BUS_rst) Dout <= def;
   else if(BUS_wren && BUS_Adr == Adr) Dout <= BUS_Din;
 assign BUS_Dout=BUS_Adr == Adr ? Din : 64'd0;
endmodule
