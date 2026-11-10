// Testbench: nocAxiIntegration1
// Drives concurrent AXI4-Lite traffic from two niAxiLiteInitiator managers to
// two niAxiLiteTarget subordinates through the NOC, and checks that write/read
// responses route back to the correct initiator.

#include <cstdint>
#include <cstdlib>
#include <functional>
#include <iomanip>
#include <iostream>

#include "Vtb_nocAxiIntegration1_top.h"
#include <verilated.h>
#include <verilated_vcd_c.h>

#define RESET_CYCLES 5

#ifndef GRID_WIDTH
#define GRID_WIDTH 4
#endif
#ifndef TIMEOUT_CYCLES
#define TIMEOUT_CYCLES 512
#endif

vluint64_t sim_time = 0;
vluint64_t posedge_cnt = 0;

// Pointers to one manager's AXI4-Lite subordinate interface on the DUT.
struct Mgr {
  IData *awaddr;
  CData *awvalid;
  CData *awready;
  IData *wdata;
  CData *wstrb;
  CData *wvalid;
  CData *wready;
  CData *bresp;
  CData *bvalid;
  CData *bready;
  IData *araddr;
  CData *arvalid;
  CData *arready;
  IData *rdata;
  CData *rresp;
  CData *rvalid;
  CData *rready;
};

int main(int argc, char **argv, char **env) {
  (void)env;
  Verilated::commandArgs(argc, argv);
  Vtb_nocAxiIntegration1_top *dut = new Vtb_nocAxiIntegration1_top;

  Verilated::traceEverOn(true);
  VerilatedVcdC *m_trace = new VerilatedVcdC;
  dut->trace(m_trace, 5);
  m_trace->open("waveform_nocAxiIntegration1.vcd");

  auto tick = [&]() {
    dut->i_clk = 0;
    dut->eval();
    m_trace->dump(sim_time++);
    dut->i_clk = 1;
    dut->eval();
    m_trace->dump(sim_time++);
    posedge_cnt++;
  };

  bool failed = false;

  auto waitFor = [&](std::function<bool()> cond) -> bool {
    int guard = 0;
    dut->eval();
    while (!cond()) {
      tick();
      dut->eval();
      if (++guard > TIMEOUT_CYCLES)
        return false;
    }
    return true;
  };

  Mgr m0 = {&dut->i_awaddr0, &dut->i_awvalid0, &dut->o_awready0,
            &dut->i_wdata0,  &dut->i_wstrb0,   &dut->i_wvalid0,
            &dut->o_wready0, &dut->o_bresp0,   &dut->o_bvalid0,
            &dut->i_bready0, &dut->i_araddr0,  &dut->i_arvalid0,
            &dut->o_arready0, &dut->o_rdata0,  &dut->o_rresp0,
            &dut->o_rvalid0, &dut->i_rready0};

  Mgr m1 = {&dut->i_awaddr1, &dut->i_awvalid1, &dut->o_awready1,
            &dut->i_wdata1,  &dut->i_wstrb1,   &dut->i_wvalid1,
            &dut->o_wready1, &dut->o_bresp1,   &dut->o_bvalid1,
            &dut->i_bready1, &dut->i_araddr1,  &dut->i_arvalid1,
            &dut->o_arready1, &dut->o_rdata1,  &dut->o_rresp1,
            &dut->o_rvalid1, &dut->i_rready1};

  // Perform an AXI write; returns true on success (BRESP == OKAY).
  auto axiWrite = [&](Mgr &m, uint32_t addr, uint32_t data) -> bool {
    *m.awaddr = addr;
    *m.awvalid = 1;
    *m.wdata = data;
    *m.wstrb = 0xF;
    *m.wvalid = 1;
    tick();
    *m.awvalid = 0;
    *m.wvalid = 0;
    if (!waitFor([&]() { return *m.bvalid != 0; }))
      return false;
    *m.bready = 1;
    bool ok = (*m.bresp == 0);
    tick();
    *m.bready = 0;
    return ok;
  };

  // Perform an AXI read; returns true on success and writes rdata.
  auto axiRead = [&](Mgr &m, uint32_t addr, uint32_t *rdata) -> bool {
    *m.araddr = addr;
    *m.arvalid = 1;
    tick();
    *m.arvalid = 0;
    if (!waitFor([&]() { return *m.rvalid != 0; }))
      return false;
    *m.rready = 1;
    *rdata = *m.rdata;
    bool ok = (*m.rresp == 0);
    tick();
    *m.rready = 0;
    return ok;
  };

  int passed = 0;
  int total = 0;
  auto check = [&](bool cond, const char *desc) {
    total++;
    if (cond) {
      std::cout << "  PASS: " << desc << std::endl;
      passed++;
    } else {
      std::cout << "  FAIL: " << desc << std::endl;
      failed = true;
    }
  };

  std::cout << "=== nocAxiIntegration1 Testbench ===" << std::endl;

  // Initialize inputs
  dut->i_clk = 0;
  dut->i_arst_n = 0;
  dut->i_awaddr0 = 0; dut->i_awvalid0 = 0; dut->i_wdata0 = 0;
  dut->i_wstrb0 = 0;  dut->i_wvalid0 = 0;  dut->i_bready0 = 0;
  dut->i_araddr0 = 0; dut->i_arvalid0 = 0; dut->i_rready0 = 0;
  dut->i_awaddr1 = 0; dut->i_awvalid1 = 0; dut->i_wdata1 = 0;
  dut->i_wstrb1 = 0;  dut->i_wvalid1 = 0;  dut->i_bready1 = 0;
  dut->i_araddr1 = 0; dut->i_arvalid1 = 0; dut->i_rready1 = 0;

  for (int i = 0; i < RESET_CYCLES; i++)
    tick();
  dut->i_arst_n = 1;
  tick();

  uint32_t rd = 0;

  // Manager 0 -> Target A (0x0xxx)
  std::cout << "M0 write Target A reg0" << std::endl;
  check(axiWrite(m0, 0x00000000, 0x11110000), "M0 write A reg0 BRESP OKAY");
  std::cout << "M0 read Target A reg0" << std::endl;
  check(axiRead(m0, 0x00000000, &rd) && rd == 0x11110000,
        "M0 read A reg0 == 0x11110000");
  if (rd != 0x11110000 && !failed)
    std::cout << "    got 0x" << std::hex << rd << std::dec << std::endl;

  // Manager 1 -> Target B (0x1xxx)
  std::cout << "M1 write Target B reg1" << std::endl;
  check(axiWrite(m1, 0x10000004, 0x22220004), "M1 write B reg1 BRESP OKAY");
  std::cout << "M1 read Target B reg1" << std::endl;
  check(axiRead(m1, 0x10000004, &rd) && rd == 0x22220004,
        "M1 read B reg1 == 0x22220004");
  if (rd != 0x22220004 && !failed)
    std::cout << "    got 0x" << std::hex << rd << std::dec << std::endl;

  // Cross traffic: Manager 0 -> Target B default reg2, Manager 1 -> Target A default reg3
  std::cout << "M0 read Target B reg2 (default)" << std::endl;
  check(axiRead(m0, 0x10000008, &rd) && rd == 0xB2222222,
        "M0 read B reg2 == 0xB2222222");
  if (rd != 0xB2222222 && !failed)
    std::cout << "    got 0x" << std::hex << rd << std::dec << std::endl;

  std::cout << "M1 read Target A reg3 (default)" << std::endl;
  check(axiRead(m1, 0x0000000C, &rd) && rd == 0xA3333333,
        "M1 read A reg3 == 0xA3333333");
  if (rd != 0xA3333333 && !failed)
    std::cout << "    got 0x" << std::hex << rd << std::dec << std::endl;

  m_trace->close();

  std::cout << "\n=== Results: " << passed << "/" << total << " passed ==="
            << std::endl;

  delete dut;
  return (!failed && passed == total) ? EXIT_SUCCESS : EXIT_FAILURE;
}
