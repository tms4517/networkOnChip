// Copyright (c) 2023 Tej Sanghavi.
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
, parameter int unsigned PACKET_WIDTH = 77
, parameter int unsigned FIFO_ADDRESS_WIDTH = pa_noc::FIFO_ADDRESS_W
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
  for (genvar j = 0; j < GRID_WIDTH; j++) begin: tieOffNorthSouth

    // North edge
    always_comb
      northInput[0][j] = '0;
    always_comb
      northInputValid[0][j] = '0;
    always_comb
      northOutputReady[0][j] = '0;

    // South edge
    always_comb
      southInput[GRID_WIDTH-1][j] = '0;
    always_comb
      southInputValid[GRID_WIDTH-1][j] = '0;
    always_comb
      southOutputReady[GRID_WIDTH-1][j] = '0;

  end: tieOffNorthSouth

  // East and west edges: iterate over rows
  for (genvar i = 0; i < GRID_WIDTH; i++) begin: tieOffEastWest

    // East edge
    always_comb
      eastInput[i][GRID_WIDTH-1] = '0;
    always_comb
      eastInputValid[i][GRID_WIDTH-1] = '0;
    always_comb
      eastOutputReady[i][GRID_WIDTH-1] = '0;

    // West edge
    always_comb
      westInput[i][0] = '0;
    always_comb
      westInputValid[i][0] = '0;
    always_comb
      westOutputReady[i][0] = '0;

  end: tieOffEastWest
  // }}} Tie off edge router input connections

  // {{{ Router interconnections
  // North-South connections
  for (genvar i = 1; i < GRID_WIDTH; i++) begin: connectNorth
    for (genvar j = 0; j < GRID_WIDTH; j++) begin: connectNorthCols
      always_comb
        northInput[i][j] = southOutput[i-1][j];
      always_comb
        northInputValid[i][j] = southOutputValid[i-1][j];
      always_comb
        southOutputReady[i-1][j] = northInputReady[i][j];
    end: connectNorthCols
  end: connectNorth

  for (genvar i = 0; i < GRID_WIDTH-1; i++) begin: connectSouth
    for (genvar j = 0; j < GRID_WIDTH; j++) begin: connectSouthCols
      always_comb
        southInput[i][j] = northOutput[i+1][j];
      always_comb
        southInputValid[i][j] = northOutputValid[i+1][j];
      always_comb
        northOutputReady[i+1][j] = southInputReady[i][j];
    end: connectSouthCols
  end: connectSouth

  // East-West connections
  for (genvar i = 0; i < GRID_WIDTH; i++) begin: connectEast
    for (genvar j = 0; j < GRID_WIDTH-1; j++) begin: connectEastCols
      always_comb
        eastInput[i][j] = westOutput[i][j+1];
      always_comb
        eastInputValid[i][j] = westOutputValid[i][j+1];
      always_comb
        westOutputReady[i][j+1] = eastInputReady[i][j];
    end: connectEastCols
  end: connectEast

  for (genvar i = 0; i < GRID_WIDTH; i++) begin: connectWest
    for (genvar j = 1; j < GRID_WIDTH; j++) begin: connectWestCols
      always_comb
        westInput[i][j] = eastOutput[i][j-1];
      always_comb
        westInputValid[i][j] = eastOutputValid[i][j-1];
      always_comb
        eastOutputReady[i][j-1] = westInputReady[i][j];
    end: connectWestCols
  end: connectWest
  // }}} Router interconnections

  // {{{ Mesh
  for (genvar i = 0; i < GRID_WIDTH; i++) begin: perRow
    for (genvar j = 0; j < GRID_WIDTH; j++) begin: perCol

      router
      #(.GRID_WIDTH (GRID_WIDTH)
      , .PACKET_WIDTH (PACKET_WIDTH)
      , .FIFO_ADDRESS_WIDTH (FIFO_ADDRESS_WIDTH)
      , .ROUTER_ROW (i)
      , .ROUTER_COL (j)
      ) u_router
      ( .i_clk    (i_clk)
      , .i_arst_n (i_arst_n)

      , .i_ni      (i_niToRouter[i][j])
      , .i_niValid (i_niToRouterValid[i][j])
      , .o_niReady (o_niToRouterReady[i][j])

      , .o_ni      (o_routerToNi[i][j])
      , .o_niValid (o_routerToNiValid[i][j])
      , .i_niReady (i_routerToNiReady[i][j])

      , .i_north      (northInput[i][j])
      , .i_northValid (northInputValid[i][j])
      , .o_northReady (northInputReady[i][j])

      , .i_south      (southInput[i][j])
      , .i_southValid (southInputValid[i][j])
      , .o_southReady (southInputReady[i][j])

      , .i_east      (eastInput[i][j])
      , .i_eastValid (eastInputValid[i][j])
      , .o_eastReady (eastInputReady[i][j])

      , .i_west      (westInput[i][j])
      , .i_westValid (westInputValid[i][j])
      , .o_westReady (westInputReady[i][j])

      , .o_north      (northOutput[i][j])
      , .o_northValid (northOutputValid[i][j])
      , .i_northReady (northOutputReady[i][j])

      , .o_south      (southOutput[i][j])
      , .o_southValid (southOutputValid[i][j])
      , .i_southReady (southOutputReady[i][j])

      , .o_east      (eastOutput[i][j])
      , .o_eastValid (eastOutputValid[i][j])
      , .i_eastReady (eastOutputReady[i][j])

      , .o_west      (westOutput[i][j])
      , .o_westValid (westOutputValid[i][j])
      , .i_westReady (westOutputReady[i][j])
      );

    end: perCol
  end: perRow
  // }}} Mesh

endmodule

`resetall
