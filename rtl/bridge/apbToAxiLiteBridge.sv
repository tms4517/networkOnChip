// APB to AXI4-Lite bridge (single-beat, single outstanding).
//
// Presents an APB SUBORDINATE interface (driven by a niApbTarget manager) and an
// AXI4-Lite MANAGER interface (driving a local AXI peripheral). Each APB access
// is translated into one AXI access; PREADY is held low until the AXI response.
// PSTRB maps to WSTRB and BRESP/RRESP to PSLVERR.

`default_nettype none

module apbToAxiLiteBridge
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
  { ST_IDLE   // Wait for the APB access phase
  , ST_AW     // AXI write address
  , ST_W      // AXI write data
  , ST_B      // AXI write response
  , ST_AR     // AXI read address
  , ST_R      // AXI read data
  , ST_DONE   // Complete the APB access (PREADY high)
  } ty_state;

  ty_state state_q, state_d;

  logic [31:0] paddr_q;
  logic [31:0] pwdata_q;
  logic [3:0]  pstrb_q;
  logic        pwrite_q;
  logic [31:0] rdata_q;
  logic [1:0]  resp_q;

  logic accept;

  always_comb
    accept = (state_q == ST_IDLE) && i_psel && i_penable;

  // {{{ Latched fields
  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n) begin
      paddr_q  <= '0;
      pwdata_q <= '0;
      pstrb_q  <= '0;
      pwrite_q <= 1'b0;
    end else if (accept) begin
      paddr_q  <= i_paddr;
      pwdata_q <= i_pwdata;
      pstrb_q  <= i_pstrb;
      pwrite_q <= i_pwrite;
    end else begin
      paddr_q  <= paddr_q;
      pwdata_q <= pwdata_q;
      pstrb_q  <= pstrb_q;
      pwrite_q <= pwrite_q;
    end

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n) begin
      rdata_q <= '0;
      resp_q  <= pa_noc::AXI_RESP_OKAY;
    end else if (state_q == ST_B && i_bvalid) begin
      resp_q  <= i_bresp;
    end else if (state_q == ST_R && i_rvalid) begin
      rdata_q <= i_rdata;
      resp_q  <= i_rresp;
    end else begin
      rdata_q <= rdata_q;
      resp_q  <= resp_q;
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
        if (accept)
          state_d = i_pwrite ? ST_AW : ST_AR;
        else
          state_d = ST_IDLE;
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
    o_awaddr = paddr_q;

  always_comb
    o_wvalid = (state_q == ST_W);

  always_comb
    o_wdata = pwdata_q;

  always_comb
    o_wstrb = pstrb_q;

  always_comb
    o_bready = (state_q == ST_B);

  always_comb
    o_arvalid = (state_q == ST_AR);

  always_comb
    o_araddr = paddr_q;

  always_comb
    o_rready = (state_q == ST_R);
  // }}} AXI manager outputs

  // {{{ APB subordinate outputs
  always_comb
    o_pready = (state_q == ST_DONE);

  always_comb
    o_pslverr = (state_q == ST_DONE) && (resp_q != pa_noc::AXI_RESP_OKAY);

  always_comb
    o_prdata = rdata_q;
  // }}} APB subordinate outputs

endmodule

`resetall
