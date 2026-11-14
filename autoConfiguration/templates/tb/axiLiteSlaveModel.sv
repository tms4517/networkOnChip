// Copyright (c) 2026 Tej Sanghavi.

// Behavioural AXI4-Lite register-file slave for generated NoC testbenches.
// AW and W are accepted independently; once both are held the word is written
// and an OKAY B response is raised. Reads return R one cycle after AR.
// Word i resets to RESET_BASE + i.

`default_nettype none

module axiLiteSlaveModel
#(parameter int unsigned ADDR_BITS  = 10
, parameter bit [31:0]   RESET_BASE = '0
)
( input  var logic        i_clk
/* verilator lint_off UNUSEDSIGNAL */
, input  var logic [31:0] i_awaddr
, input  var logic [3:0]  i_wstrb
, input  var logic [31:0] i_araddr
/* verilator lint_on UNUSEDSIGNAL */
, input  var logic        i_awvalid
, output var logic        o_awready
, input  var logic [31:0] i_wdata
, input  var logic        i_wvalid
, output var logic        o_wready
, output var logic [1:0]  o_bresp
, output var logic        o_bvalid
, input  var logic        i_bready
, input  var logic        i_arvalid
, output var logic        o_arready
, output var logic [31:0] o_rdata
, output var logic [1:0]  o_rresp
, output var logic        o_rvalid
, input  var logic        i_rready
);

  /* svlint off unpacked_array */
  logic [31:0] memory [2**ADDR_BITS];
  /* svlint on unpacked_array */

  logic                 awHeld_q;
  logic                 wHeld_q;
  logic [ADDR_BITS-1:0] awWord_q;
  logic [31:0]          wData_q;
  logic                 bValid_q;
  logic                 rValid_q;
  logic [31:0]          rData_q;

  initial begin: initialise
    for (int i = 0; i < 2**ADDR_BITS; i++)
      memory[i] = RESET_BASE + 32'(i);
    awHeld_q = '0;
    wHeld_q = '0;
    awWord_q = '0;
    wData_q = '0;
    bValid_q = '0;
    rValid_q = '0;
    rData_q = '0;
  end: initialise

  always_comb
    o_awready = !awHeld_q && !bValid_q;

  always_comb
    o_wready = !wHeld_q && !bValid_q;

  always @(posedge i_clk)
    if (awHeld_q && wHeld_q)
      awHeld_q <= '0;
    else if (i_awvalid && o_awready)
      awHeld_q <= '1;

  always @(posedge i_clk)
    if (i_awvalid && o_awready)
      awWord_q <= i_awaddr[ADDR_BITS+1:2];

  always @(posedge i_clk)
    if (awHeld_q && wHeld_q)
      wHeld_q <= '0;
    else if (i_wvalid && o_wready)
      wHeld_q <= '1;

  always @(posedge i_clk)
    if (i_wvalid && o_wready)
      wData_q <= i_wdata;

  always @(posedge i_clk)
    if (awHeld_q && wHeld_q)
      memory[awWord_q] <= wData_q;

  always @(posedge i_clk)
    if (awHeld_q && wHeld_q)
      bValid_q <= '1;
    else if (i_bready)
      bValid_q <= '0;

  always_comb
    o_bvalid = bValid_q;

  always_comb
    o_bresp = '0;

  always_comb
    o_arready = !rValid_q;

  always @(posedge i_clk)
    if (i_arvalid && o_arready)
      rValid_q <= '1;
    else if (i_rready)
      rValid_q <= '0;

  always @(posedge i_clk)
    if (i_arvalid && o_arready)
      rData_q <= memory[i_araddr[ADDR_BITS+1:2]];

  always_comb
    o_rvalid = rValid_q;

  always_comb
    o_rdata = rData_q;

  always_comb
    o_rresp = '0;

endmodule

`resetall
