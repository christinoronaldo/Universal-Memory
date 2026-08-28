/* =====================================================================
 * Module      : tt_um_universal_memory
 * Project     : Universal Memory Cell Development (Hybrid Persistent-RAM)
 * Phase       : Day 3 - Floorplan & Placement Area Fix
 * Target      : Tiny Tapeout / SkyWater 130nm PDK (OpenLane flow)
 *
 * Description :
 *   16 x 8-bit register-file based memory array with:
 *     - 4-to-16 one-hot address decoder
 *     - Single-cycle registered write
 *     - Single-cycle registered read
 *     - PERSIST mode: when uio_in[7] is asserted, the register file
 *       retains its contents across an asynchronous !rst_n event
 *       (modeling non-volatile / persistent-RAM behavior). When
 *       PERSIST is de-asserted, !rst_n clears the array normally.
 *
 *   CHANGE LOG (Day 3, Placement Area Fix):
 *   Array depth reduced from 32 words to 16 words to bring standard
 *   cell area under the core area budget (GPL-0301 utilization error
 *   at 32 words: 116.07%). Register count is the dominant area
 *   contributor and scales ~linearly with depth, so halving depth
 *   (256 -> 128 flops, 32:1 -> 16:1 read mux, 5:32 -> 4:16 decoder)
 *   is projected to bring utilization to roughly 56%, well inside a
 *   safe 40-60% placement/routing margin for sky130_hd.
 *
 *   TOP-LEVEL PIN INTERFACE IS UNCHANGED. addr_in now only consumes
 *   uio_in[3:0]; uio_in[4] is intentionally unused (folded into the
 *   existing unused-input guard) so pin count, direction, and order
 *   on ui_in / uio_in / uio_out / uio_oe are identical to the prior
 *   32-word version.
 *
 *   NOTE ON RESET SEMANTICS (carried over from the synthesis fix):
 *   A single derived reset net, rst_n_eff = rst_n | persist, is used
 *   in place of a two-signal condition inside the async-reset branch.
 *   This is required for Yosys's proc_dff pass to map the reset
 *   cleanly onto a standard async-reset DFF cell (see prior fix notes
 *   for the "Multiple edge sensitive events" root cause).
 *     - persist high  -> rst_n_eff stays high even if rst_n goes low
 *                         -> no async reset fires -> array holds.
 *     - persist low, rst_n low -> rst_n_eff low -> array clears.
 *     - rst_n high -> rst_n_eff high -> normal synchronous read/write.
 * ===================================================================== */

`default_nettype none
`timescale 1ns / 1ps

module tt_um_universal_memory (
    input  wire [7:0] ui_in,    // Dedicated inputs: ui_in[7:0] = write data payload
    output wire [7:0] uo_out,   // Dedicated outputs: uo_out[7:0] = read data
    input  wire [7:0] uio_in,   // IOs: input path
    output wire [7:0] uio_out,  // IOs: output path (unused, driven low)
    output wire [7:0] uio_oe,   // IOs: enable path (all inputs per spec)
    input  wire        ena,     // Tile enable (goes high when design is powered/selected)
    input  wire        clk,     // Clock
    input  wire        rst_n    // Active-low async reset
);

    // ---------------------------------------------------------------
    // Pin mapping (per architect handoff)
    // ---------------------------------------------------------------
    // Array depth reduced to 16 words -> only 4 address bits needed.
    // uio_in[4] is no longer part of the address field; it is folded
    // into the unused-input guard below. Pin interface (uio_in[7:0])
    // itself is unchanged.
    wire [3:0] addr_in  = uio_in[3:0];  // A[3:0] - byte select, 1-of-16
    wire       we_in    = uio_in[5];    // Write Enable, active-high
    wire       ce_in    = uio_in[6];    // Chip Enable / strobe, active-high
    wire       persist  = uio_in[7];    // Persistence simulation trigger

    // ---------------------------------------------------------------
    // Single derived asynchronous reset net.
    //   persist = 1  -> rst_n_eff forced high  -> reset path masked
    //                    (array/registers hold their state)
    //   persist = 0  -> rst_n_eff = rst_n      -> normal async clear
    // ---------------------------------------------------------------
    wire rst_n_eff = rst_n | persist;

    // uio_oe fixed per spec: all bidirectional pins configured as inputs
    assign uio_oe  = 8'b0000_0000;
    // uio_out has no function in this design (uio bus is input-only)
    assign uio_out = 8'b0000_0000;

    // Unused-input guard to keep OpenLane / lint happy without
    // affecting functionality (ui_in fully consumed as write data;
    // uio_in[4] is unused now that the address field is 4 bits wide).
    wire _unused_ok = &{1'b0, ui_in[7:0], uio_in[4], 1'b0};

    // ---------------------------------------------------------------
    // 4-to-16 one-hot address decoder
    // ---------------------------------------------------------------
    // sel[i] is high iff addr_in == i AND the array is actively
    // strobed (ce_in) AND the tile is enabled (ena). This one-hot
    // vector directly gates both the write-enable fan-out to each
    // register and (structurally) represents the wordline select
    // that the transistor-level team will realize with physical
    // wordline drivers.
    // ---------------------------------------------------------------
    wire [15:0] addr_onehot;

    genvar gi;
    generate
        for (gi = 0; gi < 16; gi = gi + 1) begin : DECODER_4TO16
            assign addr_onehot[gi] = (addr_in == gi[3:0]);
        end
    endgenerate

    wire [15:0] wr_sel = addr_onehot & {16{ena & ce_in & we_in}};
    wire [15:0] rd_sel = addr_onehot & {16{ena & ce_in}};

    // ---------------------------------------------------------------
    // 16 x 8-bit register file array (the "memory" storage bank)
    // ---------------------------------------------------------------
    reg [7:0] mem [0:15];

    integer k;

    // ---------------------------------------------------------------
    // Write port + gated asynchronous reset (persistence logic)
    //
    //   rst_n_eff low  -> full array clear (only reachable when
    //                      persist=0 and rst_n=0: volatile behavior)
    //   rst_n_eff high & ena -> normal single-cycle synchronous write
    //
    //   Clean single-signal reset condition: `if (!rst_n_eff)`.
    // ---------------------------------------------------------------
    always @(posedge clk or negedge rst_n_eff) begin
        if (!rst_n_eff) begin
            for (k = 0; k < 16; k = k + 1) begin
                mem[k] <= 8'b0000_0000;
            end
        end
        else begin
            // Single-cycle write: exactly one wr_sel bit can be set
            // per cycle since addr_onehot is a true one-hot decode.
            for (k = 0; k < 16; k = k + 1) begin
                if (wr_sel[k]) begin
                    mem[k] <= ui_in;
                end
            end
        end
    end

    // ---------------------------------------------------------------
    // Read port: single-cycle registered read.
    // Combinational 16:1 mux selects the addressed byte, then the
    // value is captured on the clock edge so uo_out reflects the
    // addressed byte exactly one clock after CE+address are applied
    // (single-cycle read latency, matches the write path timing).
    // ---------------------------------------------------------------
    reg [7:0] rdata_mux;
    integer j;

    always @(*) begin
        rdata_mux = 8'b0000_0000;
        for (j = 0; j < 16; j = j + 1) begin
            if (rd_sel[j]) begin
                rdata_mux = mem[j];
            end
        end
    end

    reg [7:0] rdata_reg;

    always @(posedge clk or negedge rst_n_eff) begin
        if (!rst_n_eff) begin
            rdata_reg <= 8'b0000_0000;
        end
        else if (ena) begin
            rdata_reg <= rdata_mux;
        end
        // PERSIST asserted -> rst_n_eff never falls -> output register
        // also holds, consistent with retained array contents beneath it.
    end

    assign uo_out = rdata_reg;

endmodule

`default_nettype wire
