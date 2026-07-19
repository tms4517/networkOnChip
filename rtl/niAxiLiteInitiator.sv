// Network Interface — AXI4-Lite Initiator (manager-facing)

// This module presents an AXI4-Lite SUBORDINATE interface to a local AXI4-Lite
// manager, and forwards its transactions into the NoC.  It is the AXI4-Lite
// counterpart of niApbInitiator.
//
// On a WRITE (AW + W), the address is decoded against the address map to select
// the destination router, a request packet is assembled and forwarded into the
// mesh, and once the write response packet returns, the B channel is driven.
//
// On a READ (AR), a request packet (WRITE=0) is forwarded into the mesh.  When
// the response packet returns through the router-to-NI port, the R channel is
// driven with RDATA/RRESP.
//
// If the address does not match any map entry, the transaction still completes
// but returns a DECERR response (no packet is forwarded).

`default_nettype none

module niAxiLiteInitiator
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
, localparam int unsigned PAYLOAD_WIDTH = pa_axi::AXI_LITE_PAYLOAD_WIDTH
, localparam int unsigned PACKET_WIDTH  = PAYLOAD_WIDTH + (2 * NI_ID_WIDTH)
                                          + (COORD_WIDTH * 4)
)
( input  var logic i_clk
, input  var logic i_arst_n

  // AXI4-Lite subordinate interface (this module is the subordinate)
  // Write address channel
, input  var logic [31:0] i_awaddr
, input  var logic        i_awvalid
, output var logic        o_awready
  // Write data channel
, input  var logic [31:0] i_wdata
, input  var logic [3:0]  i_wstrb
, input  var logic        i_wvalid
, output var logic        o_wready
  // Write response channel
, output var logic [1:0]  o_bresp
, output var logic        o_bvalid
, input  var logic        i_bready
  // Read address channel
, input  var logic [31:0] i_araddr
, input  var logic        i_arvalid
, output var logic        o_arready
  // Read data channel
, output var logic [31:0] o_rdata
, output var logic [1:0]  o_rresp
, output var logic        o_rvalid
, input  var logic        i_rready

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
  { ST_IDLE     // Ready for a new AXI transaction
  , ST_WR_SEND  // Forwarding a write request packet into the mesh
  , ST_WR_WAIT  // Waiting for the write response packet
  , ST_WR_B     // Driving the AXI B (write response) channel
  , ST_RD_SEND  // Forwarding a read request packet into the mesh
  , ST_RD_WAIT  // Waiting for the read response packet
  , ST_RD_R     // Driving the AXI R (read data) channel
  } ty_state;

  ty_state state_q, state_d;
  // }}} FSM state definition

  // {{{ New-transaction arbitration (read priority)
  logic readReq;
  logic writeReq;

  always_comb
    readReq = i_arvalid;

  always_comb
    writeReq = i_awvalid && i_wvalid;

  // Address used for map decode: read address takes priority over write.
  logic [31:0] reqAddr;

  always_comb
    if (readReq)
      reqAddr = i_araddr;
    else
      reqAddr = i_awaddr;
  // }}} New-transaction arbitration

  // {{{ Address decode
  // Decode reqAddr against the statically configured address map.  Entries are
  // checked from index 0 upward; the first matching entry wins.  If no entry
  // matches, addrHit is low and the transaction returns a DECERR response.
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
            && (reqAddr >= ADDR_MAP[i].baseAddr)
            && (reqAddr <= ADDR_MAP[i].endAddr)) begin
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
            && (reqAddr >= ADDR_MAP[i].baseAddr)
            && (reqAddr <= ADDR_MAP[i].endAddr)) begin
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

  // {{{ Accept the request in IDLE and latch its fields
  // A read is accepted when i_arvalid; a write is accepted when both i_awvalid
  // and i_wvalid are present.  Read has priority.  The relevant handshakes
  // (o_arready / o_awready+o_wready) are asserted for a single cycle in IDLE.
  logic acceptRead;
  logic acceptWrite;

  always_comb
    acceptRead = (state_q == ST_IDLE) && readReq;

  always_comb
    acceptWrite = (state_q == ST_IDLE) && !readReq && writeReq;

  always_comb
    o_arready = acceptRead;

  always_comb
    o_awready = acceptWrite;

  always_comb
    o_wready = acceptWrite;

  // Latched request fields (stable across the send/response phases).
  logic [31:0]            addr_q;
  logic [31:0]            wdata_q;
  logic [3:0]             wstrb_q;
  logic                   write_q;
  logic [COORD_WIDTH-1:0] dstRow_q;
  logic [COORD_WIDTH-1:0] dstCol_q;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      addr_q   <= '0;
    else if (acceptRead)
      addr_q   <= i_araddr;
    else if (acceptWrite)
      addr_q   <= i_awaddr;
    else
      addr_q   <= addr_q;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      wdata_q  <= '0;
    else if (acceptRead)
      wdata_q  <= '0;
    else if (acceptWrite)
      wdata_q  <= i_wdata;
    else
      wdata_q  <= wdata_q;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      wstrb_q  <= '0;
    else if (acceptRead)
      wstrb_q  <= '0;
    else if (acceptWrite)
      wstrb_q  <= i_wstrb;
    else
      wstrb_q  <= wstrb_q;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      write_q  <= 1'b0;
    else if (acceptRead)
      write_q  <= 1'b0;
    else if (acceptWrite)
      write_q  <= 1'b1;
    else
      write_q  <= write_q;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      dstRow_q <= '0;
    else if (acceptRead || acceptWrite)
      dstRow_q <= dstRow;
    else
      dstRow_q <= dstRow_q;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      dstCol_q <= '0;
    else if (acceptRead || acceptWrite)
      dstCol_q <= dstCol;
    else
      dstCol_q <= dstCol_q;

  // Latched destination NI ID (when MAX_NI_PER_ROUTER > 1).
  if (NI_ID_WIDTH > 0)
  begin: gen_dst_id_latch
    logic [NI_ID_WIDTH-1:0] dstNiId_q;

    always_ff @(posedge i_clk or negedge i_arst_n)
      if (!i_arst_n)
        dstNiId_q <= '0;
      else if (acceptRead || acceptWrite)
        dstNiId_q <= gen_addr_decode_with_id.dstNiId;
      else
        dstNiId_q <= dstNiId_q;
  end: gen_dst_id_latch
  // }}} Accept the request in IDLE and latch its fields

  // {{{ Pack AXI-Lite request payload
  // Payload encoding (LSB to MSB): {ADDR, DATA, WSTRB, WRITE, RESP}
  // RESP field is zero on a request.
  logic [PAYLOAD_WIDTH-1:0] axiPayload;

  always_comb
    axiPayload = {addr_q, wdata_q, wstrb_q, write_q, pa_axi::AXI_RESP_OKAY};

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
      o_niToRouter =  { axiPayload
                      , srcNiId
                      , srcRow
                      , srcCol
                      , gen_dst_id_latch.dstNiId_q
                      , dstRow_q
                      , dstCol_q
                      };
  end: gen_with_ids
  else
  begin: gen_no_ids
    always_comb
      o_niToRouter =  { axiPayload
                      , srcRow
                      , srcCol
                      , dstRow_q
                      , dstCol_q
                      };
  end: gen_no_ids
  // }}} Pack AXI-Lite request payload

  // {{{ FSM
  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      state_q <= ST_IDLE;
    else
      state_q <= state_d;

  always_comb
    case (state_q)
      ST_IDLE:
        if (acceptRead)
          state_d = addrHit ? ST_RD_SEND : ST_RD_R;
        else if (acceptWrite)
          state_d = addrHit ? ST_WR_SEND : ST_WR_B;
        else
          state_d = ST_IDLE;
      ST_WR_SEND:
        state_d = i_niToRouterReady ? ST_WR_WAIT : ST_WR_SEND;
      ST_WR_WAIT:
        state_d = i_routerToNiValid ? ST_WR_B : ST_WR_WAIT;
      ST_WR_B:
        state_d = i_bready ? ST_IDLE : ST_WR_B;
      ST_RD_SEND:
        state_d = i_niToRouterReady ? ST_RD_WAIT : ST_RD_SEND;
      ST_RD_WAIT:
        state_d = i_routerToNiValid ? ST_RD_R : ST_RD_WAIT;
      ST_RD_R:
        state_d = i_rready ? ST_IDLE : ST_RD_R;
      default:
        state_d = ST_IDLE;
    endcase
  // }}} FSM

  // {{{ Capture response payload
  // Response payload uses the same encoding; RDATA occupies the DATA field and
  // the response code occupies the RESP field.
  logic [PAYLOAD_WIDTH-1:0] respPayload;

  always_comb
    respPayload = i_routerToNi[PACKET_WIDTH-1 -: PAYLOAD_WIDTH];

  logic [31:0] rdata_q;
  logic [1:0]  resp_q;

  // Response packet accepted while waiting for it.
  logic respAccept;

  always_comb
    respAccept = (state_q == ST_WR_WAIT || state_q == ST_RD_WAIT)
      && i_routerToNiValid;

  // New transaction started with no matching address map entry (DECERR).
  logic noHitStart;

  always_comb
    noHitStart = (state_q == ST_IDLE) && (acceptRead || acceptWrite) && !addrHit;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      rdata_q <= '0;
    else if (respAccept)
      rdata_q <= respPayload[pa_axi::AXI_DATA_LSB +: 32];
    else if (noHitStart)
      rdata_q <= '0;
    else
      rdata_q <= rdata_q;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      resp_q  <= pa_axi::AXI_RESP_OKAY;
    else if (respAccept)
      resp_q  <= respPayload[pa_axi::AXI_RESP_LSB +: 2];
    else if (noHitStart)
      resp_q  <= pa_axi::AXI_RESP_DECERR;
    else
      resp_q  <= resp_q;
  // }}} Capture response payload

  // {{{ NoC handshake
  // Drive request valid only while forwarding a request packet.
  always_comb
    o_niToRouterValid = (state_q == ST_WR_SEND) || (state_q == ST_RD_SEND);

  // Accept a response packet only while waiting for one.
  always_comb
    o_routerToNiReady = (state_q == ST_WR_WAIT) || (state_q == ST_RD_WAIT);
  // }}} NoC handshake

  // {{{ AXI response outputs
  always_comb
    o_bvalid = (state_q == ST_WR_B);

  always_comb
    o_bresp = resp_q;

  always_comb
    o_rvalid = (state_q == ST_RD_R);

  always_comb
    o_rdata = rdata_q;

  always_comb
    o_rresp = resp_q;
  // }}} AXI response outputs

endmodule

`resetall
