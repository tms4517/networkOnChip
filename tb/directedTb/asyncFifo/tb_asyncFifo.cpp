// Testbench: asyncFifo
// Streams values through the dual-clock FIFO with the write and read clocks
// running at different, unrelated frequencies.  Checks that every value read
// out matches the value written in, in order, and that the FIFO never reports a
// spurious full/empty (no data loss or duplication).

#include <cstdint>
#include <cstdlib>
#include <deque>
#include <iostream>

#include "Vtb_asyncFifo_top.h"
#include <verilated.h>

#ifndef MAX_SIM_TIME
#define MAX_SIM_TIME 200000
#endif
#ifndef NUM_ITEMS
#define NUM_ITEMS 256
#endif

// Half-periods (in unit time steps) for the two clocks.  Deliberately coprime so
// the domains drift through every phase relationship.
#ifndef W_HALF
#define W_HALF 2
#endif
#ifndef R_HALF
#define R_HALF 3
#endif

int main(int argc, char **argv, char **env) {
  (void)env;
  Verilated::commandArgs(argc, argv);
  Vtb_asyncFifo_top *dut = new Vtb_asyncFifo_top;

  std::deque<uint32_t> model;   // values pushed but not yet checked
  int writeIdx = 0;             // next value to present on the write side
  int readCount = 0;            // values successfully checked on the read side
  int errors = 0;

  // Deterministic pseudo-random payloads.
  auto payload = [](int i) -> uint32_t {
    return (uint32_t)(0x1000u * (i + 1)) ^ (uint32_t)(i * 2654435761u);
  };

  // Reset both domains.
  dut->i_writeClk = 0;
  dut->i_readClk = 0;
  dut->i_writeArst_n = 0;
  dut->i_readArst_n = 0;
  dut->i_writeEn = 0;
  dut->i_writeData = 0;
  dut->i_readEn = 0;
  dut->eval();

  vluint64_t sim_time = 0;
  const vluint64_t RESET_TIME = 20;

  while (sim_time < MAX_SIM_TIME) {
    bool inReset = (sim_time < RESET_TIME);
    dut->i_writeArst_n = inReset ? 0 : 1;
    dut->i_readArst_n = inReset ? 0 : 1;

    // Drive stimulus for this step (sampled at the next clock edges).
    dut->i_writeEn = (!inReset && writeIdx < NUM_ITEMS) ? 1 : 0;
    dut->i_writeData = (writeIdx < NUM_ITEMS) ? payload(writeIdx) : 0;
    dut->i_readEn = (!inReset) ? 1 : 0;

    int wLvl = (sim_time / W_HALF) % 2;
    int rLvl = (sim_time / R_HALF) % 2;
    bool wRise = (wLvl == 1) && (dut->i_writeClk == 0);
    bool rRise = (rLvl == 1) && (dut->i_readClk == 0);

    // Pre-edge bookkeeping uses the current (registered) flags and head data.
    if (!inReset && wRise && dut->i_writeEn && !dut->o_full) {
      model.push_back(dut->i_writeData);
      writeIdx++;
    }
    if (!inReset && rRise && dut->i_readEn && !dut->o_empty) {
      uint32_t got = dut->o_readData;
      if (model.empty()) {
        std::cout << "ERROR: read from empty model at t=" << sim_time << "\n";
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

    dut->i_writeClk = wLvl;
    dut->i_readClk = rLvl;
    dut->eval();

    if (readCount == NUM_ITEMS)
      break;

    sim_time++;
  }

  bool pass = (errors == 0) && (readCount == NUM_ITEMS);
  std::cout << "asyncFifo TB: " << readCount << "/" << NUM_ITEMS
            << " items checked, " << errors << " errors\n";
  std::cout << (pass ? "TEST PASSED" : "TEST FAILED") << "\n";

  delete dut;
  return pass ? 0 : 1;
}
