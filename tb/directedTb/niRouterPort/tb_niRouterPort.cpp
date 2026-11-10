// Unit test for niRouterPort (NUM_NI = 3).
//
// Directly exercises the two functions of the port multiplexer:
//   1. Egress demux  — a router->NI packet is delivered to exactly the NI named
//      by the packet's destination NI-ID field (bits [5:4] for this config).
//   2. Ingress round-robin — when several NIs request the single router port,
//      grants rotate fairly with no starvation.

#include <cstdlib>
#include <iostream>
#include <vector>

#include "Vtb_niRouterPort_top.h"
#include <verilated.h>

#ifndef MAX_SIM_TIME
#define MAX_SIM_TIME 4000
#endif

// Packet layout for GRID_WIDTH=4, MAX_NI_PER_ROUTER=3:
//   COORD_WIDTH=2, NI_ID_WIDTH=2 -> dstNiId occupies bits [5:4].
#define DST_NIID_LSB 4

using Dut = Vtb_niRouterPort_top;

static vluint64_t sim_time = 0;

static void tick(Dut *dut) {
  dut->i_clk = 0;
  dut->eval();
  sim_time++;
  dut->i_clk = 1;
  dut->eval();
  sim_time++;
}

// Build a packet low-word: destination NI-ID in [5:4], a tag in the upper bits.
static uint32_t mkPacket(int dst_ni_id, uint32_t tag) {
  return ((tag & 0x00FFFFFFu) << 8) | ((dst_ni_id & 0x3) << DST_NIID_LSB);
}

int main(int argc, char **argv, char **env) {
  (void)env;
  Verilated::commandArgs(argc, argv);
  Dut *dut = new Dut;

  int pass = 0;
  int fail = 0;

  std::cout << "=== niRouterPort unit test (NUM_NI=3) ===" << std::endl;

  // Reset
  dut->i_arst_n = 0;
  dut->i_niToRouterReady = 0;
  dut->i_routerToNiValid = 0;
  dut->i_ni0ToRouterValid = 0;
  dut->i_ni1ToRouterValid = 0;
  dut->i_ni2ToRouterValid = 0;
  dut->i_ni0RouterToNiReady = 0;
  dut->i_ni1RouterToNiReady = 0;
  dut->i_ni2RouterToNiReady = 0;
  for (int i = 0; i < 5; i++) tick(dut);
  dut->i_arst_n = 1;

  // ---------------------------------------------------------------------------
  // Test 1: egress demux — a packet with dstNiId=k must reach only NI k.
  // ---------------------------------------------------------------------------
  for (int k = 0; k < 3; k++) {
    dut->i_routerToNi[0] = mkPacket(k, 0xBEEF0 + k);
    dut->i_routerToNi[1] = 0;
    dut->i_routerToNi[2] = 0;
    dut->i_routerToNiValid = 1;
    dut->i_ni0RouterToNiReady = (k == 0);
    dut->i_ni1RouterToNiReady = (k == 1);
    dut->i_ni2RouterToNiReady = (k == 2);
    dut->eval();

    bool v0 = dut->o_ni0RouterToNiValid;
    bool v1 = dut->o_ni1RouterToNiValid;
    bool v2 = dut->o_ni2RouterToNiValid;
    bool onlyK = ((k == 0) ? (v0 && !v1 && !v2)
                : (k == 1) ? (!v0 && v1 && !v2)
                           : (!v0 && !v1 && v2));
    bool rdy = dut->o_routerToNiReady; // must reflect selected NI's ready (=1)

    if (onlyK && rdy) {
      std::cout << "  PASS: egress demux dstNiId=" << k
                << " -> only NI" << k << " valid, ready propagated" << std::endl;
      pass++;
    } else {
      std::cout << "  FAIL: egress demux dstNiId=" << k
                << " v0=" << v0 << " v1=" << v1 << " v2=" << v2
                << " rdy=" << (int)rdy << std::endl;
      fail++;
    }
  }
  dut->i_routerToNiValid = 0;
  dut->i_ni0RouterToNiReady = 0;
  dut->i_ni1RouterToNiReady = 0;
  dut->i_ni2RouterToNiReady = 0;

  // ---------------------------------------------------------------------------
  // Test 2: ingress round-robin — all three NIs request, port always ready.
  // The shared roundRobinArbiter registers its grant (held until ack), so after
  // a one-cycle startup the grants settle into a fair 0,1,2 rotation.  Check the
  // steady-state window: any 9 consecutive grants contain each NI exactly 3x.
  // ---------------------------------------------------------------------------
  dut->i_ni0ToRouter[0] = 0xA0; dut->i_ni0ToRouter[1] = 0; dut->i_ni0ToRouter[2] = 0;
  dut->i_ni1ToRouter[0] = 0xA1; dut->i_ni1ToRouter[1] = 0; dut->i_ni1ToRouter[2] = 0;
  dut->i_ni2ToRouter[0] = 0xA2; dut->i_ni2ToRouter[1] = 0; dut->i_ni2ToRouter[2] = 0;
  dut->i_ni0ToRouterValid = 1;
  dut->i_ni1ToRouterValid = 1;
  dut->i_ni2ToRouterValid = 1;
  dut->i_niToRouterReady = 1;

  std::vector<int> grants;
  for (int c = 0; c < 13; c++) {
    dut->i_clk = 0; dut->eval(); sim_time++;
    dut->i_clk = 1; dut->eval(); sim_time++; // posedge: sample grant
    int g = -1;
    if (dut->o_niToRouterValid) {
      if (dut->o_ni0ToRouterReady) g = 0;
      else if (dut->o_ni1ToRouterReady) g = 1;
      else if (dut->o_ni2ToRouterReady) g = 2;
    }
    grants.push_back(g);
  }

  int cnt[3] = {0, 0, 0};
  bool ok = true;
  for (int c = 4; c < 13; c++) { // steady-state window (skip startup)
    if (grants[c] < 0 || grants[c] > 2) ok = false;
    else cnt[grants[c]]++;
  }
  ok = ok && (cnt[0] == 3) && (cnt[1] == 3) && (cnt[2] == 3);
  if (ok) {
    std::cout << "  PASS: ingress round-robin steady-state fair "
              << "(each NI 3/9 grants)" << std::endl;
    pass++;
  } else {
    std::cout << "  FAIL: ingress round-robin steady window counts NI0="
              << cnt[0] << " NI1=" << cnt[1] << " NI2=" << cnt[2] << std::endl;
    fail++;
  }

  // ---------------------------------------------------------------------------
  // Test 3: round-robin with NI0 idle — only NI1 and NI2 rotate, no starvation.
  // ---------------------------------------------------------------------------
  dut->i_ni0ToRouterValid = 0;
  std::vector<int> grants2;
  for (int c = 0; c < 10; c++) {
    dut->i_clk = 0; dut->eval(); sim_time++;
    dut->i_clk = 1; dut->eval(); sim_time++;
    int g = -1;
    if (dut->o_niToRouterValid) {
      if (dut->o_ni1ToRouterReady) g = 1;
      else if (dut->o_ni2ToRouterReady) g = 2;
      else if (dut->o_ni0ToRouterReady) g = 0;
    }
    grants2.push_back(g);
  }
  int cnt1 = 0, cnt2 = 0, cnt0 = 0, bad = 0;
  for (int i = 2; i < 10; i++) { // steady-state window
    int g = grants2[i];
    if (g == 1) cnt1++;
    else if (g == 2) cnt2++;
    else if (g == 0) cnt0++;
    else bad++;
  }
  if (bad == 0 && cnt0 == 0 && cnt1 >= 1 && cnt2 >= 1 && cnt1 == cnt2) {
    std::cout << "  PASS: two-NI rotation fair (NI1x" << cnt1 << ", NI2x"
              << cnt2 << "), NI0 never granted while idle" << std::endl;
    pass++;
  } else {
    std::cout << "  FAIL: two-NI rotation cnt0=" << cnt0 << " cnt1=" << cnt1
              << " cnt2=" << cnt2 << " bad=" << bad << std::endl;
    fail++;
  }

  std::cout << "\n=== Results: " << pass << " passed, " << fail << " failed ==="
            << std::endl;
  std::cout << ((fail == 0) ? "TEST PASSED" : "TEST FAILED") << std::endl;

  (void)MAX_SIM_TIME;
  delete dut;
  return (fail == 0) ? EXIT_SUCCESS : EXIT_FAILURE;
}
