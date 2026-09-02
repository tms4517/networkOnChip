// Asynchronous (dual-clock) FIFO.
//
// Data is written in the i_writeClk domain and read in the i_readClk domain, where the
// two clocks are asynchronous to each other.  Gray-coded read/write pointers are
// passed across the clock boundary through two-flop synchronisers, following the
// style of Clifford Cummings' "Simulation and Synthesis Techniques for
// Asynchronous FIFO Design" (SNUG 2002).
//
// The read data is first-word-fall-through: whenever o_empty is low, o_readData
// already holds the head entry, so the interface matches ready/valid semantics
// (i_readEn advances the head only when a transfer is accepted).

`default_nettype none

module asyncFifo
#(parameter int unsigned DATA_W = 8
, parameter int unsigned ADDR_W = 2
)
( // Write clock domain.
  input  var logic              i_writeClk
, input  var logic              i_writeArst_n
, input  var logic              i_writeEn
, input  var logic [DATA_W-1:0] i_writeData
, output var logic              o_full

  // Read clock domain.
, input  var logic              i_readClk
, input  var logic              i_readArst_n
, input  var logic              i_readEn
, output var logic [DATA_W-1:0] o_readData
, output var logic              o_empty
);

  // Pointers carry one extra MSB above the address bits to disambiguate the
  // full and empty conditions.
  logic [ADDR_W:0] writeBin_q, writeGray_q;
  logic [ADDR_W:0] readBin_q, readGray_q;

  // Pointers synchronised into the opposite clock domain.
  logic [ADDR_W:0] readGraySyncW_q1, readGraySyncW_q2;
  logic [ADDR_W:0] writeGraySyncR_q1, writeGraySyncR_q2;

  logic [ADDR_W:0] writeBin_d, writeGray_d;
  logic [ADDR_W:0] readBin_d, readGray_d;
  logic            full_d, full_q;
  logic            empty_d, empty_q;

  // {{{ Write clock domain

  // Two-flop synchroniser: read Gray pointer into the write domain.
  always_ff @(posedge i_writeClk, negedge i_writeArst_n)
    if (!i_writeArst_n)
      readGraySyncW_q1 <= '0;
    else
      readGraySyncW_q1 <= readGray_q;

  always_ff @(posedge i_writeClk, negedge i_writeArst_n)
    if (!i_writeArst_n)
      readGraySyncW_q2 <= '0;
    else
      readGraySyncW_q2 <= readGraySyncW_q1;

  always_comb
    writeBin_d = writeBin_q + {{ADDR_W{1'b0}}, (i_writeEn && !o_full)};

  // Binary-to-Gray conversion.
  always_comb
    writeGray_d = (writeBin_d >> 1) ^ writeBin_d;

  // Full occurs when the next write Gray pointer equals the synchronised read
  // Gray pointer with its two MSBs inverted.
  always_comb
    full_d =
      (writeGray_d == {~readGraySyncW_q2[ADDR_W:ADDR_W-1], readGraySyncW_q2[ADDR_W-2:0]});

  always_ff @(posedge i_writeClk, negedge i_writeArst_n)
    if (!i_writeArst_n)
      writeBin_q <= '0;
    else
      writeBin_q <= writeBin_d;

  always_ff @(posedge i_writeClk, negedge i_writeArst_n)
    if (!i_writeArst_n)
      writeGray_q <= '0;
    else
      writeGray_q <= writeGray_d;

  always_ff @(posedge i_writeClk, negedge i_writeArst_n)
    if (!i_writeArst_n)
      full_q <= 1'b0;
    else
      full_q <= full_d;

  always_comb o_full = full_q;
  // }}} Write clock domain

  // {{{ Read clock domain

  // Two-flop synchroniser: write Gray pointer into the read domain.
  always_ff @(posedge i_readClk, negedge i_readArst_n)
    if (!i_readArst_n)
      writeGraySyncR_q1 <= '0;
    else
      writeGraySyncR_q1 <= writeGray_q;

  always_ff @(posedge i_readClk, negedge i_readArst_n)
    if (!i_readArst_n)
      writeGraySyncR_q2 <= '0;
    else
      writeGraySyncR_q2 <= writeGraySyncR_q1;

  always_comb
    readBin_d = readBin_q + {{ADDR_W{1'b0}}, (i_readEn && !o_empty)};

  // Binary-to-Gray conversion.
  always_comb
    readGray_d = (readBin_d >> 1) ^ readBin_d;

  // Empty occurs when the next read Gray pointer catches up to the synchronised
  // write Gray pointer.
  always_comb
    empty_d = (readGray_d == writeGraySyncR_q2);

  always_ff @(posedge i_readClk, negedge i_readArst_n)
    if (!i_readArst_n)
      readBin_q <= '0;
    else
      readBin_q <= readBin_d;

  always_ff @(posedge i_readClk, negedge i_readArst_n)
    if (!i_readArst_n)
      readGray_q <= '0;
    else
      readGray_q <= readGray_d;

  always_ff @(posedge i_readClk, negedge i_readArst_n)
    if (!i_readArst_n)
      empty_q <= 1'b1;
    else
      empty_q <= empty_d;

  always_comb o_empty = empty_q;
  // }}} Read clock domain

  // {{{ FIFO memory (write-clock write, combinational read)
  localparam int unsigned DEPTH = 1 << ADDR_W;
  logic [DATA_W-1:0] mem [DEPTH-1:0];

  /* svlint off explicit_if_else */
  // Intended memory inference pattern.
  always_ff @(posedge i_writeClk)
    if (i_writeEn && !o_full)
      mem[writeBin_q[ADDR_W-1:0]] <= i_writeData;
  /* svlint on explicit_if_else */

  always_comb
    o_readData = mem[readBin_q[ADDR_W-1:0]];
  // }}} FIFO memory

endmodule

`resetall
