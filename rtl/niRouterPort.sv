// NI router-port multiplexer
//
// The NoC mesh exposes a single NI port per router.  This module shares that
// one port among up to MAX_NI_PER_ROUTER local network interfaces (any mix of
// niApbInitiator / niApbTarget), each of which owns a unique NI_ID.
//
//   NI -> router (ingress): a round-robin arbiter selects one local NI's
//   outgoing packet and drives the single router ingress port.
//
//   router -> NI (egress):  the incoming packet is demultiplexed to exactly one
//   local NI using the packet's destination NI-ID field.
//
// This keeps the network-layer endpoint selection (NI_ID) fully decoupled from
// the routing address map (which lives only inside initiators) and from any
// local slave decode (which lives only inside targets).
//
// When MAX_NI_PER_ROUTER == 1 the module degenerates to a transparent
// pass-through with no arbitration or demux overhead.

`default_nettype none

module niRouterPort
#(parameter int unsigned GRID_WIDTH        = 4
, parameter int unsigned MAX_NI_PER_ROUTER = pa_noc::MAX_NI_PER_ROUTER
, parameter int unsigned PAYLOAD_WIDTH     = pa_noc::APB_PAYLOAD_WIDTH

, localparam int unsigned NUM_NI        = (MAX_NI_PER_ROUTER < 1)
                                          ? 1 : MAX_NI_PER_ROUTER
, localparam int unsigned COORD_WIDTH   = $clog2(GRID_WIDTH)
, localparam int unsigned NI_ID_WIDTH   = (MAX_NI_PER_ROUTER > 1)
                                          ? $clog2(MAX_NI_PER_ROUTER) : 0
, localparam int unsigned PACKET_WIDTH  = PAYLOAD_WIDTH + (2 * NI_ID_WIDTH)
                                          + (COORD_WIDTH * 4)
  // Destination NI-ID field sits just above the destination row/col fields.
, localparam int unsigned DST_NIID_LSB  = 2 * COORD_WIDTH
)
( input  var logic i_clk
, input  var logic i_arst_n

  // Router NI port (single) — connects to one mesh router NI slot.
, output var logic [PACKET_WIDTH-1:0] o_niToRouter
, output var logic                    o_niToRouterValid
, input  var logic                    i_niToRouterReady
, input  var logic [PACKET_WIDTH-1:0] i_routerToNi
, input  var logic                    i_routerToNiValid
, output var logic                    o_routerToNiReady

  // Local NI side — up to NUM_NI network interfaces share the port above.
, input  var logic [NUM_NI-1:0][PACKET_WIDTH-1:0] i_niToRouter
, input  var logic [NUM_NI-1:0]                   i_niToRouterValid
, output var logic [NUM_NI-1:0]                   o_niToRouterReady
, output var logic [NUM_NI-1:0][PACKET_WIDTH-1:0] o_routerToNi
, output var logic [NUM_NI-1:0]                   o_routerToNiValid
, input  var logic [NUM_NI-1:0]                   i_routerToNiReady
);

  if (NUM_NI == 1) begin: gen_single
    // {{{ Single NI — transparent pass-through
    always_comb
      o_niToRouter = i_niToRouter[0];

    always_comb
      o_niToRouterValid = i_niToRouterValid[0];

    always_comb
      o_niToRouterReady[0] = i_niToRouterReady;

    always_comb
      o_routerToNi[0] = i_routerToNi;

    always_comb
      o_routerToNiValid[0] = i_routerToNiValid;

    always_comb
      o_routerToNiReady = i_routerToNiReady[0];
    // }}} Single NI
  end: gen_single
  else begin: gen_multi
    localparam int unsigned IDX_WIDTH = $clog2(NUM_NI);

    // {{{ Ingress (NI -> router): round-robin arbiter
    // priority_q holds the index of the highest-priority NI this cycle.  The
    // arbiter scans circularly from priority_q and grants the first NI with a
    // pending packet.  After an accepted transfer the priority rotates past the
    // granted NI, guaranteeing fairness (no starvation).
    logic [IDX_WIDTH-1:0] priority_q;
    logic [NUM_NI-1:0]    grant;
    logic [IDX_WIDTH-1:0] grantIdx;
    logic                 grantValid;

    /* svlint off sequential_block_in_always_comb */
    /* svlint off loop_statement_in_always_comb */
    /* svlint off explicit_if_else */
    always_comb begin
      grant      = '0;
      grantIdx   = '0;
      grantValid = 1'b0;

      for (int unsigned off = 0; off < NUM_NI; off++) begin
        logic [IDX_WIDTH-1:0] idx;
        idx = IDX_WIDTH'((32'(priority_q) + off) % NUM_NI);
        if (!grantValid && i_niToRouterValid[idx]) begin
          grantValid = 1'b1;
          grantIdx   = idx;
          grant[idx] = 1'b1;
        end
      end
    end

    // Mux the granted NI's packet onto the router ingress port.
    always_comb begin
      o_niToRouter = '0;
      for (int unsigned k = 0; k < NUM_NI; k++) begin
        if (grant[k])
          o_niToRouter = i_niToRouter[k];
      end
    end
    /* svlint on explicit_if_else */
    /* svlint on loop_statement_in_always_comb */
    /* svlint on sequential_block_in_always_comb */

    for (genvar i = 0; i < NUM_NI; i++) begin: gen_ni_ready

      always_comb
        o_niToRouterReady[i] = grant[i] & i_niToRouterReady;

    end: gen_ni_ready

    always_comb
      o_niToRouterValid = grantValid;

    always_ff @(posedge i_clk or negedge i_arst_n)
      if (!i_arst_n)
        priority_q <= '0;
      else if (grantValid && i_niToRouterReady)
        priority_q <= IDX_WIDTH'((32'(grantIdx) + 1) % NUM_NI);
      else
        priority_q <= priority_q;
    // }}} Ingress

    // {{{ Egress (router -> NI): demux by destination NI-ID
    logic [NI_ID_WIDTH-1:0] sel;

    always_comb
      sel = i_routerToNi[DST_NIID_LSB +: NI_ID_WIDTH];

    for (genvar i = 0; i < NUM_NI; i++) begin: gen_router_to_ni

      always_comb
        o_routerToNi[i] = i_routerToNi;

    end

    for (genvar i = 0; i < NUM_NI; i++) begin: gen_router_to_ni_valid

      always_comb
        o_routerToNiValid[i] = i_routerToNiValid & (sel == NI_ID_WIDTH'(i));

    end: gen_router_to_ni_valid

    /* svlint off sequential_block_in_always_comb */
    /* svlint off loop_statement_in_always_comb */
    /* svlint off explicit_if_else */
    always_comb begin
      o_routerToNiReady = 1'b0;
      for (int unsigned i = 0; i < NUM_NI; i++) begin
        if (sel == NI_ID_WIDTH'(i))
          o_routerToNiReady = i_routerToNiReady[i];
      end
    end
    /* svlint on explicit_if_else */
    /* svlint on loop_statement_in_always_comb */
    /* svlint on sequential_block_in_always_comb */
    // }}} Egress
  end: gen_multi

endmodule

`resetall
