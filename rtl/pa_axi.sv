// AXI4-Lite package.
// Defines the NoC payload width and field layout used by the AXI4-Lite network
// interfaces (niAxiLiteInitiator / niAxiLiteTarget).
//
// The NoC core (mesh/router/arbiter/fifo/noc) is payload-agnostic: it only
// transports PACKET_WIDTH-wide packets whose header carries the source and
// destination coordinates (see pa_noc / noc.sv).  The AXI4-Lite NIs simply swap
// the APB payload encoding for the AXI4-Lite encoding defined here.
//
// A given fabric uses EITHER the APB NIs OR the AXI4-Lite NIs, not both.

`ifndef PA_AXI
  `define PA_AXI

`default_nettype none

package pa_axi;

  // AXI4-Lite (32-bit address / 32-bit data) unified request/response payload.
  //
  // Payload encoding (LSB to MSB):
  // ---------------------------------------------------------------------------
  // |70            39|38             7|6      3|2      |1        0|
  // |ADDR (32 bits)  |DATA (32 bits)  |WSTRB(4)|WRITE  |RESP (2b) |
  // ---------------------------------------------------------------------------
  //   ADDR  : awaddr on a write request, araddr on a read request.
  //   DATA  : wdata on a write request, rdata on a read response.
  //   WSTRB : wstrb on a write request (unused on reads).
  //   WRITE : 1 = write transaction, 0 = read transaction (echoed in response).
  //   RESP  : bresp on a write response, rresp on a read response.
  //           (AXI: 2'b00 OKAY, 2'b10 SLVERR, 2'b11 DECERR)
  //
  // awprot/arprot are intentionally omitted (single-beat, non-secure access).
  localparam int unsigned AXI_LITE_PAYLOAD_WIDTH = 71;

  // Field offsets (LSB position) within the payload.
  localparam int unsigned AXI_RESP_LSB  = 0;   // [1:0]
  localparam int unsigned AXI_WRITE_LSB = 2;   // [2]
  localparam int unsigned AXI_WSTRB_LSB = 3;   // [6:3]
  localparam int unsigned AXI_DATA_LSB  = 7;   // [38:7]
  localparam int unsigned AXI_ADDR_LSB  = 39;  // [70:39]

  // AXI response encodings.
  localparam bit [1:0] AXI_RESP_OKAY   = 2'b00;
  localparam bit [1:0] AXI_RESP_SLVERR = 2'b10;
  localparam bit [1:0] AXI_RESP_DECERR = 2'b11;

endpackage

`resetall

`endif
