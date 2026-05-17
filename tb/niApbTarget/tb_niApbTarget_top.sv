// Testbench wrapper
// This module instantiates the NOC and connects a single Apb Target NI
// at router (DST_ROW, DST_COL).  The C++ testbench injects NoC packets at
// a source router (SRC_ROW, SRC_COL), and the niApbTarget drives APB
// transactions to a simple slave model. For reads, the response packet is
// observed back at the source router NI output.

`default_nettype none

module tb_niApbTarget_top
  import pa_noc::*;
#(parameter int unsigned GRID_WIDTH                = 4
, parameter int unsigned SRC_ROW                   = 0
, parameter int unsigned SRC_COL                   = 0
, parameter int unsigned DST_ROW                   = 1
, parameter int unsigned DST_COL                   = 1
, parameter int unsigned MAX_INITIATORS_PER_ROUTER = pa_noc::MAX_INITIATORS_PER_ROUTER

, localparam int unsigned COORD_WIDTH    = $clog2(GRID_WIDTH)
, localparam int unsigned ID_WIDTH       = (MAX_INITIATORS_PER_ROUTER > 1) ? $clog2(MAX_INITIATORS_PER_ROUTER) : 0
, localparam int unsigned PAYLOAD_WIDTH  = APB_PAYLOAD_WIDTH
, localparam int unsigned PACKET_WIDTH   = PAYLOAD_WIDTH + ID_WIDTH + (COORD_WIDTH * 4)
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

  // APB slave monitor — observe what niApbTarget drives
, output var logic [31:0] o_paddr
, output var logic [31:0] o_pwdata
, output var logic        o_pwrite
, output var logic [3:0]  o_pstrb
, output var logic        o_psel
, output var logic        o_penable
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

  // {{{ niApbTarget at (DST_ROW, DST_COL)
  logic [PACKET_WIDTH-1:0] niToRouter_dst;
  logic                    niToRouterValid_dst;
  logic                    niToRouterReady_dst;
  logic [PACKET_WIDTH-1:0] routerToNi_dst;
  logic                    routerToNiValid_dst;
  logic                    routerToNiReady_dst;

  // APB signals between niApbTarget and simple slave
  logic [31:0] apb_paddr;
  logic [31:0] apb_pwdata;
  logic        apb_pwrite;
  logic [3:0]  apb_pstrb;
  logic        apb_psel;
  logic        apb_penable;
  logic        apb_pready;
  logic        apb_pslverr;
  logic [31:0] apb_prdata;

  always_comb
    routerToNi_dst = routerToNi[DST_ROW][DST_COL];

  always_comb
    routerToNiValid_dst = routerToNiValid[DST_ROW][DST_COL];

  always_comb
    niToRouterReady_dst = niToRouterReady[DST_ROW][DST_COL];

  niApbTarget
  #(.GRID_WIDTH                (GRID_WIDTH)
  , .MY_ROW                    (DST_ROW)
  , .MY_COL                    (DST_COL)
  , .MAX_INITIATORS_PER_ROUTER (MAX_INITIATORS_PER_ROUTER)
  ) u_niApbTarget
  ( .i_clk     (i_clk)
  , .i_arst_n  (i_arst_n)

  , .o_paddr   (apb_paddr)
  , .o_pwdata  (apb_pwdata)
  , .o_pwrite  (apb_pwrite)
  , .o_pstrb   (apb_pstrb)
  , .o_psel    (apb_psel)
  , .o_penable (apb_penable)
  , .i_pready  (apb_pready)
  , .i_pslverr (apb_pslverr)
  , .i_prdata  (apb_prdata)

  , .i_routerToNi      (routerToNi_dst)
  , .i_routerToNiValid (routerToNiValid_dst)
  , .o_routerToNiReady (routerToNiReady_dst)

  , .o_niToRouter      (niToRouter_dst)
  , .o_niToRouterValid (niToRouterValid_dst)
  , .i_niToRouterReady (niToRouterReady_dst)
  );
  // }}} niApbTarget at (DST_ROW, DST_COL)

  // {{{ Simple APB slave model
  // Writes: accept immediately (PREADY=1 on access phase), store data.
  // Reads: return stored data at the addressed location.
  // 4 registers at word-aligned addresses (bits [3:2] select register).
  logic [31:0] slave_reg [0:3];

  always_comb
    apb_pslverr = 1'b0;

  always_comb
    apb_pready = apb_psel && apb_penable;

  always_comb
    apb_prdata = slave_reg[apb_paddr[3:2]];

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n) begin
      slave_reg[0] <= 32'hAAAA_0000;
      slave_reg[1] <= 32'hBBBB_1111;
      slave_reg[2] <= 32'hCCCC_2222;
      slave_reg[3] <= 32'hDDDD_3333;
    end else if (apb_psel && apb_penable && apb_pwrite) begin
      slave_reg[apb_paddr[3:2]] <= apb_pwdata;
    end
  // }}} Simple APB slave model

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
    o_paddr = apb_paddr;

  always_comb
    o_pwdata = apb_pwdata;

  always_comb
    o_pwrite = apb_pwrite;

  always_comb
    o_pstrb = apb_pstrb;

  always_comb
    o_psel = apb_psel;

  always_comb
    o_penable = apb_penable;
  // }}} Monitor outputs

endmodule

`resetall
