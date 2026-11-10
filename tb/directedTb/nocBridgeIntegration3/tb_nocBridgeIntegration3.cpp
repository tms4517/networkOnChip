// Testbench: nocBridgeIntegration3
// A CPU (AXI4-Lite), a DMA (AHB-Lite) and an IO block (APB) all access one AXI
// peripheral through the NoC.  Packets are opcode-tagged; the peripheral node
// converts to AXI via the AHB->AXI-Lite / APB->AXI-Lite bridges (AXI native).
// Verifies data integrity and cross-initiator sharing.

#include <cstdint>
#include <cstdlib>
#include <functional>
#include <iomanip>
#include <iostream>

#include "Vtb_nocBridgeIntegration3_top.h"
#include <verilated.h>
#include <verilated_vcd_c.h>

#define RESET_CYCLES 6
#ifndef TIMEOUT_CYCLES
#define TIMEOUT_CYCLES 1024
#endif
#ifndef MAX_SIM_TIME
#define MAX_SIM_TIME 20000
#endif

#define HTRANS_IDLE   0
#define HTRANS_NONSEQ 2
#define HSIZE_WORD    2

vluint64_t sim_time = 0;

using Dut = Vtb_nocBridgeIntegration3_top;

int main(int argc, char **argv, char **env) {
  (void)env;
  Verilated::commandArgs(argc, argv);
  Dut *dut = new Dut;

  Verilated::traceEverOn(true);
  VerilatedVcdC *m_trace = new VerilatedVcdC;
  dut->trace(m_trace, 5);
  m_trace->open("waveform_nocBridgeIntegration3.vcd");

  auto tick = [&]() {
    dut->i_clk = 0;
    dut->eval();
    m_trace->dump(sim_time++);
    dut->i_clk = 1;
    dut->eval();
    m_trace->dump(sim_time++);
  };

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

  // ---- CPU AXI4-Lite master ----
  auto axiWrite = [&](uint32_t addr, uint32_t data) -> bool {
    dut->i_awaddr = addr; dut->i_awvalid = 1;
    dut->i_wdata = data;  dut->i_wstrb = 0xF; dut->i_wvalid = 1;
    tick();
    dut->i_awvalid = 0; dut->i_wvalid = 0;
    if (!waitFor([&]() { return dut->o_bvalid != 0; })) return false;
    dut->i_bready = 1;
    bool ok = (dut->o_bresp == 0);
    tick();
    dut->i_bready = 0;
    return ok;
  };
  auto axiRead = [&](uint32_t addr, uint32_t *rdata) -> bool {
    dut->i_araddr = addr; dut->i_arvalid = 1;
    tick();
    dut->i_arvalid = 0;
    if (!waitFor([&]() { return dut->o_rvalid != 0; })) return false;
    dut->i_rready = 1;
    *rdata = dut->o_rdata;
    bool ok = (dut->o_rresp == 0);
    tick();
    dut->i_rready = 0;
    return ok;
  };

  // ---- DMA AHB-Lite master ----
  auto ahbAccess = [&](uint32_t addr, uint32_t data, bool write,
                       uint32_t *rdata) -> bool {
    dut->i_hsel = 1; dut->i_htrans = HTRANS_NONSEQ; dut->i_haddr = addr;
    dut->i_hwrite = write ? 1 : 0; dut->i_hsize = HSIZE_WORD; dut->i_hwdata = data;
    tick();                       // address phase
    dut->i_htrans = HTRANS_IDLE;  // data phase (HWDATA held)
    tick();
    if (!waitFor([&]() { return dut->o_hreadyout != 0; })) return false;
    bool ok = (dut->o_hresp == 0);
    if (!write && rdata) *rdata = dut->o_hrdata;
    dut->i_hsel = 0; dut->i_htrans = HTRANS_IDLE;
    tick();
    return ok;
  };
  auto ahbWrite = [&](uint32_t addr, uint32_t data) -> bool {
    return ahbAccess(addr, data, true, nullptr);
  };
  auto ahbRead = [&](uint32_t addr, uint32_t *rdata) -> bool {
    return ahbAccess(addr, 0, false, rdata);
  };

  // ---- IO APB master ----
  auto apbAccess = [&](uint32_t addr, uint32_t data, bool write,
                       uint32_t *rdata) -> bool {
    dut->i_apb_paddr = addr; dut->i_apb_pwdata = data;
    dut->i_apb_pwrite = write ? 1 : 0; dut->i_apb_pstrb = 0xF;
    dut->i_apb_psel = 1; dut->i_apb_penable = 0;
    tick();                   // APB setup phase
    dut->i_apb_penable = 1;   // APB access phase
    tick();
    int guard = 0;
    while (!dut->o_apb_pready) { tick(); if (++guard > TIMEOUT_CYCLES) return false; }
    bool ok = (dut->o_apb_pslverr == 0);
    if (!write && rdata) *rdata = dut->o_apb_prdata;
    dut->i_apb_psel = 0; dut->i_apb_penable = 0;
    tick();
    return ok;
  };
  auto apbWrite = [&](uint32_t addr, uint32_t data) -> bool {
    return apbAccess(addr, data, true, nullptr);
  };
  auto apbRead = [&](uint32_t addr, uint32_t *rdata) -> bool {
    return apbAccess(addr, 0, false, rdata);
  };

  int passed = 0, failed = 0;
  auto check = [&](bool ok, const std::string &msg) {
    std::cout << (ok ? "  PASS: " : "  FAIL: ") << msg << std::endl;
    if (ok) passed++; else failed++;
  };

  std::cout << "=== NoC bridge integration: AXI CPU + AHB DMA + APB IO -> AXI peripheral ==="
            << std::endl;

  // Idle all inputs, hold reset.
  dut->i_clk = 0; dut->i_arst_n = 0;
  dut->i_awvalid = 0; dut->i_wvalid = 0; dut->i_bready = 0; dut->i_arvalid = 0;
  dut->i_rready = 0; dut->i_wstrb = 0;
  dut->i_hsel = 0; dut->i_htrans = HTRANS_IDLE;
  dut->i_apb_psel = 0; dut->i_apb_penable = 0; dut->i_apb_pstrb = 0;
  for (int i = 0; i < RESET_CYCLES; i++) tick();
  dut->i_arst_n = 1;
  tick();

  uint32_t rd = 0;

  // CPU (AXI, native — no bridge) -> AXI peripheral
  check(axiRead(0x00000000u, &rd) && rd == 0xC0000000u, "CPU  AXI  read  reg0 baseline");
  check(axiWrite(0x00000004u, 0xAAAA1111u),                "CPU  AXI  write reg1 = 0xAAAA1111");
  check(axiRead(0x00000004u, &rd) && rd == 0xAAAA1111u,   "CPU  AXI  read  reg1");

  // DMA (AHB) -> AXI peripheral
  check(ahbRead(0x00000008u, &rd) && rd == 0xC2222222u,   "DMA  AHB  read  reg2 baseline");
  check(ahbWrite(0x0000000Cu, 0xBBBB3333u),                "DMA  AHB  write reg3 = 0xBBBB3333");
  check(ahbRead(0x0000000Cu, &rd) && rd == 0xBBBB3333u,   "DMA  AHB  read  reg3");

  // Cross-initiator sharing of the same peripheral.
  check(ahbRead(0x00000004u, &rd) && rd == 0xAAAA1111u,   "DMA  AHB  read  reg1 (CPU-written)");
  check(axiRead(0x0000000Cu, &rd) && rd == 0xBBBB3333u,   "CPU  AXI  read  reg3 (DMA-written)");

  // IO (APB) -> AXI peripheral
  check(apbRead(0x00000004u, &rd) && rd == 0xAAAA1111u,   "IO   APB  read  reg1 (CPU-written)");
  check(apbWrite(0x00000008u, 0xDDDD2222u),                "IO   APB  write reg2 = 0xDDDD2222");
  check(apbRead(0x00000008u, &rd) && rd == 0xDDDD2222u,   "IO   APB  read  reg2");
  check(axiRead(0x00000008u, &rd) && rd == 0xDDDD2222u,   "CPU  AXI  read  reg2 (IO-written)");

  m_trace->close();

  std::cout << "\n=== Results: " << passed << "/" << (passed + failed)
            << " passed ===" << std::endl;

  bool ok = (failed == 0) && (passed == 12);
  std::cout << (ok ? "TEST PASSED" : "TEST FAILED") << std::endl;

  delete dut;
  return ok ? EXIT_SUCCESS : EXIT_FAILURE;
}
