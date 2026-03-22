// This module interconnects the router to form a mesh network. Below, is an
// example of how routers in a 4x4 mesh network are interconnected. The arrows
// indicate the direction of data flow.

//                                     North
//     router[0][0] <--> router[0][1] <--> router[0][2] <--> router[0][3]
//        ^                 ^                  ^                 ^
//        |                 |                  |                 |
//        v                 v                  v                 v
//     router[1][0] <--> router[1][1] <--> router[1][2] <--> router[1][3]
//        ^                 ^                 ^                 ^
// West   |                 |                 |                 |        East
//        v                 v                 v                 v
//     router[2][0] <--> router[2][1] <--> router[2][2] <--> router[2][3]
//        ^                 ^                 ^                 ^
//        |                 |                 |                 |
//        v                 v                 v                 v
//     router[3][0] <--> router[3][1] <--> router[3][2] <--> router[3][3]
//                                    South

`default_nettype none

module mesh
#(parameter int unsigned GRID_WIDTH = 4
, localparam int unsigned PACKET_WIDTH = pa_noc::PACKET_WIDTH
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

  /* verilator lint_off UNUSED */
  // Inputs to router from neighboring routers
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0][PACKET_WIDTH-1:0] northInput;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0][PACKET_WIDTH-1:0] southInput;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0][PACKET_WIDTH-1:0] eastInput;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0][PACKET_WIDTH-1:0] westInput;

  // Outputs from router to neighboring routers
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0][PACKET_WIDTH-1:0] northOutput;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0][PACKET_WIDTH-1:0] southOutput;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0][PACKET_WIDTH-1:0] eastOutput;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0][PACKET_WIDTH-1:0] westOutput;

  // Valid signals (follow data direction)
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0] northInputValid;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0] southInputValid;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0] eastInputValid;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0] westInputValid;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0] northOutputValid;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0] southOutputValid;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0] eastOutputValid;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0] westOutputValid;

  // Ready signals (opposite to data direction)
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0] northInputReady;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0] southInputReady;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0] eastInputReady;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0] westInputReady;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0] northOutputReady;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0] southOutputReady;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0] eastOutputReady;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0] westOutputReady;
  /* verilator lint_on UNUSED */

  // {{{ Tie off edge router input connections
  // North and south edges: iterate over columns
  for (genvar col = 0; col < GRID_WIDTH; col++) begin: tieOffNorthSouth

    // North edge
    always_comb
      northInput[0][col] = '0;
    always_comb
      northInputValid[0][col] = '0;
    always_comb
      northOutputReady[0][col] = '0;

    // South edge
    always_comb
      southInput[GRID_WIDTH-1][col] = '0;
    always_comb
      southInputValid[GRID_WIDTH-1][col] = '0;
    always_comb
      southOutputReady[GRID_WIDTH-1][col] = '0;

  end: tieOffNorthSouth

  // East and west edges: iterate over rows
  for (genvar row = 0; row < GRID_WIDTH; row++) begin: tieOffEastWest

    // East edge
    always_comb
      eastInput[row][GRID_WIDTH-1] = '0;
    always_comb
      eastInputValid[row][GRID_WIDTH-1] = '0;
    always_comb
      eastOutputReady[row][GRID_WIDTH-1] = '0;

    // West edge
    always_comb
      westInput[row][0] = '0;
    always_comb
      westInputValid[row][0] = '0;
    always_comb
      westOutputReady[row][0] = '0;

  end: tieOffEastWest
  // }}} Tie off edge router input connections

  // {{{ Router interconnections
  // North-South connections
  for (genvar row = 1; row < GRID_WIDTH; row++) begin: connectNorth
    for (genvar col = 0; col < GRID_WIDTH; col++) begin: connectNorthCols
      always_comb
        northInput[row][col] = southOutput[row-1][col];
      always_comb
        northInputValid[row][col] = southOutputValid[row-1][col];
      always_comb
        southOutputReady[row-1][col] = northInputReady[row][col];
    end: connectNorthCols
  end: connectNorth

  for (genvar row = 0; row < GRID_WIDTH-1; row++) begin: connectSouth
    for (genvar col = 0; col < GRID_WIDTH; col++) begin: connectSouthCols
      always_comb
        southInput[row][col] = northOutput[row+1][col];
      always_comb
        southInputValid[row][col] = northOutputValid[row+1][col];
      always_comb
        northOutputReady[row+1][col] = southInputReady[row][col];
    end: connectSouthCols
  end: connectSouth

  // East-West connections
  for (genvar row = 0; row < GRID_WIDTH; row++) begin: connectEast
    for (genvar col = 0; col < GRID_WIDTH-1; col++) begin: connectEastCols
      always_comb
        eastInput[row][col] = westOutput[row][col+1];
      always_comb
        eastInputValid[row][col] = westOutputValid[row][col+1];
      always_comb
        westOutputReady[row][col+1] = eastInputReady[row][col];
    end: connectEastCols
  end: connectEast

  for (genvar row = 0; row < GRID_WIDTH; row++) begin: connectWest
    for (genvar col = 1; col < GRID_WIDTH; col++) begin: connectWestCols
      always_comb
        westInput[row][col] = eastOutput[row][col-1];
      always_comb
        westInputValid[row][col] = eastOutputValid[row][col-1];
      always_comb
        eastOutputReady[row][col-1] = westInputReady[row][col];
    end: connectWestCols
  end: connectWest
  // }}} Router interconnections

  // {{{ Mesh
  for (genvar row = 0; row < GRID_WIDTH; row++) begin: perRow
    for (genvar col = 0; col < GRID_WIDTH; col++) begin: perCol

      router
      #(.ROUTER_ROW (row)
      , .ROUTER_COL (col)
      , .GRID_WIDTH (GRID_WIDTH)
      ) u_router
      ( .i_clk    (i_clk)
      , .i_arst_n (i_arst_n)

      , .i_ni      (i_niToRouter[row][col])
      , .i_niValid (i_niToRouterValid[row][col])
      , .o_niReady (o_niToRouterReady[row][col])

      , .o_ni      (o_routerToNi[row][col])
      , .o_niValid (o_routerToNiValid[row][col])
      , .i_niReady (i_routerToNiReady[row][col])

      , .i_north      (northInput[row][col])
      , .i_northValid (northInputValid[row][col])
      , .o_northReady (northInputReady[row][col])

      , .i_south      (southInput[row][col])
      , .i_southValid (southInputValid[row][col])
      , .o_southReady (southInputReady[row][col])

      , .i_east      (eastInput[row][col])
      , .i_eastValid (eastInputValid[row][col])
      , .o_eastReady (eastInputReady[row][col])

      , .i_west      (westInput[row][col])
      , .i_westValid (westInputValid[row][col])
      , .o_westReady (westInputReady[row][col])

      , .o_north      (northOutput[row][col])
      , .o_northValid (northOutputValid[row][col])
      , .i_northReady (northOutputReady[row][col])

      , .o_south      (southOutput[row][col])
      , .o_southValid (southOutputValid[row][col])
      , .i_southReady (southOutputReady[row][col])

      , .o_east      (eastOutput[row][col])
      , .o_eastValid (eastOutputValid[row][col])
      , .i_eastReady (eastOutputReady[row][col])

      , .o_west      (westOutput[row][col])
      , .o_westValid (westOutputValid[row][col])
      , .i_westReady (westOutputReady[row][col])
      );

    end: perCol
  end: perRow
  // }}} Mesh

endmodule

`resetall
