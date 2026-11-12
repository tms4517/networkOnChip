// Copyright (c) 2026 Tej Sanghavi.

// Properties of the NoC `router`. Each property is expressed with auxiliary
// modelling logic and a single-cycle boolean checked by a concurrent assertion.
// `assert_*` booleans are the failing condition (high = violation) and are
// checked with `assert property (!assert_*)`; `assume_*` and `cover_*` are
// positive.
//
// The five router ports are packed into arrays indexed by
// `pa_noc::ty_DIRECTION` (NI, NORTH, SOUTH, EAST, WEST) so per-port properties
// can be repeated with a for loop. Port-level properties are black-box; the
// arbiter grant and FIFO pops are white-box references used to prove
// arbitration fairness and to track a packet through the router.

`default_nettype none

// Reset nets are referenced both as async resets and inside the assertion
// booleans (the disable-under-reset term), which is benign here.
/* verilator lint_off SYNCASYNCNET */

module routerAssertions
  import pa_noc::*;
#(parameter int unsigned GRID_WIDTH = 4
, parameter int unsigned PACKET_WIDTH = 8
, parameter int unsigned FIFO_ADDRESS_WIDTH = 2
, localparam int unsigned COORD_WIDTH = $clog2(GRID_WIDTH)
, parameter bit [COORD_WIDTH-1:0] ROUTER_ROW = 1
, parameter bit [COORD_WIDTH-1:0] ROUTER_COL = 1
, localparam int unsigned NUM_PORTS = NUM_INPUT_FIFOS
, localparam int unsigned PORT_WIDTH = $clog2(NUM_PORTS)
, localparam int unsigned DEPTH = 1 << FIFO_ADDRESS_WIDTH
)
( input var logic i_clk
, input var logic i_arst_n

  // Router input ports (packet into the router)
, input var logic [NUM_PORTS-1:0][PACKET_WIDTH-1:0] i_inData
, input var logic [NUM_PORTS-1:0]                   i_inValid
, input var logic [NUM_PORTS-1:0]                   i_inReady

  // Router output ports (packet out of the router)
, input var logic [NUM_PORTS-1:0][PACKET_WIDTH-1:0] i_outData
, input var logic [NUM_PORTS-1:0]                   i_outValid
, input var logic [NUM_PORTS-1:0]                   i_outReady

  // White-box: arbiter grant and input FIFO pops
, input var logic [NUM_PORTS-1:0] i_grant
, input var logic [NUM_PORTS-1:0] i_fifoReadEn

  // White-box: arbiter output and FIFO state (helper invariants only)
, input var logic [PACKET_WIDTH-1:0]                           i_arbiterPacket
, input var logic                                              i_arbiterPacketIsValid
, input var logic [NUM_PORTS-1:0][FIFO_ADDRESS_WIDTH:0]        i_fifoReadPointer
, input var logic [NUM_PORTS-1:0][FIFO_ADDRESS_WIDTH:0]        i_fifoWritePointer
, input var logic [NUM_PORTS-1:0][DEPTH-1:0][PACKET_WIDTH-1:0] i_fifoMem

  // Free inputs choosing which accepted packet is tracked end to end
, input var logic [PORT_WIDTH-1:0] i_trackPort
, input var logic                  i_trackPick
);

  localparam int unsigned OCCUPANCY_WIDTH = FIFO_ADDRESS_WIDTH + 1;
  localparam int unsigned WAIT_WIDTH = 4;

  // {{{ Auxiliary logic

  // {{{ Handshakes
  // A packet enters an input FIFO on `push` and leaves the router on an output
  // handshake. `forwarded` is the router-level ack seen by the arbiter.

  logic [NUM_PORTS-1:0] push;

  always_comb
    push = i_inValid & i_inReady;

  logic [NUM_PORTS-1:0] outHandshake;

  always_comb
    outHandshake = i_outValid & i_outReady;

  logic forwarded;

  always_comb
    forwarded = |outHandshake;

  logic [NUM_PORTS-1:0][PACKET_WIDTH-1:0] outHandshakeSource;

  for (genvar i = 0; i < NUM_PORTS; i++) begin: genOutHandshakeSource

    always_comb
      outHandshakeSource[i] = outHandshake[i] ? i_outData[i] : '0;

  end: genOutHandshakeSource

  // Packet transferred on whichever output handshakes this cycle (outputs
  // are proven one-hot, so the OR is an exact mux).
  logic [PACKET_WIDTH-1:0] forwardedPacket;

  always_comb
    forwardedPacket = outHandshakeSource[NI]
                    | outHandshakeSource[NORTH]
                    | outHandshakeSource[SOUTH]
                    | outHandshakeSource[EAST]
                    | outHandshakeSource[WEST];
  // }}} Handshakes

  // {{{ Previous-cycle values
  // Used for stability and grant-hold checks.

  logic [NUM_PORTS-1:0] outValid_q;

  always_ff @(posedge i_clk, negedge i_arst_n)
    if (!i_arst_n)
      outValid_q <= '0;
    else
      outValid_q <= i_outValid;

  logic [NUM_PORTS-1:0] outReady_q;

  always_ff @(posedge i_clk, negedge i_arst_n)
    if (!i_arst_n)
      outReady_q <= '0;
    else
      outReady_q <= i_outReady;

  logic [NUM_PORTS-1:0][PACKET_WIDTH-1:0] outData_q;

  always_ff @(posedge i_clk, negedge i_arst_n)
    if (!i_arst_n)
      outData_q <= '0;
    else
      outData_q <= i_outData;

  logic forwarded_q;

  always_ff @(posedge i_clk, negedge i_arst_n)
    if (!i_arst_n)
      forwarded_q <= '0;
    else
      forwarded_q <= forwarded;

  logic forwarded_qq;

  always_ff @(posedge i_clk, negedge i_arst_n)
    if (!i_arst_n)
      forwarded_qq <= '0;
    else
      forwarded_qq <= forwarded_q;

  logic [NUM_PORTS-1:0] grant_q;

  always_ff @(posedge i_clk, negedge i_arst_n)
    if (!i_arst_n)
      grant_q <= '0;
    else
      grant_q <= i_grant;
  // }}} Previous-cycle values

  // {{{ Input FIFO occupancy model
  // Reference count of packets held in each input FIFO: +1 on push, -1 on pop.
  // `hasPacket` is the arbiter request the router should be presenting.

  logic [NUM_PORTS-1:0][OCCUPANCY_WIDTH-1:0] occupancy_d, occupancy_q;
  logic [NUM_PORTS-1:0]                      hasPacket;

  for (genvar i = 0; i < NUM_PORTS; i++) begin: genOccupancy

    always_ff @(posedge i_clk, negedge i_arst_n)
      if (!i_arst_n)
        occupancy_q[i] <= '0;
      else
        occupancy_q[i] <= occupancy_d[i];

    always_comb
      occupancy_d[i] = occupancy_q[i]
                      + OCCUPANCY_WIDTH'(push[i])
                      - OCCUPANCY_WIDTH'(i_fifoReadEn[i]);

    always_comb
      hasPacket[i] = (occupancy_q[i] != '0);

  end: genOccupancy

  logic [NUM_PORTS-1:0] hasPacket_q;

  always_ff @(posedge i_clk, negedge i_arst_n)
    if (!i_arst_n)
      hasPacket_q <= '0;
    else
      hasPacket_q <= hasPacket;
  // }}} Input FIFO occupancy model

  // {{{ Arbitration wait counters
  // Number of acks (forwarded packets) given to other ports while port i has a
  // packet waiting and is not granted. Bounds the round-robin fairness.

  logic [NUM_PORTS-1:0][WAIT_WIDTH-1:0] waitAcks_d, waitAcks_q;

  for (genvar i = 0; i < NUM_PORTS; i++) begin: genWaitAcks

    always_ff @(posedge i_clk, negedge i_arst_n)
      if (!i_arst_n)
        waitAcks_q[i] <= '0;
      else
        waitAcks_q[i] <= waitAcks_d[i];

    always_comb
      if (!hasPacket[i] || i_grant[i])
        waitAcks_d[i] = '0;
      else if (forwarded)
        waitAcks_d[i] = waitAcks_q[i] + 1'b1;
      else
        waitAcks_d[i] = waitAcks_q[i];

  end: genWaitAcks
  // }}} Arbitration wait counters

  // {{{ Tracked packet (symbolic scoreboard)
  // On a free `i_trackPick`, the packet pushed into port `i_trackPort` is
  // recorded together with the number of packets ahead of it in that FIFO.
  // Each pop of that FIFO moves it one place closer to the head; the pop with
  // nothing ahead is the tracked packet leaving the router. Because the pick
  // is free, the proof covers every packet on every port.

  logic tracking_d, tracking_q;
  logic pick;
  logic trackedPop;

  always_ff @(posedge i_clk, negedge i_arst_n)
    if (!i_arst_n)
      tracking_q <= '0;
    else
      tracking_q <= tracking_d;

  always_comb
    pick = &{!tracking_q
          , i_trackPick
          , push[i_trackPort]
          };

  always_comb
    if (pick)
      tracking_d = '1;
    else if (trackedPop)
      tracking_d = '0;
    else
      tracking_d = tracking_q;

  logic [PORT_WIDTH-1:0] trackedPort_q;

  always_ff @(posedge i_clk, negedge i_arst_n)
    if (!i_arst_n)
      trackedPort_q <= '0;
    else if (pick)
      trackedPort_q <= i_trackPort;
    else
      trackedPort_q <= trackedPort_q;

  logic [PACKET_WIDTH-1:0] trackedPacket_q;

  always_ff @(posedge i_clk, negedge i_arst_n)
    if (!i_arst_n)
      trackedPacket_q <= '0;
    else if (pick)
      trackedPacket_q <= i_inData[i_trackPort];
    else
      trackedPacket_q <= trackedPacket_q;

  logic [OCCUPANCY_WIDTH-1:0] ahead_d, ahead_q;

  always_ff @(posedge i_clk, negedge i_arst_n)
    if (!i_arst_n)
      ahead_q <= '0;
    else
      ahead_q <= ahead_d;

  always_comb
    if (pick)
      ahead_d = occupancy_q[i_trackPort]
              - OCCUPANCY_WIDTH'(i_fifoReadEn[i_trackPort]);
    else if (tracking_q && i_fifoReadEn[trackedPort_q])
      ahead_d = ahead_q - 1'b1;
    else
      ahead_d = ahead_q;

  always_comb
    trackedPop = &{tracking_q
                , i_fifoReadEn[trackedPort_q]
                , (ahead_q == '0)
                };
  // }}} Tracked packet (symbolic scoreboard)

  // {{{ Arbiter output history
  logic arbiterPacketIsValid_q;

  always_ff @(posedge i_clk, negedge i_arst_n)
    if (!i_arst_n)
      arbiterPacketIsValid_q <= '0;
    else
      arbiterPacketIsValid_q <= i_arbiterPacketIsValid;
  // }}} Arbiter output history

  // }}} Auxiliary logic

  // {{{ Stimulus constraints

  // The tracked port selector must name a real router port.
  logic assume_trackPortLegal;

  always_comb
    assume_trackPortLegal = (i_trackPort < PORT_WIDTH'(NUM_PORTS));

  trackPortLegal: assume property (@(posedge i_clk) assume_trackPortLegal);

  // }}} Stimulus constraints

  // {{{ Output interface assertions

  // At most one output presents a packet: a packet is routed to exactly one
  // direction.
  logic assert_outValidOneHot;

  always_comb
    assert_outValidOneHot = &{i_arst_n
                            , !$onehot0(i_outValid)
                            };

  outValidOneHot: assert property (@(posedge i_clk) !assert_outValidOneHot);

  // Valid/ready: once presented, an output holds valid and data stable until
  // the downstream accepts it.
  for (genvar i = 0; i < NUM_PORTS; i++) begin: genAssertOutStable

    logic assert_outStableWhileStalled;

    always_comb
      assert_outStableWhileStalled =
        &{i_arst_n
        , outValid_q[i] && !outReady_q[i]
        , !(i_outValid[i] && (i_outData[i] == outData_q[i]))
        };

    outStableWhileStalled:
      assert property (@(posedge i_clk) !assert_outStableWhileStalled);

  end: genAssertOutStable

  // A packet is never forwarded on two consecutive cycles: the registered
  // output valid plus registered ack give a 1-packet-per-2-cycles throughput.
  logic assert_noBackToBackForward;

  always_comb
    assert_noBackToBackForward = &{i_arst_n
                                , forwarded
                                , forwarded_q
                                };

  noBackToBackForward:
    assert property (@(posedge i_clk) !assert_noBackToBackForward);

  // }}} Output interface assertions

  // {{{ XY routing assertions
  // Packets move along the row (east/west) until the destination column is
  // reached, then along the column (north/south), then to the local NI.

  logic [COORD_WIDTH-1:0] niRow, niCol;

  always_comb
    niRow = i_outData[NI][2*COORD_WIDTH-1 -: COORD_WIDTH];

  always_comb
    niCol = i_outData[NI][COORD_WIDTH-1 -: COORD_WIDTH];

  logic assert_niRouteCorrect;

  always_comb
    assert_niRouteCorrect = &{i_arst_n
                            , i_outValid[NI]
                            , !((niRow == ROUTER_ROW) && (niCol == ROUTER_COL))
                            };

  niRouteCorrect: assert property (@(posedge i_clk) !assert_niRouteCorrect);

  logic [COORD_WIDTH-1:0] northRow, northCol;

  always_comb
    northRow = i_outData[NORTH][2*COORD_WIDTH-1 -: COORD_WIDTH];

  always_comb
    northCol = i_outData[NORTH][COORD_WIDTH-1 -: COORD_WIDTH];

  logic assert_northRouteCorrect;

  always_comb
    assert_northRouteCorrect =
      &{i_arst_n
      , i_outValid[NORTH]
      , !((northCol == ROUTER_COL) && (northRow < ROUTER_ROW))
      };

  northRouteCorrect:
    assert property (@(posedge i_clk) !assert_northRouteCorrect);

  logic [COORD_WIDTH-1:0] southRow, southCol;

  always_comb
    southRow = i_outData[SOUTH][2*COORD_WIDTH-1 -: COORD_WIDTH];

  always_comb
    southCol = i_outData[SOUTH][COORD_WIDTH-1 -: COORD_WIDTH];

  logic assert_southRouteCorrect;

  always_comb
    assert_southRouteCorrect =
      &{i_arst_n
      , i_outValid[SOUTH]
      , !((southCol == ROUTER_COL) && (southRow > ROUTER_ROW))
      };

  southRouteCorrect:
    assert property (@(posedge i_clk) !assert_southRouteCorrect);

  logic [COORD_WIDTH-1:0] eastCol;

  always_comb
    eastCol = i_outData[EAST][COORD_WIDTH-1 -: COORD_WIDTH];

  logic assert_eastRouteCorrect;

  always_comb
    assert_eastRouteCorrect = &{i_arst_n
                              , i_outValid[EAST]
                              , (eastCol <= ROUTER_COL)
                              };

  eastRouteCorrect:
    assert property (@(posedge i_clk) !assert_eastRouteCorrect);

  logic [COORD_WIDTH-1:0] westCol;

  always_comb
    westCol = i_outData[WEST][COORD_WIDTH-1 -: COORD_WIDTH];

  logic assert_westRouteCorrect;

  always_comb
    assert_westRouteCorrect = &{i_arst_n
                              , i_outValid[WEST]
                              , (westCol >= ROUTER_COL)
                              };

  westRouteCorrect:
    assert property (@(posedge i_clk) !assert_westRouteCorrect);

  // }}} XY routing assertions

  // {{{ Input FIFO assertions

  // Every forwarded packet pops exactly one input FIFO, and nothing is popped
  // without a forward (no loss, no duplication, no spurious packets).
  logic assert_forwardPopsOneFifo;

  always_comb
    assert_forwardPopsOneFifo = &{i_arst_n
                                , !$onehot0(i_fifoReadEn)
                                  || ((|i_fifoReadEn) != forwarded)
                                };

  forwardPopsOneFifo:
    assert property (@(posedge i_clk) !assert_forwardPopsOneFifo);

  for (genvar i = 0; i < NUM_PORTS; i++) begin: genAssertFifo

    // A FIFO is only popped while it holds a packet.
    logic assert_popOnlyNonEmpty;

    always_comb
      assert_popOnlyNonEmpty = &{i_arst_n
                              , i_fifoReadEn[i]
                              , !hasPacket[i]
                              };

    popOnlyNonEmpty:
      assert property (@(posedge i_clk) !assert_popOnlyNonEmpty);

    // Ready is deasserted exactly when the FIFO is full (no overflow, no
    // needless back-pressure).
    logic assert_readyMatchesOccupancy;

    always_comb
      assert_readyMatchesOccupancy =
        &{i_arst_n
        , i_inReady[i] != (occupancy_q[i] < OCCUPANCY_WIDTH'(DEPTH))
        };

    readyMatchesOccupancy:
      assert property (@(posedge i_clk) !assert_readyMatchesOccupancy);

  end: genAssertFifo

  // }}} Input FIFO assertions

  // {{{ Arbitration assertions

  logic assert_grantOneHot;

  always_comb
    assert_grantOneHot = &{i_arst_n
                        , !$onehot0(i_grant)
                        };

  grantOneHot: assert property (@(posedge i_clk) !assert_grantOneHot);

  // A grant to a port that still has a packet is held until that packet is
  // forwarded, so the registered output never sees its packet change.
  logic assert_grantHeldUntilAck;

  always_comb
    assert_grantHeldUntilAck = &{i_arst_n
                              , (grant_q != '0)
                              , |(grant_q & hasPacket_q)
                              , !forwarded_q
                              , (i_grant != grant_q)
                              };

  grantHeldUntilAck:
    assert property (@(posedge i_clk) !assert_grantHeldUntilAck);

  // Round-robin fairness: a waiting port is granted before more than
  // NUM_PORTS-1 other packets are forwarded.
  for (genvar i = 0; i < NUM_PORTS; i++) begin: genAssertFairness

    logic assert_roundRobinFair;

    always_comb
      assert_roundRobinFair =
        &{i_arst_n
        , (waitAcks_q[i] > WAIT_WIDTH'(NUM_PORTS - 1))
        };

    roundRobinFair: assert property (@(posedge i_clk) !assert_roundRobinFair);

    // Starvation freedom at the bound the RTL actually meets: the mask lags
    // the grant by one ack, so a port can be granted twice in a row.
    logic assert_starvationFree;

    always_comb
      assert_starvationFree =
        &{i_arst_n
        , (waitAcks_q[i] > WAIT_WIDTH'(2 * (NUM_PORTS - 1)))
        };

    starvationFree: assert property (@(posedge i_clk) !assert_starvationFree);

  end: genAssertFairness

  // }}} Arbitration assertions

  // {{{ Data integrity assertions

  // Helper invariant: the occupancy model matches the FIFO pointers.
  for (genvar i = 0; i < NUM_PORTS; i++) begin: genAssertOccupancyModel

    logic [OCCUPANCY_WIDTH-1:0] pointerOccupancy;

    always_comb
      pointerOccupancy = i_fifoWritePointer[i] - i_fifoReadPointer[i];

    logic assert_occupancyMatchesPointers;

    always_comb
      assert_occupancyMatchesPointers = &{i_arst_n
                                        , (occupancy_q[i] != pointerOccupancy)
                                        };

    occupancyMatchesPointers:
      assert property (@(posedge i_clk) !assert_occupancyMatchesPointers);

  end: genAssertOccupancyModel

  // Helper invariant: a valid output register holds the packet the arbiter is
  // still presenting (the granted FIFO head is not popped until forwarded).
  for (genvar i = 0; i < NUM_PORTS; i++) begin: genAssertOutMatchesArbiter

    logic assert_outMatchesArbiter;

    always_comb
      assert_outMatchesArbiter =
        &{i_arst_n
        , i_outValid[i]
        , !(i_arbiterPacketIsValid && (i_outData[i] == i_arbiterPacket))
        };

    outMatchesArbiter:
      assert property (@(posedge i_clk) !assert_outMatchesArbiter);

  end: genAssertOutMatchesArbiter

  // Helper invariant: the tracked packet sits in FIFO memory `ahead` slots
  // after the read pointer.
  logic [FIFO_ADDRESS_WIDTH-1:0] trackedSlot;

  always_comb
    trackedSlot =
      FIFO_ADDRESS_WIDTH'(i_fifoReadPointer[trackedPort_q] + ahead_q);

  logic assert_trackedInMemory;

  always_comb
    assert_trackedInMemory =
      &{i_arst_n
      , tracking_q
      , (i_fifoMem[trackedPort_q][trackedSlot] != trackedPacket_q)
      };

  trackedInMemory: assert property (@(posedge i_clk) !assert_trackedInMemory);

  // Helper invariant: while tracked, the packet is still inside its FIFO.
  logic assert_trackedInFifo;

  always_comb
    assert_trackedInFifo = &{i_arst_n
                          , tracking_q
                          , (ahead_q >= occupancy_q[trackedPort_q])
                          };

  trackedInFifo: assert property (@(posedge i_clk) !assert_trackedInFifo);

  // End to end: the tracked packet leaves the router unmodified, in FIFO order.
  logic assert_trackedPacketIntegrity;

  always_comb
    assert_trackedPacketIntegrity = &{i_arst_n
                                    , trackedPop
                                    , (forwardedPacket != trackedPacket_q)
                                    };

  trackedPacketIntegrity:
    assert property (@(posedge i_clk) !assert_trackedPacketIntegrity);

  // }}} Data integrity assertions

  // {{{ Work-conserving assertions
  // With starvationFree, these imply every packet is delivered as long as
  // the downstream keeps accepting.

  // A packet waiting in any FIFO is presented by the arbiter next cycle,
  // unless a pop just happened.
  logic assert_arbiterWorkConserving;

  always_comb
    assert_arbiterWorkConserving =
      &{i_arst_n
      , |hasPacket_q
      , !forwarded_q
      , !i_arbiterPacketIsValid
      };

  arbiterWorkConserving:
    assert property (@(posedge i_clk) !assert_arbiterWorkConserving);

  // A packet presented by the arbiter reaches a registered output next cycle,
  // unless it was just forwarded.
  logic assert_outputWorkConserving;

  always_comb
    assert_outputWorkConserving = &{i_arst_n
                                  , arbiterPacketIsValid_q
                                  , !forwarded_q
                                  , !(|i_outValid)
                                  };

  outputWorkConserving:
    assert property (@(posedge i_clk) !assert_outputWorkConserving);

  // }}} Work-conserving assertions

  // {{{ Cover properties

  for (genvar i = 0; i < NUM_PORTS; i++) begin: genCover

    // Each output can forward a packet.
    logic cover_outHandshake;

    always_comb
      cover_outHandshake = outHandshake[i];

    outHandshakeSeen: cover property (@(posedge i_clk) cover_outHandshake);

    // Each input FIFO can fill and apply back-pressure.
    logic cover_inFifoFull;

    always_comb
      cover_inFifoFull = i_arst_n && !i_inReady[i];

    inFifoFull: cover property (@(posedge i_clk) cover_inFifoFull);

  end: genCover

  // All five input FIFOs hold packets at once (full contention).
  logic cover_allPortsContending;

  always_comb
    cover_allPortsContending = &hasPacket;

  allPortsContending:
    cover property (@(posedge i_clk) cover_allPortsContending);

  // A tracked packet is delivered.
  logic cover_trackedDelivered;

  always_comb
    cover_trackedDelivered = trackedPop;

  trackedDelivered: cover property (@(posedge i_clk) cover_trackedDelivered);

  // Peak throughput: forwards two cycles apart.
  logic cover_peakThroughput;

  always_comb
    cover_peakThroughput = forwarded && forwarded_qq;

  peakThroughput: cover property (@(posedge i_clk) cover_peakThroughput);

  // Worst-case arbitration wait: which wait depths beyond strict round-robin
  // (NUM_PORTS-1) are reachable. The deepest covered value is the real bound.
  for (genvar i = 0; i < NUM_PORTS; i++) begin: genCoverWaitPort
    for (genvar j = NUM_PORTS; j < 2*NUM_PORTS; j++) begin: genCoverWaitDepth

      logic cover_waitAcks;

      always_comb
        cover_waitAcks = (waitAcks_q[i] == WAIT_WIDTH'(j));

      waitAcks: cover property (@(posedge i_clk) cover_waitAcks);

    end: genCoverWaitDepth
  end: genCoverWaitPort

  // }}} Cover properties

endmodule

/* verilator lint_on SYNCASYNCNET */
`resetall
