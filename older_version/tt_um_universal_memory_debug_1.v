/* =====================================================================
 * Module      : tt_um_universal_memory
 * Project     : Universal Memory Cell Development (Hybrid Persistent-RAM)
 * Phase       : Day 1, Steps 2 & 3 - RTL Generation
 * Target      : Tiny Tapeout / SkyWater 130nm PDK (OpenLane flow)
 *
 * Description :
 *   32 x 8-bit register-file based memory array with:
 *     - 5-to-32 one-hot address decoder
 *     - Single-cycle registered write
 *     - Single-cycle registered read
 *     - PERSIST mode: when uio_in[7] is asserted, the register file
 *       retains its contents across an asynchronous !rst_n event
 *       (modeling non-volatile / persistent-RAM behavior). When
 *       PERSIST is de-asserted, !rst_n clears the array normally.
 *
 *   NOTE ON RESET SEMANTICS:
 *   PERSIST is sampled at the instant rst_n is asserted low (it is
 *   part of the asynchronous reset sensitivity condition below).
 *   This is the standard "conditional asynchronous reset" structural
 *   pattern used to model retention-cell behavior in synthesizable
 *   RTL; the actual non-volatile storage element (e.g., an FeFET /
 *   MTJ / RRAM hybrid cell) is what the transistor-level schematic
 *   team implements per-bit at the physical layer. This RTL is the
 *   golden functional/behavioral reference for that implementation.
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
    wire [4:0] addr_in  = uio_in[4:0];  // A[4:0] - byte select, 1-of-32
    wire       we_in    = uio_in[5];    // Write Enable, active-high
    wire       ce_in    = uio_in[6];    // Chip Enable / strobe, active-high
    wire       persist  = uio_in[7];    // Persistence simulation trigger

    // uio_oe fixed per spec: all bidirectional pins configured as inputs
    assign uio_oe  = 8'b0000_0000;
    // uio_out has no function in this design (uio bus is input-only)
    assign uio_out = 8'b0000_0000;

    // Unused-input guard to keep OpenLane / lint happy without
    // affecting functionality (ui_in fully consumed as write data).
    wire _unused_ok = &{1'b0, ui_in[7:0], 1'b0};

    // ---------------------------------------------------------------
    // 5-to-32 one-hot address decoder
    // ---------------------------------------------------------------
    // sel[i] is high iff addr_in == i AND the array is actively
    // strobed (ce_in) AND the tile is enabled (ena). This one-hot
    // vector directly gates both the write-enable fan-out to each
    // register and (structurally) represents the wordline select
    // that the transistor-level team will realize with physical
    // wordline drivers.
    // ---------------------------------------------------------------
    wire [31:0] addr_onehot;

    genvar gi;
    generate
        for (gi = 0; gi < 32; gi = gi + 1) begin : DECODER_5TO32
            assign addr_onehot[gi] = (addr_in == gi[4:0]);
        end
    endgenerate

    wire [31:0] wr_sel = addr_onehot & {32{ena & ce_in & we_in}};
    wire [31:0] rd_sel = addr_onehot & {32{ena & ce_in}};

    // ---------------------------------------------------------------
    // 32 x 8-bit register file array (the "memory" storage bank)
    // ---------------------------------------------------------------
    reg [7:0] mem [0:31];

    integer k;

    // ---------------------------------------------------------------
    // Write port + conditional asynchronous reset (persistence logic)
    //
    //   !rst_n & !persist  -> full array clear (volatile behavior)
    //   !rst_n &  persist  -> array holds current state (retention)
    //   rst_n  &  ena      -> normal single-cycle synchronous write
    // ---------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n && !persist) begin
            for (k = 0; k < 32; k = k + 1) begin
                mem[k] <= 8'b0000_0000;
            end
        end
        else if (rst_n) begin
            // Single-cycle write: exactly one wr_sel bit can be set
            // per cycle since addr_onehot is a true one-hot decode.
            for (k = 0; k < 32; k = k + 1) begin
                if (wr_sel[k]) begin
                    mem[k] <= ui_in;
                end
            end
        end
        // else: !rst_n && persist -> no assignment, i.e. hold state
    end

    // ---------------------------------------------------------------
    // Read port: single-cycle registered read.
    // Combinational 32:1 mux selects the addressed byte, then the
    // value is captured on the clock edge so uo_out reflects the
    // addressed byte exactly one clock after CE+address are applied
    // (single-cycle read latency, matches the write path timing).
    // ---------------------------------------------------------------
    reg [7:0] rdata_mux;
    integer j;

    always @(*) begin
        rdata_mux = 8'b0000_0000;
        for (j = 0; j < 32; j = j + 1) begin
            if (rd_sel[j]) begin
                rdata_mux = mem[j];
            end
        end
    end

    reg [7:0] rdata_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n && !persist) begin
            rdata_reg <= 8'b0000_0000;
        end
        else if (rst_n && ena) begin
            rdata_reg <= rdata_mux;
        end
        // PERSIST + !rst_n: output register also holds (consistent
        // with retained array contents underneath it)
    end

    assign uo_out = rdata_reg;

endmodule

`default_nettype wire
