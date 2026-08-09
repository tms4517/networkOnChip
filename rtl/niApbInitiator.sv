// Network Interface — APB Initiator

// This module sits between an APB initiator (master) and a NoC router NI port.
// On every APB access phase, it decodes the address against the address map to
// determine the destination router, assembles the NoC packet, and drives the
// router's ingress handshake.
//
// WRITE and READ transactions both forward a request packet into the mesh and
// stall the APB access phase until a response packet arrives back through the
// router-to-NI port.  The read response carries PRDATA in the canonical DATA
// field; the write response carries only the completion status.  This
// round-trip completion matches the AXI NI so APB masters can interoperate with
// AHB / AXI-Lite targets.

`default_nettype none

module niApbInitiator
#(parameter int unsigned GRID_WIDTH                               = 4
, parameter int unsigned NUM_ADDR_MAP_ENTRIES                     = GRID_WIDTH * GRID_WIDTH
, parameter pa_noc::ty_ADDR_MAP_ENTRY [NUM_ADDR_MAP_ENTRIES-1:0] ADDR_MAP = '0
, parameter int unsigned SRC_ROW                                  = 0
, parameter int unsigned SRC_COL                                  = 0
, parameter int unsigned MAX_NI_PER_ROUTER                        = pa_noc::MAX_NI_PER_ROUTER
, parameter int unsigned NI_ID                                    = 0

, localparam int unsigned COORD_WIDTH   = $clog2(GRID_WIDTH)
, localparam int unsigned NI_ID_WIDTH   = (MAX_NI_PER_ROUTER > 1) ?
                                          $clog2(MAX_NI_PER_ROUTER) : 0
, localparam int unsigned PAYLOAD_WIDTH = pa_noc::CANON_PAYLOAD_WIDTH
, localparam int unsigned PACKET_WIDTH  = PAYLOAD_WIDTH + (2 * NI_ID_WIDTH)
                                          + (COORD_WIDTH * 4)
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
, output var logic [31:0] o_prdata

  // NoC router NI — initiator to router (request)
, output var logic [PACKET_WIDTH-1:0] o_niToRouter
, output var logic                    o_niToRouterValid
, input  var logic                    i_niToRouterReady

  // NoC router NI — router to initiator (response)
, input  var logic [PACKET_WIDTH-1:0] i_routerToNi
, input  var logic                    i_routerToNiValid
, output var logic                    o_routerToNiReady
);

  // {{{ Address decode
  // Decode the APB address to determine the destination router to forward the
  // packet/APB transaction to.
  // The address map is statically configured via the ADDR_MAP parameter
  // which is a packed array of pa_noc::ty_ADDR_MAP_ENTRY structs.
  // Each entry holds:
  //   baseAddr — inclusive lower bound of the address range
  //   endAddr  — inclusive upper bound of the address range
  //   dstRow   — destination router row (lower COORD_WIDTH bits are used)
  //   dstCol   — destination router column (lower COORD_WIDTH bits are used)
  //   dstNiId  — destination NI ID (when MAX_NI_PER_ROUTER > 1)
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
  if (NI_ID_WIDTH > 0)
  begin: gen_addr_decode_with_id
    logic [NI_ID_WIDTH-1:0] dstNiId;

    always_comb begin
      addrHit  = 1'b0;
      dstRow   = '0;
      dstCol   = '0;
      dstNiId  = '0;

      for (int i = 0; i < NUM_ADDR_MAP_ENTRIES; i++) begin
        if (!addrHit
            && (i_paddr >= ADDR_MAP[i].baseAddr)
            && (i_paddr <= ADDR_MAP[i].endAddr)) begin
          addrHit = 1'b1;
          dstRow  = COORD_WIDTH'(ADDR_MAP[i].dstRow);
          dstCol  = COORD_WIDTH'(ADDR_MAP[i].dstCol);
          dstNiId = NI_ID_WIDTH'(ADDR_MAP[i].dstNiId);
        end
      end
    end
  end: gen_addr_decode_with_id
  else
  begin: gen_addr_decode_no_id
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
  end: gen_addr_decode_no_id
  /* svlint on explicit_if_else */
  /* svlint on loop_statement_in_always_comb */
  /* svlint on sequential_block_in_always_comb */
  // }}} Address decode

  // {{{ Pack APB Payload
  // Canonical payload (MSB to LSB): {ADDR, DATA, WSTRB, WRITE, RESP}.
  // PSTRB maps to WSTRB; RESP is zero on a request.
  logic [PAYLOAD_WIDTH-1:0] apbPayload;

  always_comb
    apbPayload = {i_paddr, i_pwdata, i_pstrb, i_pwrite, pa_noc::AXI_RESP_OKAY};

  // Full NoC packet layout (MSB to LSB):
  // {Payload, srcNiId, srcRow, srcCol, dstNiId, dstRow, dstCol}
  // When MAX_NI_PER_ROUTER = 1, NI_ID_WIDTH = 0 and no ID fields exist.
  logic [COORD_WIDTH-1:0] srcRow;
  logic [COORD_WIDTH-1:0] srcCol;

  always_comb
    srcRow = COORD_WIDTH'(SRC_ROW);

  always_comb
    srcCol = COORD_WIDTH'(SRC_COL);

  if (NI_ID_WIDTH > 0)
  begin: gen_with_ids
    logic [NI_ID_WIDTH-1:0] srcNiId;
    logic [NI_ID_WIDTH-1:0] dstNiId;

    always_comb
      srcNiId = NI_ID_WIDTH'(NI_ID);

    always_comb
      dstNiId = gen_addr_decode_with_id.dstNiId;

    always_comb
      o_niToRouter = {apbPayload, srcNiId, srcRow, srcCol, dstNiId, dstRow, dstCol};
  end: gen_with_ids
  else
  begin: gen_no_ids
    always_comb
      o_niToRouter = {apbPayload, srcRow, srcCol, dstRow, dstCol};
  end: gen_no_ids
  // }}} Pack APB Payload

  // {{{ Handshake / flow control
  // WRITE: packet is forwarded; APB stalls until the router accepts.
  // READ:  request packet is forwarded; APB stalls until the response
  //        packet arrives back through the router-to-NI port.
  // FSM states:
  //   ST_IDLE      — ready for a new APB transaction
  //   ST_WAIT_RESP — request accepted by router, waiting for the response

  logic accessPhase;

  always_comb
    accessPhase = i_psel && i_penable;

  logic reqAccepted;

  always_comb
    reqAccepted = accessPhase && addrHit && i_niToRouterReady;

  typedef enum logic
  { ST_IDLE
  , ST_WAIT_RESP
  } ty_state;

  ty_state state_q, state_d;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      state_q <= ST_IDLE;
    else
      state_q <= state_d;

  always_comb
    case (state_q)
      ST_IDLE:
        state_d = reqAccepted ? ST_WAIT_RESP : ST_IDLE;
      ST_WAIT_RESP:
        state_d = i_routerToNiValid ? ST_IDLE : ST_WAIT_RESP;
      default:
        state_d = ST_IDLE;
    endcase

  // NoC request valid
  // Drive valid for both reads and writes, but only in IDLE
  // (prevents re-sending the read request while waiting for response).
  always_comb
    if (state_q == ST_IDLE && accessPhase && addrHit)
      o_niToRouterValid = 1'b1;
    else
      o_niToRouterValid = 1'b0;

  // NoC response ready
  // Accept a response only when waiting for one.
  always_comb
    if (state_q == ST_WAIT_RESP)
      o_routerToNiReady = 1'b1;
    else
      o_routerToNiReady = 1'b0;

  // Response payload uses the canonical encoding; PRDATA occupies the DATA
  // field position.
  logic [PAYLOAD_WIDTH-1:0] respPayload;

  always_comb
    respPayload = i_routerToNi[PACKET_WIDTH-1 -: PAYLOAD_WIDTH];

  always_comb
    if (state_q == ST_WAIT_RESP && i_routerToNiValid)
      o_prdata = respPayload[pa_noc::CANON_DATA_LSB +: 32];
    else
      o_prdata = '0;

  // Reads and writes both complete when the response packet arrives.
  // No addr hit: complete immediately (SLVERR).
  always_comb
    if (state_q == ST_WAIT_RESP)
      o_pready = i_routerToNiValid;
    else if (!accessPhase)
      o_pready = 1'b0;
    else if (!addrHit)
      o_pready = 1'b1;
    else
      o_pready = 1'b0;

  always_comb
    if (state_q == ST_WAIT_RESP)
      o_pslverr = (respPayload[pa_noc::CANON_RESP_LSB +: 2] != pa_noc::AXI_RESP_OKAY);
    else if (!accessPhase)
      o_pslverr = 1'b0;
    else if (!addrHit)
      o_pslverr = 1'b1;
    else
      o_pslverr = 1'b0;
  // }}} Handshake / flow control

endmodule

`resetall
