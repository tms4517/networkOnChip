// Network Interface — APB Initiator

// This module sits between an APB initiator (master) and a NoC router NI port.
// On every APB access phase, it decodes the address against the address map to
// determine the destination router, assembles the NoC packet, and drives the
// router's ingress handshake.

// TODO:
// Only WRITE transactions are forwarded into the mesh in this implementation.
// READ support (requiring a return packet) is a future extension.

`default_nettype none

module niApbInitiator
  import pa_noc::*;
#(parameter int unsigned GRID_WIDTH                               = 4
, parameter int unsigned NUM_ADDR_MAP_ENTRIES                     = GRID_WIDTH * GRID_WIDTH
, parameter ty_ADDR_MAP_ENTRY [NUM_ADDR_MAP_ENTRIES-1:0] ADDR_MAP = '0

, localparam int unsigned COORD_WIDTH   = $clog2(GRID_WIDTH)
, localparam int unsigned PAYLOAD_WIDTH = APB_PAYLOAD_WIDTH
, localparam int unsigned PACKET_WIDTH  = PAYLOAD_WIDTH + (COORD_WIDTH * 2)
)
( input  var logic i_clk
, input  var logic i_arst_n

  // APB initiator (master) interface
, input  var logic [31:0] i_paddr
, input  var logic [31:0] i_pwdata
, input  var logic        i_pwrite
, input  var logic [3:0]  i_pstrb
, input  var logic        i_psel
, input  var logic        i_penable
, output var logic        o_pready
, output var logic        o_pslverr

  // NoC router NI initiator to router
, output var logic [PACKET_WIDTH-1:0] o_niToRouter
, output var logic                    o_niToRouterValid
, input  var logic                    i_niToRouterReady
);

  // {{{ Address decode
  // Decode the APB address to determine the destination router to forward the
  // packet/APB transaction to.
  // The address map is statically configured via the ADDR_MAP parameter
  // which is a packed array of pa_noc::ty_ADDR_MAP_ENTRY structs.
  // Each entry holds:
  //   baseAddr  — inclusive lower bound of the address range
  //   endAddr   — inclusive upper bound of the address range
  //   dstRow    — destination router row (lower COORD_WIDTH bits are used)
  //   dstCol    — destination router column (lower COORD_WIDTH bits are used)
  // Entries are checked from index 0 upward; the first matching entry wins.
  // If no entry matches, the packet is not forwarded (o_niToRouterValid is low)
  // and the APB transaction completes with a SLVERR response.
  // TODO: Is there a better way of creating this priority encoder?
  logic                    addrHit;
  logic [COORD_WIDTH-1:0]  dstRow;
  logic [COORD_WIDTH-1:0]  dstCol;

  /* svlint off sequential_block_in_always_comb */
  /* svlint off loop_statement_in_always_comb */
  /* svlint off explicit_if_else */
  always_comb begin
    addrHit = 1'b0;
    dstRow  = '0;
    dstCol  = '0;

    for (int i = 0; i < NUM_ADDR_MAP_ENTRIES; i++) begin
      if (!addrHit
          && (i_paddr >= ADDR_MAP[i].baseAddr)
          && (i_paddr <= ADDR_MAP[i].endAddr)) begin
        addrHit = 1'b1;
        dstRow  = COORD_WIDTH'(ADDR_MAP[i].dstRow);
        dstCol  = COORD_WIDTH'(ADDR_MAP[i].dstCol);
      end
    end
  end
  /* svlint on explicit_if_else */
  /* svlint on loop_statement_in_always_comb */
  /* svlint on sequential_block_in_always_comb */
  // }}} Address decode

  // {{{ Pack APB Payload
  // APB Payload encoding:
  // -------------------------------------------------------
  // |68            37|36             5|4      |3        0 |
  // |PADDR (32 bits) |PWDATA (32 bits)|PWRITE |PSTRB(4b)  |
  // -------------------------------------------------------
  logic [PAYLOAD_WIDTH-1:0] apbPayload;

  always_comb
    apbPayload = {i_paddr, i_pwdata, i_pwrite, i_pstrb};

  // Full NoC packet: payload in upper bits, coordinates in lower bits
  // For a 4x4 grid:
  // -------------------------------------------------------
  // | PAYLOAD (PAYLOAD_WIDTH-1 : 0) | dstRow | dstCol    |
  // | [APB_PAYLOAD_WIDTH-1 : 0]     | [1:0]  | [1:0]     |
  // -------------------------------------------------------
  always_comb
    o_niToRouter = {apbPayload, dstRow, dstCol};
  // }}} Pack APB Payload

  // {{{ Handshake / flow control
  // A NoC transfer is initiated during the APB access phase (PSEL & PENABLE)
  // when the address hits the map.  The APB transaction is held (PREADY low)
  // until the router accepts the packet (i_niToRouterReady).
  // Unmatched addresses respond immediately with SLVERR.

  logic accessPhase;

  always_comb accessPhase = i_psel && i_penable;

  // Drive router valid only during an access phase with a matching address
  always_comb
    o_niToRouterValid = accessPhase && i_pwrite && addrHit;

  // APB PREADY: complete immediately on SLVERR; otherwise wait for NoC accept
  always_comb
    if (!accessPhase)
      o_pready  = 1'b0;
    else if (!addrHit)
      o_pready  = 1'b1;
    else
      o_pready  = i_niToRouterReady;

  always_comb
    if (!accessPhase)
      o_pslverr = 1'b0;
    else if (!addrHit)
      o_pslverr = 1'b1; // No map entry matched — error response
    else
      o_pslverr = 1'b0;
  // }}} Handshake / flow control

endmodule

`resetall
