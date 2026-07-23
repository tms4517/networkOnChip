// Network Interface — AHB-Lite Target (subordinate-facing)

// This module receives NoC request packets from a remote initiator NI, unpacks
// the AHB-Lite fields, and drives a full AHB-Lite transaction as the MANAGER
// towards a local AHB-Lite subordinate.

// WRITE: the payload is unpacked into HADDR/HWDATA/HSIZE/HWRITE, the address and
// data phases are driven, and the access completes locally.  Writes are posted
// (no response packet is sent back), matching the APB/AXI NI behaviour.

// READ: the payload is unpacked into HADDR, the address and data phases are
// driven, HRDATA/HRESP are captured, and a response packet carrying HRDATA (in
// the HDATA field position) and the response status is sent back through the
// NoC to the initiator.

// The response destination is taken from the source coordinates embedded in the
// incoming request packet (dynamic routing).

`default_nettype none

module niAhbTarget
#(parameter int unsigned GRID_WIDTH        = 4
, parameter int unsigned MY_ROW            = 0
, parameter int unsigned MY_COL            = 0
, parameter int unsigned MAX_NI_PER_ROUTER = pa_noc::MAX_NI_PER_ROUTER
, parameter int unsigned NI_ID             = 0

, localparam int unsigned COORD_WIDTH   = $clog2(GRID_WIDTH)
, localparam int unsigned NI_ID_WIDTH   = (MAX_NI_PER_ROUTER > 1) ?
                                          $clog2(MAX_NI_PER_ROUTER) : 0
, localparam int unsigned PAYLOAD_WIDTH = pa_noc::AHB_PAYLOAD_WIDTH
, localparam int unsigned PACKET_WIDTH  = PAYLOAD_WIDTH + (2 * NI_ID_WIDTH)
                                          + (COORD_WIDTH * 4)
)
( input  var logic i_clk
, input  var logic i_arst_n

  // AHB-Lite manager interface (this module is the manager)
, output var logic        o_hsel
, output var logic [31:0] o_haddr
, output var logic        o_hwrite
, output var logic [2:0]  o_hsize
, output var logic [1:0]  o_htrans
, output var logic [31:0] o_hwdata
, input  var logic [31:0] i_hrdata
, input  var logic        i_hready
, input  var logic        i_hresp

  // NoC router NI — router to target (request)
, input  var logic [PACKET_WIDTH-1:0] i_routerToNi
, input  var logic                    i_routerToNiValid
, output var logic                    o_routerToNiReady

  // NoC router NI — target to router (response)
, output var logic [PACKET_WIDTH-1:0] o_niToRouter
, output var logic                    o_niToRouterValid
, input  var logic                    i_niToRouterReady
);

  typedef enum logic [1:0]
  { ST_IDLE  // Waiting for an incoming request packet
  , ST_ADDR  // Driving the AHB address phase
  , ST_DATA  // Driving the AHB data phase (capture HRDATA/HRESP)
  , ST_RESP  // Sending the read response packet back through the NoC
  } ty_state;

  ty_state state_q, state_d;

  // Request packet accepted this cycle (ready/valid handshake completes).
  // o_routerToNiReady is only asserted in ST_IDLE, so reqAccept already implies
  // the FSM is idle.
  logic reqAccept;

  always_comb
    reqAccept = i_routerToNiValid && o_routerToNiReady;

  // {{{ Unpack AHB request payload
  logic [PAYLOAD_WIDTH-1:0] reqPayload;

  always_comb
    reqPayload = i_routerToNi[PACKET_WIDTH-1 -: PAYLOAD_WIDTH];

  logic [31:0] haddr_d;
  logic [31:0] hwdata_d;
  logic        hwrite_d;
  logic [2:0]  hsize_d;

  always_comb
    haddr_d  = reqPayload[pa_noc::AHB_HADDR_LSB +: 32];

  always_comb
    hwdata_d = reqPayload[pa_noc::AHB_HDATA_LSB +: 32];

  always_comb
    hwrite_d = reqPayload[pa_noc::AHB_HWRITE_LSB];

  always_comb
    hsize_d  = reqPayload[pa_noc::AHB_HSIZE_LSB +: 3];
  // }}} Unpack AHB request payload

  // {{{ Extract source coordinates from incoming packet
  // Packet layout: {payload, srcNiId, srcRow, srcCol, dstNiId, dstRow, dstCol}
  logic [COORD_WIDTH-1:0] reqSrcRow_d;
  logic [COORD_WIDTH-1:0] reqSrcCol_d;

  always_comb
    reqSrcRow_d = i_routerToNi[(4*COORD_WIDTH + NI_ID_WIDTH)-1
                                -: COORD_WIDTH];

  always_comb
    reqSrcCol_d = i_routerToNi[(3*COORD_WIDTH + NI_ID_WIDTH)-1
                                -: COORD_WIDTH];
  // }}} Extract source coordinates

  // {{{ Extract and latch source NI ID (when MAX_NI_PER_ROUTER > 1)
  if (NI_ID_WIDTH > 0)
  begin: gen_id
    logic [NI_ID_WIDTH-1:0] reqSrcNiId_d;
    logic [NI_ID_WIDTH-1:0] reqSrcNiId_q;

    always_comb
      reqSrcNiId_d = i_routerToNi[(4*COORD_WIDTH + 2*NI_ID_WIDTH)-1
                                    -: NI_ID_WIDTH];

    always_ff @(posedge i_clk or negedge i_arst_n)
      if (!i_arst_n)
        reqSrcNiId_q <= '0;
      else if (reqAccept)
        reqSrcNiId_q <= reqSrcNiId_d;
      else
        reqSrcNiId_q <= reqSrcNiId_q;
  end: gen_id
  // }}} Extract and latch source NI ID

  // {{{ Flop incoming request fields
  logic [31:0]            haddr_q;
  logic [31:0]            hwdata_q;
  logic                   hwrite_q;
  logic [2:0]             hsize_q;
  logic [COORD_WIDTH-1:0] reqSrcRow_q;
  logic [COORD_WIDTH-1:0] reqSrcCol_q;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      haddr_q <= '0;
    else if (reqAccept)
      haddr_q <= haddr_d;
    else
      haddr_q <= haddr_q;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      hwdata_q <= '0;
    else if (reqAccept)
      hwdata_q <= hwdata_d;
    else
      hwdata_q <= hwdata_q;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      hwrite_q <= 1'b0;
    else if (reqAccept)
      hwrite_q <= hwrite_d;
    else
      hwrite_q <= hwrite_q;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      hsize_q <= '0;
    else if (reqAccept)
      hsize_q <= hsize_d;
    else
      hsize_q <= hsize_q;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      reqSrcRow_q <= '0;
    else if (reqAccept)
      reqSrcRow_q <= reqSrcRow_d;
    else
      reqSrcRow_q <= reqSrcRow_q;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      reqSrcCol_q <= '0;
    else if (reqAccept)
      reqSrcCol_q <= reqSrcCol_d;
    else
      reqSrcCol_q <= reqSrcCol_q;
  // }}} Flop incoming request fields

  // {{{ FSM
  // The FSM sequences one incoming NoC request through the full AHB-Lite
  // transaction and, for reads, back into a response packet, handling exactly
  // one request at a time.

  // Single-outstanding guarantee: the FSM leaves ST_IDLE only on reqAccept, and
  // o_routerToNiReady is asserted only in ST_IDLE, so a new request cannot be
  // consumed until the current one has driven its AHB access (and, for reads,
  // pushed its response packet back into the mesh).

  // Write path: ST_ADDR -> ST_DATA drives the address and data phases; writes
  // are posted so the FSM returns to ST_IDLE once the data phase completes.
  // Read path: ST_ADDR -> ST_DATA captures HRDATA/HRESP, then ST_RESP sends the
  // response packet and blocks until i_niToRouterReady accepts it.
  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      state_q <= ST_IDLE;
    else
      state_q <= state_d;

  always_comb
    case (state_q)
      ST_IDLE:  // wait for a request packet
        state_d = reqAccept ? ST_ADDR : ST_IDLE;
      ST_ADDR:  // drive the address phase, hold until the slave is ready
        state_d = i_hready ? ST_DATA : ST_ADDR;
      ST_DATA:  // drive the data phase, hold until the slave completes it
        if (i_hready)
          state_d = hwrite_q ? ST_IDLE : ST_RESP;
        else
          state_d = ST_DATA;
      ST_RESP:  // send response packet, hold until the mesh accepts it
        state_d = i_niToRouterReady ? ST_IDLE : ST_RESP;
      default:
        state_d = ST_IDLE;
    endcase
  // }}} FSM

  // {{{ Capture AHB response
  logic [31:0] hrdata_q;
  logic        hresp_q;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      hrdata_q <= '0;
    else if (state_q == ST_DATA && i_hready)
      hrdata_q <= i_hrdata;
    else
      hrdata_q <= hrdata_q;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      hresp_q <= 1'b0;
    else if (state_q == ST_DATA && i_hready)
      hresp_q <= i_hresp;
    else
      hresp_q <= hresp_q;
  // }}} Capture AHB response

  // {{{ AHB manager outputs
  always_comb
    o_hsel = (state_q == ST_ADDR) || (state_q == ST_DATA);

  always_comb
    if (state_q == ST_ADDR)
      o_htrans = pa_noc::AHB_TRANS_NONSEQ;
    else
      o_htrans = pa_noc::AHB_TRANS_IDLE;

  always_comb
    o_haddr = haddr_q;

  always_comb
    o_hwrite = hwrite_q;

  always_comb
    o_hsize = hsize_q;

  always_comb
    o_hwdata = hwdata_q;
  // }}} AHB manager outputs

  // {{{ NoC handshake
  // Accept a request packet only when idle and destination NI ID matches
  // (if applicable).
  if (NI_ID_WIDTH > 0)
  begin: gen_ni_filter
    logic niIdMatch;

    always_comb
      niIdMatch = (i_routerToNi[(2*COORD_WIDTH + NI_ID_WIDTH)-1 -: NI_ID_WIDTH]
                  == NI_ID_WIDTH'(NI_ID));

    always_comb
      if (state_q == ST_IDLE && niIdMatch)
        o_routerToNiReady = 1'b1;
      else
        o_routerToNiReady = 1'b0;
  end: gen_ni_filter
  else
  begin: gen_no_ni_filter
    always_comb
      if (state_q == ST_IDLE)
        o_routerToNiReady = 1'b1;
      else
        o_routerToNiReady = 1'b0;
  end: gen_no_ni_filter

  // Response packet (reads only): HRDATA in the HDATA field position, HRESP in
  // the HRESP field, HWRITE echoed.  HTRANS/HSIZE fields are unused on a
  // response and are packed as zero.
  // Response destination = request's source coords (dynamic routing).
  // Response source = this target's own position (MY_ROW, MY_COL).
  logic [PAYLOAD_WIDTH-1:0] respPayload;
  logic [COORD_WIDTH-1:0]   respSrcRow;
  logic [COORD_WIDTH-1:0]   respSrcCol;

  always_comb
    respPayload = {haddr_q, hrdata_q, 2'b00, 3'b000, hwrite_q, hresp_q};

  always_comb
    respSrcRow = COORD_WIDTH'(MY_ROW);

  always_comb
    respSrcCol = COORD_WIDTH'(MY_COL);

  if (NI_ID_WIDTH > 0)
  begin: gen_resp_with_ids
    always_comb
      o_niToRouter =  { respPayload
                      , NI_ID_WIDTH'(NI_ID)
                      , respSrcRow
                      , respSrcCol
                      , gen_id.reqSrcNiId_q
                      , reqSrcRow_q
                      , reqSrcCol_q
                      };
  end: gen_resp_with_ids
  else
  begin: gen_resp_no_ids
    always_comb
      o_niToRouter =  { respPayload
                      , respSrcRow
                      , respSrcCol
                      , reqSrcRow_q
                      , reqSrcCol_q
                      };
  end: gen_resp_no_ids

  // Drive response valid only in the RESP state.
  always_comb
    o_niToRouterValid = (state_q == ST_RESP);
  // }}} NoC handshake

endmodule

`resetall
