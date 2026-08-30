// AXI4-Lite to AHB-Lite bridge (single-beat, single outstanding).
//
// Presents an AXI4-Lite SUBORDINATE interface (driven by a niAxiLiteTarget
// manager) and an AHB-Lite MANAGER interface (driving a local AHB peripheral).
// AW and W are accepted sequentially; each AXI access is translated into one
// AHB single-beat transfer.  HRESP maps to BRESP/RRESP.

`default_nettype none

module axiLiteToAhbBridge
( input  var logic i_clk
, input  var logic i_arst_n

  // AXI4-Lite subordinate interface (this module is the subordinate)
, input  var logic [31:0] i_awaddr
, input  var logic        i_awvalid
, output var logic        o_awready
, input  var logic [31:0] i_wdata
, input  var logic [3:0]  i_wstrb
, input  var logic        i_wvalid
, output var logic        o_wready
, output var logic [1:0]  o_bresp
, output var logic        o_bvalid
, input  var logic        i_bready
, input  var logic [31:0] i_araddr
, input  var logic        i_arvalid
, output var logic        o_arready
, output var logic [31:0] o_rdata
, output var logic [1:0]  o_rresp
, output var logic        o_rvalid
, input  var logic        i_rready

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

  typedef enum logic [2:0]
  { ST_IDLE   // Accept AW (write) or AR (read)
  , ST_WDATA  // Accept the write data beat
  , ST_ADDR   // AHB address phase
  , ST_DATA   // AHB data phase (capture HRDATA/HRESP)
  , ST_RESP   // Drive the AXI B (write) or R (read) response
  } ty_state;

  ty_state state_q, state_d;

  logic [31:0] addr_q;
  logic [31:0] wdata_q;
  logic        write_q;
  logic [31:0] rdata_q;
  logic        hresp_q;

  logic acceptWrite, acceptRead;

  always_comb
    acceptWrite = (state_q == ST_IDLE) && i_awvalid;

  always_comb
    acceptRead = (state_q == ST_IDLE) && !i_awvalid && i_arvalid;

  // {{{ Latched fields
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
    end else begin
      addr_q  <= addr_q;
      write_q <= write_q;
    end

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      wdata_q <= '0;
    else if (state_q == ST_WDATA && i_wvalid)
      wdata_q <= i_wdata;
    else
      wdata_q <= wdata_q;

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
        if (acceptWrite)
          state_d = ST_WDATA;
        else if (acceptRead)
          state_d = ST_ADDR;
        else
          state_d = ST_IDLE;
      ST_WDATA:
        state_d = i_wvalid ? ST_ADDR : ST_WDATA;
      ST_ADDR:
        state_d = i_hready ? ST_DATA : ST_ADDR;
      ST_DATA:
        state_d = i_hready ? ST_RESP : ST_DATA;
      ST_RESP:
        if (write_q)
          state_d = i_bready ? ST_IDLE : ST_RESP;
        else
          state_d = i_rready ? ST_IDLE : ST_RESP;
      default:
        state_d = ST_IDLE;
    endcase
  // }}} FSM

  // {{{ AXI subordinate outputs
  always_comb
    o_awready = acceptWrite;

  always_comb
    o_arready = acceptRead;

  always_comb
    o_wready = (state_q == ST_WDATA);

  always_comb
    o_bvalid = (state_q == ST_RESP) && write_q;

  always_comb
    o_bresp = hresp_q ? pa_noc::AXI_RESP_SLVERR : pa_noc::AXI_RESP_OKAY;

  always_comb
    o_rvalid = (state_q == ST_RESP) && !write_q;

  always_comb
    o_rdata = rdata_q;

  always_comb
    o_rresp = hresp_q ? pa_noc::AXI_RESP_SLVERR : pa_noc::AXI_RESP_OKAY;
  // }}} AXI subordinate outputs

  // {{{ AHB manager outputs
  always_comb
    o_hsel = (state_q == ST_ADDR) || (state_q == ST_DATA);

  always_comb
    o_htrans = (state_q == ST_ADDR) ? pa_noc::AHB_TRANS_NONSEQ
                                    : pa_noc::AHB_TRANS_IDLE;

  always_comb
    o_haddr = addr_q;

  always_comb
    o_hwrite = write_q;

  always_comb
    o_hsize = 3'd2;   // word

  always_comb
    o_hwdata = wdata_q;
  // }}} AHB manager outputs

endmodule

`resetall
