// Network Interface — APB Initiator
//
// Sits between an APB initiator (master) and a NoC router NI port.
// On every APB access phase (PSEL & PENABLE), it decodes PADDR against the
// address map to determine the destination router (dstRow, dstCol), assembles
// the NoC packet, and drives the router's ingress handshake.
//
// Only WRITE transactions are forwarded into the mesh in this implementation.
// READ support (requiring a return packet) is a future extension.
//
// Packet format (see noc.sv for field definitions):
// -------------------------------------------------------
// | PAYLOAD (PAYLOAD_WIDTH-1 : 0) | dstRow | dstCol    |
// | [APB_PAYLOAD_WIDTH-1 : 0]     | [1:0]  | [1:0]     |
// -------------------------------------------------------
//
// APB Payload encoding:
// -------------------------------------------------------
// |68            37|36             5|4      |3        0 |
// |PADDR (32 bits) |PWDATA (32 bits)|PWRITE |PSTRB(4b)  |
// -------------------------------------------------------
//
// Address Map Parameter
// ---------------------
// ADDR_MAP is a packed array of pa_noc::ty_ADDR_MAP_ENTRY structs.  Each
// entry holds:
//   baseAddr  — inclusive lower bound of the address range
//   endAddr   — inclusive upper bound of the address range
//   dstRow    — destination router row (lower COORD_WIDTH bits are used)
//   dstCol    — destination router column (lower COORD_WIDTH bits are used)
//
// Entries are checked from index 0 upward; the first matching entry wins.
// If no entry matches, the packet is not forwarded (o_niToRouterValid is low)
// and the APB transaction completes with a SLVERR response.

`default_nettype none

module ni_apb_initiator
#(parameter  int unsigned                                          GRID_WIDTH             = 4
, parameter  int unsigned                                          NUM_ADDR_MAP_ENTRIES   = 4
, parameter  pa_noc::ty_ADDR_MAP_ENTRY [NUM_ADDR_MAP_ENTRIES-1:0] ADDR_MAP               = '0
, localparam int unsigned                                          COORD_WIDTH            = $clog2(GRID_WIDTH)
, localparam int unsigned                                          PAYLOAD_WIDTH          = pa_noc::APB_PAYLOAD_WIDTH
, localparam int unsigned                                          PACKET_WIDTH           = PAYLOAD_WIDTH + (COORD_WIDTH * 2)
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

  // NoC router NI port — initiator → router
, output var logic [PACKET_WIDTH-1:0] o_niToRouter
, output var logic                    o_niToRouterValid
, input  var logic                    i_niToRouterReady
);

  // --------------------------------------------------------------------------
  // Address decode: combinationally find the first matching map entry
  // --------------------------------------------------------------------------
  logic                    addrHit;
  logic [COORD_WIDTH-1:0]  dstRow;
  logic [COORD_WIDTH-1:0]  dstCol;

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

  // --------------------------------------------------------------------------
  // Packet assembly
  // --------------------------------------------------------------------------
  // APB payload: {PADDR, PWDATA, PWRITE, PSTRB}
  logic [PAYLOAD_WIDTH-1:0] apbPayload;
  always_comb
    apbPayload = {i_paddr, i_pwdata, i_pwrite, i_pstrb};

  // Full NoC packet: payload in upper bits, coordinates in lower bits
  always_comb
    o_niToRouter = {apbPayload, dstRow, dstCol};

  // --------------------------------------------------------------------------
  // Handshake / flow control
  //
  // A NoC transfer is initiated during the APB access phase (PSEL & PENABLE)
  // when the address hits the map.  The APB transaction is held (PREADY low)
  // until the router accepts the packet (i_niToRouterReady).
  // Unmatched addresses respond immediately with SLVERR.
  // --------------------------------------------------------------------------
  logic accessPhase;
  always_comb accessPhase = i_psel & i_penable;

  // Drive router valid only during an access phase with a matching address
  always_comb
    o_niToRouterValid = accessPhase & i_pwrite & addrHit;

  // APB PREADY: complete immediately on SLVERR; otherwise wait for NoC accept
  always_comb begin
    if (!accessPhase) begin
      o_pready  = 1'b0;
      o_pslverr = 1'b0;
    end else if (!addrHit) begin
      // No map entry matched — error response
      o_pready  = 1'b1;
      o_pslverr = 1'b1;
    end else begin
      // Stall APB until the router accepts the packet
      o_pready  = i_niToRouterReady;
      o_pslverr = 1'b0;
    end
  end

endmodule

`resetall
