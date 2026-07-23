// Integration testbench wrapper #2 — NI ID demux (AHB-Lite)
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

module tb_nocAhbIntegration2_top
#(parameter int unsigned GRID_WIDTH        = 4
, parameter int unsigned MAX_NI_PER_ROUTER = 2
, parameter int unsigned INIT_ROW          = 0
, parameter int unsigned INIT_COL          = 0
, parameter int unsigned TGT_ROW           = GRID_WIDTH - 1
, parameter int unsigned TGT_COL           = GRID_WIDTH - 1

, localparam int unsigned COORD_WIDTH   = $clog2(GRID_WIDTH)
, localparam int unsigned NI_ID_WIDTH   = (MAX_NI_PER_ROUTER > 1)
                                          ? $clog2(MAX_NI_PER_ROUTER) : 0
, localparam int unsigned PAYLOAD_WIDTH = pa_noc::AHB_PAYLOAD_WIDTH
, localparam int unsigned PACKET_WIDTH  = PAYLOAD_WIDTH + (2 * NI_ID_WIDTH)
                                          + (COORD_WIDTH * 4)
)
( input  var logic i_clk
, input  var logic i_arst_n

  // Initiator 0 (NI_ID 0) AHB-Lite master interface — driven by C++
, input  var logic [31:0] i_haddr0
, input  var logic [31:0] i_hwdata0
, input  var logic        i_hwrite0
, input  var logic [2:0]  i_hsize0
, input  var logic [1:0]  i_htrans0
, input  var logic        i_hsel0
, output var logic        o_hreadyout0
, output var logic        o_hresp0
, output var logic [31:0] o_hrdata0

  // Initiator 1 (NI_ID 1) AHB-Lite master interface — driven by C++
, input  var logic [31:0] i_haddr1
, input  var logic [31:0] i_hwdata1
, input  var logic        i_hwrite1
, input  var logic [2:0]  i_hsize1
, input  var logic [1:0]  i_htrans1
, input  var logic        i_hsel1
, output var logic        o_hreadyout1
, output var logic        o_hresp1
, output var logic [31:0] o_hrdata1
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
  // HREADY of the single-slave AHB port is the NI's own HREADYOUT.
  logic i0_hreadyout;

  niAhbInitiator
  #(.GRID_WIDTH            (GRID_WIDTH)
  , .NUM_ADDR_MAP_ENTRIES  (NUM_ENTRIES)
  , .ADDR_MAP              (ADDR_MAP)
  , .SRC_ROW               (INIT_ROW)
  , .SRC_COL               (INIT_COL)
  , .MAX_NI_PER_ROUTER     (MAX_NI_PER_ROUTER)
  , .NI_ID                 (0)
  ) u_init0
  ( .i_clk       (i_clk)
  , .i_arst_n    (i_arst_n)

  , .i_haddr     (i_haddr0)
  , .i_hwrite    (i_hwrite0)
  , .i_hsize     (i_hsize0)
  , .i_htrans    (i_htrans0)
  , .i_hwdata    (i_hwdata0)
  , .i_hsel      (i_hsel0)
  , .i_hready    (i0_hreadyout)
  , .o_hreadyout (i0_hreadyout)
  , .o_hresp     (o_hresp0)
  , .o_hrdata    (o_hrdata0)

  , .o_niToRouter      (i0_niToRouter)
  , .o_niToRouterValid (i0_niToRouterValid)
  , .i_niToRouterReady (i0_niToRouterReady)

  , .i_routerToNi      (i0_routerToNi)
  , .i_routerToNiValid (i0_routerToNiValid)
  , .o_routerToNiReady (i0_routerToNiReady)
  );

  always_comb
    o_hreadyout0 = i0_hreadyout;
  // }}} Initiator 0

  // {{{ Initiator 1 (NI_ID 1)
  logic i1_hreadyout;

  niAhbInitiator
  #(.GRID_WIDTH            (GRID_WIDTH)
  , .NUM_ADDR_MAP_ENTRIES  (NUM_ENTRIES)
  , .ADDR_MAP              (ADDR_MAP)
  , .SRC_ROW               (INIT_ROW)
  , .SRC_COL               (INIT_COL)
  , .MAX_NI_PER_ROUTER     (MAX_NI_PER_ROUTER)
  , .NI_ID                 (1)
  ) u_init1
  ( .i_clk       (i_clk)
  , .i_arst_n    (i_arst_n)

  , .i_haddr     (i_haddr1)
  , .i_hwrite    (i_hwrite1)
  , .i_hsize     (i_hsize1)
  , .i_htrans    (i_htrans1)
  , .i_hwdata    (i_hwdata1)
  , .i_hsel      (i_hsel1)
  , .i_hready    (i1_hreadyout)
  , .o_hreadyout (i1_hreadyout)
  , .o_hresp     (o_hresp1)
  , .o_hrdata    (o_hrdata1)

  , .o_niToRouter      (i1_niToRouter)
  , .o_niToRouterValid (i1_niToRouterValid)
  , .i_niToRouterReady (i1_niToRouterReady)

  , .i_routerToNi      (i1_routerToNi)
  , .i_routerToNiValid (i1_routerToNiValid)
  , .o_routerToNiReady (i1_routerToNiReady)
  );

  always_comb
    o_hreadyout1 = i1_hreadyout;
  // }}} Initiator 1

  // {{{ Target A (NI_ID 0) + AHB slave
  logic [31:0] ahbA_haddr;
  logic [31:0] ahbA_hwdata;
  logic        ahbA_hwrite;
  logic [2:0]  ahbA_hsize;
  logic [1:0]  ahbA_htrans;
  logic        ahbA_hsel;
  logic [31:0] ahbA_hrdata;
  logic        ahbA_hready;
  logic        ahbA_hresp;

  niAhbTarget
  #(.GRID_WIDTH        (GRID_WIDTH)
  , .MY_ROW            (TGT_ROW)
  , .MY_COL            (TGT_COL)
  , .MAX_NI_PER_ROUTER (MAX_NI_PER_ROUTER)
  , .NI_ID             (0)
  ) u_tgtA
  ( .i_clk     (i_clk)
  , .i_arst_n  (i_arst_n)

  , .o_hsel    (ahbA_hsel)
  , .o_haddr   (ahbA_haddr)
  , .o_hwrite  (ahbA_hwrite)
  , .o_hsize   (ahbA_hsize)
  , .o_htrans  (ahbA_htrans)
  , .o_hwdata  (ahbA_hwdata)
  , .i_hrdata  (ahbA_hrdata)
  , .i_hready  (ahbA_hready)
  , .i_hresp   (ahbA_hresp)

  , .i_routerToNi      (tA_routerToNi)
  , .i_routerToNiValid (tA_routerToNiValid)
  , .o_routerToNiReady (tA_routerToNiReady)

  , .o_niToRouter      (tA_niToRouter)
  , .o_niToRouterValid (tA_niToRouterValid)
  , .i_niToRouterReady (tA_niToRouterReady)
  );

  // Simple zero-wait-state AHB-Lite slave for Target A: 4 word registers.
  logic [31:0] slaveA_reg [0:3];
  logic        dphaseA_wr;
  logic [1:0]  dphaseA_addr;

  always_comb
    ahbA_hready = 1'b1;

  always_comb
    ahbA_hresp = 1'b0;

  always_comb
    ahbA_hrdata = slaveA_reg[dphaseA_addr];

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n) begin
      slaveA_reg[0] <= 32'hA000_0000;
      slaveA_reg[1] <= 32'hA111_1111;
      slaveA_reg[2] <= 32'hA222_2222;
      slaveA_reg[3] <= 32'hA333_3333;
      dphaseA_wr    <= 1'b0;
      dphaseA_addr  <= '0;
    end else begin
      if (dphaseA_wr)
        slaveA_reg[dphaseA_addr] <= ahbA_hwdata;

      if (ahbA_hsel && ahbA_htrans[1]) begin
        dphaseA_addr <= ahbA_haddr[3:2];
        dphaseA_wr   <= ahbA_hwrite;
      end else begin
        dphaseA_wr   <= 1'b0;
      end
    end
  // }}} Target A

  // {{{ Target B (NI_ID 1) + AHB slave
  logic [31:0] ahbB_haddr;
  logic [31:0] ahbB_hwdata;
  logic        ahbB_hwrite;
  logic [2:0]  ahbB_hsize;
  logic [1:0]  ahbB_htrans;
  logic        ahbB_hsel;
  logic [31:0] ahbB_hrdata;
  logic        ahbB_hready;
  logic        ahbB_hresp;

  niAhbTarget
  #(.GRID_WIDTH        (GRID_WIDTH)
  , .MY_ROW            (TGT_ROW)
  , .MY_COL            (TGT_COL)
  , .MAX_NI_PER_ROUTER (MAX_NI_PER_ROUTER)
  , .NI_ID             (1)
  ) u_tgtB
  ( .i_clk     (i_clk)
  , .i_arst_n  (i_arst_n)

  , .o_hsel    (ahbB_hsel)
  , .o_haddr   (ahbB_haddr)
  , .o_hwrite  (ahbB_hwrite)
  , .o_hsize   (ahbB_hsize)
  , .o_htrans  (ahbB_htrans)
  , .o_hwdata  (ahbB_hwdata)
  , .i_hrdata  (ahbB_hrdata)
  , .i_hready  (ahbB_hready)
  , .i_hresp   (ahbB_hresp)

  , .i_routerToNi      (tB_routerToNi)
  , .i_routerToNiValid (tB_routerToNiValid)
  , .o_routerToNiReady (tB_routerToNiReady)

  , .o_niToRouter      (tB_niToRouter)
  , .o_niToRouterValid (tB_niToRouterValid)
  , .i_niToRouterReady (tB_niToRouterReady)
  );

  // Simple zero-wait-state AHB-Lite slave for Target B: 4 word registers.
  logic [31:0] slaveB_reg [0:3];
  logic        dphaseB_wr;
  logic [1:0]  dphaseB_addr;

  always_comb
    ahbB_hready = 1'b1;

  always_comb
    ahbB_hresp = 1'b0;

  always_comb
    ahbB_hrdata = slaveB_reg[dphaseB_addr];

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n) begin
      slaveB_reg[0] <= 32'hB000_0000;
      slaveB_reg[1] <= 32'hB111_1111;
      slaveB_reg[2] <= 32'hB222_2222;
      slaveB_reg[3] <= 32'hB333_3333;
      dphaseB_wr    <= 1'b0;
      dphaseB_addr  <= '0;
    end else begin
      if (dphaseB_wr)
        slaveB_reg[dphaseB_addr] <= ahbB_hwdata;

      if (ahbB_hsel && ahbB_htrans[1]) begin
        dphaseB_addr <= ahbB_haddr[3:2];
        dphaseB_wr   <= ahbB_hwrite;
      end else begin
        dphaseB_wr   <= 1'b0;
      end
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
