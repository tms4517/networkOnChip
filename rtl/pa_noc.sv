// Do not modify this file.

`ifndef PA_NOC
  `define PA_NOC

`default_nettype none

package pa_noc;

  // APB Packet Definition
  // -------------------------------------------------------------------
  // |72                             4|3              2|1              0|
  // |       Payload (69 bits)        |Dst Row (2 bits)|Dst Col (2 bits)|
  // |-------------------------------------------------------------------
  localparam int unsigned APB_PACKET_WIDTH = 73;

endpackage

`resetall

`endif
