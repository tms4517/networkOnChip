// Do not modify this file.

`ifndef PA_NOC
  `define PA_NOC

`default_nettype none

package pa_noc;

  localparam int unsigned APB_PAYLOAD_WIDTH = 69;

  localparam int unsigned FIFO_ADDRESS_W = 2;

  localparam int unsigned NUM_INPUT_FIFOS = 5;

  // Address map entry: maps an address range to a NoC destination node.
  // dstRow/dstCol are stored as 8-bit fields so this struct is independent of
  // GRID_WIDTH; the NI module masks them down to COORD_WIDTH bits at use.
  typedef struct packed {
    logic [31:0] baseAddr; // Inclusive lower bound of address range
    logic [31:0] endAddr;  // Inclusive upper bound of address range
    logic [7:0]  dstRow;   // Destination router row
    logic [7:0]  dstCol;   // Destination router column
  } ty_ADDR_MAP_ENTRY;

  typedef enum bit [2:0]
  { NI    = 3'b000
  , NORTH = 3'b001
  , SOUTH = 3'b010
  , EAST  = 3'b011
  , WEST  = 3'b100
  } ty_DIRECTION;

endpackage

`resetall

`endif
