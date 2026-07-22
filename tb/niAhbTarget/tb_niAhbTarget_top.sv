// Testbench wrapper
// This module instantiates the NOC and connects a single Ahb Target NI
// at router (DST_ROW, DST_COL).  The C++ testbench injects NoC packets at
// a source router (SRC_ROW, SRC_COL), and the niAhbTarget drives AHB-Lite
// transactions to a simple slave model. For reads, the response packet is
// observed back at the source router NI output.

`default_nettype none

module tb_niAhbTarget_top
#(parameter int unsigned GRID_WIDTH        = 4
, parameter int unsigned SRC_ROW           = 0
, parameter int unsigned SRC_COL           = 0
, parameter int unsigned DST_ROW           = 1
, parameter int unsigned DST_COL           = 1
, parameter int unsigned MAX_NI_PER_ROUTER = pa_noc::MAX_NI_PER_ROUTER

, localparam int unsigned COORD_WIDTH    = $clog2(GRID_WIDTH)
, localparam int unsigned NI_ID_WIDTH    = (MAX_NI_PER_ROUTER > 1) ? $clog2(MAX_NI_PER_ROUTER) : 0
, localparam int unsigned PAYLOAD_WIDTH  = pa_noc::AHB_PAYLOAD_WIDTH
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

  // AHB slave monitor — observe what niAhbTarget drives
, output var logic [31:0] o_haddr
, output var logic [31:0] o_hwdata
, output var logic        o_hwrite
, output var logic [2:0]  o_hsize
, output var logic [1:0]  o_htrans
, output var logic        o_hsel
);

  // {{{ Interconnects
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0][PACKET_WIDTH-1:0] niToRouter;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0]                   niToRouterValid;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0]                   niToRouterReady;

  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0][PACKET_WIDTH-1:0] routerToNi;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0]                   routerToNiValid;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0]                   routerToNiReady;
  // }}} Interconnects

  // {{{ Source NI port — readback signals
  always_comb
    o_srcNiToRouterReady = niToRouterReady[SRC_ROW][SRC_COL];

  always_comb
    o_srcRouterToNi = routerToNi[SRC_ROW][SRC_COL];

  always_comb
    o_srcRouterToNiValid = routerToNiValid[SRC_ROW][SRC_COL];
  // }}} Source NI port

  // {{{ niAhbTarget at (DST_ROW, DST_COL)
  logic [PACKET_WIDTH-1:0] niToRouter_dst;
  logic                    niToRouterValid_dst;
  logic                    niToRouterReady_dst;
  logic [PACKET_WIDTH-1:0] routerToNi_dst;
  logic                    routerToNiValid_dst;
  logic                    routerToNiReady_dst;

  // AHB signals between niAhbTarget (master) and the simple slave
  logic [31:0] ahb_haddr;
  logic [31:0] ahb_hwdata;
  logic        ahb_hwrite;
  logic [2:0]  ahb_hsize;
  logic [1:0]  ahb_htrans;
  logic        ahb_hsel;
  logic [31:0] ahb_hrdata;
  logic        ahb_hready;
  logic        ahb_hresp;

  always_comb
    routerToNi_dst = routerToNi[DST_ROW][DST_COL];

  always_comb
    routerToNiValid_dst = routerToNiValid[DST_ROW][DST_COL];

  always_comb
    niToRouterReady_dst = niToRouterReady[DST_ROW][DST_COL];

  niAhbTarget
  #(.GRID_WIDTH        (GRID_WIDTH)
  , .MY_ROW            (DST_ROW)
  , .MY_COL            (DST_COL)
  , .MAX_NI_PER_ROUTER (MAX_NI_PER_ROUTER)
  ) u_niAhbTarget
  ( .i_clk     (i_clk)
  , .i_arst_n  (i_arst_n)

  , .o_hsel    (ahb_hsel)
  , .o_haddr   (ahb_haddr)
  , .o_hwrite  (ahb_hwrite)
  , .o_hsize   (ahb_hsize)
  , .o_htrans  (ahb_htrans)
  , .o_hwdata  (ahb_hwdata)
  , .i_hrdata  (ahb_hrdata)
  , .i_hready  (ahb_hready)
  , .i_hresp   (ahb_hresp)

  , .i_routerToNi      (routerToNi_dst)
  , .i_routerToNiValid (routerToNiValid_dst)
  , .o_routerToNiReady (routerToNiReady_dst)

  , .o_niToRouter      (niToRouter_dst)
  , .o_niToRouterValid (niToRouterValid_dst)
  , .i_niToRouterReady (niToRouterReady_dst)
  );
  // }}} niAhbTarget at (DST_ROW, DST_COL)

  // {{{ Simple AHB-Lite slave model (zero wait state)
  // 4 registers at word-aligned addresses (bits [3:2] select register).
  // The AHB address phase (HSEL & HTRANS[1]) captures the register index and
  // the write flag; the following data phase performs the write / read.
  logic [31:0] slave_reg [0:3];
  logic        dphase_wr;
  logic [1:0]  dphase_addr;

  always_comb
    ahb_hready = 1'b1;  // always ready (zero wait state)

  always_comb
    ahb_hresp = 1'b0;   // always OKAY

  always_comb
    ahb_hrdata = slave_reg[dphase_addr];

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n) begin
      slave_reg[0] <= 32'hAAAA_0000;
      slave_reg[1] <= 32'hBBBB_1111;
      slave_reg[2] <= 32'hCCCC_2222;
      slave_reg[3] <= 32'hDDDD_3333;
      dphase_wr    <= 1'b0;
      dphase_addr  <= '0;
    end else begin
      // Data phase: complete the previously captured access (write).
      if (dphase_wr)
        slave_reg[dphase_addr] <= ahb_hwdata;

      // Address phase: capture register index and direction.
      if (ahb_hsel && ahb_htrans[1]) begin
        dphase_addr <= ahb_haddr[3:2];
        dphase_wr   <= ahb_hwrite;
      end else begin
        dphase_wr   <= 1'b0;
      end
    end
  // }}} Simple AHB-Lite slave model

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
  // }}} Tie off remaining NI ports

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

  // {{{ Monitor outputs
  always_comb
    o_haddr = ahb_haddr;

  always_comb
    o_hwdata = ahb_hwdata;

  always_comb
    o_hwrite = ahb_hwrite;

  always_comb
    o_hsize = ahb_hsize;

  always_comb
    o_htrans = ahb_htrans;

  always_comb
    o_hsel = ahb_hsel;
  // }}} Monitor outputs

endmodule

`resetall
