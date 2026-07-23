// Integration testbench wrapper
// Instantiates the NOC with TWO niAhbInitiator masters (on different routers)
// and TWO niAhbTarget slaves (on different routers).  Both initiators share an
// address map that can reach either target, so this exercises concurrent
// multi-initiator / multi-target traffic and the dynamic source-based response
// routing of niAhbTarget.
//
// Node placement (default 4x4 grid):
//   Initiator 0 : (0,0)              Target A : (0, GRID_WIDTH-1)
//   Initiator 1 : (GW-1,GW-1)        Target B : (GRID_WIDTH-1, 0)
//
// Address map (shared by both initiators):
//   0x0000_0000 - 0x0FFF_FFFF -> Target A
//   0x1000_0000 - 0x1FFF_FFFF -> Target B

`default_nettype none

module tb_nocAhbIntegration1_top
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
, localparam int unsigned PAYLOAD_WIDTH = pa_noc::AHB_PAYLOAD_WIDTH
, localparam int unsigned PACKET_WIDTH  = PAYLOAD_WIDTH + (COORD_WIDTH * 4)
)
( input  var logic i_clk
, input  var logic i_arst_n

  // Initiator 0 AHB-Lite master interface — driven by C++
, input  var logic [31:0] i_haddr0
, input  var logic [31:0] i_hwdata0
, input  var logic        i_hwrite0
, input  var logic [2:0]  i_hsize0
, input  var logic [1:0]  i_htrans0
, input  var logic        i_hsel0
, output var logic        o_hreadyout0
, output var logic        o_hresp0
, output var logic [31:0] o_hrdata0

  // Initiator 1 AHB-Lite master interface — driven by C++
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

  // {{{ Initiator 0 NI — router-side signals
  logic [PACKET_WIDTH-1:0] niToRouter_i0;
  logic                    niToRouterValid_i0;
  logic                    niToRouterReady_i0;
  logic [PACKET_WIDTH-1:0] routerToNi_i0;
  logic                    routerToNiValid_i0;
  logic                    routerToNiReady_i0;

  // HREADY of the single-slave AHB port is the NI's own HREADYOUT.
  logic                    ahb0_hreadyout;

  always_comb
    niToRouterReady_i0 = niToRouterReady[INIT0_ROW][INIT0_COL];

  always_comb
    routerToNi_i0 = routerToNi[INIT0_ROW][INIT0_COL];

  always_comb
    routerToNiValid_i0 = routerToNiValid[INIT0_ROW][INIT0_COL];

  niAhbInitiator
  #(.GRID_WIDTH            (GRID_WIDTH)
  , .NUM_ADDR_MAP_ENTRIES  (NUM_ENTRIES)
  , .ADDR_MAP              (ADDR_MAP)
  , .SRC_ROW               (INIT0_ROW)
  , .SRC_COL               (INIT0_COL)
  ) u_init0
  ( .i_clk       (i_clk)
  , .i_arst_n    (i_arst_n)

  , .i_haddr     (i_haddr0)
  , .i_hwrite    (i_hwrite0)
  , .i_hsize     (i_hsize0)
  , .i_htrans    (i_htrans0)
  , .i_hwdata    (i_hwdata0)
  , .i_hsel      (i_hsel0)
  , .i_hready    (ahb0_hreadyout)
  , .o_hreadyout (ahb0_hreadyout)
  , .o_hresp     (o_hresp0)
  , .o_hrdata    (o_hrdata0)

  , .o_niToRouter      (niToRouter_i0)
  , .o_niToRouterValid (niToRouterValid_i0)
  , .i_niToRouterReady (niToRouterReady_i0)

  , .i_routerToNi      (routerToNi_i0)
  , .i_routerToNiValid (routerToNiValid_i0)
  , .o_routerToNiReady (routerToNiReady_i0)
  );

  always_comb
    o_hreadyout0 = ahb0_hreadyout;
  // }}} Initiator 0

  // {{{ Initiator 1 NI — router-side signals
  logic [PACKET_WIDTH-1:0] niToRouter_i1;
  logic                    niToRouterValid_i1;
  logic                    niToRouterReady_i1;
  logic [PACKET_WIDTH-1:0] routerToNi_i1;
  logic                    routerToNiValid_i1;
  logic                    routerToNiReady_i1;

  logic                    ahb1_hreadyout;

  always_comb
    niToRouterReady_i1 = niToRouterReady[INIT1_ROW][INIT1_COL];

  always_comb
    routerToNi_i1 = routerToNi[INIT1_ROW][INIT1_COL];

  always_comb
    routerToNiValid_i1 = routerToNiValid[INIT1_ROW][INIT1_COL];

  niAhbInitiator
  #(.GRID_WIDTH            (GRID_WIDTH)
  , .NUM_ADDR_MAP_ENTRIES  (NUM_ENTRIES)
  , .ADDR_MAP              (ADDR_MAP)
  , .SRC_ROW               (INIT1_ROW)
  , .SRC_COL               (INIT1_COL)
  ) u_init1
  ( .i_clk       (i_clk)
  , .i_arst_n    (i_arst_n)

  , .i_haddr     (i_haddr1)
  , .i_hwrite    (i_hwrite1)
  , .i_hsize     (i_hsize1)
  , .i_htrans    (i_htrans1)
  , .i_hwdata    (i_hwdata1)
  , .i_hsel      (i_hsel1)
  , .i_hready    (ahb1_hreadyout)
  , .o_hreadyout (ahb1_hreadyout)
  , .o_hresp     (o_hresp1)
  , .o_hrdata    (o_hrdata1)

  , .o_niToRouter      (niToRouter_i1)
  , .o_niToRouterValid (niToRouterValid_i1)
  , .i_niToRouterReady (niToRouterReady_i1)

  , .i_routerToNi      (routerToNi_i1)
  , .i_routerToNiValid (routerToNiValid_i1)
  , .o_routerToNiReady (routerToNiReady_i1)
  );

  always_comb
    o_hreadyout1 = ahb1_hreadyout;
  // }}} Initiator 1

  // {{{ Target A NI + AHB slave
  logic [PACKET_WIDTH-1:0] niToRouter_tA;
  logic                    niToRouterValid_tA;
  logic                    niToRouterReady_tA;
  logic [PACKET_WIDTH-1:0] routerToNi_tA;
  logic                    routerToNiValid_tA;
  logic                    routerToNiReady_tA;

  logic [31:0] ahbA_haddr;
  logic [31:0] ahbA_hwdata;
  logic        ahbA_hwrite;
  logic [2:0]  ahbA_hsize;
  logic [1:0]  ahbA_htrans;
  logic        ahbA_hsel;
  logic [31:0] ahbA_hrdata;
  logic        ahbA_hready;
  logic        ahbA_hresp;

  always_comb
    routerToNi_tA = routerToNi[TGTA_ROW][TGTA_COL];

  always_comb
    routerToNiValid_tA = routerToNiValid[TGTA_ROW][TGTA_COL];

  always_comb
    niToRouterReady_tA = niToRouterReady[TGTA_ROW][TGTA_COL];

  niAhbTarget
  #(.GRID_WIDTH (GRID_WIDTH)
  , .MY_ROW     (TGTA_ROW)
  , .MY_COL     (TGTA_COL)
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

  , .i_routerToNi      (routerToNi_tA)
  , .i_routerToNiValid (routerToNiValid_tA)
  , .o_routerToNiReady (routerToNiReady_tA)

  , .o_niToRouter      (niToRouter_tA)
  , .o_niToRouterValid (niToRouterValid_tA)
  , .i_niToRouterReady (niToRouterReady_tA)
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

  // {{{ Target B NI + AHB slave
  logic [PACKET_WIDTH-1:0] niToRouter_tB;
  logic                    niToRouterValid_tB;
  logic                    niToRouterReady_tB;
  logic [PACKET_WIDTH-1:0] routerToNi_tB;
  logic                    routerToNiValid_tB;
  logic                    routerToNiReady_tB;

  logic [31:0] ahbB_haddr;
  logic [31:0] ahbB_hwdata;
  logic        ahbB_hwrite;
  logic [2:0]  ahbB_hsize;
  logic [1:0]  ahbB_htrans;
  logic        ahbB_hsel;
  logic [31:0] ahbB_hrdata;
  logic        ahbB_hready;
  logic        ahbB_hresp;

  always_comb
    routerToNi_tB = routerToNi[TGTB_ROW][TGTB_COL];

  always_comb
    routerToNiValid_tB = routerToNiValid[TGTB_ROW][TGTB_COL];

  always_comb
    niToRouterReady_tB = niToRouterReady[TGTB_ROW][TGTB_COL];

  niAhbTarget
  #(.GRID_WIDTH (GRID_WIDTH)
  , .MY_ROW     (TGTB_ROW)
  , .MY_COL     (TGTB_COL)
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

  , .i_routerToNi      (routerToNi_tB)
  , .i_routerToNiValid (routerToNiValid_tB)
  , .o_routerToNiReady (routerToNiReady_tB)

  , .o_niToRouter      (niToRouter_tB)
  , .o_niToRouterValid (niToRouterValid_tB)
  , .i_niToRouterReady (niToRouterReady_tB)
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

  // {{{ NOC
  noc
  #(.GRID_WIDTH (GRID_WIDTH)
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
  // }}} NOC

endmodule

`resetall
