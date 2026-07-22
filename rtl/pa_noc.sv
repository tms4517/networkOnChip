`ifndef PA_NOC
  `define PA_NOC

`default_nettype none

package pa_noc;

  // {{{ APB parameters
  // APB (32-bit address / 32-bit data) unified request/response payload.
  //
  // Payload encoding (LSB to MSB):
  // -------------------------------------------------------
  // |68            37|36             5|4      |3        0 |
  // |PADDR (32 bits) |PWDATA (32 bits)|PWRITE |PSTRB (4b) |
  // -------------------------------------------------------
  //   PADDR  : APB address (paddr).
  //   PWDATA : pwdata on a write request, prdata on a read response.
  //   PWRITE : 1 = write transaction, 0 = read transaction (echoed in response).
  //   PSTRB  : write strobe (unused on reads).
  //
  // Width = 32 (PADDR) + 32 (PWDATA) + 1 (PWRITE) + 4 (PSTRB) = 69 bits.
  localparam int unsigned APB_PAYLOAD_WIDTH = 69;
  // }}} APB parameters

  // {{{ AXI parameters
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

  // Field offsets (LSB position) within the AXI4-Lite payload.
  localparam int unsigned AXI_RESP_LSB  = 0;   // [1:0]
  localparam int unsigned AXI_WRITE_LSB = 2;   // [2]
  localparam int unsigned AXI_WSTRB_LSB = 3;   // [6:3]
  localparam int unsigned AXI_DATA_LSB  = 7;   // [38:7]
  localparam int unsigned AXI_ADDR_LSB  = 39;  // [70:39]

  // AXI response encodings.
  typedef enum bit [1:0]
  { AXI_RESP_OKAY   = 2'b00
  , AXI_RESP_SLVERR = 2'b10
  , AXI_RESP_DECERR = 2'b11
  } ty_AXI_RESP;
  // }}} AXI parameters

  // Address map entry: maps an address range to a NoC destination node.
  // dstRow/dstCol are stored as 8-bit fields so this struct is independent of
  // GRID_WIDTH; the NI module masks them down to COORD_WIDTH bits at use.
  // dstNiId selects which target NI at the destination router (when multiple).
  typedef struct packed {
    logic [31:0] baseAddr; // Inclusive lower bound of address range
    logic [31:0] endAddr;  // Inclusive upper bound of address range
    logic [7:0]  dstRow;   // Destination router row
    logic [7:0]  dstCol;   // Destination router column
    logic [7:0]  dstNiId;  // Destination NI ID (0 when single target)
  } ty_ADDR_MAP_ENTRY;

  // Maximum number of NIs (initiators or targets) that can share a single
  // router port. When > 1, NI ID fields are added to the packet format:
  //   - Source NI ID: identifies the initiator, echoed in responses
  //   - Destination NI ID: selects the target at the destination router
  // NI_ID_WIDTH = $clog2(MAX_NI_PER_ROUTER); 0 when MAX = 1 (no overhead).
  localparam int unsigned MAX_NI_PER_ROUTER = 1;

  // {{{ NOC fabric parameters
  localparam int unsigned FIFO_ADDRESS_W = 2;

  localparam int unsigned NUM_INPUT_FIFOS = 5;

  typedef enum bit [2:0]
  { NI    = 3'b000
  , NORTH = 3'b001
  , SOUTH = 3'b010
  , EAST  = 3'b011
  , WEST  = 3'b100
  } ty_DIRECTION;
  // }}} NOC fabric parameters

endpackage

`resetall

`endif
