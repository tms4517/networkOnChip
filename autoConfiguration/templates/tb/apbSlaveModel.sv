// Copyright (c) 2026 Tej Sanghavi.

// Behavioural APB register-file slave for generated NoC testbenches.
// Zero-wait; word i of the 2**ADDR_BITS-word memory resets to RESET_BASE + i
// and is selected by paddr[ADDR_BITS+1:2].

`default_nettype none

module apbSlaveModel
#(parameter int unsigned ADDR_BITS  = 10
, parameter bit [31:0]   RESET_BASE = '0
)
( input  var logic        i_clk
/* verilator lint_off UNUSEDSIGNAL */
, input  var logic [31:0] i_paddr
, input  var logic [3:0]  i_pstrb
/* verilator lint_on UNUSEDSIGNAL */
, input  var logic [31:0] i_pwdata
, input  var logic        i_pwrite
, input  var logic        i_psel
, input  var logic        i_penable
, output var logic        o_pready
, output var logic        o_pslverr
, output var logic [31:0] o_prdata
);

  /* svlint off unpacked_array */
  logic [31:0] memory [2**ADDR_BITS];
  /* svlint on unpacked_array */

  initial
    for (int i = 0; i < 2**ADDR_BITS; i++)
      memory[i] = RESET_BASE + 32'(i);

  always @(posedge i_clk)
    if (i_psel && i_penable && i_pwrite)
      memory[i_paddr[ADDR_BITS+1:2]] <= i_pwdata;

  always_comb
    o_pready = i_psel && i_penable;

  always_comb
    o_pslverr = '0;

  always_comb
    o_prdata = memory[i_paddr[ADDR_BITS+1:2]];

endmodule

`resetall
