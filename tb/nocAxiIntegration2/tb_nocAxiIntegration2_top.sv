// Integration testbench wrapper #2 — NI ID demux (AXI4-Lite)
//
// This variant proves the MAX_NI_PER_ROUTER > 1 packet format and the NI-ID
// based demultiplexing.  BOTH initiators share a single router NI port, and
// BOTH targets share a single (different) router NI port:
//
//   Router (INIT_ROW,INIT_COL)  hosts  Initiator NI_ID 0  and  Initiator NI_ID 1
//   Router (TGT_ROW ,TGT_COL )  hosts  Target    NI_ID 0  and  Target    NI_ID 1
//
// Because the NOC exposes a single NI port per router, this wrapper implements
// a small shared-port adapter around each shared router port:
//   - NI -> router direction : a fixed-priority arbiter muxes the two NIs onto
//     the single router ingress port.
//   - router -> NI direction : a demux steers each packet to one of the two NIs
//     using the packet's destination NI-ID field.
//
// The address map sends range 0 to target NI_ID 0 and range 1 to target NI_ID 1
// (both at the same router), so correct delivery can only happen if the NI-ID
// demux works in both directions.
//
// Address map (shared by both initiators):
//   0x0000_0000 - 0x0FFF_FFFF -> (TGT_ROW,TGT_COL) NI_ID 0  (Target A)
//   0x1000_0000 - 0x1FFF_FFFF -> (TGT_ROW,TGT_COL) NI_ID 1  (Target B)

`default_nettype none

module tb_nocAxiIntegration2_top
#(parameter int unsigned GRID_WIDTH        = 4
, parameter int unsigned MAX_NI_PER_ROUTER = 2
, parameter int unsigned INIT_ROW          = 0
, parameter int unsigned INIT_COL          = 0
, parameter int unsigned TGT_ROW           = GRID_WIDTH - 1
, parameter int unsigned TGT_COL           = GRID_WIDTH - 1

, localparam int unsigned COORD_WIDTH   = $clog2(GRID_WIDTH)
, localparam int unsigned NI_ID_WIDTH   = (MAX_NI_PER_ROUTER > 1)
                                          ? $clog2(MAX_NI_PER_ROUTER) : 0
, localparam int unsigned PAYLOAD_WIDTH = pa_noc::AXI_LITE_PAYLOAD_WIDTH
, localparam int unsigned PACKET_WIDTH  = PAYLOAD_WIDTH + (2 * NI_ID_WIDTH)
                                          + (COORD_WIDTH * 4)
)
( input  var logic i_clk
, input  var logic i_arst_n

  // Initiator 0 (NI_ID 0) AXI4-Lite subordinate interface — driven by C++
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

  // Initiator 1 (NI_ID 1) AXI4-Lite subordinate interface — driven by C++
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

  // {{{ Address map (shared by both initiators) — both targets on same router
  localparam int unsigned NUM_ENTRIES = 2;

  localparam pa_noc::ty_ADDR_MAP_ENTRY [NUM_ENTRIES-1:0] ADDR_MAP =
    '{
      '{baseAddr: 32'h1000_0000
      , endAddr: 32'h1FFF_FFFF
      , dstRow: 8'(TGT_ROW)
      , dstCol: 8'(TGT_COL)
      , dstNiId: 8'd1
      },
      '{baseAddr: 32'h0000_0000
      , endAddr: 32'h0FFF_FFFF
      , dstRow: 8'(TGT_ROW)
      , dstCol: 8'(TGT_COL)
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

  // {{{ Per-NI router-side signals
  logic [PACKET_WIDTH-1:0] i0_niToRouter, i1_niToRouter;
  logic                    i0_niToRouterValid, i1_niToRouterValid;
  logic                    i0_niToRouterReady, i1_niToRouterReady;
  logic [PACKET_WIDTH-1:0] i0_routerToNi, i1_routerToNi;
  logic                    i0_routerToNiValid, i1_routerToNiValid;
  logic                    i0_routerToNiReady, i1_routerToNiReady;

  logic [PACKET_WIDTH-1:0] tA_niToRouter, tB_niToRouter;
  logic                    tA_niToRouterValid, tB_niToRouterValid;
  logic                    tA_niToRouterReady, tB_niToRouterReady;
  logic [PACKET_WIDTH-1:0] tA_routerToNi, tB_routerToNi;
  logic                    tA_routerToNiValid, tB_routerToNiValid;
  logic                    tA_routerToNiReady, tB_routerToNiReady;
  // }}} Per-NI router-side signals

  // {{{ Initiator 0 (NI_ID 0)
  niAxiLiteInitiator
  #(.GRID_WIDTH            (GRID_WIDTH)
  , .NUM_ADDR_MAP_ENTRIES  (NUM_ENTRIES)
  , .ADDR_MAP              (ADDR_MAP)
  , .SRC_ROW               (INIT_ROW)
  , .SRC_COL               (INIT_COL)
  , .MAX_NI_PER_ROUTER     (MAX_NI_PER_ROUTER)
  , .NI_ID                 (0)
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

  , .o_niToRouter      (i0_niToRouter)
  , .o_niToRouterValid (i0_niToRouterValid)
  , .i_niToRouterReady (i0_niToRouterReady)

  , .i_routerToNi      (i0_routerToNi)
  , .i_routerToNiValid (i0_routerToNiValid)
  , .o_routerToNiReady (i0_routerToNiReady)
  );
  // }}} Initiator 0

  // {{{ Initiator 1 (NI_ID 1)
  niAxiLiteInitiator
  #(.GRID_WIDTH            (GRID_WIDTH)
  , .NUM_ADDR_MAP_ENTRIES  (NUM_ENTRIES)
  , .ADDR_MAP              (ADDR_MAP)
  , .SRC_ROW               (INIT_ROW)
  , .SRC_COL               (INIT_COL)
  , .MAX_NI_PER_ROUTER     (MAX_NI_PER_ROUTER)
  , .NI_ID                 (1)
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

  , .o_niToRouter      (i1_niToRouter)
  , .o_niToRouterValid (i1_niToRouterValid)
  , .i_niToRouterReady (i1_niToRouterReady)

  , .i_routerToNi      (i1_routerToNi)
  , .i_routerToNiValid (i1_routerToNiValid)
  , .o_routerToNiReady (i1_routerToNiReady)
  );
  // }}} Initiator 1

  // {{{ Target A (NI_ID 0) + AXI subordinate
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

  niAxiLiteTarget
  #(.GRID_WIDTH        (GRID_WIDTH)
  , .MY_ROW            (TGT_ROW)
  , .MY_COL            (TGT_COL)
  , .MAX_NI_PER_ROUTER (MAX_NI_PER_ROUTER)
  , .NI_ID             (0)
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

  , .i_routerToNi      (tA_routerToNi)
  , .i_routerToNiValid (tA_routerToNiValid)
  , .o_routerToNiReady (tA_routerToNiReady)

  , .o_niToRouter      (tA_niToRouter)
  , .o_niToRouterValid (tA_niToRouterValid)
  , .i_niToRouterReady (tA_niToRouterReady)
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

  // {{{ Target B (NI_ID 1) + AXI subordinate
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

  niAxiLiteTarget
  #(.GRID_WIDTH        (GRID_WIDTH)
  , .MY_ROW            (TGT_ROW)
  , .MY_COL            (TGT_COL)
  , .MAX_NI_PER_ROUTER (MAX_NI_PER_ROUTER)
  , .NI_ID             (1)
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

  , .i_routerToNi      (tB_routerToNi)
  , .i_routerToNiValid (tB_routerToNiValid)
  , .o_routerToNiReady (tB_routerToNiReady)

  , .o_niToRouter      (tB_niToRouter)
  , .o_niToRouterValid (tB_niToRouterValid)
  , .i_niToRouterReady (tB_niToRouterReady)
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

  // {{{ Packed NI-side views for the two niRouterPort instances
  // Index 0 = NI_ID 0, index 1 = NI_ID 1.
  logic [MAX_NI_PER_ROUTER-1:0][PACKET_WIDTH-1:0] initNiToRouter;
  logic [MAX_NI_PER_ROUTER-1:0]                   initNiToRouterValid;
  logic [MAX_NI_PER_ROUTER-1:0]                   initNiToRouterReady;
  logic [MAX_NI_PER_ROUTER-1:0][PACKET_WIDTH-1:0] initRouterToNi;
  logic [MAX_NI_PER_ROUTER-1:0]                   initRouterToNiValid;
  logic [MAX_NI_PER_ROUTER-1:0]                   initRouterToNiReady;

  logic [MAX_NI_PER_ROUTER-1:0][PACKET_WIDTH-1:0] tgtNiToRouter;
  logic [MAX_NI_PER_ROUTER-1:0]                   tgtNiToRouterValid;
  logic [MAX_NI_PER_ROUTER-1:0]                   tgtNiToRouterReady;
  logic [MAX_NI_PER_ROUTER-1:0][PACKET_WIDTH-1:0] tgtRouterToNi;
  logic [MAX_NI_PER_ROUTER-1:0]                   tgtRouterToNiValid;
  logic [MAX_NI_PER_ROUTER-1:0]                   tgtRouterToNiReady;

  always_comb begin
    initNiToRouter[0]      = i0_niToRouter;
    initNiToRouter[1]      = i1_niToRouter;
    initNiToRouterValid[0] = i0_niToRouterValid;
    initNiToRouterValid[1] = i1_niToRouterValid;
    initRouterToNiReady[0] = i0_routerToNiReady;
    initRouterToNiReady[1] = i1_routerToNiReady;

    i0_niToRouterReady = initNiToRouterReady[0];
    i1_niToRouterReady = initNiToRouterReady[1];
    i0_routerToNi      = initRouterToNi[0];
    i1_routerToNi      = initRouterToNi[1];
    i0_routerToNiValid = initRouterToNiValid[0];
    i1_routerToNiValid = initRouterToNiValid[1];
  end

  always_comb begin
    tgtNiToRouter[0]      = tA_niToRouter;
    tgtNiToRouter[1]      = tB_niToRouter;
    tgtNiToRouterValid[0] = tA_niToRouterValid;
    tgtNiToRouterValid[1] = tB_niToRouterValid;
    tgtRouterToNiReady[0] = tA_routerToNiReady;
    tgtRouterToNiReady[1] = tB_routerToNiReady;

    tA_niToRouterReady = tgtNiToRouterReady[0];
    tB_niToRouterReady = tgtNiToRouterReady[1];
    tA_routerToNi      = tgtRouterToNi[0];
    tB_routerToNi      = tgtRouterToNi[1];
    tA_routerToNiValid = tgtRouterToNiValid[0];
    tB_routerToNiValid = tgtRouterToNiValid[1];
  end
  // }}} Packed NI-side views

  // {{{ niRouterPort instances — shared-port arbitration + NI-ID demux
  // Router-side signals that feed the NOC arrays (driven below).
  logic [PACKET_WIDTH-1:0] initPortToRouter;
  logic                    initPortToRouterValid;
  logic                    initPortFromRouterReady;

  logic [PACKET_WIDTH-1:0] tgtPortToRouter;
  logic                    tgtPortToRouterValid;
  logic                    tgtPortFromRouterReady;

  niRouterPort
  #(.GRID_WIDTH        (GRID_WIDTH)
  , .MAX_NI_PER_ROUTER (MAX_NI_PER_ROUTER)
  , .PAYLOAD_WIDTH     (PAYLOAD_WIDTH)
  ) u_initPort
  ( .i_clk    (i_clk)
  , .i_arst_n (i_arst_n)

  , .o_niToRouter      (initPortToRouter)
  , .o_niToRouterValid (initPortToRouterValid)
  , .i_niToRouterReady (niToRouterReady[INIT_ROW][INIT_COL])
  , .i_routerToNi      (routerToNi[INIT_ROW][INIT_COL])
  , .i_routerToNiValid (routerToNiValid[INIT_ROW][INIT_COL])
  , .o_routerToNiReady (initPortFromRouterReady)

  , .i_niToRouter      (initNiToRouter)
  , .i_niToRouterValid (initNiToRouterValid)
  , .o_niToRouterReady (initNiToRouterReady)
  , .o_routerToNi      (initRouterToNi)
  , .o_routerToNiValid (initRouterToNiValid)
  , .i_routerToNiReady (initRouterToNiReady)
  );

  niRouterPort
  #(.GRID_WIDTH        (GRID_WIDTH)
  , .MAX_NI_PER_ROUTER (MAX_NI_PER_ROUTER)
  , .PAYLOAD_WIDTH     (PAYLOAD_WIDTH)
  ) u_tgtPort
  ( .i_clk    (i_clk)
  , .i_arst_n (i_arst_n)

  , .o_niToRouter      (tgtPortToRouter)
  , .o_niToRouterValid (tgtPortToRouterValid)
  , .i_niToRouterReady (niToRouterReady[TGT_ROW][TGT_COL])
  , .i_routerToNi      (routerToNi[TGT_ROW][TGT_COL])
  , .i_routerToNiValid (routerToNiValid[TGT_ROW][TGT_COL])
  , .o_routerToNiReady (tgtPortFromRouterReady)

  , .i_niToRouter      (tgtNiToRouter)
  , .i_niToRouterValid (tgtNiToRouterValid)
  , .o_niToRouterReady (tgtNiToRouterReady)
  , .o_routerToNi      (tgtRouterToNi)
  , .o_routerToNiValid (tgtRouterToNiValid)
  , .i_routerToNiReady (tgtRouterToNiReady)
  );
  // }}} niRouterPort instances

  // {{{ Drive NOC ingress arrays — exactly one driver per array element
  for (genvar i = 0; i < GRID_WIDTH; i++) begin: gen_ni_row
    for (genvar j = 0; j < GRID_WIDTH; j++) begin: gen_ni_col
      if (i == INIT_ROW && j == INIT_COL) begin: gen_init_port
        always_comb niToRouter[i][j]      = initPortToRouter;
        always_comb niToRouterValid[i][j] = initPortToRouterValid;
        always_comb routerToNiReady[i][j] = initPortFromRouterReady;
      end: gen_init_port
      else if (i == TGT_ROW && j == TGT_COL) begin: gen_tgt_port
        always_comb niToRouter[i][j]      = tgtPortToRouter;
        always_comb niToRouterValid[i][j] = tgtPortToRouterValid;
        always_comb routerToNiReady[i][j] = tgtPortFromRouterReady;
      end: gen_tgt_port
      else begin: gen_tieoff
        always_comb niToRouter[i][j]      = '0;
        always_comb niToRouterValid[i][j] = 1'b0;
        always_comb routerToNiReady[i][j] = 1'b1;
      end: gen_tieoff
    end
  end
  // }}} Drive NOC ingress arrays

  // {{{ NOC
  noc
  #(.GRID_WIDTH        (GRID_WIDTH)
  , .MAX_NI_PER_ROUTER (MAX_NI_PER_ROUTER)
  , .PAYLOAD_WIDTH     (PAYLOAD_WIDTH)
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
  // }}} NOC

endmodule

`resetall
