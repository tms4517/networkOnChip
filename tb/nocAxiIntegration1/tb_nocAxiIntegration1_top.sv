// Integration testbench wrapper
// Instantiates the NOC with TWO niAxiLiteInitiator managers (on different
// routers) and TWO niAxiLiteTarget subordinates (on different routers). Both
// initiators share an address map that can reach either target, exercising
// concurrent multi-manager / multi-subordinate AXI4-Lite traffic and the
// dynamic source-based response routing of niAxiLiteTarget.
//
// Node placement (default 4x4 grid):
//   Initiator 0 : (0,0)              Target A : (0, GRID_WIDTH-1)
//   Initiator 1 : (GW-1,GW-1)        Target B : (GRID_WIDTH-1, 0)
//
// Address map (shared by both initiators):
//   0x0000_0000 - 0x0FFF_FFFF -> Target A
//   0x1000_0000 - 0x1FFF_FFFF -> Target B

`default_nettype none

module tb_nocAxiIntegration1_top
#(parameter int unsigned GRID_WIDTH = 4
, parameter int unsigned INIT0_ROW  = 0
, parameter int unsigned INIT0_COL  = 0
, parameter int unsigned INIT1_ROW  = GRID_WIDTH - 1
, parameter int unsigned INIT1_COL  = GRID_WIDTH - 1
, parameter int unsigned TGTA_ROW   = 0
, parameter int unsigned TGTA_COL   = GRID_WIDTH - 1
, parameter int unsigned TGTB_ROW   = GRID_WIDTH - 1
, parameter int unsigned TGTB_COL   = 0

, localparam int unsigned COORD_WIDTH   = $clog2(GRID_WIDTH)
, localparam int unsigned PAYLOAD_WIDTH = pa_noc::AXI_LITE_PAYLOAD_WIDTH
, localparam int unsigned PACKET_WIDTH  = PAYLOAD_WIDTH + (COORD_WIDTH * 4)
)
( input  var logic i_clk
, input  var logic i_arst_n

  // Initiator 0 AXI4-Lite subordinate interface — driven by C++
, input  var logic [31:0] i_awaddr0
, input  var logic        i_awvalid0
, output var logic        o_awready0
, input  var logic [31:0] i_wdata0
, input  var logic [3:0]  i_wstrb0
, input  var logic        i_wvalid0
, output var logic        o_wready0
, output var logic [1:0]  o_bresp0
, output var logic        o_bvalid0
, input  var logic        i_bready0
, input  var logic [31:0] i_araddr0
, input  var logic        i_arvalid0
, output var logic        o_arready0
, output var logic [31:0] o_rdata0
, output var logic [1:0]  o_rresp0
, output var logic        o_rvalid0
, input  var logic        i_rready0

  // Initiator 1 AXI4-Lite subordinate interface — driven by C++
, input  var logic [31:0] i_awaddr1
, input  var logic        i_awvalid1
, output var logic        o_awready1
, input  var logic [31:0] i_wdata1
, input  var logic [3:0]  i_wstrb1
, input  var logic        i_wvalid1
, output var logic        o_wready1
, output var logic [1:0]  o_bresp1
, output var logic        o_bvalid1
, input  var logic        i_bready1
, input  var logic [31:0] i_araddr1
, input  var logic        i_arvalid1
, output var logic        o_arready1
, output var logic [31:0] o_rdata1
, output var logic [1:0]  o_rresp1
, output var logic        o_rvalid1
, input  var logic        i_rready1
);

  // {{{ Address map (shared by both initiators)
  localparam int unsigned NUM_ENTRIES = 2;

  localparam pa_noc::ty_ADDR_MAP_ENTRY [NUM_ENTRIES-1:0] ADDR_MAP =
    '{
      '{baseAddr: 32'h1000_0000
      , endAddr: 32'h1FFF_FFFF
      , dstRow: 8'(TGTB_ROW)
      , dstCol: 8'(TGTB_COL)
      , dstNiId: 8'd0
      },
      '{baseAddr: 32'h0000_0000
      , endAddr: 32'h0FFF_FFFF
      , dstRow: 8'(TGTA_ROW)
      , dstCol: 8'(TGTA_COL)
      , dstNiId: 8'd0
      }
    };
  // }}} Address map

  // {{{ NOC interconnect arrays
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0][PACKET_WIDTH-1:0] niToRouter;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0]                   niToRouterValid;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0]                   niToRouterReady;

  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0][PACKET_WIDTH-1:0] routerToNi;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0]                   routerToNiValid;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0]                   routerToNiReady;
  // }}} NOC interconnect arrays

  // {{{ Initiator 0
  logic [PACKET_WIDTH-1:0] niToRouter_i0;
  logic                    niToRouterValid_i0;
  logic                    niToRouterReady_i0;
  logic [PACKET_WIDTH-1:0] routerToNi_i0;
  logic                    routerToNiValid_i0;
  logic                    routerToNiReady_i0;

  always_comb
    niToRouterReady_i0 = niToRouterReady[INIT0_ROW][INIT0_COL];
  always_comb
    routerToNi_i0 = routerToNi[INIT0_ROW][INIT0_COL];
  always_comb
    routerToNiValid_i0 = routerToNiValid[INIT0_ROW][INIT0_COL];

  niAxiLiteInitiator
  #(.GRID_WIDTH            (GRID_WIDTH)
  , .NUM_ADDR_MAP_ENTRIES  (NUM_ENTRIES)
  , .ADDR_MAP              (ADDR_MAP)
  , .SRC_ROW               (INIT0_ROW)
  , .SRC_COL               (INIT0_COL)
  ) u_init0
  ( .i_clk     (i_clk)
  , .i_arst_n  (i_arst_n)

  , .i_awaddr  (i_awaddr0)
  , .i_awvalid (i_awvalid0)
  , .o_awready (o_awready0)
  , .i_wdata   (i_wdata0)
  , .i_wstrb   (i_wstrb0)
  , .i_wvalid  (i_wvalid0)
  , .o_wready  (o_wready0)
  , .o_bresp   (o_bresp0)
  , .o_bvalid  (o_bvalid0)
  , .i_bready  (i_bready0)
  , .i_araddr  (i_araddr0)
  , .i_arvalid (i_arvalid0)
  , .o_arready (o_arready0)
  , .o_rdata   (o_rdata0)
  , .o_rresp   (o_rresp0)
  , .o_rvalid  (o_rvalid0)
  , .i_rready  (i_rready0)

  , .o_niToRouter      (niToRouter_i0)
  , .o_niToRouterValid (niToRouterValid_i0)
  , .i_niToRouterReady (niToRouterReady_i0)

  , .i_routerToNi      (routerToNi_i0)
  , .i_routerToNiValid (routerToNiValid_i0)
  , .o_routerToNiReady (routerToNiReady_i0)
  );
  // }}} Initiator 0

  // {{{ Initiator 1
  logic [PACKET_WIDTH-1:0] niToRouter_i1;
  logic                    niToRouterValid_i1;
  logic                    niToRouterReady_i1;
  logic [PACKET_WIDTH-1:0] routerToNi_i1;
  logic                    routerToNiValid_i1;
  logic                    routerToNiReady_i1;

  always_comb
    niToRouterReady_i1 = niToRouterReady[INIT1_ROW][INIT1_COL];
  always_comb
    routerToNi_i1 = routerToNi[INIT1_ROW][INIT1_COL];
  always_comb
    routerToNiValid_i1 = routerToNiValid[INIT1_ROW][INIT1_COL];

  niAxiLiteInitiator
  #(.GRID_WIDTH            (GRID_WIDTH)
  , .NUM_ADDR_MAP_ENTRIES  (NUM_ENTRIES)
  , .ADDR_MAP              (ADDR_MAP)
  , .SRC_ROW               (INIT1_ROW)
  , .SRC_COL               (INIT1_COL)
  ) u_init1
  ( .i_clk     (i_clk)
  , .i_arst_n  (i_arst_n)

  , .i_awaddr  (i_awaddr1)
  , .i_awvalid (i_awvalid1)
  , .o_awready (o_awready1)
  , .i_wdata   (i_wdata1)
  , .i_wstrb   (i_wstrb1)
  , .i_wvalid  (i_wvalid1)
  , .o_wready  (o_wready1)
  , .o_bresp   (o_bresp1)
  , .o_bvalid  (o_bvalid1)
  , .i_bready  (i_bready1)
  , .i_araddr  (i_araddr1)
  , .i_arvalid (i_arvalid1)
  , .o_arready (o_arready1)
  , .o_rdata   (o_rdata1)
  , .o_rresp   (o_rresp1)
  , .o_rvalid  (o_rvalid1)
  , .i_rready  (i_rready1)

  , .o_niToRouter      (niToRouter_i1)
  , .o_niToRouterValid (niToRouterValid_i1)
  , .i_niToRouterReady (niToRouterReady_i1)

  , .i_routerToNi      (routerToNi_i1)
  , .i_routerToNiValid (routerToNiValid_i1)
  , .o_routerToNiReady (routerToNiReady_i1)
  );
  // }}} Initiator 1

  // {{{ Target A NI + AXI subordinate
  logic [PACKET_WIDTH-1:0] niToRouter_tA;
  logic                    niToRouterValid_tA;
  logic                    niToRouterReady_tA;
  logic [PACKET_WIDTH-1:0] routerToNi_tA;
  logic                    routerToNiValid_tA;
  logic                    routerToNiReady_tA;

  logic [31:0] axiA_awaddr;
  logic        axiA_awvalid;
  logic [31:0] axiA_wdata;
  logic [3:0]  axiA_wstrb;
  logic        axiA_wvalid;
  logic        axiA_bready;
  logic [31:0] axiA_araddr;
  logic        axiA_arvalid;
  logic        axiA_rready;
  logic [1:0]  axiA_bresp;
  logic        axiA_bvalid;
  logic [31:0] axiA_rdata;
  logic [1:0]  axiA_rresp;
  logic        axiA_rvalid;

  always_comb
    routerToNi_tA = routerToNi[TGTA_ROW][TGTA_COL];
  always_comb
    routerToNiValid_tA = routerToNiValid[TGTA_ROW][TGTA_COL];
  always_comb
    niToRouterReady_tA = niToRouterReady[TGTA_ROW][TGTA_COL];

  niAxiLiteTarget
  #(.GRID_WIDTH (GRID_WIDTH)
  , .MY_ROW     (TGTA_ROW)
  , .MY_COL     (TGTA_COL)
  ) u_tgtA
  ( .i_clk     (i_clk)
  , .i_arst_n  (i_arst_n)

  , .o_awaddr  (axiA_awaddr)
  , .o_awvalid (axiA_awvalid)
  , .i_awready (1'b1)
  , .o_wdata   (axiA_wdata)
  , .o_wstrb   (axiA_wstrb)
  , .o_wvalid  (axiA_wvalid)
  , .i_wready  (1'b1)
  , .i_bresp   (axiA_bresp)
  , .i_bvalid  (axiA_bvalid)
  , .o_bready  (axiA_bready)
  , .o_araddr  (axiA_araddr)
  , .o_arvalid (axiA_arvalid)
  , .i_arready (1'b1)
  , .i_rdata   (axiA_rdata)
  , .i_rresp   (axiA_rresp)
  , .i_rvalid  (axiA_rvalid)
  , .o_rready  (axiA_rready)

  , .i_routerToNi      (routerToNi_tA)
  , .i_routerToNiValid (routerToNiValid_tA)
  , .o_routerToNiReady (routerToNiReady_tA)

  , .o_niToRouter      (niToRouter_tA)
  , .o_niToRouterValid (niToRouterValid_tA)
  , .i_niToRouterReady (niToRouterReady_tA)
  );

  logic [31:0] slaveA_reg [0:3];
  logic [31:0] awaddrA_q;
  logic        bpendingA_q;
  logic [31:0] rdataA_q;
  logic        rpendingA_q;

  always_comb
    axiA_bvalid = bpendingA_q;
  always_comb
    axiA_bresp = 2'b00;
  always_comb
    axiA_rvalid = rpendingA_q;
  always_comb
    axiA_rdata = rdataA_q;
  always_comb
    axiA_rresp = 2'b00;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n) begin
      slaveA_reg[0] <= 32'hA000_0000;
      slaveA_reg[1] <= 32'hA111_1111;
      slaveA_reg[2] <= 32'hA222_2222;
      slaveA_reg[3] <= 32'hA333_3333;
      awaddrA_q     <= '0;
      bpendingA_q   <= 1'b0;
      rdataA_q      <= '0;
      rpendingA_q   <= 1'b0;
    end else begin
      if (axiA_awvalid)
        awaddrA_q <= axiA_awaddr;
      if (axiA_wvalid)
        slaveA_reg[awaddrA_q[3:2]] <= axiA_wdata;
      if (axiA_wvalid)
        bpendingA_q <= 1'b1;
      else if (axiA_bvalid && axiA_bready)
        bpendingA_q <= 1'b0;
      if (axiA_arvalid) begin
        rdataA_q    <= slaveA_reg[axiA_araddr[3:2]];
        rpendingA_q <= 1'b1;
      end else if (axiA_rvalid && axiA_rready)
        rpendingA_q <= 1'b0;
    end
  // }}} Target A

  // {{{ Target B NI + AXI subordinate
  logic [PACKET_WIDTH-1:0] niToRouter_tB;
  logic                    niToRouterValid_tB;
  logic                    niToRouterReady_tB;
  logic [PACKET_WIDTH-1:0] routerToNi_tB;
  logic                    routerToNiValid_tB;
  logic                    routerToNiReady_tB;

  logic [31:0] axiB_awaddr;
  logic        axiB_awvalid;
  logic [31:0] axiB_wdata;
  logic [3:0]  axiB_wstrb;
  logic        axiB_wvalid;
  logic        axiB_bready;
  logic [31:0] axiB_araddr;
  logic        axiB_arvalid;
  logic        axiB_rready;
  logic [1:0]  axiB_bresp;
  logic        axiB_bvalid;
  logic [31:0] axiB_rdata;
  logic [1:0]  axiB_rresp;
  logic        axiB_rvalid;

  always_comb
    routerToNi_tB = routerToNi[TGTB_ROW][TGTB_COL];
  always_comb
    routerToNiValid_tB = routerToNiValid[TGTB_ROW][TGTB_COL];
  always_comb
    niToRouterReady_tB = niToRouterReady[TGTB_ROW][TGTB_COL];

  niAxiLiteTarget
  #(.GRID_WIDTH (GRID_WIDTH)
  , .MY_ROW     (TGTB_ROW)
  , .MY_COL     (TGTB_COL)
  ) u_tgtB
  ( .i_clk     (i_clk)
  , .i_arst_n  (i_arst_n)

  , .o_awaddr  (axiB_awaddr)
  , .o_awvalid (axiB_awvalid)
  , .i_awready (1'b1)
  , .o_wdata   (axiB_wdata)
  , .o_wstrb   (axiB_wstrb)
  , .o_wvalid  (axiB_wvalid)
  , .i_wready  (1'b1)
  , .i_bresp   (axiB_bresp)
  , .i_bvalid  (axiB_bvalid)
  , .o_bready  (axiB_bready)
  , .o_araddr  (axiB_araddr)
  , .o_arvalid (axiB_arvalid)
  , .i_arready (1'b1)
  , .i_rdata   (axiB_rdata)
  , .i_rresp   (axiB_rresp)
  , .i_rvalid  (axiB_rvalid)
  , .o_rready  (axiB_rready)

  , .i_routerToNi      (routerToNi_tB)
  , .i_routerToNiValid (routerToNiValid_tB)
  , .o_routerToNiReady (routerToNiReady_tB)

  , .o_niToRouter      (niToRouter_tB)
  , .o_niToRouterValid (niToRouterValid_tB)
  , .i_niToRouterReady (niToRouterReady_tB)
  );

  logic [31:0] slaveB_reg [0:3];
  logic [31:0] awaddrB_q;
  logic        bpendingB_q;
  logic [31:0] rdataB_q;
  logic        rpendingB_q;

  always_comb
    axiB_bvalid = bpendingB_q;
  always_comb
    axiB_bresp = 2'b00;
  always_comb
    axiB_rvalid = rpendingB_q;
  always_comb
    axiB_rdata = rdataB_q;
  always_comb
    axiB_rresp = 2'b00;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n) begin
      slaveB_reg[0] <= 32'hB000_0000;
      slaveB_reg[1] <= 32'hB111_1111;
      slaveB_reg[2] <= 32'hB222_2222;
      slaveB_reg[3] <= 32'hB333_3333;
      awaddrB_q     <= '0;
      bpendingB_q   <= 1'b0;
      rdataB_q      <= '0;
      rpendingB_q   <= 1'b0;
    end else begin
      if (axiB_awvalid)
        awaddrB_q <= axiB_awaddr;
      if (axiB_wvalid)
        slaveB_reg[awaddrB_q[3:2]] <= axiB_wdata;
      if (axiB_wvalid)
        bpendingB_q <= 1'b1;
      else if (axiB_bvalid && axiB_bready)
        bpendingB_q <= 1'b0;
      if (axiB_arvalid) begin
        rdataB_q    <= slaveB_reg[axiB_araddr[3:2]];
        rpendingB_q <= 1'b1;
      end else if (axiB_rvalid && axiB_rready)
        rpendingB_q <= 1'b0;
    end
  // }}} Target B

  // {{{ NI port connections (single driver per element)
  for (genvar i = 0; i < GRID_WIDTH; i++) begin: gen_ni_row
    for (genvar j = 0; j < GRID_WIDTH; j++) begin: gen_ni_col
      if (i == INIT0_ROW && j == INIT0_COL) begin: gen_i0
        always_comb niToRouter[i][j]      = niToRouter_i0;
        always_comb niToRouterValid[i][j] = niToRouterValid_i0;
        always_comb routerToNiReady[i][j] = routerToNiReady_i0;
      end: gen_i0
      else if (i == INIT1_ROW && j == INIT1_COL) begin: gen_i1
        always_comb niToRouter[i][j]      = niToRouter_i1;
        always_comb niToRouterValid[i][j] = niToRouterValid_i1;
        always_comb routerToNiReady[i][j] = routerToNiReady_i1;
      end: gen_i1
      else if (i == TGTA_ROW && j == TGTA_COL) begin: gen_tA
        always_comb niToRouter[i][j]      = niToRouter_tA;
        always_comb niToRouterValid[i][j] = niToRouterValid_tA;
        always_comb routerToNiReady[i][j] = routerToNiReady_tA;
      end: gen_tA
      else if (i == TGTB_ROW && j == TGTB_COL) begin: gen_tB
        always_comb niToRouter[i][j]      = niToRouter_tB;
        always_comb niToRouterValid[i][j] = niToRouterValid_tB;
        always_comb routerToNiReady[i][j] = routerToNiReady_tB;
      end: gen_tB
      else begin: gen_tieoff
        always_comb niToRouter[i][j]      = '0;
        always_comb niToRouterValid[i][j] = 1'b0;
        always_comb routerToNiReady[i][j] = 1'b1;
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

  // {{{ AXI4-Lite protocol checkers (verilaxi)
  // One checker per AXI4-Lite port. Initiators present a subordinate interface
  // (C++ drives AW/W/AR, DUT drives B/R); Targets are managers driving the
  // local subordinate models. All AW/W/AR ready inputs of the target models are
  // tied high, matching the niAxiLiteTarget instantiations above.
  axil_checker #(.ADDR_WIDTH (32), .DATA_WIDTH (32), .LABEL ("AXIL_INIT0"))
  u_axil_chk_i0
  ( .clk (i_clk), .rst_n (i_arst_n)
  , .awaddr (i_awaddr0), .awvalid (i_awvalid0), .awready (o_awready0)
  , .wdata  (i_wdata0),  .wstrb   (i_wstrb0),   .wvalid  (i_wvalid0)
  , .wready (o_wready0)
  , .bresp  (o_bresp0),  .bvalid  (o_bvalid0),  .bready  (i_bready0)
  , .araddr (i_araddr0), .arvalid (i_arvalid0), .arready (o_arready0)
  , .rdata  (o_rdata0),  .rresp   (o_rresp0),   .rvalid  (o_rvalid0)
  , .rready (i_rready0)
  );

  axil_checker #(.ADDR_WIDTH (32), .DATA_WIDTH (32), .LABEL ("AXIL_INIT1"))
  u_axil_chk_i1
  ( .clk (i_clk), .rst_n (i_arst_n)
  , .awaddr (i_awaddr1), .awvalid (i_awvalid1), .awready (o_awready1)
  , .wdata  (i_wdata1),  .wstrb   (i_wstrb1),   .wvalid  (i_wvalid1)
  , .wready (o_wready1)
  , .bresp  (o_bresp1),  .bvalid  (o_bvalid1),  .bready  (i_bready1)
  , .araddr (i_araddr1), .arvalid (i_arvalid1), .arready (o_arready1)
  , .rdata  (o_rdata1),  .rresp   (o_rresp1),   .rvalid  (o_rvalid1)
  , .rready (i_rready1)
  );

  axil_checker #(.ADDR_WIDTH (32), .DATA_WIDTH (32), .LABEL ("AXIL_TGTA"))
  u_axil_chk_tA
  ( .clk (i_clk), .rst_n (i_arst_n)
  , .awaddr (axiA_awaddr), .awvalid (axiA_awvalid), .awready (1'b1)
  , .wdata  (axiA_wdata),  .wstrb   (axiA_wstrb),   .wvalid  (axiA_wvalid)
  , .wready (1'b1)
  , .bresp  (axiA_bresp),  .bvalid  (axiA_bvalid),  .bready  (axiA_bready)
  , .araddr (axiA_araddr), .arvalid (axiA_arvalid), .arready (1'b1)
  , .rdata  (axiA_rdata),  .rresp   (axiA_rresp),   .rvalid  (axiA_rvalid)
  , .rready (axiA_rready)
  );

  axil_checker #(.ADDR_WIDTH (32), .DATA_WIDTH (32), .LABEL ("AXIL_TGTB"))
  u_axil_chk_tB
  ( .clk (i_clk), .rst_n (i_arst_n)
  , .awaddr (axiB_awaddr), .awvalid (axiB_awvalid), .awready (1'b1)
  , .wdata  (axiB_wdata),  .wstrb   (axiB_wstrb),   .wvalid  (axiB_wvalid)
  , .wready (1'b1)
  , .bresp  (axiB_bresp),  .bvalid  (axiB_bvalid),  .bready  (axiB_bready)
  , .araddr (axiB_araddr), .arvalid (axiB_arvalid), .arready (1'b1)
  , .rdata  (axiB_rdata),  .rresp   (axiB_rresp),   .rvalid  (axiB_rvalid)
  , .rready (axiB_rready)
  );
  // }}} AXI4-Lite protocol checkers

endmodule

`resetall
