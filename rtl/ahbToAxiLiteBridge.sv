// AHB-Lite to AXI4-Lite bridge (single-beat, single outstanding).
//
// Presents an AHB-Lite SUBORDINATE interface (driven by a niAhbTarget manager)
// and an AXI4-Lite MANAGER interface (driving a local AXI peripheral).  Each AHB
// single-beat transfer is translated into one AXI access; the AHB data phase is
// stalled (HREADYOUT low) until the AXI response.  HSIZE maps to WSTRB and
// BRESP/RRESP to HRESP.

`default_nettype none

module ahbToAxiLiteBridge
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

  // AXI4-Lite manager interface (this module is the manager)
, output var logic [31:0] o_awaddr
, output var logic        o_awvalid
, input  var logic        i_awready
, output var logic [31:0] o_wdata
, output var logic [3:0]  o_wstrb
, output var logic        o_wvalid
, input  var logic        i_wready
, input  var logic [1:0]  i_bresp
, input  var logic        i_bvalid
, output var logic        o_bready
, output var logic [31:0] o_araddr
, output var logic        o_arvalid
, input  var logic        i_arready
, input  var logic [31:0] i_rdata
, input  var logic [1:0]  i_rresp
, input  var logic        i_rvalid
, output var logic        o_rready
);

  typedef enum logic [2:0]
  { ST_IDLE   // Accept the AHB address phase
  , ST_SETUP  // Capture HWDATA, launch the AXI access
  , ST_AW     // AXI write address
  , ST_W      // AXI write data
  , ST_B      // AXI write response
  , ST_AR     // AXI read address
  , ST_R      // AXI read data
  , ST_DONE   // Complete the AHB data phase (HREADYOUT high)
  } ty_state;

  ty_state state_q, state_d;

  logic [31:0] haddr_q;
  logic        hwrite_q;
  logic [2:0]  hsize_q;
  logic [31:0] hwdata_q;
  logic [31:0] rdata_q;
  logic [1:0]  resp_q;

  logic accept;

  always_comb
    accept = (state_q == ST_IDLE) && i_hsel && i_htrans[1];

  // {{{ HSIZE -> byte strobe (aligned single beats)
  logic [3:0] wstrb_d;

  always_comb
    case (hsize_q)
      3'd0:    wstrb_d = 4'b0001 << haddr_q[1:0];
      3'd1:    wstrb_d = haddr_q[1] ? 4'b1100 : 4'b0011;
      default: wstrb_d = 4'b1111;
    endcase
  // }}} HSIZE -> byte strobe

  // {{{ Latched fields
  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n) begin
      haddr_q  <= '0;
      hwrite_q <= 1'b0;
      hsize_q  <= '0;
    end else if (accept) begin
      haddr_q  <= i_haddr;
      hwrite_q <= i_hwrite;
      hsize_q  <= i_hsize;
    end

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      hwdata_q <= '0;
    else if (state_q == ST_SETUP)
      hwdata_q <= i_hwdata;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n) begin
      rdata_q <= '0;
      resp_q  <= pa_noc::AXI_RESP_OKAY;
    end else if (state_q == ST_B && i_bvalid) begin
      resp_q  <= i_bresp;
    end else if (state_q == ST_R && i_rvalid) begin
      rdata_q <= i_rdata;
      resp_q  <= i_rresp;
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
        state_d = accept ? ST_SETUP : ST_IDLE;
      ST_SETUP:
        state_d = hwrite_q ? ST_AW : ST_AR;
      ST_AW:
        state_d = i_awready ? ST_W : ST_AW;
      ST_W:
        state_d = i_wready ? ST_B : ST_W;
      ST_B:
        state_d = i_bvalid ? ST_DONE : ST_B;
      ST_AR:
        state_d = i_arready ? ST_R : ST_AR;
      ST_R:
        state_d = i_rvalid ? ST_DONE : ST_R;
      ST_DONE:
        state_d = ST_IDLE;
      default:
        state_d = ST_IDLE;
    endcase
  // }}} FSM

  // {{{ AXI manager outputs
  always_comb
    o_awvalid = (state_q == ST_AW);

  always_comb
    o_awaddr = haddr_q;

  always_comb
    o_wvalid = (state_q == ST_W);

  always_comb
    o_wdata = hwdata_q;

  always_comb
    o_wstrb = wstrb_d;

  always_comb
    o_bready = (state_q == ST_B);

  always_comb
    o_arvalid = (state_q == ST_AR);

  always_comb
    o_araddr = haddr_q;

  always_comb
    o_rready = (state_q == ST_R);
  // }}} AXI manager outputs

  // {{{ AHB subordinate outputs
  always_comb
    o_hreadyout = (state_q == ST_IDLE) || (state_q == ST_DONE);

  always_comb
    o_hresp = (state_q == ST_DONE) && (resp_q != pa_noc::AXI_RESP_OKAY);

  always_comb
    o_hrdata = rdata_q;
  // }}} AHB subordinate outputs

endmodule

`resetall
