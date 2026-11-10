// Testbench wrapper
// Instantiates the NOC with a single AXI4-Lite Initiator NI at (SRC_ROW,
// SRC_COL). A "responder" NI port at (RSP_ROW, RSP_COL) is exposed to C++ so
// the testbench can observe the request packets emitted by the initiator and
// inject the corresponding response packets (acting as a remote target). This
// exercises the full initiator FSM: request generation and B/R responses.

`default_nettype none

module tb_niAxiLiteInitiator_top
#(parameter int unsigned GRID_WIDTH        = 4
, parameter int unsigned SRC_ROW           = 0
, parameter int unsigned SRC_COL           = 0
, parameter int unsigned RSP_ROW           = GRID_WIDTH - 1
, parameter int unsigned RSP_COL           = GRID_WIDTH - 1
, parameter int unsigned MAX_NI_PER_ROUTER = pa_noc::MAX_NI_PER_ROUTER
, parameter int unsigned NI_ID             = 0

, localparam int unsigned COORD_WIDTH    = $clog2(GRID_WIDTH)
, localparam int unsigned NI_ID_WIDTH    = (MAX_NI_PER_ROUTER > 1) ? $clog2(MAX_NI_PER_ROUTER) : 0
, localparam int unsigned PAYLOAD_WIDTH  = pa_noc::AXI_LITE_PAYLOAD_WIDTH
, localparam int unsigned PACKET_WIDTH   = PAYLOAD_WIDTH + (2 * NI_ID_WIDTH) + (COORD_WIDTH * 4)
)
( input  var logic i_clk
, input  var logic i_arst_n

  // AXI4-Lite subordinate interface — driven by C++
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

  // Responder NI port (RSP_ROW, RSP_COL) — observe requests, inject responses
, output var logic [PACKET_WIDTH-1:0] o_rspRouterToNi
, output var logic                    o_rspRouterToNiValid
, input  var logic                    i_rspRouterToNiReady
, input  var logic [PACKET_WIDTH-1:0] i_rspNiToRouter
, input  var logic                    i_rspNiToRouterValid
, output var logic                    o_rspNiToRouterReady
);

  // {{{ Address map — all ranges route to the responder node (RSP_ROW,RSP_COL)
  localparam int unsigned NUM_ENTRIES = 1;

  localparam pa_noc::ty_ADDR_MAP_ENTRY [NUM_ENTRIES-1:0] ADDR_MAP =
    '{
      '{baseAddr: 32'h0000_0000
      , endAddr: 32'h7FFF_FFFF
      , dstRow: 8'(RSP_ROW)
      , dstCol: 8'(RSP_COL)
      , dstNiId: 8'd0
      }
    };
  // }}} Address map

  // {{{ Interconnects
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0][PACKET_WIDTH-1:0] niToRouter;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0]                   niToRouterValid;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0]                   niToRouterReady;

  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0][PACKET_WIDTH-1:0] routerToNi;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0]                   routerToNiValid;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0]                   routerToNiReady;

  logic [PACKET_WIDTH-1:0] niToRouter_src;
  logic                    niToRouterValid_src;
  logic                    niToRouterReady_src;
  logic [PACKET_WIDTH-1:0] routerToNi_src;
  logic                    routerToNiValid_src;
  logic                    routerToNiReady_src;
  // }}} Interconnects

  niAxiLiteInitiator
  #(.GRID_WIDTH            (GRID_WIDTH)
  , .NUM_ADDR_MAP_ENTRIES  (NUM_ENTRIES)
  , .ADDR_MAP              (ADDR_MAP)
  , .SRC_ROW               (SRC_ROW)
  , .SRC_COL               (SRC_COL)
  , .MAX_NI_PER_ROUTER     (MAX_NI_PER_ROUTER)
  , .NI_ID                 (NI_ID)
  ) u_niAxiLiteInitiator
  ( .i_clk     (i_clk)
  , .i_arst_n  (i_arst_n)

  , .i_awaddr  (i_awaddr)
  , .i_awvalid (i_awvalid)
  , .o_awready (o_awready)
  , .i_wdata   (i_wdata)
  , .i_wstrb   (i_wstrb)
  , .i_wvalid  (i_wvalid)
  , .o_wready  (o_wready)
  , .o_bresp   (o_bresp)
  , .o_bvalid  (o_bvalid)
  , .i_bready  (i_bready)
  , .i_araddr  (i_araddr)
  , .i_arvalid (i_arvalid)
  , .o_arready (o_arready)
  , .o_rdata   (o_rdata)
  , .o_rresp   (o_rresp)
  , .o_rvalid  (o_rvalid)
  , .i_rready  (i_rready)

  , .o_niToRouter      (niToRouter_src)
  , .o_niToRouterValid (niToRouterValid_src)
  , .i_niToRouterReady (niToRouterReady_src)

  , .i_routerToNi      (routerToNi_src)
  , .i_routerToNiValid (routerToNiValid_src)
  , .o_routerToNiReady (routerToNiReady_src)
  );

  always_comb
    niToRouterReady_src = niToRouterReady[SRC_ROW][SRC_COL];

  always_comb
    routerToNi_src = routerToNi[SRC_ROW][SRC_COL];

  always_comb
    routerToNiValid_src = routerToNiValid[SRC_ROW][SRC_COL];

  // {{{ Responder NI port readback / injection
  always_comb
    o_rspRouterToNi = routerToNi[RSP_ROW][RSP_COL];

  always_comb
    o_rspRouterToNiValid = routerToNiValid[RSP_ROW][RSP_COL];

  always_comb
    o_rspNiToRouterReady = niToRouterReady[RSP_ROW][RSP_COL];
  // }}} Responder NI port

  // {{{ NI port connections (single driver per element)
  for (genvar i = 0; i < GRID_WIDTH; i++) begin: gen_ni_row
    for (genvar j = 0; j < GRID_WIDTH; j++) begin: gen_ni_col
      if (i == SRC_ROW && j == SRC_COL) begin: gen_src
        always_comb
          niToRouter[i][j] = niToRouter_src;
        always_comb
          niToRouterValid[i][j] = niToRouterValid_src;
        always_comb
          routerToNiReady[i][j] = routerToNiReady_src;
      end: gen_src
      else if (i == RSP_ROW && j == RSP_COL) begin: gen_rsp
        always_comb
          niToRouter[i][j] = i_rspNiToRouter;
        always_comb
          niToRouterValid[i][j] = i_rspNiToRouterValid;
        always_comb
          routerToNiReady[i][j] = i_rspRouterToNiReady;
      end: gen_rsp
      else begin: gen_tieoff
        always_comb
          niToRouter[i][j] = '0;
        always_comb
          niToRouterValid[i][j] = 1'b0;
        always_comb
          routerToNiReady[i][j] = 1'b1;
      end: gen_tieoff
    end
  end
  // }}} NI port connections

  noc
  #(.GRID_WIDTH    (GRID_WIDTH)
  , .PAYLOAD_WIDTH (PAYLOAD_WIDTH)
  ) u_noc
  ( .i_clk     (i_clk)
  , .i_arst_n  (i_arst_n)

  , .i_niToRouter      (niToRouter)
  , .i_niToRouterValid (niToRouterValid)
  , .o_niToRouterReady (niToRouterReady)

  , .o_routerToNi      (routerToNi)
  , .o_routerToNiValid (routerToNiValid)
  , .i_routerToNiReady (routerToNiReady)
  );

  // {{{ AXI4-Lite protocol checker (verilaxi)
  // DUT presents an AXI4-Lite subordinate interface; C++ drives AW/W/AR and the
  // DUT drives B/R. Verifies VALID/READY handshake stability, payload stability,
  // no-X and error-response rules on every channel.
  axil_checker
  #(.ADDR_WIDTH (32)
  , .DATA_WIDTH (32)
  , .LABEL      ("AXIL_INITIATOR")
  ) u_axil_chk
  ( .clk     (i_clk)
  , .rst_n   (i_arst_n)
  , .awaddr  (i_awaddr)
  , .awvalid (i_awvalid)
  , .awready (o_awready)
  , .wdata   (i_wdata)
  , .wstrb   (i_wstrb)
  , .wvalid  (i_wvalid)
  , .wready  (o_wready)
  , .bresp   (o_bresp)
  , .bvalid  (o_bvalid)
  , .bready  (i_bready)
  , .araddr  (i_araddr)
  , .arvalid (i_arvalid)
  , .arready (o_arready)
  , .rdata   (o_rdata)
  , .rresp   (o_rresp)
  , .rvalid  (o_rvalid)
  , .rready  (i_rready)
  );
  // }}} AXI4-Lite protocol checker

endmodule

`resetall
