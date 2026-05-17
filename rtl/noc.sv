// Top level module.

// Default: APB Packet Definition (4x4 grid, COORD_WIDTH=2)
// ---------------------------------------------------------------------------------
// |76                             8|7    6|5    4|3              2|1              0|
// |       Payload (69 bits)        |SrcRow|SrcCol|Dst Row (2 bits)|Dst Col (2 bits)|
// ---------------------------------------------------------------------------------

`default_nettype none

module noc
#(parameter int unsigned GRID_WIDTH = 4
, parameter int unsigned PAYLOAD_WIDTH = pa_noc::APB_PAYLOAD_WIDTH
, parameter int unsigned FIFO_ADDRESS_WIDTH = pa_noc::FIFO_ADDRESS_W
, localparam int unsigned PACKET_WIDTH = PAYLOAD_WIDTH + ($clog2(GRID_WIDTH) * 4)
)
( input  var logic i_clk
, input  var logic i_arst_n

, input  var logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0][PACKET_WIDTH-1:0] i_niToRouter
, input  var logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0]                   i_niToRouterValid
, output var logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0]                   o_niToRouterReady

, output var logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0][PACKET_WIDTH-1:0] o_routerToNi
, output var logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0]                   o_routerToNiValid
, input  var logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0]                   i_routerToNiReady
);

  if (GRID_WIDTH < 2) begin: ParamCheck
    $error("Grid width parameter 'GRID_WIDTH' is invalid. Must be at least 2.");
  end: ParamCheck

  mesh
  #(.GRID_WIDTH         (GRID_WIDTH)
  , .PACKET_WIDTH       (PACKET_WIDTH)
  , .FIFO_ADDRESS_WIDTH (FIFO_ADDRESS_WIDTH)
  ) u_mesh
  ( .i_clk    (i_clk)
  , .i_arst_n (i_arst_n)

  , .i_niToRouter      (i_niToRouter)
  , .i_niToRouterValid (i_niToRouterValid)
  , .o_niToRouterReady (o_niToRouterReady)

  , .o_routerToNi      (o_routerToNi)
  , .o_routerToNiValid (o_routerToNiValid)
  , .i_routerToNiReady (i_routerToNiReady)
  );

endmodule

`resetall
