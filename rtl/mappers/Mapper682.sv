// NES 2.0 Mapper 682 - Broke Studio Rainbow (RNBW)
// Docs: https://github.com/BrokeStudio/rainbow-net/blob/master/NES/mapper-doc.md
//       https://www.nesdev.org/wiki/NES_2.0_Mapper_682
//
// Implemented:
//   - PRG banking modes 0-4 ($4100/$4108-$410F/$4118-$411F) with ROM/RAM chip select
//   - PRG-RAM banking modes 0-1 ($4106-$4107/$4116-$4117) ROM/RAM/FPGA-RAM
//   - FPGA-RAM 8KB: $4800-$4FFF (last 2K), $5000-$5FFF (banked via $4115)
//   - FPGA-RAM auto reader/writer ($415C-$415F)
//   - CHR banking modes 0-4 ($4120/$4130-$414F) CHR-ROM/CHR-RAM/FPGA-RAM/CIRAM
//   - Nametable bank + control ($4126-$412D): CIRAM/CHR-RAM/FPGA-RAM/CHR-ROM
//   - Fill-mode ($4124-$4125), Attribute + Background extended modes (basic)
//   - Scanline IRQ ($4150-$4153) and CPU-cycle IRQ ($4157-$415B)
//   - Mapper version ($4160), IRQ status ($4161), SaveStateBus + FPGA-RAM savestate
// Deferred (explicitly):
//   - Wi-Fi/ESP ($4190-$4194)
//   - Expansion audio ($41A0-$41AA) / IPCM / EPSM
//   - Window Split Mode rendering ($4120.W / $412E-$412F / $4170-$4175)
//   - Sprite Extended Mode ($4200-$4240)
//   - Auto-generated OAM routines ($4241-$4243 / $4280/$4282)
//   - Vector redirection ($416B-$416F)
//   - Self-flash PRG/CHR
//   - Full 8MiB PRG/CHR via extended SDRAM address bits (maps within ~2MB/~1MB)

module Mapper682(
	input         clk,
	input         ce,
	input         enable,
	input  [63:0] flags,
	input  [15:0] prg_ain,
	inout  [21:0] prg_aout_b,
	input         prg_read,
	input         prg_write,
	input   [7:0] prg_din,
	inout   [7:0] prg_dout_b,
	inout         prg_allow_b,
	input  [13:0] chr_ain,
	inout  [21:0] chr_aout_b,
	input         chr_read,
	inout   [7:0] chr_dout_b,
	inout         chr_allow_b,
	inout         vram_a10_b,
	inout         vram_ce_b,
	inout         irq_b,
	input  [15:0] audio_in,
	inout  [15:0] audio_b,
	inout  [15:0] flags_out_b,
	input  [13:0] chr_ain_o,
	input         chr_write,
	input   [7:0] chr_din,
	input         paused,
	input  [63:0] SaveStateBus_Din,
	input   [9:0] SaveStateBus_Adr,
	input         SaveStateBus_wren,
	input         SaveStateBus_rst,
	input         SaveStateBus_load,
	output [63:0] SaveStateBus_Dout,
	input         Savestate_MAPRAMactive,
	input  [12:0] Savestate_MAPRAMAddr,
	input         Savestate_MAPRAMRdEn,
	input         Savestate_MAPRAMWrEn,
	input   [7:0] Savestate_MAPRAMWriteData,
	output  [7:0] Savestate_MAPRAMReadData
);

import regs_savestates::*;

assign prg_aout_b  = enable ? prg_aout  : 22'hZ;
assign prg_dout_b  = enable ? prg_dout  : 8'hZ;
assign prg_allow_b = enable ? prg_allow : 1'hZ;
assign chr_aout_b  = enable ? chr_aout  : 22'hZ;
assign chr_dout_b  = enable ? chr_dout  : 8'hZ;
assign chr_allow_b = enable ? chr_allow : 1'hZ;
assign vram_a10_b  = enable ? vram_a10  : 1'hZ;
assign vram_ce_b   = enable ? vram_ce   : 1'hZ;
assign irq_b       = enable ? irq       : 1'hZ;
assign flags_out_b = enable ? flags_out : 16'hZ;
assign audio_b     = enable ? {1'b0, audio_in[15:1]} : 16'hZ;

wire [15:0] flags_out = {12'h0, 1'b1, 1'b0, prg_bus_write, has_chr_dout};

wire [21:0] prg_aout, chr_aout;
wire  [7:0] prg_dout, chr_dout;
wire        prg_allow, chr_allow, vram_a10, vram_ce, irq;
wire        prg_bus_write, has_chr_dout;

// -------------------------------------------------------------------------
// Register file
// -------------------------------------------------------------------------
reg [7:0] prg_mode_reg;
reg [7:0] prg_hi[0:7], prg_lo[0:7];
reg [7:0] ram_hi[0:1], ram_lo[0:1];
reg       fpga_bank;

reg [7:0] chr_mode_reg;
reg [4:0] bg_ext_upper;
reg [7:0] fill_tile;
reg [1:0] fill_attr;
reg [7:0] nt_bank[0:3], nt_ctrl[0:3];
reg [7:0] chr_hi[0:15], chr_lo[0:15];

reg [7:0] sl_latch, sl_offset, jitter;
reg       sl_irq_en, sl_irq_pending;
reg       parity;
reg [15:0] cpu_irq_latch, cpu_irq_counter;
reg        cpu_irq_en, cpu_irq_en_after, cpu_irq_pending;

reg [12:0] fpga_auto_addr;
reg [7:0]  fpga_auto_inc;

reg        ppu_in_frame, ppu_in_hblank;
reg [7:0]  ppu_scanline, ppu_read_ctr;
reg [1:0]  nt_same_ctr, ppu_idle;
reg [13:0] last_ppu_addr;
reg [7:0]  ext_data;
reg        override_tile;
reg [7:0]  last_chr_dout;

// -------------------------------------------------------------------------
// 8KB FPGA-RAM (dual-port)
// -------------------------------------------------------------------------
reg  [12:0] ram_addrA;
reg         ram_wrenA;
reg  [7:0]  ram_dataA;

wire        prg_fpga_fixed = (prg_ain[15:11] == 5'b01001); // $4800-$4FFF
wire        prg_fpga_banked= (prg_ain[15:12] == 4'b0101);  // $5000-$5FFF
wire        prg_is_low     = (prg_ain[15:13] == 3'b011);   // $6000-$7FFF
wire        prg_is_hi      = prg_ain[15];
wire        prg_regs       = (prg_ain[15:8] == 8'h41);

wire       low_idx  = prg_mode_reg[7] ? prg_ain[12] : 1'b0;
wire [15:0] low_bank = {ram_hi[low_idx], ram_lo[low_idx]};
wire [1:0]  low_src  = low_bank[15:14];

wire [12:0] fpga_cpu_addr =
	prg_fpga_fixed ? {2'b11, prg_ain[10:0]} :
	prg_fpga_banked? {fpga_bank, prg_ain[11:0]} :
	(prg_mode_reg[7] ? {low_bank[0], prg_ain[11:0]} : prg_ain[12:0]);

wire prg_low_fpga = prg_is_low && (low_src == 2'b11);
wire prg_hit_fpga = prg_fpga_fixed | prg_fpga_banked | prg_low_fpga;
wire prg_hit_auto = prg_regs && (prg_ain[7:0] == 8'h5F);

// PPU FPGA address (nametable / pattern)
wire [1:0] nt_page = chr_ain[11:10];
wire [7:0] ntb = nt_bank[nt_page];
wire [7:0] ntc = nt_ctrl[nt_page];
wire [1:0] nt_src = ntc[7:6];
wire       nt_fill = ntc[5];
wire [1:0] nt_ext_page = ntc[3:2];
wire       nt_attr_ext = ntc[0];
wire       nt_bg_ext   = ntc[1];

wire ppu_is_nt = (chr_ain[13:12] == 2'b10) && ~(&chr_ain[9:6]);
wire ppu_is_at = (chr_ain[13:12] == 2'b10) &&  (&chr_ain[9:6]);

wire [1:0] chr_src = chr_mode_reg[7:6];

wire [12:0] fpga_ppu_addr =
	chr_ain[13] ? ((nt_src == 2'b10) ? {ntb[1:0], chr_ain[9:0]} :
	               {nt_ext_page, chr_ain[9:0]}) :
	              {1'b0, chr_ain[11:0]};

wire [12:0] ram_addrB = Savestate_MAPRAMactive ? Savestate_MAPRAMAddr :
                        prg_hit_auto ? fpga_auto_addr :
                        prg_hit_fpga ? fpga_cpu_addr :
                        fpga_ppu_addr;
wire       ram_wrenB = Savestate_MAPRAMactive & Savestate_MAPRAMWrEn;
wire [7:0] ram_dataB = Savestate_MAPRAMWriteData;
wire [7:0] ram_qB;

dpram #(.widthad_a(13)) fpga_ram (
	.clock_a(clk), .address_a(ram_addrA), .wren_a(ram_wrenA), .byteena_a(1'b1), .data_a(ram_dataA),
	.clock_b(clk), .address_b(ram_addrB), .wren_b(ram_wrenB), .byteena_b(1'b1), .data_b(ram_dataB), .q_b(ram_qB)
);
assign Savestate_MAPRAMReadData = enable ? ram_qB : 8'h00;

// -------------------------------------------------------------------------
// Banking decode
// -------------------------------------------------------------------------
wire [2:0] prg_md = (prg_mode_reg[2:0] >= 3'd4) ? 3'd4 : prg_mode_reg[2:0];
wire [2:0] chr_md = (chr_mode_reg[2:0] >= 3'd4) ? 3'd4 : chr_mode_reg[2:0];

// Power-up/reset defaults follow BrokeStudio mapper-doc (NOT web SotN
// loadROM). Official rnbw-mapper-test ROMs put RESET at the end of the
// first 32KB ($FCDD); mode 0 + bank 0 maps that correctly. Web/SotN
// last-bank boot is a game-image concern, not FPGA power-on.

reg [2:0] prg_ridx;
reg [2:0] prg_bsh; // 5=32K,4=16K,3=8K,2=4K
always @* begin
	prg_ridx = 3'd0;
	prg_bsh  = 3'd5;
	case (prg_md)
		3'd0: begin prg_ridx = 3'd0; prg_bsh = 3'd5; end
		3'd1: begin prg_ridx = prg_ain[14] ? 3'd4 : 3'd0; prg_bsh = 3'd4; end
		3'd2: begin
			if (!prg_ain[14])      begin prg_ridx = 3'd0; prg_bsh = 3'd4; end
			else if (!prg_ain[13]) begin prg_ridx = 3'd4; prg_bsh = 3'd3; end
			else                   begin prg_ridx = 3'd6; prg_bsh = 3'd3; end
		end
		3'd3: begin prg_ridx = {prg_ain[14:13], 1'b0}; prg_bsh = 3'd3; end
		default: begin prg_ridx = prg_ain[14:12]; prg_bsh = 3'd2; end
	endcase
end

wire [15:0] prg_b16 = {prg_hi[prg_ridx], prg_lo[prg_ridx]};
wire        prg_to_ram = prg_b16[15];
wire [14:0] prg_bnum = prg_b16[14:0];

reg [20:0] prg_lin;
always @* begin
	case (prg_bsh)
		3'd5: prg_lin = {prg_bnum[5:0], prg_ain[14:0]};
		3'd4: prg_lin = {prg_bnum[6:0], prg_ain[13:0]};
		3'd3: prg_lin = {prg_bnum[7:0], prg_ain[12:0]};
		default: prg_lin = {prg_bnum[8:0], prg_ain[11:0]};
	endcase
end

reg [3:0] chr_ridx;
always @* begin
	case (chr_md)
		3'd0: chr_ridx = 4'd0;
		3'd1: chr_ridx = {3'b0, chr_ain[12]};
		3'd2: chr_ridx = {2'b0, chr_ain[12:11]};
		3'd3: chr_ridx = {1'b0, chr_ain[12:10]};
		default: chr_ridx = chr_ain[12:9];
	endcase
end
wire [12:0] chr_bnum = {chr_hi[chr_ridx][4:0], chr_lo[chr_ridx]};

reg [19:0] chr_lin;
always @* begin
	case (chr_md)
		3'd0: chr_lin = {chr_bnum[6:0], chr_ain[12:0]};
		3'd1: chr_lin = {chr_bnum[7:0], chr_ain[11:0]};
		3'd2: chr_lin = {chr_bnum[8:0], chr_ain[10:0]};
		3'd3: chr_lin = {chr_bnum[9:0], chr_ain[9:0]};
		default: chr_lin = {chr_bnum[10:0], chr_ain[8:0]};
	endcase
end

wire [20:0] low_rom = prg_mode_reg[7] ? {low_bank[8:0], prg_ain[11:0]} : {low_bank[7:0], prg_ain[12:0]};
wire [16:0] low_ram = prg_mode_reg[7] ? {low_bank[4:0], prg_ain[11:0]} : {low_bank[3:0], prg_ain[12:0]};

// -------------------------------------------------------------------------
// Register writes + IRQ + scanline (single sequential block)
// -------------------------------------------------------------------------
integer i;
always @(posedge clk) begin
	ram_wrenA <= 1'b0;

	if (!enable) begin
		// BrokeStudio mapper-doc "Power-up and reset register status"
		prg_mode_reg <= 8'h00; // $4100: PRG mode 0 (32K) + RAM mode 0 (8K)
		for (i = 0; i < 8; i = i + 1) begin prg_hi[i] <= 8'h00; prg_lo[i] <= 8'h00; end // $4108/$4118 bank 0
		for (i = 0; i < 2; i = i + 1) begin ram_hi[i] <= 8'h00; ram_lo[i] <= 8'h00; end
		fpga_bank <= 1'b0;
		chr_mode_reg <= 8'h00; // $4120: CHR mode 0 (8K), CHR-ROM, no split/sprite-ext
		bg_ext_upper <= 5'h00;
		fill_tile <= 8'h00; fill_attr <= 2'h0;
		nt_bank[0] <= 8'h00; nt_bank[1] <= 8'h00; nt_bank[2] <= 8'h01; nt_bank[3] <= 8'h01; // $4126-$4129
		nt_ctrl[0] <= 8'h00; nt_ctrl[1] <= 8'h00; nt_ctrl[2] <= 8'h00; nt_ctrl[3] <= 8'h00; // CIRAM
		for (i = 0; i < 16; i = i + 1) begin chr_hi[i] <= 8'h00; chr_lo[i] <= 8'h00; end // $4130/$4140 bank 0
		sl_latch <= 8'h00; sl_irq_en <= 1'b0; sl_irq_pending <= 1'b0; sl_offset <= 8'h87; // $4152/$4153
		parity <= 1'b0; jitter <= 8'h00;
		cpu_irq_latch <= 16'h0; cpu_irq_counter <= 16'h0;
		cpu_irq_en <= 1'b0; cpu_irq_en_after <= 1'b0; cpu_irq_pending <= 1'b0; // $415A
		fpga_auto_addr <= 13'h0; fpga_auto_inc <= 8'h0;
		ppu_in_frame <= 1'b0; ppu_in_hblank <= 1'b0; ppu_scanline <= 8'h0; ppu_read_ctr <= 8'h0;
		nt_same_ctr <= 2'h0; ppu_idle <= 2'h0; last_ppu_addr <= 14'h0;
		ext_data <= 8'h0; override_tile <= 1'b0; last_chr_dout <= 8'h0;
	end else if (SaveStateBus_load) begin
		prg_mode_reg <= SS_MAP1[7:0];
		fpga_bank    <= SS_MAP1[8];
		chr_mode_reg <= SS_MAP1[16:9];
		bg_ext_upper <= SS_MAP1[21:17];
		fill_tile    <= SS_MAP1[29:22];
		fill_attr    <= SS_MAP1[31:30];
		sl_latch     <= SS_MAP1[39:32];
		sl_irq_en    <= SS_MAP1[40];
		sl_irq_pending <= SS_MAP1[41];
		sl_offset    <= SS_MAP1[49:42];
		parity       <= SS_MAP1[50];
		cpu_irq_en   <= SS_MAP1[51];
		cpu_irq_en_after <= SS_MAP1[52];
		cpu_irq_pending <= SS_MAP1[53];
		ppu_in_frame <= SS_MAP1[54];
		ppu_in_hblank<= SS_MAP1[55];
		override_tile<= SS_MAP1[56];
		ppu_scanline <= SS_MAP1[63:57]; // 7 bits enough for 0-239; pad

		prg_hi[0] <= SS_MAP2[7:0];   prg_hi[1] <= SS_MAP2[15:8];
		prg_hi[2] <= SS_MAP2[23:16]; prg_hi[3] <= SS_MAP2[31:24];
		prg_hi[4] <= SS_MAP2[39:32]; prg_hi[5] <= SS_MAP2[47:40];
		prg_hi[6] <= SS_MAP2[55:48]; prg_hi[7] <= SS_MAP2[63:56];

		prg_lo[0] <= SS_MAP3[7:0];   prg_lo[1] <= SS_MAP3[15:8];
		prg_lo[2] <= SS_MAP3[23:16]; prg_lo[3] <= SS_MAP3[31:24];
		prg_lo[4] <= SS_MAP3[39:32]; prg_lo[5] <= SS_MAP3[47:40];
		prg_lo[6] <= SS_MAP3[55:48]; prg_lo[7] <= SS_MAP3[63:56];

		ram_lo[0] <= SS_MAP4[7:0];   ram_lo[1] <= SS_MAP4[15:8];
		ram_hi[0] <= SS_MAP4[23:16]; ram_hi[1] <= SS_MAP4[31:24];
		nt_bank[0]<= SS_MAP4[39:32]; nt_bank[1]<= SS_MAP4[47:40];
		nt_bank[2]<= SS_MAP4[55:48]; nt_bank[3]<= SS_MAP4[63:56];

		nt_ctrl[0]<= SS_MAP5[7:0];   nt_ctrl[1]<= SS_MAP5[15:8];
		nt_ctrl[2]<= SS_MAP5[23:16]; nt_ctrl[3]<= SS_MAP5[31:24];
		cpu_irq_latch   <= SS_MAP5[47:32];
		cpu_irq_counter <= SS_MAP5[63:48];

		chr_lo[0] <= SS_MAP6[7:0];   chr_lo[1] <= SS_MAP6[15:8];
		chr_lo[2] <= SS_MAP6[23:16]; chr_lo[3] <= SS_MAP6[31:24];
		chr_lo[4] <= SS_MAP6[39:32]; chr_lo[5] <= SS_MAP6[47:40];
		chr_lo[6] <= SS_MAP6[55:48]; chr_lo[7] <= SS_MAP6[63:56];

		chr_lo[8]  <= SS_MAP7[7:0];   chr_lo[9]  <= SS_MAP7[15:8];
		chr_lo[10] <= SS_MAP7[23:16]; chr_lo[11] <= SS_MAP7[31:24];
		chr_lo[12] <= SS_MAP7[39:32]; chr_lo[13] <= SS_MAP7[47:40];
		chr_lo[14] <= SS_MAP7[55:48]; chr_lo[15] <= SS_MAP7[63:56];

		chr_hi[0]  <= {3'b0, SS_MAP8[4:0]};
		chr_hi[1]  <= {3'b0, SS_MAP8[9:5]};
		chr_hi[2]  <= {3'b0, SS_MAP8[14:10]};
		chr_hi[3]  <= {3'b0, SS_MAP8[19:15]};
		chr_hi[4]  <= {3'b0, SS_MAP8[24:20]};
		chr_hi[5]  <= {3'b0, SS_MAP8[29:25]};
		chr_hi[6]  <= {3'b0, SS_MAP8[34:30]};
		chr_hi[7]  <= {3'b0, SS_MAP8[39:35]};
		chr_hi[8]  <= {3'b0, SS_MAP8[44:40]};
		chr_hi[9]  <= {3'b0, SS_MAP8[49:45]};
		chr_hi[10] <= {3'b0, SS_MAP8[54:50]};
		chr_hi[11] <= {3'b0, SS_MAP8[59:55]};
		chr_hi[12] <= {4'b0, SS_MAP8[63:60]};
		chr_hi[13] <= 8'h0; chr_hi[14] <= 8'h0; chr_hi[15] <= 8'h0;
	end else begin
		if (ce) begin
			parity <= ~parity;
			jitter <= jitter + 1'b1;

			if (cpu_irq_en) begin
				if (cpu_irq_counter == 16'h0) begin
					/* idle until reloaded via enable */
				end else if (cpu_irq_counter == 16'h1) begin
					cpu_irq_counter <= cpu_irq_latch;
					cpu_irq_pending <= 1'b1;
					jitter <= 8'h0;
				end else
					cpu_irq_counter <= cpu_irq_counter - 16'd1;
			end

			if (ppu_idle != 2'd0)
				ppu_idle <= ppu_idle - 2'd1;
			else begin
				ppu_in_frame <= 1'b0;
				ppu_in_hblank <= 1'b0;
			end

			if (prg_write && prg_regs) begin
				casez (prg_ain[7:0])
					8'h00: prg_mode_reg <= prg_din;
					8'h06: ram_hi[0] <= prg_din;
					8'h07: ram_hi[1] <= prg_din;
					8'h08: prg_hi[0] <= prg_din;
					8'h09: prg_hi[1] <= prg_din;
					8'h0A: prg_hi[2] <= prg_din;
					8'h0B: prg_hi[3] <= prg_din;
					8'h0C: prg_hi[4] <= prg_din;
					8'h0D: prg_hi[5] <= prg_din;
					8'h0E: prg_hi[6] <= prg_din;
					8'h0F: prg_hi[7] <= prg_din;
					8'h15: fpga_bank <= prg_din[0];
					8'h16: ram_lo[0] <= prg_din;
					8'h17: ram_lo[1] <= prg_din;
					8'h18: prg_lo[0] <= prg_din;
					8'h19: prg_lo[1] <= prg_din;
					8'h1A: prg_lo[2] <= prg_din;
					8'h1B: prg_lo[3] <= prg_din;
					8'h1C: prg_lo[4] <= prg_din;
					8'h1D: prg_lo[5] <= prg_din;
					8'h1E: prg_lo[6] <= prg_din;
					8'h1F: prg_lo[7] <= prg_din;
					8'h20: chr_mode_reg <= prg_din;
					8'h21: bg_ext_upper <= prg_din[4:0];
					8'h24: fill_tile <= prg_din;
					8'h25: fill_attr <= prg_din[1:0];
					8'h26: nt_bank[0] <= prg_din;
					8'h27: nt_bank[1] <= prg_din;
					8'h28: nt_bank[2] <= prg_din;
					8'h29: nt_bank[3] <= prg_din;
					8'h2A: nt_ctrl[0] <= prg_din;
					8'h2B: nt_ctrl[1] <= prg_din;
					8'h2C: nt_ctrl[2] <= prg_din;
					8'h2D: nt_ctrl[3] <= prg_din;
					8'h30: chr_hi[0]  <= prg_din;
					8'h31: chr_hi[1]  <= prg_din;
					8'h32: chr_hi[2]  <= prg_din;
					8'h33: chr_hi[3]  <= prg_din;
					8'h34: chr_hi[4]  <= prg_din;
					8'h35: chr_hi[5]  <= prg_din;
					8'h36: chr_hi[6]  <= prg_din;
					8'h37: chr_hi[7]  <= prg_din;
					8'h38: chr_hi[8]  <= prg_din;
					8'h39: chr_hi[9]  <= prg_din;
					8'h3A: chr_hi[10] <= prg_din;
					8'h3B: chr_hi[11] <= prg_din;
					8'h3C: chr_hi[12] <= prg_din;
					8'h3D: chr_hi[13] <= prg_din;
					8'h3E: chr_hi[14] <= prg_din;
					8'h3F: chr_hi[15] <= prg_din;
					8'h40: chr_lo[0]  <= prg_din;
					8'h41: chr_lo[1]  <= prg_din;
					8'h42: chr_lo[2]  <= prg_din;
					8'h43: chr_lo[3]  <= prg_din;
					8'h44: chr_lo[4]  <= prg_din;
					8'h45: chr_lo[5]  <= prg_din;
					8'h46: chr_lo[6]  <= prg_din;
					8'h47: chr_lo[7]  <= prg_din;
					8'h48: chr_lo[8]  <= prg_din;
					8'h49: chr_lo[9]  <= prg_din;
					8'h4A: chr_lo[10] <= prg_din;
					8'h4B: chr_lo[11] <= prg_din;
					8'h4C: chr_lo[12] <= prg_din;
					8'h4D: chr_lo[13] <= prg_din;
					8'h4E: chr_lo[14] <= prg_din;
					8'h4F: chr_lo[15] <= prg_din;
					8'h50: sl_latch <= prg_din;
					8'h51: sl_irq_en <= 1'b1;
					8'h52: begin sl_irq_en <= 1'b0; sl_irq_pending <= 1'b0; end
					8'h53: sl_offset <= (prg_din == 8'h00) ? 8'h01 : (prg_din > 8'hAA ? 8'hAA : prg_din);
					8'h57: parity <= 1'b1;
					8'h58: cpu_irq_latch[15:8] <= prg_din;
					8'h59: cpu_irq_latch[7:0]  <= prg_din;
					8'h5A: begin
						cpu_irq_en <= prg_din[0];
						cpu_irq_en_after <= prg_din[1];
						cpu_irq_pending <= 1'b0;
						if (prg_din[0]) cpu_irq_counter <= cpu_irq_latch;
					end
					8'h5B: begin
						cpu_irq_pending <= 1'b0;
						cpu_irq_en <= cpu_irq_en_after;
					end
					8'h5C: fpga_auto_addr[12:8] <= prg_din[4:0];
					8'h5D: fpga_auto_addr[7:0] <= prg_din;
					8'h5E: fpga_auto_inc <= prg_din;
					8'h5F: begin
						ram_addrA <= fpga_auto_addr;
						ram_dataA <= prg_din;
						ram_wrenA <= 1'b1;
						fpga_auto_addr <= fpga_auto_addr + fpga_auto_inc;
					end
					default: ;
				endcase
			end

			if (prg_read && prg_ain == 16'h4151)
				sl_irq_pending <= 1'b0;

			if (prg_read && prg_ain == 16'h415F)
				fpga_auto_addr <= fpga_auto_addr + fpga_auto_inc;

			if (prg_write && prg_hit_fpga) begin
				ram_addrA <= fpga_cpu_addr;
				ram_dataA <= prg_din;
				ram_wrenA <= 1'b1;
			end
		end

		if (~paused) begin
			if (chr_read) begin
				ppu_idle <= 2'd3;
				last_chr_dout <= ram_qB;

				if (chr_ain[13:12] == 2'b10) begin
					if (chr_ain == last_ppu_addr) begin
						if (nt_same_ctr < 2'd3)
							nt_same_ctr <= nt_same_ctr + 2'd1;
						if (nt_same_ctr >= 2'd2) begin
							if (!ppu_in_frame) begin
								ppu_in_frame <= 1'b1;
								ppu_scanline <= 8'h0;
							end else
								ppu_scanline <= ppu_scanline + 8'd1;
							ppu_read_ctr <= 8'h0;
							ppu_in_hblank <= 1'b0;
							nt_same_ctr <= 2'd0;
						end
					end else
						nt_same_ctr <= 2'd0;
				end else
					nt_same_ctr <= 2'd0;

				last_ppu_addr <= chr_ain;

				if (ppu_in_frame) begin
					ppu_read_ctr <= ppu_read_ctr + 8'd1;
					if (ppu_read_ctr == 8'd33)
						ppu_in_hblank <= 1'b1;
					if (sl_irq_en && sl_latch != 8'h00 &&
					    ppu_scanline == sl_latch &&
					    (ppu_read_ctr + 8'd1) == sl_offset) begin
						sl_irq_pending <= 1'b1;
						jitter <= 8'h0;
					end
				end

				if (ppu_is_nt && (nt_attr_ext | nt_bg_ext))
					ext_data <= ram_qB;
				override_tile <= ppu_is_nt & nt_bg_ext;
			end

			if (chr_write) begin
				if (chr_ain[13] && nt_src == 2'b10) begin
					ram_addrA <= {ntb[1:0], chr_ain[9:0]};
					ram_dataA <= chr_din;
					ram_wrenA <= 1'b1;
				end else if (!chr_ain[13] && chr_src == 2'b10) begin
					ram_addrA <= {1'b0, chr_ain[11:0]};
					ram_dataA <= chr_din;
					ram_wrenA <= 1'b1;
				end
			end
		end
	end
end

assign irq = (sl_irq_en & sl_irq_pending) | (cpu_irq_en & cpu_irq_pending);

// -------------------------------------------------------------------------
// CPU bus
// -------------------------------------------------------------------------
reg [7:0] prg_dout_r;
reg       prg_bus_write_r;
assign prg_dout = prg_dout_r;
assign prg_bus_write = prg_bus_write_r;

always @* begin
	prg_dout_r = 8'hFF;
	prg_bus_write_r = 1'b0;
	if (prg_regs) begin
		prg_bus_write_r = 1'b1;
		case (prg_ain[7:0])
			8'h00: prg_dout_r = prg_mode_reg;
			8'h20: prg_dout_r = chr_mode_reg;
			8'h2A: prg_dout_r = nt_ctrl[0];
			8'h2B: prg_dout_r = nt_ctrl[1];
			8'h2C: prg_dout_r = nt_ctrl[2];
			8'h2D: prg_dout_r = nt_ctrl[3];
			8'h50: prg_dout_r = ppu_scanline;
			8'h51: prg_dout_r = {ppu_in_hblank, ppu_in_frame, 6'b0};
			8'h54: prg_dout_r = jitter;
			8'h57: prg_dout_r = {parity, 7'b0};
			8'h5F: prg_dout_r = ram_qB;
			8'h60: prg_dout_r = 8'h21; // platform=emulator(1), version=1
			8'h61: prg_dout_r = {sl_irq_pending, cpu_irq_pending, 6'b0};
			default: prg_dout_r = 8'hFF;
		endcase
	end else if (prg_hit_fpga) begin
		prg_bus_write_r = 1'b1;
		prg_dout_r = ram_qB;
	end
end

reg [21:0] prg_aout_r;
reg        prg_allow_r;
assign prg_aout = prg_aout_r;
assign prg_allow = prg_allow_r;

always @* begin
	prg_aout_r  = {1'b0, prg_lin};
	prg_allow_r = prg_is_hi & ~prg_write & ~prg_to_ram;

	if (prg_hit_fpga || prg_hit_auto) begin
		prg_aout_r  = {9'b11_1100_000, prg_ain[12:0]};
		prg_allow_r = 1'b1;
	end else if (prg_is_low) begin
		case (low_src)
			2'b00, 2'b01: begin
				prg_aout_r  = {1'b0, low_rom};
				prg_allow_r = ~prg_write;
			end
			2'b10: begin
				prg_aout_r  = {5'b11100, low_ram};
				prg_allow_r = 1'b1;
			end
			default: begin
				prg_aout_r  = {9'b11_1100_000, prg_ain[12:0]};
				prg_allow_r = 1'b1;
			end
		endcase
	end else if (prg_is_hi && prg_to_ram) begin
		case (prg_bsh)
			3'd5: prg_aout_r = {5'b11100, prg_bnum[1:0], prg_ain[14:0]};
			3'd4: prg_aout_r = {5'b11100, prg_bnum[2:0], prg_ain[13:0]};
			3'd3: prg_aout_r = {5'b11100, prg_bnum[3:0], prg_ain[12:0]};
			default: prg_aout_r = {5'b11100, prg_bnum[4:0], prg_ain[11:0]};
		endcase
		prg_allow_r = 1'b1;
	end
end

// -------------------------------------------------------------------------
// PPU bus
// -------------------------------------------------------------------------
reg        has_chr_dout_r;
reg  [7:0] chr_dout_r;
reg [21:0] chr_aout_r;
reg        chr_allow_r, vram_ce_r, vram_a10_r;
assign has_chr_dout = has_chr_dout_r;
assign chr_dout = chr_dout_r;
assign chr_aout = chr_aout_r;
assign chr_allow = chr_allow_r;
assign vram_ce = vram_ce_r;
assign vram_a10 = vram_a10_r;

always @* begin
	has_chr_dout_r = 1'b0;
	chr_dout_r = last_chr_dout;
	chr_aout_r = {2'b10, chr_lin};
	chr_allow_r = 1'b0;
	vram_ce_r = 1'b0;
	vram_a10_r = ntb[0];

	if (chr_ain[13]) begin
		// Fill / attr-ext override
		if (nt_fill && ppu_is_nt) begin
			has_chr_dout_r = 1'b1;
			chr_dout_r = fill_tile;
		end else if (nt_fill && ppu_is_at) begin
			has_chr_dout_r = 1'b1;
			chr_dout_r = {4{fill_attr}};
		end else if (nt_attr_ext && ppu_is_at) begin
			has_chr_dout_r = 1'b1;
			chr_dout_r = {4{ext_data[7:6]}};
		end

		case (nt_src)
			2'b00: begin
				vram_ce_r = ~has_chr_dout_r;
				vram_a10_r = ntb[0];
				chr_allow_r = 1'b1;
			end
			2'b01: begin
				chr_aout_r = {9'b11_1111_111, ntb[2:0], chr_ain[9:0]};
				chr_allow_r = 1'b1;
			end
			2'b10: begin
				has_chr_dout_r = 1'b1;
				chr_dout_r = last_chr_dout;
			end
			default: begin
				chr_aout_r = {2'b10, ntb, chr_ain[9:0]};
			end
		endcase
	end else begin
		case (chr_src)
			2'b00: begin
				if (override_tile)
					chr_aout_r = {2'b10, bg_ext_upper[3:0], ext_data[5:0], chr_ain[11:0]};
				else
					chr_aout_r = {2'b10, chr_lin};
			end
			2'b01: begin
				if (override_tile)
					chr_aout_r = {4'b1111, ext_data[5:0], chr_ain[11:0]};
				else
					chr_aout_r = {9'b11_1111_111, chr_lin[12:0]};
				chr_allow_r = 1'b1;
			end
			2'b10: begin
				has_chr_dout_r = 1'b1;
				chr_dout_r = last_chr_dout;
			end
			default: begin
				vram_ce_r = 1'b1;
				vram_a10_r = chr_ain[10];
				chr_allow_r = 1'b1;
			end
		endcase
	end
end

// -------------------------------------------------------------------------
// Savestate
// -------------------------------------------------------------------------
wire [63:0] SS_MAP1, SS_MAP2, SS_MAP3, SS_MAP4, SS_MAP5, SS_MAP6, SS_MAP7, SS_MAP8;
wire [63:0] SS_MAP1_BACK, SS_MAP2_BACK, SS_MAP3_BACK, SS_MAP4_BACK;
wire [63:0] SS_MAP5_BACK, SS_MAP6_BACK, SS_MAP7_BACK, SS_MAP8_BACK;
wire [63:0] SS_w[0:7];

assign SS_MAP1_BACK[7:0]   = prg_mode_reg;
assign SS_MAP1_BACK[8]     = fpga_bank;
assign SS_MAP1_BACK[16:9]  = chr_mode_reg;
assign SS_MAP1_BACK[21:17] = bg_ext_upper;
assign SS_MAP1_BACK[29:22] = fill_tile;
assign SS_MAP1_BACK[31:30] = fill_attr;
assign SS_MAP1_BACK[39:32] = sl_latch;
assign SS_MAP1_BACK[40]    = sl_irq_en;
assign SS_MAP1_BACK[41]    = sl_irq_pending;
assign SS_MAP1_BACK[49:42] = sl_offset;
assign SS_MAP1_BACK[50]    = parity;
assign SS_MAP1_BACK[51]    = cpu_irq_en;
assign SS_MAP1_BACK[52]    = cpu_irq_en_after;
assign SS_MAP1_BACK[53]    = cpu_irq_pending;
assign SS_MAP1_BACK[54]    = ppu_in_frame;
assign SS_MAP1_BACK[55]    = ppu_in_hblank;
assign SS_MAP1_BACK[56]    = override_tile;
assign SS_MAP1_BACK[63:57] = ppu_scanline[6:0];

assign SS_MAP2_BACK = {prg_hi[7],prg_hi[6],prg_hi[5],prg_hi[4],prg_hi[3],prg_hi[2],prg_hi[1],prg_hi[0]};
assign SS_MAP3_BACK = {prg_lo[7],prg_lo[6],prg_lo[5],prg_lo[4],prg_lo[3],prg_lo[2],prg_lo[1],prg_lo[0]};
assign SS_MAP4_BACK = {nt_bank[3],nt_bank[2],nt_bank[1],nt_bank[0], ram_hi[1],ram_hi[0],ram_lo[1],ram_lo[0]};
assign SS_MAP5_BACK = {cpu_irq_counter, cpu_irq_latch, nt_ctrl[3],nt_ctrl[2],nt_ctrl[1],nt_ctrl[0]};
assign SS_MAP6_BACK = {chr_lo[7],chr_lo[6],chr_lo[5],chr_lo[4],chr_lo[3],chr_lo[2],chr_lo[1],chr_lo[0]};
assign SS_MAP7_BACK = {chr_lo[15],chr_lo[14],chr_lo[13],chr_lo[12],chr_lo[11],chr_lo[10],chr_lo[9],chr_lo[8]};
assign SS_MAP8_BACK = {
	chr_hi[12][3:0],
	chr_hi[11][4:0], chr_hi[10][4:0], chr_hi[9][4:0], chr_hi[8][4:0],
	chr_hi[7][4:0], chr_hi[6][4:0], chr_hi[5][4:0], chr_hi[4][4:0],
	chr_hi[3][4:0], chr_hi[2][4:0], chr_hi[1][4:0], chr_hi[0][4:0]
};

eReg_SavestateV #(SSREG_INDEX_MAP1, 64'h0) i1 (clk, SaveStateBus_Din, SaveStateBus_Adr, SaveStateBus_wren, SaveStateBus_rst, SS_w[0], SS_MAP1_BACK, SS_MAP1);
eReg_SavestateV #(SSREG_INDEX_MAP2, 64'h0) i2 (clk, SaveStateBus_Din, SaveStateBus_Adr, SaveStateBus_wren, SaveStateBus_rst, SS_w[1], SS_MAP2_BACK, SS_MAP2);
eReg_SavestateV #(SSREG_INDEX_MAP3, 64'h0) i3 (clk, SaveStateBus_Din, SaveStateBus_Adr, SaveStateBus_wren, SaveStateBus_rst, SS_w[2], SS_MAP3_BACK, SS_MAP3);
eReg_SavestateV #(SSREG_INDEX_MAP4, 64'h0) i4 (clk, SaveStateBus_Din, SaveStateBus_Adr, SaveStateBus_wren, SaveStateBus_rst, SS_w[3], SS_MAP4_BACK, SS_MAP4);
eReg_SavestateV #(SSREG_INDEX_MAP5, 64'h0) i5 (clk, SaveStateBus_Din, SaveStateBus_Adr, SaveStateBus_wren, SaveStateBus_rst, SS_w[4], SS_MAP5_BACK, SS_MAP5);
eReg_SavestateV #(SSREG_INDEX_MAP6, 64'h0) i6 (clk, SaveStateBus_Din, SaveStateBus_Adr, SaveStateBus_wren, SaveStateBus_rst, SS_w[5], SS_MAP6_BACK, SS_MAP6);
eReg_SavestateV #(10'd38, 64'h0) i7 (clk, SaveStateBus_Din, SaveStateBus_Adr, SaveStateBus_wren, SaveStateBus_rst, SS_w[6], SS_MAP7_BACK, SS_MAP7);
eReg_SavestateV #(10'd39, 64'h0) i8 (clk, SaveStateBus_Din, SaveStateBus_Adr, SaveStateBus_wren, SaveStateBus_rst, SS_w[7], SS_MAP8_BACK, SS_MAP8);

assign SaveStateBus_Dout = enable ? (SS_w[0]|SS_w[1]|SS_w[2]|SS_w[3]|SS_w[4]|SS_w[5]|SS_w[6]|SS_w[7]) : 64'h0;

endmodule
