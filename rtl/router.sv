// This module implements a simple router for a network-on-chip (NoC).
// It receives packets from Network Interfaces (NI) and forward them to
// neighboring routers based on the destination router's coordinates.
// If the packet's destination matches the current router's coordinates,
// it forwards the packet to the local NI.
// The router uses a basic XY routing algorithm to decide which neighbouring
// router to send the packet to next.

`default_nettype none

module router
#(parameter int unsigned GRID_WIDTH = 4
, parameter bit [$clog2(GRID_WIDTH)-1:0] ROUTER_ROW = 0
, parameter bit [$clog2(GRID_WIDTH)-1:0] ROUTER_COL = 0
, localparam int unsigned APB_PACKET_WIDTH = pa_noc::APB_PACKET_WIDTH
)
( input  var logic i_clk
, input  var logic i_arst_n

// To/from network interfaces
, input  var logic [APB_PACKET_WIDTH-1:0] i_apbPacket
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

  /* verilator lint_off UNUSED */
  // For now until routing has been tested, we combine packets from NI and
  // neighboring routers.
  logic [APB_PACKET_WIDTH-1:0] apbPacket;

  always_comb
    apbPacket = i_apbPacket | i_north | i_south | i_east | i_west;
  /* verilator lint_on UNUSED */

  // {{{ Decode destination coordinates from incoming packet
  localparam int unsigned COORD_WIDTH = $clog2(GRID_WIDTH);
  logic [COORD_WIDTH-1:0] destinationRow, destinationCol;

  always_comb
    destinationRow = apbPacket[3:2];

  always_comb
    destinationCol = apbPacket[1:0];
  // }}} Decode destination coordinates from incoming packet

  // {{{ Router coordinates match destination coordinates
  logic isDestination;

  always_comb
    isDestination = (destinationRow == ROUTER_ROW)
                    && (destinationCol == ROUTER_COL);

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      o_apbPacket <= '0;
    else
      o_apbPacket <= isDestination ? apbPacket : '0;
  // }}} Router coordinates match destination coordinates

  // {{{ Forward packets to neighboring routers
  // The packet moves horizontally until it reaches the correct column, then
  // moves vertically to the correct row.
  logic [APB_PACKET_WIDTH-1:0] eastPacket, westPacket, northPacket, southPacket;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      o_east <= '0;
    else
      o_east <= eastPacket;

  // For edge routers at max column (GRID_WIDTH-1), comparison is always false
  // (optimized away by synthesis).
  /* verilator lint_off CMPCONST */
  always_comb
    eastPacket = &{!isDestination
                  , destinationCol > ROUTER_COL
                  } ? apbPacket : '0;
  /* verilator lint_on CMPCONST */

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      o_west <= '0;
    else
      o_west <= westPacket;

  // For edge routers at column 0, comparison is always false
  // (optimized away by synthesis).
  /* verilator lint_off UNSIGNED */
  always_comb
    westPacket = &{!isDestination
                  , destinationCol < ROUTER_COL
                  } ? apbPacket : '0;
  /* verilator lint_on UNSIGNED */

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      o_south <= '0;
    else
      o_south <= southPacket;

  // For edge routers at max row (GRID_WIDTH-1), comparison is always false
  // (optimized away by synthesis).
  /* verilator lint_off CMPCONST */
  always_comb
    southPacket = &{!isDestination
                  , destinationCol == ROUTER_COL
                  , destinationRow > ROUTER_ROW
                  } ? apbPacket : '0;
  /* verilator lint_on CMPCONST */

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      o_north <= '0;
    else
      o_north <= northPacket;

  // For edge routers at row 0, comparison is always false
  // (optimized away by synthesis).
  /* verilator lint_off UNSIGNED */
  always_comb
    northPacket = &{!isDestination
                  , destinationCol == ROUTER_COL
                  , destinationRow < ROUTER_ROW
                  } ? apbPacket : '0;
  /* verilator lint_on UNSIGNED */
  // }}} Forward packets to neighboring routers

endmodule

`resetall
