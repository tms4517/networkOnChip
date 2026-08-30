// APB to AHB-Lite bridge (single-beat).
//
// Presents an APB SUBORDINATE interface (driven by a niApbTarget manager) and an
// AHB-Lite MANAGER interface (driving a local AHB peripheral).  Each APB access
// is translated into one AHB single-beat transfer; PREADY is held low until the
// AHB data phase completes.  HRESP maps to PSLVERR.

`default_nettype none

module apbToAhbBridge
( input  var logic i_clk
, input  var logic i_arst_n

  // APB subordinate interface (this module is the subordinate)
, input  var logic [31:0] i_paddr
, input  var logic [31:0] i_pwdata
, input  var logic        i_pwrite
, input  var logic [3:0]  i_pstrb
, input  var logic        i_psel
, input  var logic        i_penable
, output var logic        o_pready
, output var logic        o_pslverr
, output var logic [31:0] o_prdata

  // AHB-Lite manager interface (this module is the manager)
, output var logic        o_hsel
, output var logic [31:0] o_haddr
, output var logic        o_hwrite
, output var logic [2:0]  o_hsize
, output var logic [1:0]  o_htrans
, output var logic [31:0] o_hwdata
, input  var logic [31:0] i_hrdata
, input  var logic        i_hready
, input  var logic        i_hresp
);

  typedef enum logic [1:0]
  { ST_IDLE   // Wait for the APB access phase
  , ST_ADDR   // AHB address phase
  , ST_DATA   // AHB data phase (capture HRDATA/HRESP)
  , ST_DONE   // Complete the APB access (PREADY high)
  } ty_state;

  ty_state state_q, state_d;

  logic [31:0] paddr_q;
  logic [31:0] pwdata_q;
  logic        pwrite_q;
  logic [31:0] rdata_q;
  logic        hresp_q;

  // APB access phase begins when both PSEL and PENABLE are asserted.
  logic accept;

  always_comb
    accept = (state_q == ST_IDLE) && i_psel && i_penable;

  // {{{ Latched fields
  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n) begin
      paddr_q  <= '0;
      pwdata_q <= '0;
      pwrite_q <= 1'b0;
    end else if (accept) begin
      paddr_q  <= i_paddr;
      pwdata_q <= i_pwdata;
      pwrite_q <= i_pwrite;
    end else begin
      paddr_q  <= paddr_q;
      pwdata_q <= pwdata_q;
      pwrite_q <= pwrite_q;
    end

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n) begin
      rdata_q <= '0;
      hresp_q <= 1'b0;
    end else if (state_q == ST_DATA && i_hready) begin
      rdata_q <= i_hrdata;
      hresp_q <= i_hresp;
    end else begin
      rdata_q <= rdata_q;
      hresp_q <= hresp_q;
    end
  // }}} Latched fields

  // {{{ FSM
  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      state_q <= ST_IDLE;
    else
      state_q <= state_d;

  always_comb
    case (state_q)
      ST_IDLE:
        state_d = accept ? ST_ADDR : ST_IDLE;
      ST_ADDR:
        state_d = i_hready ? ST_DATA : ST_ADDR;
      ST_DATA:
        state_d = i_hready ? ST_DONE : ST_DATA;
      ST_DONE:
        state_d = ST_IDLE;
      default:
        state_d = ST_IDLE;
    endcase
  // }}} FSM

  // {{{ APB subordinate outputs
  always_comb
    o_pready = (state_q == ST_DONE);

  always_comb
    o_pslverr = (state_q == ST_DONE) && hresp_q;

  always_comb
    o_prdata = rdata_q;
  // }}} APB subordinate outputs

  // {{{ AHB manager outputs
  always_comb
    o_hsel = (state_q == ST_ADDR) || (state_q == ST_DATA);

  always_comb
    o_htrans = (state_q == ST_ADDR) ? pa_noc::AHB_TRANS_NONSEQ
                                    : pa_noc::AHB_TRANS_IDLE;

  always_comb
    o_haddr = paddr_q;

  always_comb
    o_hwrite = pwrite_q;

  always_comb
    o_hsize = 3'd2;   // word

  always_comb
    o_hwdata = pwdata_q;
  // }}} AHB manager outputs

endmodule

`resetall
