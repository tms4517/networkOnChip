// Copyright (c) 2026 Tej Sanghavi.

// Behavioural AHB-Lite register-file slave for generated NoC testbenches.
// Always ready, never errors. The address phase is captured when HSEL and a
// NONSEQ transfer are presented; the following data phase writes HWDATA or
// returns HRDATA. Word i resets to RESET_BASE + i.

`default_nettype none

module ahbSlaveModel
#(parameter int unsigned ADDR_BITS  = 10
, parameter bit [31:0]   RESET_BASE = '0
)
( input  var logic        i_clk
, input  var logic        i_hsel
/* verilator lint_off UNUSEDSIGNAL */
, input  var logic [31:0] i_haddr
, input  var logic [2:0]  i_hsize
, input  var logic [1:0]  i_htrans
/* verilator lint_on UNUSEDSIGNAL */
, input  var logic        i_hwrite
, input  var logic [31:0] i_hwdata
, output var logic [31:0] o_hrdata
, output var logic        o_hready
, output var logic        o_hresp
);

  /* svlint off unpacked_array */
  logic [31:0] memory [2**ADDR_BITS];
  /* svlint on unpacked_array */

  logic                 dataPhase_q;
  logic                 write_q;
  logic [ADDR_BITS-1:0] word_q;

  initial begin: initialise
    for (int i = 0; i < 2**ADDR_BITS; i++)
      memory[i] = RESET_BASE + 32'(i);
    dataPhase_q = '0;
    write_q = '0;
    word_q = '0;
  end: initialise

  always @(posedge i_clk)
    dataPhase_q <= i_hsel && i_htrans[1];

  always @(posedge i_clk)
    if (i_hsel && i_htrans[1])
      write_q <= i_hwrite;

  always @(posedge i_clk)
    if (i_hsel && i_htrans[1])
      word_q <= i_haddr[ADDR_BITS+1:2];

  always @(posedge i_clk)
    if (dataPhase_q && write_q)
      memory[word_q] <= i_hwdata;

  always_comb
    o_hrdata = memory[word_q];

  always_comb
    o_hready = '1;

  always_comb
    o_hresp = '0;

endmodule

`resetall
