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
//   - Fill-mode ($4124-$4125), Attribute + Background extended modes
//     (MMC5-style ext latch; attr-ext wins over FPGA-NT on AT fetches;
//      bg-ext 4K CHR addr is 22-bit-safe; sticky through BG pattern fetches)
//   - Scanline IRQ ($4150-$4153) and CPU-cycle IRQ ($4157-$415B)
//   - Mapper version ($4160), IRQ status ($4161), SaveStateBus + FPGA-RAM savestate
//   - Window Split Mode ($4120.W / $412E-$412F / $4170-$4175), including
//     next-line prefetch and independent fine-Y, from actual PPU dot timing
//   - EXP6/VRC6 pulse + saw audio ($41A0-$41A8), enable and volume ($41A9/$41AA)
//   - Independent CPU/PPU FPGA-RAM ports for active-display tile streaming
//   - Full 8MiB PRG + 8MiB CHR-ROM, 256KiB PRG/CHR-RAM, NES 2.0 size masks
//   - Sprite extended banks using actual evaluated OAM indices, 8x8 / 8x16
//   - Executable OAM slow update, extended-bank update and clear routines
//   - NMI/IRQ vector redirection ($416B-$416F)
// Deferred (explicitly):
//   - Wi-Fi/ESP ($4190-$4194)
//   - IPCM / EPSM
//   - Self-flash PRG/CHR


module Mapper682(
	input         clk,
	input         ce,
	input         enable,
	input  [63:0] flags,
	input  [11:0] prg_rom_mask, chr_rom_mask,
	output [24:0] prg_address, chr_address,
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
	input         chr_ex,       // Extra sprite fetch, never a background fetch
	input  [8:0]  ppu_dot,      // Actual PPU cycle: 0..340
	input  [8:0]  ppu_line,     // Actual PPU scanline; pre-render is 511
	input         ppu_rendering,
    input [5:0] sprite_oam_index,
    input sprite_size_16,
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

assign prg_aout_b  = enable ? prg_aout[21:0] : 22'hZ;
assign prg_dout_b  = enable ? prg_dout  : 8'hZ;
assign prg_allow_b = enable ? prg_allow : 1'hZ;
assign chr_aout_b  = enable ? chr_aout[21:0] : 22'hZ;
assign chr_dout_b  = enable ? chr_dout  : 8'hZ;
assign chr_allow_b = enable ? chr_allow : 1'hZ;
assign vram_a10_b  = enable ? vram_a10  : 1'hZ;
assign vram_ce_b   = enable ? vram_ce   : 1'hZ;
assign irq_b       = enable ? irq       : 1'hZ;
assign flags_out_b = enable ? flags_out : 16'hZ;
assign audio_b     = enable ? mixed_audio[16:1] : 16'hZ;

wire [15:0] flags_out = {12'h0, 1'b1, 1'b0, prg_bus_write, has_chr_dout};

wire [24:0] prg_aout, chr_aout;
assign prg_address = prg_aout;
assign chr_address = chr_aout;
// Rainbow gets disjoint 8MiB PRG/CHR ROM apertures in the 32MiB SDRAM.
// The shared core's CPU/CIRAM/savestate regions stay at their existing addresses.
localparam [24:0] PRG_ROM_BASE = 25'h0800000;
localparam [24:0] CHR_ROM_BASE = 25'h1000000;
localparam [24:0] PRG_RAM_BASE = 25'h03C0000;
localparam [24:0] CHR_RAM_BASE = 25'h0300000;
wire [3:0] prg_ram_shift = flags[34:31] > flags[29:26] ? flags[34:31] : flags[29:26];
wire [17:0] prg_ram_mask = prg_ram_shift == 0 ? 18'h07FFF :
    prg_ram_shift >= 12 ? 18'h3FFFF : (18'd64 << prg_ram_shift) - 18'd1;
wire [3:0] chr_ram_shift = flags[63:60];
wire [17:0] chr_ram_mask = chr_ram_shift == 0 ? 18'h07FFF :
    chr_ram_shift >= 12 ? 18'h3FFFF : (18'd64 << chr_ram_shift) - 18'd1;
function [24:0] prg_rom_address(input [22:0] offset);
    prg_rom_address = PRG_ROM_BASE | {2'b0, (offset & {prg_rom_mask,11'h7FF})};
endfunction
function [24:0] chr_rom_address(input [22:0] offset);
    chr_rom_address = CHR_ROM_BASE | {2'b0, (offset & {chr_rom_mask,11'h7FF})};
endfunction
function [24:0] prg_ram_address(input [17:0] offset);
    prg_ram_address = PRG_RAM_BASE | {7'b0, (offset & prg_ram_mask)};
endfunction
function [24:0] chr_ram_address(input [17:0] offset);
    chr_ram_address = CHR_RAM_BASE | {7'b0, (offset & chr_ram_mask)};
endfunction
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
reg [7:0] sprite_ext[0:63];
reg [2:0] sprite_ext_bank;
wire use_sprite_ext = chr_mode_reg[5] && ppu_in_frame && ppu_dot >= 257 && ppu_dot <= 320;
wire [22:0] sprite_ext_address = sprite_size_16 ?
    {sprite_ext_bank[1:0], sprite_ext[sprite_oam_index], chr_ain[12:0]} :
    {sprite_ext_bank, sprite_ext[sprite_oam_index], chr_ain[11:0]};

// Executable slow OAM transfer at $4280. Generate instruction bytes instead
// of allocating a 1286-byte ROM: LDA #0 / STA $2003, then 256 pairs of
// LDA #shadow_byte / STA $2004, finally RTS. X/Y are preserved.
reg [2:0] oam_page;
reg [4:0] oam_ext_page;
reg [1:0] oam_kind;
reg oam_locked;
reg [1:0] vector_enable;
reg [15:0] nmi_vector, irq_vector;
wire vector_hit = ((prg_ain == 16'hFFFA || prg_ain == 16'hFFFB) && vector_enable[0]) ||
                  ((prg_ain == 16'hFFFE || prg_ain == 16'hFFFF) && vector_enable[1]);
wire [15:0] selected_vector = prg_ain[2] ? irq_vector : nmi_vector;
reg [5:0] oam_limit;
reg [7:0] oam_read_data;
wire oam_code = prg_ain >= 16'h4280 && prg_ain < 16'h4800;
wire oam_entry = !oam_locked && (prg_ain == 16'h4280 || prg_ain == 16'h4282 || prg_ain == 16'h4286);
wire [1:0] oam_active_kind = oam_entry ? (prg_ain == 16'h4280 ? 2'd0 : prg_ain == 16'h4282 ? 2'd1 : 2'd2) : oam_kind;
wire [10:0] oam_offset = prg_ain - (oam_active_kind == 1 ? 16'h4282 : 16'h4285);
wire [10:0] oam_index = oam_offset / 11'd5;
wire [2:0] oam_phase = oam_offset % 11'd5;
wire [12:0] oam_ram_addr = oam_active_kind == 1 ? {2'b11, oam_ext_page, oam_index[5:0]} : {2'b11, oam_page, oam_index[7:0]};
wire [10:0] clear_offset = prg_ain - 16'h4286;
wire [10:0] clear_regular = clear_offset < 2 ? clear_offset : clear_offset - 11'd2;
reg [7:0] oam_instruction;
always @* begin
    oam_instruction = 8'h60;
    if (oam_active_kind == 2) begin
        if (clear_offset == 2) oam_instruction = 8'hAA; // TAX, first sprite only
        else if (clear_offset == 3) oam_instruction = 8'hCA; // DEX -> $FF
        else if (clear_regular < 512) begin
            case (clear_regular[2:0])
                0: oam_instruction = 8'hA9;
                1: oam_instruction = {clear_regular[8:3], 2'b00};
                2: oam_instruction = 8'h8D;
                3: oam_instruction = 8'h03;
                4: oam_instruction = 8'h20;
                5: oam_instruction = 8'h8E;
                6: oam_instruction = 8'h04;
                7: oam_instruction = 8'h20;
            endcase
        end
    end else if (oam_active_kind == 1) begin
        if (oam_index <= {5'b0, oam_limit}) begin
            case (oam_phase)
                0: oam_instruction = 8'hA9;
                1: oam_instruction = ram_qA;
                2: oam_instruction = 8'h8D;
                3: oam_instruction = {2'b00, oam_index[5:0]};
                4: oam_instruction = 8'h42;
                default: ;
            endcase
        end
    end else if (prg_ain < 16'h4285) begin
        case (prg_ain[2:0])
            0: oam_instruction = 8'hA9;
            1: oam_instruction = 8'h00;
            2: oam_instruction = 8'h8D;
            3: oam_instruction = 8'h03;
            4: oam_instruction = 8'h20;
            default: ;
        endcase
    end else if (oam_index < ({5'b0, oam_limit} + 11'd1) * 11'd4) begin
        case (oam_phase)
            0: oam_instruction = 8'hA9;
            1: oam_instruction = ram_qA;
            2: oam_instruction = 8'h8D;
            3: oam_instruction = 8'h04;
            4: oam_instruction = 8'h20;
            default: ;
        endcase
    end
end

reg [7:0] sl_latch, sl_offset, jitter;
reg       sl_irq_en, sl_irq_pending;
reg       parity;
reg [15:0] cpu_irq_latch, cpu_irq_counter;
reg        cpu_irq_en, cpu_irq_en_after, cpu_irq_pending;

reg [12:0] fpga_auto_addr;
reg [7:0]  fpga_auto_inc;

// PPU /RD is held for an entire dot (several clk edges). Do not count
// its asserted level or infer scanlines from repeated addresses. Those reads
// also occur during $2007 access and the extra-sprite fetch schedule.
wire ppu_in_frame = ppu_rendering && (ppu_line < 9'd240 || ppu_line == 9'd511);
wire ppu_in_hblank = ppu_in_frame && ppu_dot >= 9'd257;
wire [7:0] ppu_scanline = ppu_line == 9'd511 ? 8'd0 : ppu_line[7:0];
wire bg_fetch = ppu_in_frame && !chr_ex &&
    ((ppu_dot >= 9'd1 && ppu_dot <= 9'd256) ||
     (ppu_dot >= 9'd321 && ppu_dot <= 9'd336));
reg [7:0] ext_data;
reg override_tile;
reg [7:0] last_chr_dout;
reg [7:0] fpga_read_data;
reg [9:0] ext_tile_addr;
reg last_chr_read;

// Window Split Mode ($4120 bit4, $412E/$412F, $4170-$4175)
reg [7:0]  split_bank;       // $412E
reg [7:0]  split_ctrl;       // $412F (chip forced FPGA-RAM)
reg [4:0]  split_x0, split_x1; // $4170/$4171 tile columns
reg [7:0]  split_y0, split_y1; // $4172/$4173 scanlines (web: y < y1)
reg [4:0]  split_sx;         // $4174 coarse X scroll (tiles)
reg [7:0]  split_sy;         // $4175 fine Y scroll
wire [7:0] split_screen_y = (ppu_dot >= 9'd321)
    ? (ppu_line == 9'd511 ? 8'd0 : ppu_line[7:0] + 8'd1)
    : ppu_scanline;
reg [7:0]  split_ext_data;   // latched ext byte for split attr/bg-ext
reg [9:0]  split_tile_addr;  // NT tile offset inside split nametable

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
	prg_is_hi ? prg_lin[12:0] :
	(prg_mode_reg[7] ? {low_bank[0], prg_ain[11:0]} : prg_ain[12:0]);

wire prg_low_fpga = prg_is_low && (low_src == 2'b11);
wire prg_hit_fpga = prg_fpga_fixed | prg_fpga_banked | prg_low_fpga |
    (prg_is_hi && prg_b16[15:14] == 2'b11);
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

// During rendering the fetch phase distinguishes NT from AT, including
// coarse Y=30/31, whose *tile* address is in the usual attribute range.
wire ppu_is_nt = (chr_ain[13:12] == 2'b10) && (bg_fetch
    ? (ppu_dot[2:0] == 3'd1 || ppu_dot[2:0] == 3'd2) : ~(&chr_ain[9:6]));
wire ppu_is_at = (chr_ain[13:12] == 2'b10) && (bg_fetch
    ? (ppu_dot[2:0] == 3'd3 || ppu_dot[2:0] == 3'd4) : (&chr_ain[9:6]));

wire [1:0] chr_src = chr_mode_reg[7:6];
wire       split_on = chr_mode_reg[4];

// The visible fetch pipeline is two tiles ahead of the pixel output.
// Dots 321..336 fetch tiles 0/1 of the next line (line 0 on pre-render).
wire [8:0] fetch_dot = ppu_dot - 9'd1;
wire [4:0] split_tile_x = ppu_dot >= 9'd321
    ? {4'b0, ppu_dot[3]} : fetch_dot[7:3] + 5'd2;
wire       split_in_x = (split_x0 <= split_x1)
	? (split_tile_x >= split_x0 && split_tile_x <= split_x1)
	: (split_tile_x >= split_x0 || split_tile_x <= split_x1);
wire       split_in_y = (split_y0 <= split_y1)
	? (split_screen_y >= split_y0 && split_screen_y < split_y1)
	: (split_screen_y >= split_y0 || split_screen_y < split_y1);
wire       in_split = split_on & bg_fetch & split_in_x & split_in_y;

// Split NT loopy: coarse X scroll in tiles; Y = screenY + split_sy, wrap 30 rows.
wire [8:0] split_y_sum = {1'b0, split_screen_y} + {1'b0, split_sy};
wire [8:0] split_y_wrap = split_y_sum >= 9'd480 ? split_y_sum - 9'd480 :
    split_y_sum >= 9'd240 ? split_y_sum - 9'd240 : split_y_sum;
wire [4:0] split_col = split_tile_x + split_sx;
wire [4:0] split_row = split_y_wrap[7:3];
wire [9:0] split_nt_loopy = {split_row, split_col};
wire [9:0] split_at_loopy = {4'b1111, split_row[4:2], split_col[4:2]};
wire [2:0] split_fine_y = split_y_wrap[2:0];

wire [1:0] split_ext_page = split_ctrl[3:2];
wire       split_attr_ext = split_ctrl[0];
wire       split_bg_ext   = split_ctrl[1];
wire       split_need_ext = split_attr_ext | split_bg_ext;

// Ext-mode FPGA addressing (BrokeStudio mapper-doc + MMC5-style pipeline):
// - CIRAM/CHR-* NT + ext: during NT/AT, read ext page at the tile offset.
// - FPGA-RAM NT + ext: NT cycles must return the nametable byte, so latch the
//   tile offset and fetch the ext byte from nt_ext_page during the AT cycles.
// - Window Split: always FPGA-RAM NT at split_bank; ext from split_ctrl DD page.
// altsyncram address_reg_b => 1 clk latency; PPU holds NT/AT for 2 dots.
wire       ppu_need_ext = nt_attr_ext | nt_bg_ext;
// Always re-fetch ext on AT via latched tile offset (CIRAM *and* FPGA-NT).
// Using chr_ain[9:0] on AT would hit the attribute loopy (0x3C0+), not the tile.
wire       ppu_ext_at   = ppu_need_ext & ppu_is_at & ~in_split;
wire       ppu_ext_nt   = ppu_need_ext & ppu_is_nt & (nt_src != 2'b10) & ~in_split;

wire [12:0] fpga_ppu_addr =
	!chr_ain[13] ? (use_sprite_ext ? sprite_ext_address[12:0] : {1'b0, (in_split ? {chr_ain[11:3], split_fine_y} : chr_ain[11:0])}) :
	// Window Split NT/AT (and split ext on AT when EE!=0)
	(in_split && ppu_is_at && split_need_ext) ? {split_ext_page, split_tile_addr} :
	(in_split && (ppu_is_nt || ppu_is_at)) ? {split_bank[1:0], ppu_is_nt ? split_nt_loopy : split_at_loopy} :
	ppu_ext_at   ? {nt_ext_page, ext_tile_addr} :
	ppu_ext_nt   ? {nt_ext_page, chr_ain[9:0]} :
	(nt_src == 2'b10) ? {ntb[1:0], chr_ain[9:0]} :
	ppu_need_ext ? {nt_ext_page, chr_ain[9:0]} :
	               {ntb[1:0], chr_ain[9:0]};

// Port A handles CPU reads/writes and $2007 writes. Port B remains on
// the PPU even during CPU reads, so streaming cannot steal attribute data.
wire [12:0] ram_addr_cpu = ram_wrenA ? ram_addrA :
    oam_code ? oam_ram_addr : prg_hit_auto ? fpga_auto_addr : fpga_cpu_addr;
wire [12:0] ram_addrB = Savestate_MAPRAMactive ? Savestate_MAPRAMAddr : fpga_ppu_addr;
wire       ram_wrenB = Savestate_MAPRAMactive & Savestate_MAPRAMWrEn;
wire [7:0] ram_dataB = Savestate_MAPRAMWriteData;
wire [7:0] ram_qA, ram_qB;

dpram #(.widthad_a(13)) fpga_ram (
	.clock_a(clk), .address_a(ram_addr_cpu), .wren_a(ram_wrenA), .byteena_a(1'b1), .data_a(ram_dataA), .q_a(ram_qA),
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

reg [22:0] prg_lin;
always @* begin
	case (prg_bsh)
		3'd5: prg_lin = {prg_bnum[7:0], prg_ain[14:0]};
		3'd4: prg_lin = {prg_bnum[8:0], prg_ain[13:0]};
		3'd3: prg_lin = {prg_bnum[9:0], prg_ain[12:0]};
		default: prg_lin = {prg_bnum[10:0], prg_ain[11:0]};
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
// Mesen and the 8MiB test ROM use bit 13 in 512-byte mode.
wire [13:0] chr_bnum = {chr_hi[chr_ridx][5:0], chr_lo[chr_ridx]};

reg [22:0] chr_lin;
always @* begin
    case (chr_md)
        3'd0: chr_lin = {chr_bnum[9:0], chr_ain[12:0]};
        3'd1: chr_lin = {chr_bnum[10:0], chr_ain[11:0]};
        3'd2: chr_lin = {chr_bnum[11:0], chr_ain[10:0]};
        3'd3: chr_lin = {chr_bnum[12:0], chr_ain[9:0]};
        default: chr_lin = {chr_bnum[13:0], chr_ain[8:0]};
    endcase
end
wire [22:0] low_rom = prg_mode_reg[7] ? {low_bank[10:0], prg_ain[11:0]} : {low_bank[9:0], prg_ain[12:0]};
wire [17:0] low_ram = prg_mode_reg[7] ? {low_bank[5:0], prg_ain[11:0]} : {low_bank[4:0], prg_ain[12:0]};

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
		ext_data <= 8'h0; override_tile <= 1'b0; last_chr_dout <= 8'h0;
		ext_tile_addr <= 10'h0; last_chr_read <= 1'b0;
		fpga_read_data <= 8'h0;
        oam_page <= 3'd7; oam_limit <= 6'd63; oam_read_data <= 8'h60;
        oam_ext_page <= 5'd0; oam_kind <= 0; oam_locked <= 0;
        vector_enable <= 0; nmi_vector <= 0; irq_vector <= 0;
        sprite_ext_bank <= 0;
        for (i=0;i<64;i=i+1) sprite_ext[i] <= 0;
		audio_ctrl <= 3'b0; audio_volume <= 4'hF;
		split_bank <= 8'h00; split_ctrl <= 8'h80; // mapper-doc power-up
		split_x0 <= 5'h0; split_x1 <= 5'h1F; split_y0 <= 8'h0; split_y1 <= 8'h0;
		split_sx <= 5'h0; split_sy <= 8'h0;
		split_ext_data <= 8'h0; split_tile_addr <= 10'h0;
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
		override_tile<= SS_MAP1[56];

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

		chr_hi[0]  <= {2'b0, SS_MAP12[0], SS_MAP8[4:0]};
		chr_hi[1]  <= {2'b0, SS_MAP12[1], SS_MAP8[9:5]};
		chr_hi[2]  <= {2'b0, SS_MAP12[2], SS_MAP8[14:10]};
		chr_hi[3]  <= {2'b0, SS_MAP12[3], SS_MAP8[19:15]};
		chr_hi[4]  <= {2'b0, SS_MAP12[4], SS_MAP8[24:20]};
		chr_hi[5]  <= {2'b0, SS_MAP12[5], SS_MAP8[29:25]};
		chr_hi[6]  <= {2'b0, SS_MAP12[6], SS_MAP8[34:30]};
		chr_hi[7]  <= {2'b0, SS_MAP12[7], SS_MAP8[39:35]};
		chr_hi[8]  <= {2'b0, SS_MAP12[8], SS_MAP8[44:40]};
		chr_hi[9]  <= {2'b0, SS_MAP12[9], SS_MAP8[49:45]};
		chr_hi[10] <= {2'b0, SS_MAP12[10], SS_MAP8[54:50]};
		chr_hi[11] <= {2'b0, SS_MAP12[11], SS_MAP8[59:55]};
		chr_hi[12] <= {2'b0, SS_MAP12[12], SS_MAP11[0], SS_MAP8[63:60]};
		chr_hi[13] <= {2'b0, SS_MAP12[13], SS_MAP11[5:1]};
		chr_hi[14] <= {2'b0, SS_MAP12[14], SS_MAP11[10:6]};
		chr_hi[15] <= {2'b0, SS_MAP12[15], SS_MAP11[15:11]};

		split_bank      <= SS_MAP9[7:0];
		split_ctrl      <= SS_MAP9[15:8];
		split_x0        <= SS_MAP9[20:16];
		split_x1        <= SS_MAP9[25:21];
		split_y0        <= SS_MAP9[33:26];
		split_y1        <= SS_MAP9[41:34];
		split_sx        <= SS_MAP9[46:42];
		split_sy        <= SS_MAP9[54:47];
		audio_ctrl <= SS_MAP10[2:0];
		audio_volume <= SS_MAP10[6:3];
		fpga_auto_addr <= SS_MAP10[19:7];
		fpga_auto_inc <= SS_MAP10[27:20];
		ext_data <= SS_MAP10[35:28];
		split_ext_data <= SS_MAP10[43:36];
		ext_tile_addr <= SS_MAP10[53:44];
		split_tile_addr <= SS_MAP10[63:54];
		last_chr_dout <= SS_MAP11[23:16];
		last_chr_read <= SS_MAP11[24];
		jitter <= SS_MAP11[32:25];
		fpga_read_data <= SS_MAP11[40:33];
        oam_page <= SS_MAP12[18:16];
        oam_limit <= SS_MAP12[24:19];
        oam_read_data <= SS_MAP12[32:25];
        {irq_vector, nmi_vector, vector_enable, oam_locked, oam_kind, oam_ext_page} <= SS_MAP13[41:0];
        sprite_ext_bank <= SS_MAP13[44:42];
        for (i=0;i<64;i=i+1) sprite_ext[i] <= SS_SPR[i/8][(i%8)*8 +: 8];
	end else begin
		if (ce) begin
            if (prg_read && oam_code) begin
                oam_read_data <= oam_instruction;
                if (oam_entry) begin oam_kind <= oam_active_kind; oam_locked <= 1; end
                if (prg_ain >= 16'h4286) oam_locked <= 0;
            end
            if (prg_write && prg_ain == 16'h4241) oam_page <= prg_din[2:0];
            if (prg_write && prg_ain == 16'h4242) oam_ext_page <= prg_din[4:0];
            if (prg_write && prg_ain == 16'h4243) oam_limit <= prg_din[5:0];
            if (prg_write && prg_ain[15:6] == 10'h108) sprite_ext[prg_ain[5:0]] <= prg_din;
            if (prg_write && prg_ain == 16'h4240) sprite_ext_bank <= prg_din[2:0];
            if (prg_write) case (prg_ain)
                16'h416B: vector_enable <= prg_din[1:0];
                16'h416C: nmi_vector[15:8] <= prg_din;
                16'h416D: nmi_vector[7:0] <= prg_din;
                16'h416E: irq_vector[15:8] <= prg_din;
                16'h416F: irq_vector[7:0] <= prg_din;
                default: ;
            endcase
			// T65 samples two master clocks after cart ce. Hold the byte
			// across an auto-reader increment until the next CPU access.
			if (prg_read && (prg_hit_fpga || prg_hit_auto))
				fpga_read_data <= ram_qA;
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

			if (prg_write && prg_regs) begin
				casez (prg_ain[7:0])
					8'hA9: audio_ctrl <= prg_din[2:0];
					8'hAA: audio_volume <= prg_din[3:0];
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
					8'h2E: split_bank <= prg_din;
					8'h2F: split_ctrl <= prg_din;
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
					8'h70: split_x0 <= prg_din[4:0];
					8'h71: split_x1 <= prg_din[4:0];
					8'h72: split_y0 <= prg_din;
					8'h73: split_y1 <= prg_din;
					8'h74: split_sx <= prg_din[4:0];
					8'h75: split_sy <= prg_din;
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

			if (prg_read && (prg_ain == 16'h4151 || prg_ain == 16'hFFFA || prg_ain == 16'hFFFB))
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
			last_chr_read <= chr_read;
			// One event per physical /RD, with the IRQ offset measured in
			// two-dot reads. Rendering resumes correctly even in mid-frame.
			if (chr_read && !last_chr_read && ppu_in_frame &&
			    sl_irq_en && sl_latch != 0 && ppu_scanline == sl_latch &&
			    ppu_dot[8:1] == sl_offset &&
			    !(ce && ((prg_write && prg_ain == 16'h4152) ||
			             (prg_read && prg_ain == 16'h4151)))) begin
				sl_irq_pending <= 1'b1;
				jitter <= 8'h0;
			end
			if (chr_read) begin
				// Data can settle throughout /RD; unlike counters this latch
				// must allow the block RAM's registered address to propagate.
				last_chr_dout <= ram_qB;
				// Ext latch: NT latches tile offset (+ early CIRAM ext read);
				// AT always re-fetches ext from latched offset (CIRAM + FPGA-NT).
				// Window Split: NT uses split loopy; ext captured on AT.
				if (bg_fetch && ppu_is_nt) begin
					if (in_split) begin
						split_tile_addr <= split_nt_loopy;
						override_tile <= split_bg_ext;
					end else begin
						ext_tile_addr <= chr_ain_o[9:0];
						if (ppu_need_ext && (nt_src != 2'b10))
							ext_data <= ram_qB;
						override_tile <= nt_bg_ext;
					end
				end else if (ppu_is_at && !chr_ex) begin
					if (in_split && split_need_ext)
						split_ext_data <= ram_qB;
					else if (ppu_need_ext)
						ext_data <= ram_qB;
				end
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
	if (vector_hit) begin
        prg_bus_write_r = 1'b1;
        prg_dout_r = prg_ain[0] ? selected_vector[15:8] : selected_vector[7:0];
    end else if (prg_regs) begin
		prg_bus_write_r = 1'b1;
		case (prg_ain[7:0])
			8'h00: prg_dout_r = prg_mode_reg;
			8'h20: prg_dout_r = chr_mode_reg;
			8'h2A: prg_dout_r = nt_ctrl[0];
			8'h2B: prg_dout_r = nt_ctrl[1];
			8'h2C: prg_dout_r = nt_ctrl[2];
			8'h2D: prg_dout_r = nt_ctrl[3];
			8'h2F: prg_dout_r = split_ctrl;
			8'h50: prg_dout_r = ppu_scanline;
			8'h51: prg_dout_r = {ppu_in_hblank, ppu_in_frame, 6'b0};
			8'h54: prg_dout_r = jitter;
			8'h57: prg_dout_r = {parity, 7'b0};
			8'h5F: prg_dout_r = fpga_read_data;
			8'h60: prg_dout_r = 8'h21; // platform=emulator(1), version=1
			8'h61: prg_dout_r = {sl_irq_pending, cpu_irq_pending, 6'b0};
			default: prg_dout_r = 8'hFF;
		endcase
	end else if (oam_code) begin
        prg_bus_write_r = 1'b1;
        prg_dout_r = oam_read_data;
	end else if (prg_hit_fpga) begin
		prg_bus_write_r = 1'b1;
		prg_dout_r = fpga_read_data;
	end
end

reg [24:0] prg_aout_r;
reg        prg_allow_r;
assign prg_aout = prg_aout_r;
assign prg_allow = prg_allow_r;

always @* begin
	prg_aout_r  = prg_rom_address(prg_lin);
	prg_allow_r = prg_is_hi & ~prg_write & ~prg_to_ram;

	if (prg_hit_fpga || prg_hit_auto || oam_code || vector_hit) begin
		prg_aout_r  = {9'b11_1100_000, prg_ain[12:0]};
		// Internal FPGA-RAM drives the mapper bus, not external SDRAM.
		prg_allow_r = 1'b0;
	end else if (prg_is_low) begin
		case (low_src)
			2'b00, 2'b01: begin
				prg_aout_r  = prg_rom_address(low_rom);
				prg_allow_r = ~prg_write;
			end
			2'b10: begin
				prg_aout_r  = prg_ram_address(low_ram);
				prg_allow_r = 1'b1;
			end
			default: begin
				prg_aout_r  = {9'b11_1100_000, prg_ain[12:0]};
				prg_allow_r = 1'b1;
			end
		endcase
	end else if (prg_is_hi && prg_to_ram) begin
		prg_aout_r = prg_ram_address(prg_lin[17:0]);
		prg_allow_r = 1'b1;
	end
end

// -------------------------------------------------------------------------
// PPU bus
// -------------------------------------------------------------------------
reg        has_chr_dout_r;
reg  [7:0] chr_dout_r;
reg [24:0] chr_aout_r;
reg        chr_allow_r, vram_ce_r, vram_a10_r;
assign has_chr_dout = has_chr_dout_r;
assign chr_dout = chr_dout_r;
assign chr_aout = chr_aout_r;
assign chr_allow = chr_allow_r;
assign vram_ce = vram_ce_r;
assign vram_a10 = vram_a10_r;

// BG-ext applies only during background pattern fetches (not sprites).
// Window Split uses its own ext latch / fine-Y (playfield fine-Y would slice HUD).
// The NT control was latched during the NT fetch. Pattern-address bits
// 11:10 select a tile, not a nametable: never re-decode NT control here.
wire use_bg_ext = override_tile & bg_fetch;
wire [7:0] active_ext = in_split ? split_ext_data : ext_data;
// Pattern fine address: replace PPU fine-Y with split fine-Y inside the window.
wire [11:0] pat_fine = in_split ? {chr_ain[11:3], split_fine_y} : chr_ain[11:0];

always @* begin
	has_chr_dout_r = 1'b0;
	chr_dout_r = last_chr_dout;
	chr_aout_r = chr_rom_address(chr_lin);
	chr_allow_r = 1'b0;
	vram_ce_r = 1'b0;
	vram_a10_r = ntb[0];

	if (chr_ain[13]) begin
		// Window Split redirects NT/AT to FPGA-RAM at absolute screen position.
		if (in_split && (ppu_is_nt || ppu_is_at)) begin
			has_chr_dout_r = 1'b1;
			if (ppu_is_at && split_attr_ext)
				chr_dout_r = {4{split_ext_data[7:6]}};
			else
				chr_dout_r = last_chr_dout;
		end
		// Fill / attr-ext MUST take priority over FPGA-RAM NT source.
		// Previous code set attr-ext then case(nt_src==10) overwrote it with
		// the 16x16 AT byte — File Select MENU_EXT ($81) fell back to shared attrs.
		else if (nt_fill && ppu_is_nt) begin
			has_chr_dout_r = 1'b1;
			chr_dout_r = fill_tile;
		end else if (nt_fill && ppu_is_at) begin
			has_chr_dout_r = 1'b1;
			chr_dout_r = {4{fill_attr}};
		end else if (nt_attr_ext && ppu_is_at) begin
			has_chr_dout_r = 1'b1;
			chr_dout_r = {4{ext_data[7:6]}};
		end else begin
			case (nt_src)
				2'b00: begin
					vram_ce_r = 1'b1;
					vram_a10_r = ntb[0];
					chr_allow_r = 1'b1;
				end
				2'b01: begin
					chr_aout_r = chr_ram_address({ntb, chr_ain[9:0]});
					chr_allow_r = 1'b1;
				end
				2'b10: begin
					has_chr_dout_r = 1'b1;
					chr_dout_r = last_chr_dout;
				end
				default: begin
					chr_aout_r = chr_rom_address({5'b0, ntb, chr_ain[9:0]});
				end
			endcase
		end
		// CIRAM + mapper-supplied AT/NT: keep vram_ce low when overriding
		if (has_chr_dout_r)
			vram_ce_r = 1'b0;
	end else begin
		case (chr_src)
			2'b00: begin
				// 22-bit safe: {CHRROM, upper[1:0], ext[5:0], fine[11:0]}
				// Old concat was 24-bit and truncated away the 2'b10 CHR-ROM tag
				// → BG fetches hit the wrong SDRAM region (tile soup / font as BG).
				if (use_sprite_ext)
                    chr_aout_r = chr_rom_address(sprite_ext_address);
                else if (use_bg_ext)
					chr_aout_r = chr_rom_address({bg_ext_upper, active_ext[5:0], pat_fine});
				else if (in_split)
					chr_aout_r = chr_rom_address({chr_lin[22:3], split_fine_y});
				else
					chr_aout_r = chr_rom_address(chr_lin);
			end
			2'b01: begin
				// Up to 256KiB of independent CHR-RAM, masked by header size.
				if (use_sprite_ext)
                    chr_aout_r = chr_ram_address(sprite_ext_address[17:0]);
                else if (use_bg_ext)
					chr_aout_r = chr_ram_address({active_ext[5:0], pat_fine});
				else if (in_split)
					chr_aout_r = chr_ram_address({chr_lin[17:3], split_fine_y});
				else
					chr_aout_r = chr_ram_address(chr_lin[17:0]);
				chr_allow_r = 1'b1;
			end
			2'b10: begin
				has_chr_dout_r = 1'b1;
				chr_dout_r = last_chr_dout;
			end
			default: begin
                if (use_sprite_ext) begin
                    has_chr_dout_r = 1'b1;
                    chr_dout_r = last_chr_dout;
                end else begin
                    vram_ce_r = 1'b1;
                    vram_a10_r = chr_ain[10];
                    chr_allow_r = 1'b1;
                end
			end
		endcase
	end
end

// EXP6 uses the existing VRC6 oscillators at Rainbow's contiguous aliases.
// Oscillators keep phase while master-muted; $41AA changes only mixer gain.
reg [2:0] audio_ctrl;
reg [3:0] audio_volume;
wire [3:0] pulse1, pulse2;
wire [4:0] saw;
wire [63:0] audio_ss;
wire audio_write = prg_write && prg_ain >= 16'h41A0 && prg_ain <= 16'h41A8;
wire [15:0] audio_addr = prg_ain <= 16'h41A2 ? 16'h9000 + (prg_ain - 16'h41A0) :
    prg_ain <= 16'h41A5 ? 16'hA000 + (prg_ain - 16'h41A3) :
    16'hB000 + (prg_ain - 16'h41A6);
vrc6sound #(.RESET_PHASES(1)) exp6 (
    .clk(clk), .ce(ce && !paused), .enable(enable), .wr(audio_write),
    .addr_invert(1'b0), .addr_in(audio_addr), .din(prg_din),
    .outSq1(pulse1), .outSq2(pulse2), .outSaw(saw),
    .SaveStateBus_Din(SaveStateBus_Din), .SaveStateBus_Adr(SaveStateBus_Adr),
    .SaveStateBus_wren(SaveStateBus_wren), .SaveStateBus_rst(SaveStateBus_rst),
    .SaveStateBus_load(SaveStateBus_load), .SaveStateBus_Dout(audio_ss)
);
wire [5:0] exp6_sum = {2'b0, pulse1} + {2'b0, pulse2} + {1'b0, saw};
wire [9:0] exp6_volume = exp6_sum * audio_volume;
wire [9:0] exp6_scaled = exp6_volume / 10'd15;
// EXP6 and EXP9 are front-/top-loader output pins for the same waveform.
wire [5:0] exp6_level = (|audio_ctrl[1:0]) ? exp6_scaled[5:0] : 6'd0;
// Same full-volume gain as the core's VRC6 mapper mixer, with overflow headroom.
wire [15:0] exp6_audio = {exp6_level, exp6_level, exp6_level[5:2]};
wire [16:0] mixed_audio = {1'b0, audio_in} +
    {2'b0, exp6_audio[15:1]} + {4'b0, exp6_audio[15:3]};

// -------------------------------------------------------------------------
// Savestate
// -------------------------------------------------------------------------
wire [63:0] SS_MAP1, SS_MAP2, SS_MAP3, SS_MAP4, SS_MAP5, SS_MAP6, SS_MAP7, SS_MAP8, SS_MAP9;
wire [63:0] SS_MAP1_BACK, SS_MAP2_BACK, SS_MAP3_BACK, SS_MAP4_BACK;
wire [63:0] SS_MAP5_BACK, SS_MAP6_BACK, SS_MAP7_BACK, SS_MAP8_BACK, SS_MAP9_BACK;
wire [63:0] SS_MAP10, SS_MAP11, SS_MAP10_BACK, SS_MAP11_BACK;
wire [63:0] SS_w[0:10];

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
assign SS_MAP9_BACK = {
	1'b0,
	split_screen_y,
	split_sy,
	split_sx,
	split_y1,
	split_y0,
	split_x1,
	split_x0,
	split_ctrl,
	split_bank
};

assign SS_MAP10_BACK = {split_tile_addr, ext_tile_addr, split_ext_data,
    ext_data, fpga_auto_inc, fpga_auto_addr, audio_volume, audio_ctrl};
assign SS_MAP11_BACK = {23'b0, fpga_read_data, jitter, last_chr_read, last_chr_dout,
    chr_hi[15][4:0], chr_hi[14][4:0], chr_hi[13][4:0], chr_hi[12][4]};

eReg_SavestateV #(SSREG_INDEX_MAP1, 64'h0) i1 (clk, SaveStateBus_Din, SaveStateBus_Adr, SaveStateBus_wren, SaveStateBus_rst, SS_w[0], SS_MAP1_BACK, SS_MAP1);
eReg_SavestateV #(SSREG_INDEX_MAP2, 64'h0) i2 (clk, SaveStateBus_Din, SaveStateBus_Adr, SaveStateBus_wren, SaveStateBus_rst, SS_w[1], SS_MAP2_BACK, SS_MAP2);
eReg_SavestateV #(SSREG_INDEX_MAP3, 64'h0) i3 (clk, SaveStateBus_Din, SaveStateBus_Adr, SaveStateBus_wren, SaveStateBus_rst, SS_w[2], SS_MAP3_BACK, SS_MAP3);
eReg_SavestateV #(SSREG_INDEX_MAP4, 64'h0) i4 (clk, SaveStateBus_Din, SaveStateBus_Adr, SaveStateBus_wren, SaveStateBus_rst, SS_w[3], SS_MAP4_BACK, SS_MAP4);
eReg_SavestateV #(SSREG_INDEX_MAP5, 64'h0) i5 (clk, SaveStateBus_Din, SaveStateBus_Adr, SaveStateBus_wren, SaveStateBus_rst, SS_w[4], SS_MAP5_BACK, SS_MAP5);
eReg_SavestateV #(SSREG_INDEX_MAP6, 64'h0) i6 (clk, SaveStateBus_Din, SaveStateBus_Adr, SaveStateBus_wren, SaveStateBus_rst, SS_w[5], SS_MAP6_BACK, SS_MAP6);
eReg_SavestateV #(10'd38, 64'h0) i7 (clk, SaveStateBus_Din, SaveStateBus_Adr, SaveStateBus_wren, SaveStateBus_rst, SS_w[6], SS_MAP7_BACK, SS_MAP7);
eReg_SavestateV #(10'd39, 64'h0) i8 (clk, SaveStateBus_Din, SaveStateBus_Adr, SaveStateBus_wren, SaveStateBus_rst, SS_w[7], SS_MAP8_BACK, SS_MAP8);
eReg_SavestateV #(10'd40, 64'h0) i9 (clk, SaveStateBus_Din, SaveStateBus_Adr, SaveStateBus_wren, SaveStateBus_rst, SS_w[8], SS_MAP9_BACK, SS_MAP9);

eReg_SavestateV #(10'd41, 64'h78) i10 (clk, SaveStateBus_Din, SaveStateBus_Adr, SaveStateBus_wren, SaveStateBus_rst, SS_w[9], SS_MAP10_BACK, SS_MAP10);
eReg_SavestateV #(10'd42, 64'h0) i11 (clk, SaveStateBus_Din, SaveStateBus_Adr, SaveStateBus_wren, SaveStateBus_rst, SS_w[10], SS_MAP11_BACK, SS_MAP11);

wire [63:0] SS_MAP12, SS_MAP12_BACK, SS_MAP12_OUT;
genvar ci;
generate for(ci=0;ci<16;ci=ci+1) begin: chr_high_save
    assign SS_MAP12_BACK[ci] = chr_hi[ci][5];
end endgenerate
assign SS_MAP12_BACK[63:16] = {31'b0, oam_read_data, oam_limit, oam_page};
eReg_SavestateV #(10'd43, 64'h1FF0000) i12 (clk, SaveStateBus_Din, SaveStateBus_Adr,
    SaveStateBus_wren, SaveStateBus_rst, SS_MAP12_OUT, SS_MAP12_BACK, SS_MAP12);
wire [63:0] SS_MAP13, SS_MAP13_OUT;
wire [63:0] SS_MAP13_BACK = {19'b0, sprite_ext_bank, irq_vector, nmi_vector, vector_enable, oam_locked, oam_kind, oam_ext_page};
eReg_SavestateV #(10'd44, 64'h0) i13 (clk, SaveStateBus_Din, SaveStateBus_Adr,
    SaveStateBus_wren, SaveStateBus_rst, SS_MAP13_OUT, SS_MAP13_BACK, SS_MAP13);
wire [63:0] SS_SPR[0:7], SS_SPR_OUT[0:7], SS_SPR_BACK[0:7];
genvar si,sb;
generate for(si=0;si<8;si=si+1) begin: sprite_save
    for(sb=0;sb<8;sb=sb+1) begin: byte_save
        assign SS_SPR_BACK[si][sb*8 +: 8] = sprite_ext[si*8+sb];
    end
    eReg_SavestateV #(10'd54+si, 64'h0) ss (clk, SaveStateBus_Din, SaveStateBus_Adr,
        SaveStateBus_wren, SaveStateBus_rst, SS_SPR_OUT[si], SS_SPR_BACK[si], SS_SPR[si]);
end endgenerate
assign SaveStateBus_Dout = enable ? (SS_w[0]|SS_w[1]|SS_w[2]|SS_w[3]|SS_w[4]|SS_w[5]|SS_w[6]|SS_w[7]|SS_w[8]|SS_w[9]|SS_w[10]|SS_MAP12_OUT|SS_MAP13_OUT|audio_ss|
    SS_SPR_OUT[0]|SS_SPR_OUT[1]|SS_SPR_OUT[2]|SS_SPR_OUT[3]|SS_SPR_OUT[4]|SS_SPR_OUT[5]|SS_SPR_OUT[6]|SS_SPR_OUT[7]) : 64'h0;

endmodule
