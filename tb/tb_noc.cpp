#include <cmath>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <stdlib.h>
#include <vector>

#include "Vnoc.h"            // Verilated DUT.
#include <verilated.h>       // Common verilator routines.
#include <verilated_vcd_c.h> // Write waverforms to a VCD file.

#define MAX_SIM_TIME 1000 // Number of clk edges.
#define RESET_NEG_EDGE 5  // Clk edge number to deassert arst.

vluint64_t sim_time = 0;
vluint64_t posedge_cnt = 0;

// Deassert arst_n only on the first clock edge.
// Note: By default all signals are initialized to 0, so there's no need to
// drive the other inputs to '0.
void dut_reset(Vnoc *dut) {
  dut->i_arst_n = 1;

  if ((sim_time > 2) && (sim_time < RESET_NEG_EDGE)) {
    dut->i_arst_n = 0;
  }
}

int main(int argc, char **argv, char **env) {
  srand(time(NULL));
  Verilated::commandArgs(argc, argv);
  Vnoc *dut = new Vnoc; // Instantiate DUT.

  // {{{ Set-up waveform dumping.

  Verilated::traceEverOn(true);
  VerilatedVcdC *m_trace = new VerilatedVcdC;
  dut->trace(m_trace, 5);
  m_trace->open("waveform.vcd");

  // }}} Set-up waveform dumping.

  while (sim_time < MAX_SIM_TIME) {
    dut_reset(dut);

    dut->i_clk ^= 1; // Toggle clk to create pos and neg edge.

    dut->eval(); // Evaluate all the signals in the DUT on each clock edge.

    if (dut->i_clk == 1) {
      posedge_cnt++;
    }

    // Write all the traced signal values into the waveform dump file.
    m_trace->dump(sim_time);

    sim_time++;
  }

  m_trace->close();
  delete dut;
  exit(EXIT_SUCCESS);
}
