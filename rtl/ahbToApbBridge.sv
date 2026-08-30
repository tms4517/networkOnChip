// AHB-Lite to APB bridge (single-beat).
//
// Presents an AHB-Lite SUBORDINATE interface (driven by a niAhbTarget manager)
// and an APB MANAGER interface (driving a local APB peripheral).  Each AHB
// single-beat transfer is translated into one APB SETUP+ACCESS transaction; the
// AHB data phase is stalled (HREADYOUT low) until PREADY.  HSIZE is mapped to
// PSTRB and PSLVERR to HRESP.

`default_nettype none

module ahbToApbBridge
( input  var logic i_clk
, input  var logic i_arst_n

  // AHB-Lite subordinate interface (this module is the subordinate)
, input  var logic        i_hsel
, input  var logic [31:0] i_haddr
, input  var logic        i_hwrite
, input  var logic [2:0]  i_hsize
, input  var logic [1:0]  i_htrans
, input  var logic [31:0] i_hwdata
, output var logic        o_hreadyout
, output var logic        o_hresp
, output var logic [31:0] o_hrdata

  // APB manager interface (this module is the APB master)
, output var logic [31:0] o_paddr
, output var logic [31:0] o_pwdata
, output var logic        o_pwrite
, output var logic [3:0]  o_pstrb
, output var logic        o_psel
, output var logic        o_penable
, input  var logic        i_pready
, input  var logic        i_pslverr
, input  var logic [31:0] i_prdata
);

  typedef enum logic [1:0]
  { ST_IDLE   // Accept the AHB address phase (HREADYOUT high)
  , ST_SETUP  // APB setup phase (stall AHB data phase)
  , ST_ACCESS // APB access phase, wait for PREADY
  , ST_DONE   // Complete the AHB data phase (HREADYOUT high)
  } ty_state;

  ty_state state_q, state_d;

  logic [31:0] haddr_q;
  logic        hwrite_q;
  logic [2:0]  hsize_q;
  logic [31:0] hwdata_q;
  logic [31:0] prdata_q;
  logic        hresp_q;

  // Accept a new AHB transfer only in IDLE (HREADYOUT is high there).
  logic accept;

  always_comb
    accept = (state_q == ST_IDLE) && i_hsel && i_htrans[1];

  // {{{ HSIZE -> APB byte strobe (aligned single beats)
  logic [3:0] pstrb_d;

  always_comb
    case (hsize_q)
      3'd0:    pstrb_d = 4'b0001 << haddr_q[1:0];             // byte
      3'd1:    pstrb_d = haddr_q[1] ? 4'b1100 : 4'b0011;      // halfword
      default: pstrb_d = 4'b1111;                             // word
    endcase
  // }}} HSIZE -> APB byte strobe

  // {{{ Latched request fields
  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n) begin
      haddr_q  <= '0;
      hwrite_q <= 1'b0;
      hsize_q  <= '0;
    end else if (accept) begin
      haddr_q  <= i_haddr;
      hwrite_q <= i_hwrite;
      hsize_q  <= i_hsize;
    end else begin
      haddr_q  <= haddr_q;
      hwrite_q <= hwrite_q;
      hsize_q  <= hsize_q;
    end

  // HWDATA is valid in the AHB data phase (the cycle the FSM sits in ST_SETUP).
  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      hwdata_q <= '0;
    else if (state_q == ST_SETUP)
      hwdata_q <= i_hwdata;
    else
      hwdata_q <= hwdata_q;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n) begin
      prdata_q <= '0;
      hresp_q  <= 1'b0;
    end else if (state_q == ST_ACCESS && i_pready) begin
      prdata_q <= i_prdata;
      hresp_q  <= i_pslverr;
    end else begin
      prdata_q <= prdata_q;
      hresp_q  <= hresp_q;
    end
  // }}} Latched request fields

  // {{{ FSM
  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      state_q <= ST_IDLE;
    else
      state_q <= state_d;

  always_comb
    case (state_q)
      ST_IDLE:
        state_d = accept ? ST_SETUP : ST_IDLE;
      ST_SETUP:
        state_d = ST_ACCESS;
      ST_ACCESS:
        state_d = i_pready ? ST_DONE : ST_ACCESS;
      ST_DONE:
        state_d = ST_IDLE;
      default:
        state_d = ST_IDLE;
    endcase
  // }}} FSM

  // {{{ APB manager outputs
  always_comb
    o_psel = (state_q == ST_SETUP) || (state_q == ST_ACCESS);

  always_comb
    o_penable = (state_q == ST_ACCESS);

  always_comb
    o_paddr = haddr_q;

  always_comb
    o_pwrite = hwrite_q;

  always_comb
    o_pwdata = (state_q == ST_SETUP) ? i_hwdata : hwdata_q;

  always_comb
    o_pstrb = pstrb_d;
  // }}} APB manager outputs

  // {{{ AHB subordinate outputs
  // HREADYOUT is high when able to accept a new address phase (IDLE) or when
  // completing the current data phase (DONE); low to insert wait states.
  always_comb
    o_hreadyout = (state_q == ST_IDLE) || (state_q == ST_DONE);

  always_comb
    o_hresp = (state_q == ST_DONE) && hresp_q;

  always_comb
    o_hrdata = prdata_q;
  // }}} AHB subordinate outputs

endmodule

`resetall
