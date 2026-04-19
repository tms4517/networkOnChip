// Do not modify this file.

`ifndef PA_NOC
  `define PA_NOC

`default_nettype none

package pa_noc;

  localparam int unsigned APB_PAYLOAD_WIDTH = 69;

  localparam int unsigned FIFO_ADDRESS_W = 2;

  localparam int unsigned NUM_INPUT_FIFOS = 5;

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
