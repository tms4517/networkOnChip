// Network Interface — APB Target

// This module sits between a NoC router NI port and a local APB target (slave).
// It receives NoC request packets from a remote initiator NI, unpacks the APB
// fields, and drives a full APB transaction (setup + access phase) to the local
// slave.
//
// WRITE transactions: the payload is unpacked into PADDR/PWDATA/PSTRB/PWRITE,
// the APB transaction completes, and the packet is consumed.
//
// READ transactions: the payload is unpacked, the APB read completes, and a
// response packet carrying PRDATA (in the PWDATA field position) is sent back
// through the NoC to the initiator.  The response destination is extracted from
// the source coordinates embedded in the incoming request packet.

`default_nettype none

module niApbTarget
  import pa_noc::*;
#(parameter int unsigned GRID_WIDTH                = 4
, parameter int unsigned MY_ROW                    = 0
, parameter int unsigned MY_COL                    = 0
, parameter int unsigned MAX_INITIATORS_PER_ROUTER = pa_noc::MAX_INITIATORS_PER_ROUTER

, localparam int unsigned COORD_WIDTH   = $clog2(GRID_WIDTH)
, localparam int unsigned ID_WIDTH      = (MAX_INITIATORS_PER_ROUTER > 1) ?
                                          $clog2(MAX_INITIATORS_PER_ROUTER) : 0
, localparam int unsigned PAYLOAD_WIDTH = APB_PAYLOAD_WIDTH
, localparam int unsigned PACKET_WIDTH  = PAYLOAD_WIDTH + ID_WIDTH + (COORD_WIDTH * 4)
)
( input  var logic i_clk
, input  var logic i_arst_n

  // APB target (slave) interface — this module is the APB master
, output var logic [31:0] o_paddr
, output var logic [31:0] o_pwdata
, output var logic        o_pwrite
, output var logic [3:0]  o_pstrb
, output var logic        o_psel
, output var logic        o_penable
, input  var logic        i_pready
, input  var logic        i_pslverr
, input  var logic [31:0] i_prdata

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
  { ST_IDLE
  , ST_APB_SETUP
  , ST_APB_ACCESS
  , ST_RESP
  } ty_state;

  ty_state state_q, state_d;

  // {{{ Unpack APB Payload
  // APB Payload encoding (same as niApbInitiator):
  // -------------------------------------------------------
  // |68            37|36             5|4      |3        0 |
  // |PADDR (32 bits) |PWDATA (32 bits)|PWRITE |PSTRB(4b)  |
  // -------------------------------------------------------
  logic [PAYLOAD_WIDTH-1:0] reqPayload;

  always_comb
    reqPayload = i_routerToNi[PACKET_WIDTH-1 -: PAYLOAD_WIDTH];

  logic [31:0] paddr_d;
  logic [31:0] pwdata_d;
  logic        pwrite_d;
  logic [3:0]  pstrb_d;

  always_comb
    paddr_d  = reqPayload[68:37];

  always_comb
    pwdata_d = reqPayload[36:5];

  always_comb
    pwrite_d = reqPayload[4];

  always_comb
    pstrb_d  = reqPayload[3:0];
  // }}} Unpack APB Payload

  // {{{ Extract source coordinates from incoming packet
  // Packet layout: {payload, [initiatorID], srcRow, srcCol, dstRow, dstCol}
  // Source coords sit at bits [4*COORD_WIDTH + ID_WIDTH - 1 : 2*COORD_WIDTH + ID_WIDTH]
  logic [COORD_WIDTH-1:0] reqSrcRow_d;
  logic [COORD_WIDTH-1:0] reqSrcCol_d;

  always_comb
    reqSrcRow_d = i_routerToNi[(4*COORD_WIDTH + ID_WIDTH)-1 -: COORD_WIDTH];

  always_comb
    reqSrcCol_d = i_routerToNi[(3*COORD_WIDTH + ID_WIDTH)-1 -: COORD_WIDTH];
  // }}} Extract source coordinates

  // {{{ Extract and latch initiator ID (when multiple initiators per router)
  // ID sits at bits [(4*COORD_WIDTH + ID_WIDTH)-1 : 4*COORD_WIDTH] in the packet
  if (ID_WIDTH > 0) begin: gen_id
    logic [ID_WIDTH-1:0] reqInitId_d;
    logic [ID_WIDTH-1:0] reqInitId_q;

    always_comb
      reqInitId_d = i_routerToNi[(4*COORD_WIDTH + ID_WIDTH)-1 -: ID_WIDTH];

    always_ff @(posedge i_clk or negedge i_arst_n)
      if (!i_arst_n)
        reqInitId_q <= '0;
      else if (state_q == ST_IDLE && i_routerToNiValid)
        reqInitId_q <= reqInitId_d;
      else
        reqInitId_q <= reqInitId_q;
  end: gen_id
  // }}} Extract and latch initiator ID

  // {{{ Flop incoming request fields
  // To ensure they remain stable across APB phases
  logic [31:0] paddr_q;
  logic [31:0] pwdata_q;
  logic        pwrite_q;
  logic [3:0]  pstrb_q;
  logic [COORD_WIDTH-1:0] reqSrcRow_q;
  logic [COORD_WIDTH-1:0] reqSrcCol_q;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      paddr_q  <= '0;
    else if (state_q == ST_IDLE && i_routerToNiValid)
      paddr_q  <= paddr_d;
    else
      paddr_q  <= paddr_q;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      pwdata_q <= '0;
    else if (state_q == ST_IDLE && i_routerToNiValid)
      pwdata_q <= pwdata_d;
    else
      pwdata_q <= pwdata_q;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      pwrite_q <= '0;
    else if (state_q == ST_IDLE && i_routerToNiValid)
      pwrite_q <= pwrite_d;
    else
      pwrite_q <= pwrite_q;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      pstrb_q  <= '0;
    else if (state_q == ST_IDLE && i_routerToNiValid)
      pstrb_q  <= pstrb_d;
    else
      pstrb_q  <= pstrb_q;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      reqSrcRow_q <= '0;
    else if (state_q == ST_IDLE && i_routerToNiValid)
      reqSrcRow_q <= reqSrcRow_d;
    else
      reqSrcRow_q <= reqSrcRow_q;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      reqSrcCol_q <= '0;
    else if (state_q == ST_IDLE && i_routerToNiValid)
      reqSrcCol_q <= reqSrcCol_d;
    else
      reqSrcCol_q <= reqSrcCol_q;
  // }}} Flop incoming request fields

  // {{{ FSM
  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      state_q <= ST_IDLE;
    else
      state_q <= state_d;

  always_comb
    case (state_q)
      ST_IDLE:
        state_d = i_routerToNiValid ? ST_APB_SETUP : ST_IDLE;
      ST_APB_SETUP:
        state_d = ST_APB_ACCESS;
      ST_APB_ACCESS:
        if (i_pready)
          state_d = pwrite_q ? ST_IDLE : ST_RESP;
        else
          state_d = ST_APB_ACCESS;
      ST_RESP:
        state_d = i_niToRouterReady ? ST_IDLE : ST_RESP;
      default:
        state_d = ST_IDLE;
    endcase

  // Latch PRDATA from the slave when the access phase completes
  logic [31:0] prdata_q;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      prdata_q <= '0;
    else if (state_q == ST_APB_ACCESS && i_pready)
      prdata_q <= i_prdata;
    else
      prdata_q <= prdata_q;
  // }}} FSM

  // {{{ APB master outputs
  always_comb
    o_psel    = (state_q == ST_APB_SETUP) || (state_q == ST_APB_ACCESS);

  always_comb
    o_penable = (state_q == ST_APB_ACCESS);

  always_comb
    o_paddr   = paddr_q;

  always_comb
    o_pwdata  = pwdata_q;

  always_comb
    o_pwrite  = pwrite_q;

  always_comb
    o_pstrb   = pstrb_q;
  // }}} APB master outputs

  // {{{ NoC handshake
  // Accept a request packet only when idle.
  always_comb
    if (state_q == ST_IDLE)
      o_routerToNiReady = 1'b1;
    else
      o_routerToNiReady = 1'b0;

  // Response packet: PRDATA in the PWDATA field position, same encoding.
  // Response payload: {PADDR, PRDATA, PWRITE=0, PSTRB=0}
  // Response destination = request's source coords (dynamic routing).
  // Response source = this target's own position (MY_ROW, MY_COL).
  // Response initiator ID = echoed from request (when ID_WIDTH > 0).
  logic [PAYLOAD_WIDTH-1:0] respPayload;
  logic [COORD_WIDTH-1:0]   respSrcRow;
  logic [COORD_WIDTH-1:0]   respSrcCol;

  always_comb
    respPayload = {paddr_q, prdata_q, 1'b0, 4'b0000};

  always_comb
    respSrcRow = COORD_WIDTH'(MY_ROW);

  always_comb
    respSrcCol = COORD_WIDTH'(MY_COL);

  if (ID_WIDTH > 0) begin: gen_resp_with_id
    always_comb
      o_niToRouter =  { respPayload
                      , gen_id.reqInitId_q
                      , respSrcRow
                      , respSrcCol
                      , reqSrcRow_q
                      , reqSrcCol_q
                      };
  end: gen_resp_with_id
  else begin: gen_resp_no_id
    always_comb
      o_niToRouter =  { respPayload
                      , respSrcRow
                      , respSrcCol
                      , reqSrcRow_q
                      , reqSrcCol_q
                      };
  end: gen_resp_no_id

  // Drive response valid only in the RESP state.
  always_comb
    if (state_q == ST_RESP)
      o_niToRouterValid = 1'b1;
    else
      o_niToRouterValid = 1'b0;
  // }}} NoC handshake

endmodule

`resetall
