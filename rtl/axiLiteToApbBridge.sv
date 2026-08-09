// AXI4-Lite to APB bridge (single-beat, single outstanding).
//
// Presents an AXI4-Lite SUBORDINATE interface (driven by a niAxiLiteTarget
// manager) and an APB MANAGER interface (driving a local APB peripheral).  Each
// AXI single access is translated into one APB SETUP+ACCESS transaction.  AW
// and W are accepted sequentially (matching niAxiLiteTarget), WSTRB maps to
// PSTRB and PSLVERR to BRESP/RRESP.

`default_nettype none

module axiLiteToApbBridge
( input  var logic i_clk
, input  var logic i_arst_n

  // AXI4-Lite subordinate interface (this module is the subordinate)
  // Write address channel
, input  var logic [31:0] i_awaddr
, input  var logic        i_awvalid
, output var logic        o_awready
  // Write data channel
, input  var logic [31:0] i_wdata
, input  var logic [3:0]  i_wstrb
, input  var logic        i_wvalid
, output var logic        o_wready
  // Write response channel
, output var logic [1:0]  o_bresp
, output var logic        o_bvalid
, input  var logic        i_bready
  // Read address channel
, input  var logic [31:0] i_araddr
, input  var logic        i_arvalid
, output var logic        o_arready
  // Read data channel
, output var logic [31:0] o_rdata
, output var logic [1:0]  o_rresp
, output var logic        o_rvalid
, input  var logic        i_rready

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

  typedef enum logic [2:0]
  { ST_IDLE   // Accept AW (write) or AR (read)
  , ST_WDATA  // Accept the write data beat
  , ST_SETUP  // APB setup phase
  , ST_ACCESS // APB access phase, wait for PREADY
  , ST_RESP   // Drive the AXI B (write) or R (read) response
  } ty_state;

  ty_state state_q, state_d;

  logic [31:0] addr_q;
  logic [31:0] wdata_q;
  logic [3:0]  wstrb_q;
  logic        write_q;
  logic [31:0] prdata_q;
  logic [1:0]  resp_q;

  logic acceptWrite;
  logic acceptRead;

  always_comb
    acceptWrite = (state_q == ST_IDLE) && i_awvalid;

  always_comb
    acceptRead = (state_q == ST_IDLE) && !i_awvalid && i_arvalid;

  // {{{ Latched request fields
  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n) begin
      addr_q  <= '0;
      write_q <= 1'b0;
    end else if (acceptWrite) begin
      addr_q  <= i_awaddr;
      write_q <= 1'b1;
    end else if (acceptRead) begin
      addr_q  <= i_araddr;
      write_q <= 1'b0;
    end

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n) begin
      wdata_q <= '0;
      wstrb_q <= '0;
    end else if (state_q == ST_WDATA && i_wvalid) begin
      wdata_q <= i_wdata;
      wstrb_q <= i_wstrb;
    end

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n) begin
      prdata_q <= '0;
      resp_q   <= pa_noc::AXI_RESP_OKAY;
    end else if (state_q == ST_ACCESS && i_pready) begin
      prdata_q <= i_prdata;
      resp_q   <= i_pslverr ? pa_noc::AXI_RESP_SLVERR : pa_noc::AXI_RESP_OKAY;
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
        if (acceptWrite)
          state_d = ST_WDATA;
        else if (acceptRead)
          state_d = ST_SETUP;
        else
          state_d = ST_IDLE;
      ST_WDATA:
        state_d = i_wvalid ? ST_SETUP : ST_WDATA;
      ST_SETUP:
        state_d = ST_ACCESS;
      ST_ACCESS:
        state_d = i_pready ? ST_RESP : ST_ACCESS;
      ST_RESP:
        if (write_q)
          state_d = i_bready ? ST_IDLE : ST_RESP;
        else
          state_d = i_rready ? ST_IDLE : ST_RESP;
      default:
        state_d = ST_IDLE;
    endcase
  // }}} FSM

  // {{{ AXI subordinate handshake outputs
  always_comb
    o_awready = acceptWrite;

  always_comb
    o_arready = acceptRead;

  always_comb
    o_wready = (state_q == ST_WDATA);

  always_comb
    o_bvalid = (state_q == ST_RESP) && write_q;

  always_comb
    o_bresp = resp_q;

  always_comb
    o_rvalid = (state_q == ST_RESP) && !write_q;

  always_comb
    o_rdata = prdata_q;

  always_comb
    o_rresp = resp_q;
  // }}} AXI subordinate handshake outputs

  // {{{ APB manager outputs
  always_comb
    o_psel = (state_q == ST_SETUP) || (state_q == ST_ACCESS);

  always_comb
    o_penable = (state_q == ST_ACCESS);

  always_comb
    o_paddr = addr_q;

  always_comb
    o_pwrite = write_q;

  always_comb
    o_pwdata = wdata_q;

  always_comb
    o_pstrb = wstrb_q;
  // }}} APB manager outputs

endmodule

`resetall
