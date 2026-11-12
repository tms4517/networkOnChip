# Formal Verification Plan — `router`

## 1. Purpose

This document describes the formal verification (FV) plan for the NoC
`router` ([rtl/fabric/router.sv](../../../rtl/fabric/router.sv)). The router
buffers packets from its local NI and four mesh neighbours in five input
FIFOs, picks one with a round-robin arbiter and forwards it with XY routing
to the NI or a neighbour over a registered valid/ready interface.

The goal is an unbounded proof that, for every legal stimulus, the router
never loses, duplicates, corrupts or misroutes a packet, obeys valid/ready,
arbitrates fairly and always makes forward progress.

## 2. Design under test

| Item          | Value                                                        |
|---------------|--------------------------------------------------------------|
| Top module    | `router` (+ `arbiter`, `roundRobinArbiter`, `synchronousFifo`) |
| Parameters    | `GRID_WIDTH`, `PACKET_WIDTH`, `FIFO_ADDRESS_WIDTH`, `ROUTER_ROW`, `ROUTER_COL` |
| Clock         | `i_clk`                                                      |
| Reset         | `i_arst_n` (async, active-low)                               |
| FV config     | `GRID_WIDTH=4`, `PACKET_WIDTH=8`, `FIFO_ADDRESS_WIDTH=2`, `ROUTER_ROW=1`, `ROUTER_COL=1` |

`PACKET_WIDTH=8` keeps the destination coordinates (`[3:0]`) plus 4 payload
bits; the datapath is bit-symmetric so wider packets add nothing. Row/column 1
is an interior router so all four neighbour directions are reachable.

### 2.1 Ports

Packed into `[5]` arrays indexed by `pa_noc::ty_DIRECTION`
(`NI`, `NORTH`, `SOUTH`, `EAST`, `WEST`):

- Input side: `i_<dir>`, `i_<dir>Valid`, `o_<dir>Ready` (= FIFO not full).
- Output side: `o_<dir>`, `o_<dir>Valid` (registered), `i_<dir>Ready`.
- Packet layout (LSB first): `dstCol[COORD_WIDTH-1:0]`,
  `dstRow[2*COORD_WIDTH-1:COORD_WIDTH]`, payload above.

### 2.2 Key internal signals (white-box references)

| Signal                       | Description                                         |
|------------------------------|-----------------------------------------------------|
| `u_dut.u_arbiter.grant`      | One-hot round-robin grant (registered `grant_q`)     |
| `u_dut.fifoReadEn`           | Per-FIFO pop = `grant & (packetForwarded && packetIsValid)` |
| `u_dut.packet`, `u_dut.packetIsValid` | Arbiter output (granted FIFO head)        |
| `u_dut.u_<dir>Fifo.{readPointer_q,writePointer_q,mem}` | FIFO state, used only by helper invariants |

## 3. Verification strategy

- **Tool:** JasperGold FPV, run by `make formalRouterTb` from the repo root.
- **Files:** [routerTb.sv](routerTb.sv) (DUT + checker, all inputs free),
  [routerAssertions.sv](routerAssertions.sv) (checker),
  [jg/jg.tcl](jg/jg.tcl).
- **Style:** auxiliary modelling logic plus single-cycle booleans
  (`assert_*`, `assume_*`, `cover_*`), each checked by a concurrent
  `assert/assume/cover property`. Every boolean includes a `!i_arst_n` term.
  Only the liveness section uses a temporal operator (`s_eventually`).
- **Reference models in the checker:**
  - *Occupancy model*: per-port packet count (+1 on input handshake, -1 on
    FIFO pop). Gives the expected ready and request (`hasPacket`).
  - *Wait counters*: acks given to other ports while a port waits.
  - *Symbolic tracked packet*: on a free `i_trackPick`, the packet pushed into
    free port `i_trackPort` is recorded with the number of packets ahead of it.
    Each pop of that FIFO decrements the count; the pop at zero is the tracked
    packet leaving. Because the pick is free, the proof covers every packet
    on every port (Wolper-style data independence).
- **Coverage:** `check_cov` stimuli (reachability) and COI (checker
  observability) on `u_dut`.

## 4. Assumptions (constraints)

| ID | Assumption | Rationale |
|----|------------|-----------|
| A1 | `i_clk` free-running, `i_arst_n` asserted at start then deasserted. | JasperGold `clock` / `reset`. |
| A2 | `i_trackPort < 5`. | Selector names a real port (checker only). |
| A3 | `o_<dir>Valid \|-> s_eventually i_<dir>Ready` for each output. | Downstream fairness; needed only for liveness (L1). |

No constraints are placed on input packets, input valids or output readys
for safety properties: they hold against an arbitrary environment (including
a neighbour that drops valid without a handshake or sends a packet that is not
XY-legal for the port it arrives on).

## 5. Assertions to be proved

Legend: **Dir** = Assertion (A), Cover (C).

### 5.1 Output interface

| ID | Dir | Property | Checker name |
|----|-----|----------|--------------|
| O1 | A | At most one output valid at a time (a packet goes one way). | `assert_outValidOneHot` |
| O2 | A | Per output: valid && !ready ⇒ next cycle valid stays high and data is unchanged. | `genAssertOutStable[*].assert_outStableWhileStalled` |
| O3 | A | No forwards on two consecutive cycles (documents 1 packet / 2 cycles throughput). | `assert_noBackToBackForward` |

### 5.2 XY routing

| ID | Dir | Property | Checker name |
|----|-----|----------|--------------|
| X1 | A | `o_niValid` ⇒ dst == (ROUTER_ROW, ROUTER_COL). | `assert_niRouteCorrect` |
| X2 | A | `o_northValid` ⇒ dstCol == COL && dstRow < ROW. | `assert_northRouteCorrect` |
| X3 | A | `o_southValid` ⇒ dstCol == COL && dstRow > ROW. | `assert_southRouteCorrect` |
| X4 | A | `o_eastValid` ⇒ dstCol > COL. | `assert_eastRouteCorrect` |
| X5 | A | `o_westValid` ⇒ dstCol < COL. | `assert_westRouteCorrect` |

### 5.3 Input FIFOs (no loss / no duplication)

| ID | Dir | Property | Checker name |
|----|-----|----------|--------------|
| F1 | A | Each forward pops exactly one FIFO; no pop without a forward. | `assert_forwardPopsOneFifo` |
| F2 | A | A FIFO is only popped while it holds a packet. | `genAssertFifo[*].assert_popOnlyNonEmpty` |
| F3 | A | `o_<dir>Ready` == occupancy < DEPTH (no overflow, no needless back-pressure). | `genAssertFifo[*].assert_readyMatchesOccupancy` |

### 5.4 Arbitration

| ID | Dir | Property | Checker name |
|----|-----|----------|--------------|
| R1 | A | Grant is one-hot or zero. | `assert_grantOneHot` |
| R2 | A | A grant whose FIFO still has a packet is held until that packet is forwarded. | `assert_grantHeldUntilAck` |
| R3 | A | Strict round-robin: a waiting port is granted before more than 4 (N-1) other packets are forwarded. | `genAssertFairness[*].roundRobinFair` |
| R4 | A | Starvation freedom: a waiting port is granted before more than 8 (2(N-1)) other packets are forwarded. | `genAssertFairness[*].starvationFree` |

### 5.5 Data integrity

| ID | Dir | Property | Checker name |
|----|-----|----------|--------------|
| H1 | A | Helper: occupancy model == FIFO `writePointer - readPointer`. | `genAssertOccupancyModel[*].occupancyMatchesPointers` |
| H2 | A | Helper: a valid output register equals the arbiter's current packet. | `genAssertOutMatchesArbiter[*].outMatchesArbiter` |
| H3 | A | Helper: tracked packet is in FIFO memory at `readPointer + ahead`. | `trackedInMemory` |
| D1 | A | Helper invariant: a tracked packet is still inside its FIFO (`ahead < occupancy`). | `assert_trackedInFifo` |
| D2 | A | The tracked packet leaves the router unmodified and in FIFO order. | `assert_trackedPacketIntegrity` |

H1–H3 make D2 inductive. Without them D2 did not converge; with them it
proves in under a second.

D2 + F1 + O1 together give: every output packet is exactly one previously
accepted packet, unmodified, and every packet leaves exactly once.

### 5.6 Liveness

| ID | Dir | Property | Notes |
|----|-----|----------|-------|
| L1a | A | Arbiter work-conserving: a packet in any FIFO is presented next cycle unless a pop just happened. | `arbiterWorkConserving` |
| L1b | A | Output work-conserving: a presented packet is on a registered output next cycle unless just forwarded. | `outputWorkConserving` |
| L1 | A | `tracking \|-> s_eventually trackedPop` — every accepted packet is eventually forwarded. | Under A3. Full temporal form. |

L1a and L1b are safety properties. Together with R4 (each pop of a FIFO is
preceded by at most 8 other forwards), O2 (a presented output stays
presented) and A3 (it is eventually accepted), they imply L1: while any FIFO
is non-empty a packet is always on an output, every such output eventually
forwards, and each port is popped after a bounded number of forwards.

### 5.7 Covers (reachability)

| ID | Dir | Property | Checker name |
|----|-----|----------|--------------|
| C1 | C | Each output handshakes. | `genCover[*].cover_outHandshake` |
| C2 | C | Each input FIFO fills (ready low). | `genCover[*].cover_inFifoFull` |
| C3 | C | All five FIFOs non-empty at once. | `cover_allPortsContending` |
| C4 | C | A tracked packet is delivered. | `cover_trackedDelivered` |
| C5 | C | Peak throughput: forwards two cycles apart. | `cover_peakThroughput` |
| C6 | C | Arbitration wait depth 5..9 per port (measures the real fairness bound). | `genCoverWaitPort[*].genCoverWaitDepth[*].waitAcks` |

## 6. Proof bring-up order

1. Covers C1–C5 (sanity: environment not over-constrained).
2. Shallow safety: O1, R1, F2, F3, X1–X5.
3. Handshake/arbitration: O2, O3, F1, R2.
4. Data integrity D1, D2 (D1 is the induction helper for D2).
5. Fairness R3.
6. Liveness L1.
7. Coverage: stimuli and COI on `u_dut` ≈ 100%.

## 7. Results (2026-11-11, JasperGold 2026.09p001, after F-1 fix)

Re-run with `make formalRouterTb`; logs in `logs/formalRouterTb/`
(`jg.log`, `router_fv_summary.rpt`, `router_cov.rpt`).

| Group | Properties | Result |
|-------|------------|--------|
| Output interface | O1, O2 (x5), O3 | Proven |
| XY routing | X1–X5 | Proven |
| Input FIFOs | F1, F2 (x5), F3 (x5) | Proven |
| Arbitration | R1, R2, R3 (x5), R4 (x5) | Proven |
| Helpers | H1 (x5), H2 (x5), H3, D1 | Proven |
| Data integrity | D2 | Proven |
| Work conserving | L1a, L1b | Proven |
| Liveness | L1 | Undetermined at the 10 min limit (no CEX, bounded to 80 cycles); covered by L1a + L1b + R4 + O2 + A3 |
| Covers | C1–C5 | All covered |
| Covers | C6 wait depth 5–9 | Unreachable (all ports): true round-robin |

All safety properties prove in under 2 s each.

### F-1: round-robin arbiter grants each port twice in a row (FIXED)

Before the fix R3 failed (CEX 13–15 cycles) and C6 covered wait depth 8.

`roundRobinArbiter` computes the next grant (`grant_d`) from `mask_q`, but on
an ack `mask_q` only advances to the mask after the *previous* grant
(`mask_d` is decoded from `grant_q`). The mask therefore lags the grant by
one ack, so a port that still has packets is re-granted once before priority
moves on. With all five FIFOs busy the grant order is 0,0,1,1,2,2,3,3,4,4,...

- Impact: not a starvation bug — R4 proves the worst case wait is 8 forwards
  (C6 covers depth 8, proves depth 9 unreachable). But fairness is half that
  of true round-robin (4), and the header comment ("the next-highest-numbered
  client becomes highest priority") is not what the RTL does.
- A side effect: when the acked FIFO held only one packet the re-grant points
  at an empty FIFO, costing one dead cycle before re-arbitration.
- Fix (2026-11-11): `maskedReq = i_request & mask_d;` in `roundRobinArbiter`,
  so the next grant is picked with the mask after the current grant. R3 now
  proves on all ports and wait depths above N-1 are unreachable. All runnable
  directed TBs still pass.

## 8. Open items / notes

- Edge/corner routers (row/col 0 or GRID_WIDTH-1): re-run with
  `ROUTER_ROW/ROUTER_COL` overridden to confirm no output toward a
  non-existent neighbour.
- `FIFO_ADDRESS_WIDTH` is proven at the default (2, depth 4); the logic is
  depth-generic.
- Mesh-level deadlock (request/response sharing one network) is out of scope
  for a single router; see the system-level item in the NoC FV backlog.
