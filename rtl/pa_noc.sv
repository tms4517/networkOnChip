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

  // {{{ AHB parameters
  // AHB-Lite (32-bit address / 32-bit data) unified request/response payload.
  //
  // Payload encoding (LSB to MSB):
  // ---------------------------------------------------------------------------
  // |70            39|38             7|6      5|4      2|1      |0        |
  // |HADDR (32 bits) |HDATA (32 bits) |HTRANS  |HSIZE   |HWRITE |HRESP    |
  // ---------------------------------------------------------------------------
  //   HADDR  : AHB address (haddr).
  //   HDATA  : hwdata on a write request, hrdata on a read response.
  //   HTRANS : transfer type (echoed for the target's address phase).
  //   HSIZE  : transfer size.
  //   HWRITE : 1 = write transaction, 0 = read transaction (echoed in response).
  //   HRESP  : AHB-Lite response (0 = OKAY, 1 = ERROR) on a response packet.
  //
  // Only single-beat IDLE/NONSEQ transfers are modelled; hprot/hmastlock and
  // bursts are intentionally omitted.
  // Width = 32 + 32 + 2 + 3 + 1 + 1 = 71 bits.
  localparam int unsigned AHB_PAYLOAD_WIDTH = 71;

  // Field offsets (LSB position) within the AHB-Lite payload.
  localparam int unsigned AHB_HRESP_LSB  = 0;   // [0]
  localparam int unsigned AHB_HWRITE_LSB = 1;   // [1]
  localparam int unsigned AHB_HSIZE_LSB  = 2;   // [4:2]
  localparam int unsigned AHB_HTRANS_LSB = 5;   // [6:5]
  localparam int unsigned AHB_HDATA_LSB  = 7;   // [38:7]
  localparam int unsigned AHB_HADDR_LSB  = 39;  // [70:39]

  // AHB-Lite HTRANS encodings (only the single-beat transfers are used).
  localparam bit [1:0] AHB_TRANS_IDLE   = 2'b00;
  localparam bit [1:0] AHB_TRANS_NONSEQ = 2'b10;

  // AHB-Lite HRESP encodings.
  localparam bit AHB_RESP_OKAY  = 1'b0;
  localparam bit AHB_RESP_ERROR = 1'b1;
  // }}} AHB parameters

  // {{{ Canonical (protocol-agnostic) NoC payload
  // The fabric carries one common transaction payload so that NIs of different
  // AMBA protocols (AHB-Lite, AXI4-Lite, APB) can interoperate.  The encoding is
  // identical to AXI4-Lite (the richest common denominator):
  //   {ADDR[70:39], DATA[38:7], WSTRB[6:3], WRITE[2], RESP[1:0]} = 71 bits.
  // Each NI translates its native protocol to/from this encoding at its edge.
  localparam int unsigned CANON_PAYLOAD_WIDTH = AXI_LITE_PAYLOAD_WIDTH;
  localparam int unsigned CANON_RESP_LSB  = AXI_RESP_LSB;
  localparam int unsigned CANON_WRITE_LSB = AXI_WRITE_LSB;
  localparam int unsigned CANON_WSTRB_LSB = AXI_WSTRB_LSB;
  localparam int unsigned CANON_DATA_LSB  = AXI_DATA_LSB;
  localparam int unsigned CANON_ADDR_LSB  = AXI_ADDR_LSB;

  // AHB HSIZE <-> byte-strobe translation (aligned single beats only).
  function automatic logic [3:0] canonHsizeToWstrb
  ( input logic [2:0] hsize
  , input logic [1:0] addrLo
  );
    case (hsize)
      3'd0:    canonHsizeToWstrb = 4'b0001 << addrLo;             // byte
      3'd1:    canonHsizeToWstrb = addrLo[1] ? 4'b1100 : 4'b0011; // halfword
      default: canonHsizeToWstrb = 4'b1111;                       // word
    endcase
  endfunction

  function automatic logic [2:0] canonWstrbToHsize
  ( input logic [3:0] wstrb
  );
    case (wstrb)
      4'b1111:          canonWstrbToHsize = 3'd2; // word
      4'b0011, 4'b1100: canonWstrbToHsize = 3'd1; // halfword
      default:          canonWstrbToHsize = 3'd0; // byte
    endcase
  endfunction
  // }}} Canonical (protocol-agnostic) NoC payload

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
