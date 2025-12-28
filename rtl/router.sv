// This module implements a simple router for a network-on-chip (NoC).
// It receives packets from Network Interfaces (NI) and forward them to
// neighboring routers based on the destination router's coordinates.
// If the packet's destination matches the current router's coordinates,
// it forwards the packet to the local NI.
// The router uses a basic XY routing algorithm to decide which neighbouring
// router to send the packet to next.

`default_nettype none

import pa_noc::*;

module router
#( parameter int unsigned ROUTER_ROW = 0
 , parameter int unsigned ROUTER_COL = 0
 , parameter int unsigned GRID_WIDTH = 4
)
( // To/from network interfaces
  input  var logic [APB_PACKET_WIDTH-1:0] i_apbPacket
, output var logic [APB_PACKET_WIDTH-1:0] o_apbPacket

  // To/from neighboring routers
, input  var logic [APB_PACKET_WIDTH-1:0] i_north
, input  var logic [APB_PACKET_WIDTH-1:0] i_south
, input  var logic [APB_PACKET_WIDTH-1:0] i_east
, input  var logic [APB_PACKET_WIDTH-1:0] i_west
, output var logic [APB_PACKET_WIDTH-1:0] o_north
, output var logic [APB_PACKET_WIDTH-1:0] o_south
, output var logic [APB_PACKET_WIDTH-1:0] o_east
, output var logic [APB_PACKET_WIDTH-1:0] o_west
);

  // {{{ Decode destination coordinates from incoming packet
  localparam int unsigned COORD_WIDTH = $clog2(GRID_WIDTH);
  logic [COORD_WIDTH-1:0] destinationRow, destinationCol;

  always_comb
    destinationRow = i_apbPacket[3:2];

  always_comb
    destinationCol = i_apbPacket[1:0];
  // }}} Decode destination coordinates from incoming packet

  // {{{ Router coordinates match destination coordinates
  logic isDestination;

  always_comb
    isDestination = (destinationRow == ROUTER_ROW) &&
                    (destinationCol == ROUTER_COL);

  always_comb
    o_apbPacket = isDestination ? i_apbPacket : '0;
  // }}} Router coordinates match destination coordinates

  // {{{ Forward packets to neighboring routers
  // The packet moves horizontally until it reaches the correct column, then
  // moves vertically to the correct row.
  always_comb
    o_east = &{!isDestination
              , destinationCol > ROUTER_COL
             } ? i_apbPacket : '0;

  always_comb
    o_west = &{!isDestination
              , destinationCol < ROUTER_COL
             } ? i_apbPacket : '0;

  always_comb
    o_south = &{!isDestination
               , destinationCol == ROUTER_COL
               , destinationRow > ROUTER_ROW
              } ? i_apbPacket : '0;

  always_comb
    o_north = &{!isDestination
               , destinationCol == ROUTER_COL
               , destinationRow < ROUTER_ROW
              } ? i_apbPacket : '0;
  // }}} Forward packets to neighboring routers

endmodule

`resetall
