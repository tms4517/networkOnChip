// Testbench wrapper
// Instantiates the NOC and connects a single AXI4-Lite Target NI at router
// (DST_ROW, DST_COL) to a simple AXI4-Lite subordinate model. The C++ testbench
// injects NoC request packets at a source router (SRC_ROW, SRC_COL) and observes
// the response packets returned at that same source router NI output.

`default_nettype none

module tb_niAxiLiteTarget_top
#(parameter int unsigned GRID_WIDTH        = 4
, parameter int unsigned SRC_ROW           = 0
, parameter int unsigned SRC_COL           = 0
, parameter int unsigned DST_ROW           = 1
, parameter int unsigned DST_COL           = 1
, parameter int unsigned MAX_NI_PER_ROUTER = pa_noc::MAX_NI_PER_ROUTER

, localparam int unsigned COORD_WIDTH    = $clog2(GRID_WIDTH)
, localparam int unsigned NI_ID_WIDTH    = (MAX_NI_PER_ROUTER > 1) ? $clog2(MAX_NI_PER_ROUTER) : 0
, localparam int unsigned PAYLOAD_WIDTH  = pa_noc::AXI_LITE_PAYLOAD_WIDTH
, localparam int unsigned PACKET_WIDTH   = PAYLOAD_WIDTH + (2 * NI_ID_WIDTH) + (COORD_WIDTH * 4)
)
( input  var logic i_clk
, input  var logic i_arst_n

  // Source router NI — inject request packets from C++
, input  var logic [PACKET_WIDTH-1:0] i_srcNiToRouter
, input  var logic                    i_srcNiToRouterValid
, output var logic                    o_srcNiToRouterReady

  // Source router NI — observe response packets in C++
, output var logic [PACKET_WIDTH-1:0] o_srcRouterToNi
, output var logic                    o_srcRouterToNiValid
, input  var logic                    i_srcRouterToNiReady

  // AXI subordinate monitor — observe what niAxiLiteTarget drives
, output var logic [31:0] o_awaddr
, output var logic        o_awvalid
, output var logic [31:0] o_wdata
, output var logic        o_wvalid
, output var logic [31:0] o_araddr
, output var logic        o_arvalid
);

  // {{{ Interconnects
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0][PACKET_WIDTH-1:0] niToRouter;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0]                   niToRouterValid;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0]                   niToRouterReady;

  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0][PACKET_WIDTH-1:0] routerToNi;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0]                   routerToNiValid;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0]                   routerToNiReady;
  // }}} Interconnects

  // {{{ Source NI port readback
  always_comb
    o_srcNiToRouterReady = niToRouterReady[SRC_ROW][SRC_COL];

  always_comb
    o_srcRouterToNi = routerToNi[SRC_ROW][SRC_COL];

  always_comb
    o_srcRouterToNiValid = routerToNiValid[SRC_ROW][SRC_COL];
  // }}} Source NI port

  // {{{ niAxiLiteTarget at (DST_ROW, DST_COL)
  logic [PACKET_WIDTH-1:0] niToRouter_dst;
  logic                    niToRouterValid_dst;
  logic                    niToRouterReady_dst;
  logic [PACKET_WIDTH-1:0] routerToNi_dst;
  logic                    routerToNiValid_dst;
  logic                    routerToNiReady_dst;

  // AXI signals between niAxiLiteTarget (manager) and the subordinate model
  logic [31:0] axi_awaddr;
  logic        axi_awvalid;
  logic        axi_awready;
  logic [31:0] axi_wdata;
  logic [3:0]  axi_wstrb;
  logic        axi_wvalid;
  logic        axi_wready;
  logic [1:0]  axi_bresp;
  logic        axi_bvalid;
  logic        axi_bready;
  logic [31:0] axi_araddr;
  logic        axi_arvalid;
  logic        axi_arready;
  logic [31:0] axi_rdata;
  logic [1:0]  axi_rresp;
  logic        axi_rvalid;
  logic        axi_rready;

  always_comb
    routerToNi_dst = routerToNi[DST_ROW][DST_COL];

  always_comb
    routerToNiValid_dst = routerToNiValid[DST_ROW][DST_COL];

  always_comb
    niToRouterReady_dst = niToRouterReady[DST_ROW][DST_COL];

  niAxiLiteTarget
  #(.GRID_WIDTH        (GRID_WIDTH)
  , .MY_ROW            (DST_ROW)
  , .MY_COL            (DST_COL)
  , .MAX_NI_PER_ROUTER (MAX_NI_PER_ROUTER)
  ) u_niAxiLiteTarget
  ( .i_clk     (i_clk)
  , .i_arst_n  (i_arst_n)

  , .o_awaddr  (axi_awaddr)
  , .o_awvalid (axi_awvalid)
  , .i_awready (axi_awready)
  , .o_wdata   (axi_wdata)
  , .o_wstrb   (axi_wstrb)
  , .o_wvalid  (axi_wvalid)
  , .i_wready  (axi_wready)
  , .i_bresp   (axi_bresp)
  , .i_bvalid  (axi_bvalid)
  , .o_bready  (axi_bready)
  , .o_araddr  (axi_araddr)
  , .o_arvalid (axi_arvalid)
  , .i_arready (axi_arready)
  , .i_rdata   (axi_rdata)
  , .i_rresp   (axi_rresp)
  , .i_rvalid  (axi_rvalid)
  , .o_rready  (axi_rready)

  , .i_routerToNi      (routerToNi_dst)
  , .i_routerToNiValid (routerToNiValid_dst)
  , .o_routerToNiReady (routerToNiReady_dst)

  , .o_niToRouter      (niToRouter_dst)
  , .o_niToRouterValid (niToRouterValid_dst)
  , .i_niToRouterReady (niToRouterReady_dst)
  );
  // }}} niAxiLiteTarget

  // {{{ Simple AXI4-Lite subordinate model
  // Always ready to accept AW/W/AR. Writes store into a 4-entry register file
  // (addr bits [3:2] select). Reads return the stored value. Responses OKAY.
  logic [31:0] slave_reg [0:3];
  logic [31:0] awaddr_q;
  logic        bpending_q;
  logic [31:0] rdata_q;
  logic        rpending_q;

  always_comb
    axi_awready = 1'b1;

  always_comb
    axi_wready = 1'b1;

  always_comb
    axi_arready = 1'b1;

  always_comb
    axi_bvalid = bpending_q;

  always_comb
    axi_bresp = 2'b00;

  always_comb
    axi_rvalid = rpending_q;

  always_comb
    axi_rdata = rdata_q;

  always_comb
    axi_rresp = 2'b00;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n) begin
      slave_reg[0] <= 32'hAAAA_0000;
      slave_reg[1] <= 32'hBBBB_1111;
      slave_reg[2] <= 32'hCCCC_2222;
      slave_reg[3] <= 32'hDDDD_3333;
      awaddr_q     <= '0;
      bpending_q   <= 1'b0;
      rdata_q      <= '0;
      rpending_q   <= 1'b0;
    end else begin
      if (axi_awvalid && axi_awready)
        awaddr_q <= axi_awaddr;

      if (axi_wvalid && axi_wready)
        slave_reg[awaddr_q[3:2]] <= axi_wdata;

      if (axi_wvalid && axi_wready)
        bpending_q <= 1'b1;
      else if (axi_bvalid && axi_bready)
        bpending_q <= 1'b0;

      if (axi_arvalid && axi_arready) begin
        rdata_q    <= slave_reg[axi_araddr[3:2]];
        rpending_q <= 1'b1;
      end else if (axi_rvalid && axi_rready)
        rpending_q <= 1'b0;
    end
  // }}} Simple AXI4-Lite subordinate model

  // {{{ NI port connections (single driver per element)
  for (genvar i = 0; i < GRID_WIDTH; i++) begin: gen_ni_row
    for (genvar j = 0; j < GRID_WIDTH; j++) begin: gen_ni_col
      if (i == SRC_ROW && j == SRC_COL) begin: gen_src
        always_comb
          niToRouter[i][j] = i_srcNiToRouter;
        always_comb
          niToRouterValid[i][j] = i_srcNiToRouterValid;
        always_comb
          routerToNiReady[i][j] = i_srcRouterToNiReady;
      end: gen_src
      else if (i == DST_ROW && j == DST_COL) begin: gen_dst
        always_comb
          niToRouter[i][j] = niToRouter_dst;
        always_comb
          niToRouterValid[i][j] = niToRouterValid_dst;
        always_comb
          routerToNiReady[i][j] = routerToNiReady_dst;
      end: gen_dst
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

  // {{{ Monitor outputs
  always_comb
    o_awaddr = axi_awaddr;
  always_comb
    o_awvalid = axi_awvalid;
  always_comb
    o_wdata = axi_wdata;
  always_comb
    o_wvalid = axi_wvalid;
  always_comb
    o_araddr = axi_araddr;
  always_comb
    o_arvalid = axi_arvalid;
  // }}} Monitor outputs

  // {{{ AXI4-Lite protocol checker (verilaxi)
  // DUT (niAxiLiteTarget) is the AXI4-Lite manager: it drives AW/W/AR to the
  // subordinate model and receives B/R. Verifies VALID/READY handshake
  // stability, payload stability, no-X and error-response rules per channel.
  axil_checker
  #(.ADDR_WIDTH (32)
  , .DATA_WIDTH (32)
  , .LABEL      ("AXIL_TARGET")
  ) u_axil_chk
  ( .clk     (i_clk)
  , .rst_n   (i_arst_n)
  , .awaddr  (axi_awaddr)
  , .awvalid (axi_awvalid)
  , .awready (axi_awready)
  , .wdata   (axi_wdata)
  , .wstrb   (axi_wstrb)
  , .wvalid  (axi_wvalid)
  , .wready  (axi_wready)
  , .bresp   (axi_bresp)
  , .bvalid  (axi_bvalid)
  , .bready  (axi_bready)
  , .araddr  (axi_araddr)
  , .arvalid (axi_arvalid)
  , .arready (axi_arready)
  , .rdata   (axi_rdata)
  , .rresp   (axi_rresp)
  , .rvalid  (axi_rvalid)
  , .rready  (axi_rready)
  );
  // }}} AXI4-Lite protocol checker

endmodule

`resetall
