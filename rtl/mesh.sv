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

import pa_noc::*;

module mesh
#(parameter int unsigned GRID_WIDTH = 4)
( input  var logic i_clk
, input  var logic i_arst_n

, input  var logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0][APB_PACKET_WIDTH-1:0] niToRouter
, output var logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0][APB_PACKET_WIDTH-1:0] routerToNi
);

  /* verilator lint_off UNUSED */
  // Inputs to router from neighboring routers
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0][APB_PACKET_WIDTH-1:0] northInput;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0][APB_PACKET_WIDTH-1:0] southInput;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0][APB_PACKET_WIDTH-1:0] eastInput;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0][APB_PACKET_WIDTH-1:0] westInput;

  // Outputs from router to neighboring routers
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0][APB_PACKET_WIDTH-1:0] northOutput;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0][APB_PACKET_WIDTH-1:0] southOutput;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0][APB_PACKET_WIDTH-1:0] eastOutput;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0][APB_PACKET_WIDTH-1:0] westOutput;
  /* verilator lint_on UNUSED */

  // {{{ Tie off edge router input connections
  // North and south edges: iterate over columns
  for (genvar col = 0; col < GRID_WIDTH; col++) begin: tieOffNorthSouth

    // North edge
    always_comb
      northInput[0][col] = '0;

    // South edge
    always_comb
      southInput[GRID_WIDTH-1][col] = '0;

  end: tieOffNorthSouth

  // East and west edges: iterate over rows
  for (genvar row = 0; row < GRID_WIDTH; row++) begin: tieOffEastWest

    // East edge
    always_comb
      eastInput[row][GRID_WIDTH-1] = '0;

    // West edge
    always_comb
      westInput[row][0] = '0;

  end: tieOffEastWest
  // }}} Tie off edge router input connections

  // {{{ Router interconnections
  // North-South connections
  for (genvar row = 1; row < GRID_WIDTH; row++) begin: connectNorth
    for (genvar col = 0; col < GRID_WIDTH; col++) begin: connectNorthCols
      always_comb
        northInput[row][col] = southOutput[row-1][col];
    end: connectNorthCols
  end: connectNorth

  for (genvar row = 0; row < GRID_WIDTH-1; row++) begin: connectSouth
    for (genvar col = 0; col < GRID_WIDTH; col++) begin: connectSouthCols
      always_comb
        southInput[row][col] = northOutput[row+1][col];
    end: connectSouthCols
  end: connectSouth

  // East-West connections
  for (genvar row = 0; row < GRID_WIDTH; row++) begin: connectEast
    for (genvar col = 0; col < GRID_WIDTH-1; col++) begin: connectEastCols
      always_comb
        eastInput[row][col] = westOutput[row][col+1];
    end: connectEastCols
  end: connectEast

  for (genvar row = 0; row < GRID_WIDTH; row++) begin: connectWest
    for (genvar col = 1; col < GRID_WIDTH; col++) begin: connectWestCols
      always_comb
        westInput[row][col] = eastOutput[row][col-1];
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
      ( .i_clk   (i_clk)
      , .i_arst_n(i_arst_n)

      , .i_apbPacket (niToRouter[row][col])
      , .o_apbPacket (routerToNi[row][col])

      , .i_north (northInput[row][col])
      , .i_south (southInput[row][col])
      , .i_east  (eastInput[row][col])
      , .i_west  (westInput[row][col])
      , .o_north (northOutput[row][col])
      , .o_south (southOutput[row][col])
      , .o_east  (eastOutput[row][col])
      , .o_west  (westOutput[row][col])
      );

    end: perCol
  end: perRow
  // }}} Mesh

endmodule

`resetall
