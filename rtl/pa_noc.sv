// Copyright (c) 2023 Tej Sanghavi.
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
  //   PWRITE : 1 = write transaction, 0 = read transaction (echoed in
  //            response).
  //   PSTRB  : write strobe on a request; a read response carries PSLVERR
  //            in PSTRB[0].
  //
  // Width = 32 (PADDR) + 32 (PWDATA) + 1 (PWRITE) + 4 (PSTRB) = 69 bits.
  typedef struct packed {
    logic [31:0] paddr;
    logic [31:0] pdata;
    logic        pwrite;
    logic [3:0]  pstrb;
  } ty_APB_PAYLOAD;

  localparam int unsigned APB_PAYLOAD_WIDTH = $bits(ty_APB_PAYLOAD);
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
  typedef struct packed {
    logic [31:0] addr;
    logic [31:0] data;
    logic [3:0]  wstrb;
    logic        write;
    logic [1:0]  resp;
  } ty_AXI_LITE_PAYLOAD;

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
  //   HWRITE : 1 = write transaction, 0 = read transaction (echoed in
  //            response).
  //   HRESP  : AHB-Lite response (0 = OKAY, 1 = ERROR) on a response packet.
  //
  // Only single-beat IDLE/NONSEQ transfers are modelled; hprot/hmastlock and
  // bursts are intentionally omitted.
  // Width = 32 + 32 + 2 + 3 + 1 + 1 = 71 bits.
  typedef struct packed {
    logic [31:0] haddr;
    logic [31:0] hdata;
    logic [1:0]  htrans;
    logic [2:0]  hsize;
    logic        hwrite;
    logic        hresp;
  } ty_AHB_PAYLOAD;

  // AHB-Lite HTRANS encodings (only the single-beat transfers are used).
  typedef enum logic [1:0]
  { AHB_TRANS_IDLE   = 2'b00
  , AHB_TRANS_NONSEQ = 2'b10
  } ty_AHB_TRANS;
  // }}} AHB parameters

  // {{{ Initiator protocol opcode
  // Each packet carries the AMBA protocol its initiator used, so a target node
  // can steer it to the matching per-protocol target NI (and, when the target
  // peripheral speaks a different protocol, through the corresponding bridge).
  // The initiator performs no protocol conversion; conversion happens at the
  // target.  The opcode is prepended above the payload, so it is transparent to
  // the routing fabric (coordinates stay at the LSB) and is carried by widening
  // the fabric PAYLOAD_WIDTH by PROTOCOL_WIDTH.
  localparam int unsigned PROTOCOL_WIDTH = 2;

  typedef enum logic [PROTOCOL_WIDTH-1:0]
  { PROTO_AXI_LITE = 2'd0
  , PROTO_AHB      = 2'd1
  , PROTO_APB      = 2'd2
  } ty_PROTOCOL;
  // }}} Initiator protocol opcode

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
