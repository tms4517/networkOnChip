// Network Interface — AXI4-Lite Target (subordinate-facing)

// This module receives NoC request packets from a remote initiator NI, unpacks
// the AXI4-Lite fields, and drives a full AXI4-Lite transaction as the MANAGER
// towards a local AXI4-Lite subordinate.  It is the AXI4-Lite counterpart of
// niApbTarget.
//
// WRITE: the payload is unpacked into AWADDR/WDATA/WSTRB, the AW and W channels
// are driven, the B response is captured, and a response packet carrying BRESP
// is sent back through the NoC to the initiator.
//
// READ: the payload is unpacked into ARADDR, the AR channel is driven, the R
// response (RDATA/RRESP) is captured, and a response packet is sent back.
//
// The response destination is taken from the source coordinates embedded in the
// incoming request packet (dynamic routing).

`default_nettype none

module niAxiLiteTarget
#(parameter int unsigned GRID_WIDTH        = 4
, parameter int unsigned MY_ROW            = 0
, parameter int unsigned MY_COL            = 0
, parameter int unsigned MAX_NI_PER_ROUTER = pa_noc::MAX_NI_PER_ROUTER
, parameter int unsigned NI_ID             = 0

, localparam int unsigned COORD_WIDTH   = $clog2(GRID_WIDTH)
, localparam int unsigned NI_ID_WIDTH   = (MAX_NI_PER_ROUTER > 1) ?
                                          $clog2(MAX_NI_PER_ROUTER) : 0
, localparam int unsigned PAYLOAD_WIDTH = pa_noc::AXI_LITE_PAYLOAD_WIDTH
, localparam int unsigned PACKET_WIDTH  = PAYLOAD_WIDTH + (2 * NI_ID_WIDTH)
                                          + (COORD_WIDTH * 4)
)
( input  var logic i_clk
, input  var logic i_arst_n

  // AXI4-Lite manager interface (this module is the manager)
  // Write address channel
, output var logic [31:0] o_awaddr
, output var logic        o_awvalid
, input  var logic        i_awready
  // Write data channel
, output var logic [31:0] o_wdata
, output var logic [3:0]  o_wstrb
, output var logic        o_wvalid
, input  var logic        i_wready
  // Write response channel
, input  var logic [1:0]  i_bresp
, input  var logic        i_bvalid
, output var logic        o_bready
  // Read address channel
, output var logic [31:0] o_araddr
, output var logic        o_arvalid
, input  var logic        i_arready
  // Read data channel
, input  var logic [31:0] i_rdata
, input  var logic [1:0]  i_rresp
, input  var logic        i_rvalid
, output var logic        o_rready

  // NoC router NI — router to target (request)
, input  var logic [PACKET_WIDTH-1:0] i_routerToNi
, input  var logic                    i_routerToNiValid
, output var logic                    o_routerToNiReady

  // NoC router NI — target to router (response)
, output var logic [PACKET_WIDTH-1:0] o_niToRouter
, output var logic                    o_niToRouterValid
, input  var logic                    i_niToRouterReady
);

  typedef enum logic [2:0]
  { ST_IDLE   // Waiting for an incoming request packet
  , ST_AW     // Driving the AXI write address channel
  , ST_W      // Driving the AXI write data channel
  , ST_B      // Awaiting the AXI write response
  , ST_AR     // Driving the AXI read address channel
  , ST_R      // Awaiting the AXI read data
  , ST_RESP   // Sending the response packet back through the NoC
  } ty_state;

  ty_state state_q, state_d;

  // {{{ Unpack AXI-Lite request payload
  // Payload encoding (LSB to MSB): {ADDR, DATA, WSTRB, WRITE, RESP}
  logic [PAYLOAD_WIDTH-1:0] reqPayload;

  always_comb
    reqPayload = i_routerToNi[PACKET_WIDTH-1 -: PAYLOAD_WIDTH];

  logic [31:0] addr_d;
  logic [31:0] wdata_d;
  logic [3:0]  wstrb_d;
  logic        write_d;

  always_comb
    addr_d  = reqPayload[pa_noc::AXI_ADDR_LSB +: 32];

  always_comb
    wdata_d = reqPayload[pa_noc::AXI_DATA_LSB +: 32];

  always_comb
    wstrb_d = reqPayload[pa_noc::AXI_WSTRB_LSB +: 4];

  always_comb
    write_d = reqPayload[pa_noc::AXI_WRITE_LSB];
  // }}} Unpack AXI-Lite request payload

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
      else if (state_q == ST_IDLE && i_routerToNiValid && o_routerToNiReady)
        reqSrcNiId_q <= reqSrcNiId_d;
      else
        reqSrcNiId_q <= reqSrcNiId_q;
  end: gen_id
  // }}} Extract and latch source NI ID

  // {{{ Flop incoming request fields
  logic [31:0]            addr_q;
  logic [31:0]            wdata_q;
  logic [3:0]             wstrb_q;
  logic                   write_q;
  logic [COORD_WIDTH-1:0] reqSrcRow_q;
  logic [COORD_WIDTH-1:0] reqSrcCol_q;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      addr_q      <= '0;
    else if (state_q == ST_IDLE && i_routerToNiValid && o_routerToNiReady)
      addr_q      <= addr_d;
    else
      addr_q      <= addr_q;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      wdata_q     <= '0;
    else if (state_q == ST_IDLE && i_routerToNiValid && o_routerToNiReady)
      wdata_q     <= wdata_d;
    else
      wdata_q     <= wdata_q;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      wstrb_q     <= '0;
    else if (state_q == ST_IDLE && i_routerToNiValid && o_routerToNiReady)
      wstrb_q     <= wstrb_d;
    else
      wstrb_q     <= wstrb_q;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      write_q     <= 1'b0;
    else if (state_q == ST_IDLE && i_routerToNiValid && o_routerToNiReady)
      write_q     <= write_d;
    else
      write_q     <= write_q;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      reqSrcRow_q <= '0;
    else if (state_q == ST_IDLE && i_routerToNiValid && o_routerToNiReady)
      reqSrcRow_q <= reqSrcRow_d;
    else
      reqSrcRow_q <= reqSrcRow_q;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      reqSrcCol_q <= '0;
    else if (state_q == ST_IDLE && i_routerToNiValid && o_routerToNiReady)
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
        if (i_routerToNiValid && o_routerToNiReady)
          state_d = write_d ? ST_AW : ST_AR;
        else
          state_d = ST_IDLE;
      ST_AW:
        state_d = i_awready ? ST_W : ST_AW;
      ST_W:
        state_d = i_wready ? ST_B : ST_W;
      ST_B:
        state_d = i_bvalid ? ST_RESP : ST_B;
      ST_AR:
        state_d = i_arready ? ST_R : ST_AR;
      ST_R:
        state_d = i_rvalid ? ST_RESP : ST_R;
      ST_RESP:
        state_d = i_niToRouterReady ? ST_IDLE : ST_RESP;
      default:
        state_d = ST_IDLE;
    endcase
  // }}} FSM

  // {{{ Capture AXI response
  logic [31:0] rdata_q;
  logic [1:0]  resp_q;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      rdata_q <= '0;
    else if (state_q == ST_R && i_rvalid)
      rdata_q <= i_rdata;
    else if (state_q == ST_B && i_bvalid)
      rdata_q <= '0;
    else
      rdata_q <= rdata_q;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      resp_q  <= pa_noc::AXI_RESP_OKAY;
    else if (state_q == ST_B && i_bvalid)
      resp_q  <= i_bresp;
    else if (state_q == ST_R && i_rvalid)
      resp_q  <= i_rresp;
    else
      resp_q  <= resp_q;
  // }}} Capture AXI response

  // {{{ AXI manager outputs
  always_comb
    o_awvalid = (state_q == ST_AW);

  always_comb
    o_awaddr = addr_q;

  always_comb
    o_wvalid = (state_q == ST_W);

  always_comb
    o_wdata = wdata_q;

  always_comb
    o_wstrb = wstrb_q;

  always_comb
    o_bready = (state_q == ST_B);

  always_comb
    o_arvalid = (state_q == ST_AR);

  always_comb
    o_araddr = addr_q;

  always_comb
    o_rready = (state_q == ST_R);
  // }}} AXI manager outputs

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

  // Response payload: {ADDR, DATA, WSTRB=0, WRITE echoed, RESP}
  //   write response -> DATA=0,     RESP=BRESP
  //   read  response -> DATA=RDATA, RESP=RRESP
  // Response destination = request's source coords (dynamic routing).
  // Response source = this target's own position (MY_ROW, MY_COL).
  logic [PAYLOAD_WIDTH-1:0] respPayload;
  logic [COORD_WIDTH-1:0]   respSrcRow;
  logic [COORD_WIDTH-1:0]   respSrcCol;

  always_comb
    respPayload = {addr_q, rdata_q, 4'b0000, write_q, resp_q};

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
