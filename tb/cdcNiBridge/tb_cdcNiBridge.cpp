// Testbench: cdcNiBridge
// Pushes packets into the NI ingress with the NI and fabric clocks running at
// different frequencies.  The fabric side loops back, so each packet must return
// on the NI egress, in order and unchanged, after crossing both clock domains.

#include <cstdint>
#include <cstdlib>
#include <deque>
#include <iostream>

#include "Vtb_cdcNiBridge_top.h"
#include <verilated.h>

#ifndef MAX_SIM_TIME
#define MAX_SIM_TIME 200000
#endif
#ifndef NUM_ITEMS
#define NUM_ITEMS 256
#endif

// NI runs slower than the fabric here; coprime half-periods drift the phase.
#ifndef NI_HALF
#define NI_HALF 3
#endif
#ifndef FAB_HALF
#define FAB_HALF 2
#endif

int main(int argc, char **argv, char **env) {
  (void)env;
  Verilated::commandArgs(argc, argv);
  Vtb_cdcNiBridge_top *dut = new Vtb_cdcNiBridge_top;

  std::deque<uint32_t> model;
  int writeIdx = 0;
  int readCount = 0;
  int errors = 0;

  auto payload = [](int i) -> uint32_t {
    return (uint32_t)(0xABC0u * (i + 7)) ^ (uint32_t)(i * 2246822519u);
  };

  dut->i_niClk = 0;
  dut->i_fabClk = 0;
  dut->i_niArst_n = 0;
  dut->i_fabArst_n = 0;
  dut->i_niToRouter = 0;
  dut->i_niToRouterValid = 0;
  dut->i_routerToNiReady = 0;
  dut->eval();

  vluint64_t sim_time = 0;
  const vluint64_t RESET_TIME = 20;

  while (sim_time < MAX_SIM_TIME) {
    bool inReset = (sim_time < RESET_TIME);
    dut->i_niArst_n = inReset ? 0 : 1;
    dut->i_fabArst_n = inReset ? 0 : 1;

    // NI-domain stimulus (sampled at the NI clock edges).
    dut->i_niToRouterValid = (!inReset && writeIdx < NUM_ITEMS) ? 1 : 0;
    dut->i_niToRouter = (writeIdx < NUM_ITEMS) ? payload(writeIdx) : 0;
    dut->i_routerToNiReady = (!inReset) ? 1 : 0;

    int niLvl = (sim_time / NI_HALF) % 2;
    int fabLvl = (sim_time / FAB_HALF) % 2;
    bool niRise = (niLvl == 1) && (dut->i_niClk == 0);

    // Ingress accept and egress consume both happen on the NI clock edge.
    if (!inReset && niRise && dut->i_niToRouterValid && dut->o_niToRouterReady) {
      model.push_back(dut->i_niToRouter);
      writeIdx++;
    }
    if (!inReset && niRise && dut->o_routerToNiValid && dut->i_routerToNiReady) {
      uint32_t got = dut->o_routerToNi;
      if (model.empty()) {
        std::cout << "ERROR: egress data with empty model at t=" << sim_time << "\n";
        errors++;
      } else {
        uint32_t exp = model.front();
        model.pop_front();
        if (got != exp) {
          std::cout << "ERROR: mismatch at item " << readCount
                    << " exp=0x" << std::hex << exp
                    << " got=0x" << got << std::dec << "\n";
          errors++;
        }
        readCount++;
      }
    }

    dut->i_niClk = niLvl;
    dut->i_fabClk = fabLvl;
    dut->eval();

    if (readCount == NUM_ITEMS)
      break;

    sim_time++;
  }

  bool pass = (errors == 0) && (readCount == NUM_ITEMS);
  std::cout << "cdcNiBridge TB: " << readCount << "/" << NUM_ITEMS
            << " items looped back, " << errors << " errors\n";
  std::cout << (pass ? "TEST PASSED" : "TEST FAILED") << "\n";

  delete dut;
  return pass ? 0 : 1;
}
