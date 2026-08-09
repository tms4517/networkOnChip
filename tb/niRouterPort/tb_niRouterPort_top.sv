// Unit-test wrapper for niRouterPort (NUM_NI = 3).
//
// Exposes the module's router-side port and each of the three NI-side ports as
// flat, individually-named signals so the C++ testbench can drive/observe them
// without dealing with packed multi-dimensional arrays.

`default_nettype none

module tb_niRouterPort_top
#(parameter int unsigned GRID_WIDTH        = 4
, parameter int unsigned MAX_NI_PER_ROUTER = 3

, localparam int unsigned NUM_NI        = MAX_NI_PER_ROUTER
, localparam int unsigned COORD_WIDTH   = $clog2(GRID_WIDTH)
, localparam int unsigned NI_ID_WIDTH   = $clog2(MAX_NI_PER_ROUTER)
, localparam int unsigned PAYLOAD_WIDTH = pa_noc::CANON_PAYLOAD_WIDTH
, localparam int unsigned PACKET_WIDTH  = PAYLOAD_WIDTH + (2 * NI_ID_WIDTH)
                                          + (COORD_WIDTH * 4)
)
( input  var logic i_clk
, input  var logic i_arst_n

  // Router side
, output var logic [PACKET_WIDTH-1:0] o_niToRouter
, output var logic                    o_niToRouterValid
, input  var logic                    i_niToRouterReady
, input  var logic [PACKET_WIDTH-1:0] i_routerToNi
, input  var logic                    i_routerToNiValid
, output var logic                    o_routerToNiReady

  // NI 0
, input  var logic [PACKET_WIDTH-1:0] i_ni0ToRouter
, input  var logic                    i_ni0ToRouterValid
, output var logic                    o_ni0ToRouterReady
, output var logic [PACKET_WIDTH-1:0] o_ni0RouterToNi
, output var logic                    o_ni0RouterToNiValid
, input  var logic                    i_ni0RouterToNiReady

  // NI 1
, input  var logic [PACKET_WIDTH-1:0] i_ni1ToRouter
, input  var logic                    i_ni1ToRouterValid
, output var logic                    o_ni1ToRouterReady
, output var logic [PACKET_WIDTH-1:0] o_ni1RouterToNi
, output var logic                    o_ni1RouterToNiValid
, input  var logic                    i_ni1RouterToNiReady

  // NI 2
, input  var logic [PACKET_WIDTH-1:0] i_ni2ToRouter
, input  var logic                    i_ni2ToRouterValid
, output var logic                    o_ni2ToRouterReady
, output var logic [PACKET_WIDTH-1:0] o_ni2RouterToNi
, output var logic                    o_ni2RouterToNiValid
, input  var logic                    i_ni2RouterToNiReady
);

  logic [NUM_NI-1:0][PACKET_WIDTH-1:0] niToRouter;
  logic [NUM_NI-1:0]                   niToRouterValid;
  logic [NUM_NI-1:0]                   niToRouterReady;
  logic [NUM_NI-1:0][PACKET_WIDTH-1:0] routerToNi;
  logic [NUM_NI-1:0]                   routerToNiValid;
  logic [NUM_NI-1:0]                   routerToNiReady;

  always_comb begin
    niToRouter[0]      = i_ni0ToRouter;
    niToRouter[1]      = i_ni1ToRouter;
    niToRouter[2]      = i_ni2ToRouter;
    niToRouterValid[0] = i_ni0ToRouterValid;
    niToRouterValid[1] = i_ni1ToRouterValid;
    niToRouterValid[2] = i_ni2ToRouterValid;
    routerToNiReady[0] = i_ni0RouterToNiReady;
    routerToNiReady[1] = i_ni1RouterToNiReady;
    routerToNiReady[2] = i_ni2RouterToNiReady;
  end

  always_comb begin
    o_ni0ToRouterReady   = niToRouterReady[0];
    o_ni1ToRouterReady   = niToRouterReady[1];
    o_ni2ToRouterReady   = niToRouterReady[2];
    o_ni0RouterToNi      = routerToNi[0];
    o_ni1RouterToNi      = routerToNi[1];
    o_ni2RouterToNi      = routerToNi[2];
    o_ni0RouterToNiValid = routerToNiValid[0];
    o_ni1RouterToNiValid = routerToNiValid[1];
    o_ni2RouterToNiValid = routerToNiValid[2];
  end

  niRouterPort
  #(.GRID_WIDTH        (GRID_WIDTH)
  , .MAX_NI_PER_ROUTER (MAX_NI_PER_ROUTER)
  ) u_dut
  ( .i_clk    (i_clk)
  , .i_arst_n (i_arst_n)

  , .o_niToRouter      (o_niToRouter)
  , .o_niToRouterValid (o_niToRouterValid)
  , .i_niToRouterReady (i_niToRouterReady)
  , .i_routerToNi      (i_routerToNi)
  , .i_routerToNiValid (i_routerToNiValid)
  , .o_routerToNiReady (o_routerToNiReady)

  , .i_niToRouter      (niToRouter)
  , .i_niToRouterValid (niToRouterValid)
  , .o_niToRouterReady (niToRouterReady)
  , .o_routerToNi      (routerToNi)
  , .o_routerToNiValid (routerToNiValid)
  , .i_routerToNiReady (routerToNiReady)
  );

endmodule

`resetall
