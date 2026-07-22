// Network Interface — AHB-Lite Initiator (manager-facing)

// This module presents an AHB-Lite SUBORDINATE interface to a local AHB-Lite
// manager, and forwards its transactions into the NoC.

// AHB-Lite is pipelined: the control information (HADDR/HTRANS/HWRITE/HSIZE) is
// sampled during the address phase, and HWDATA is presented one cycle later in
// the data phase.  This NI samples the address phase in ST_IDLE, captures
// HWDATA in ST_SETUP, and then stalls the data phase (HREADYOUT low) until the
// NoC transaction completes.

// WRITE transactions are posted: a request packet is forwarded into the mesh
// and the AHB access completes (OKAY) as soon as the router accepts it; no
// response round-trip is awaited (matching the APB/AXI NI behaviour).

// READ transactions forward a request packet (HWRITE=0) and stall the data
// phase until the response packet returns through the router-to-NI port
// carrying HRDATA (in the HDATA field position) and the response status.

// If the address does not match any map entry, the access completes with a
// two-cycle AHB ERROR response and no packet is forwarded.

`default_nettype none

module niAhbInitiator
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
, localparam int unsigned PAYLOAD_WIDTH = pa_noc::AHB_PAYLOAD_WIDTH
, localparam int unsigned PACKET_WIDTH  = PAYLOAD_WIDTH + (2 * NI_ID_WIDTH)
                                          + (COORD_WIDTH * 4)
)
( input  var logic i_clk
, input  var logic i_arst_n

  // AHB-Lite subordinate interface (this module is the subordinate)
, input  var logic        i_hsel
, input  var logic [31:0] i_haddr
, input  var logic        i_hwrite
, input  var logic [2:0]  i_hsize
, input  var logic [1:0]  i_htrans
, input  var logic [31:0] i_hwdata
, input  var logic        i_hready
, output var logic        o_hreadyout
, output var logic        o_hresp
, output var logic [31:0] o_hrdata

  // NoC router NI — initiator to router (request)
, output var logic [PACKET_WIDTH-1:0] o_niToRouter
, output var logic                    o_niToRouterValid
, input  var logic                    i_niToRouterReady

  // NoC router NI — router to initiator (response)
, input  var logic [PACKET_WIDTH-1:0] i_routerToNi
, input  var logic                    i_routerToNiValid
, output var logic                    o_routerToNiReady
);

  // {{{ FSM state definition
  typedef enum logic [2:0]
  { ST_IDLE   // Ready to sample a new AHB address phase
  , ST_SETUP  // Data phase begins: capture HWDATA, decide send vs error
  , ST_SEND   // Forwarding a request packet into the mesh
  , ST_WAIT   // Waiting for the read response packet
  , ST_OKAY   // Completing the data phase with an OKAY response
  , ST_ERR1   // AHB ERROR response, first cycle  (HREADYOUT=0, HRESP=1)
  , ST_ERR2   // AHB ERROR response, second cycle (HREADYOUT=1, HRESP=1)
  } ty_state;

  ty_state state_q, state_d;
  // }}} FSM state definition

  // {{{ Latched request fields
  // Sampled from the AHB address phase and held stable for the whole access.
  logic [31:0] haddr_q;
  logic        hwrite_q;
  logic [2:0]  hsize_q;
  logic [1:0]  htrans_q;
  logic [31:0] hwdata_q;

  // An active transfer is requested when selected, the previous transfer has
  // completed (HREADY high) and HTRANS indicates NONSEQ/SEQ (HTRANS[1] set).
  logic acceptAddr;

  always_comb
    acceptAddr = (state_q == ST_IDLE) && i_hsel && i_hready && i_htrans[1];

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      haddr_q  <= '0;
    else if (acceptAddr)
      haddr_q  <= i_haddr;
    else
      haddr_q  <= haddr_q;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      hwrite_q <= 1'b0;
    else if (acceptAddr)
      hwrite_q <= i_hwrite;
    else
      hwrite_q <= hwrite_q;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      hsize_q  <= '0;
    else if (acceptAddr)
      hsize_q  <= i_hsize;
    else
      hsize_q  <= hsize_q;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      htrans_q <= '0;
    else if (acceptAddr)
      htrans_q <= i_htrans;
    else
      htrans_q <= htrans_q;

  // HWDATA is valid in the data phase, i.e. the cycle the FSM sits in ST_SETUP.
  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      hwdata_q <= '0;
    else if (state_q == ST_SETUP)
      hwdata_q <= i_hwdata;
    else
      hwdata_q <= hwdata_q;
  // }}} Latched request fields

  // {{{ Address decode
  // Decode the latched AHB address against the statically configured address
  // map.  Entries are checked from index 0 upward; the first matching entry
  // wins.  If no entry matches, addrHit is low and the access returns ERROR.
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
            && (haddr_q >= ADDR_MAP[i].baseAddr)
            && (haddr_q <= ADDR_MAP[i].endAddr)) begin
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
            && (haddr_q >= ADDR_MAP[i].baseAddr)
            && (haddr_q <= ADDR_MAP[i].endAddr)) begin
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

  // {{{ Pack AHB request payload
  // Full NoC packet layout (MSB to LSB):
  // {Payload, srcNiId, srcRow, srcCol, dstNiId, dstRow, dstCol}
  // When MAX_NI_PER_ROUTER = 1, NI_ID_WIDTH = 0 and no ID fields exist.
  // The HRESP field is zero on a request.
  logic [PAYLOAD_WIDTH-1:0] ahbPayload;

  always_comb
    ahbPayload = {haddr_q, hwdata_q, htrans_q, hsize_q, hwrite_q, 1'b0};

  logic [COORD_WIDTH-1:0] srcRow;
  logic [COORD_WIDTH-1:0] srcCol;

  always_comb
    srcRow = COORD_WIDTH'(SRC_ROW);

  always_comb
    srcCol = COORD_WIDTH'(SRC_COL);

  if (NI_ID_WIDTH > 0)
  begin: gen_with_ids
    logic [NI_ID_WIDTH-1:0] srcNiId;

    always_comb
      srcNiId = NI_ID_WIDTH'(NI_ID);

    always_comb
      o_niToRouter =  { ahbPayload
                      , srcNiId
                      , srcRow
                      , srcCol
                      , gen_addr_decode_with_id.dstNiId
                      , dstRow
                      , dstCol
                      };
  end: gen_with_ids
  else
  begin: gen_no_ids
    always_comb
      o_niToRouter =  { ahbPayload
                      , srcRow
                      , srcCol
                      , dstRow
                      , dstCol
                      };
  end: gen_no_ids
  // }}} Pack AHB request payload

  // {{{ Capture response payload
  // Response payload uses the same encoding; HRDATA occupies the HDATA field
  // and the response status occupies the HRESP field.
  logic [PAYLOAD_WIDTH-1:0] respPayload;

  always_comb
    respPayload = i_routerToNi[PACKET_WIDTH-1 -: PAYLOAD_WIDTH];

  logic respErr;

  always_comb
    respErr = respPayload[pa_noc::AHB_HRESP_LSB];

  logic [31:0] hrdata_q;

  // Response packet accepted while waiting for it.
  logic respAccept;

  always_comb
    respAccept = (state_q == ST_WAIT) && i_routerToNiValid;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      hrdata_q <= '0;
    else if (respAccept)
      hrdata_q <= respPayload[pa_noc::AHB_HDATA_LSB +: 32];
    else
      hrdata_q <= hrdata_q;
  // }}} Capture response payload

  // {{{ FSM
  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      state_q <= ST_IDLE;
    else
      state_q <= state_d;

  always_comb
    case (state_q)
      ST_IDLE:   // sample the address phase; enter the data phase next cycle
        state_d = acceptAddr ? ST_SETUP : ST_IDLE;
      ST_SETUP:  // data phase started (HWDATA captured); route or error
        state_d = addrHit ? ST_SEND : ST_ERR1;
      ST_SEND:   // hold until the mesh accepts the request packet
        if (i_niToRouterReady)
          state_d = hwrite_q ? ST_OKAY : ST_WAIT;
        else
          state_d = ST_SEND;
      ST_WAIT:   // block until the read response packet returns
        if (i_routerToNiValid)
          state_d = respErr ? ST_ERR1 : ST_OKAY;
        else
          state_d = ST_WAIT;
      ST_OKAY:   // single-cycle OKAY completion of the data phase
        state_d = ST_IDLE;
      ST_ERR1:   // first cycle of the two-cycle AHB ERROR response
        state_d = ST_ERR2;
      ST_ERR2:   // second cycle of the two-cycle AHB ERROR response
        state_d = ST_IDLE;
      default:
        state_d = ST_IDLE;
    endcase
  // }}} FSM

  // {{{ NoC handshake
  // Drive request valid only while forwarding a request packet.
  always_comb
    o_niToRouterValid = (state_q == ST_SEND);

  // Accept a response packet only while waiting for one.
  always_comb
    o_routerToNiReady = (state_q == ST_WAIT);
  // }}} NoC handshake

  // {{{ AHB subordinate outputs
  // HREADYOUT is high when able to accept a new address phase (ST_IDLE) or when
  // completing the current data phase (ST_OKAY / ST_ERR2); it is low to insert
  // wait states while the NoC transaction is in flight.
  always_comb
    o_hreadyout = (state_q == ST_IDLE)
                || (state_q == ST_OKAY)
                || (state_q == ST_ERR2);

  // HRESP asserts across both cycles of the AHB ERROR response.
  always_comb
    o_hresp = (state_q == ST_ERR1) || (state_q == ST_ERR2);

  always_comb
    if (state_q == ST_OKAY)
      o_hrdata = hrdata_q;
    else
      o_hrdata = '0;
  // }}} AHB subordinate outputs

endmodule

`resetall
