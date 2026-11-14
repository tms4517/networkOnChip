// Testbench: nocBridgeIntegration4
// A CPU (AXI4-Lite) and a DMA (AHB-Lite) share one router; an APB peripheral
// (apbTargetBridge) and an AHB peripheral (ahbTargetBridge) share another.
// Verifies NI-ID routing through the bridge wrappers in both directions,
// cross-initiator sharing, and concurrent requests through niRouterPort.

#include <cstdint>
#include <cstdlib>
#include <functional>
#include <iomanip>
#include <iostream>

#include "Vtb_nocBridgeIntegration4_top.h"
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

#define APB_BASE 0x00000000u
#define AHB_BASE 0x10000000u

vluint64_t sim_time = 0;

using Dut = Vtb_nocBridgeIntegration4_top;

int main(int argc, char **argv, char **env) {
  (void)env;
  Verilated::commandArgs(argc, argv);
  Dut *dut = new Dut;

  Verilated::traceEverOn(true);
  VerilatedVcdC *m_trace = new VerilatedVcdC;
  dut->trace(m_trace, 5);
  m_trace->open("waveform_nocBridgeIntegration4.vcd");

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

  // ---- CPU read and DMA read issued in the same cycle ----
  auto concurrentRead = [&](uint32_t axiAddr, uint32_t *axiData,
                            uint32_t ahbAddr, uint32_t *ahbData) -> bool {
    dut->i_araddr = axiAddr; dut->i_arvalid = 1;
    dut->i_hsel = 1; dut->i_htrans = HTRANS_NONSEQ; dut->i_haddr = ahbAddr;
    dut->i_hwrite = 0; dut->i_hsize = HSIZE_WORD; dut->i_hwdata = 0;
    tick();
    dut->i_arvalid = 0;
    dut->i_htrans = HTRANS_IDLE;
    tick();
    bool axiDone = false, ahbDone = false, ok = true;
    int guard = 0;
    while (!(axiDone && ahbDone)) {
      dut->eval();
      if (!axiDone && dut->o_rvalid) {
        *axiData = dut->o_rdata;
        ok = ok && (dut->o_rresp == 0);
        dut->i_rready = 1;
        axiDone = true;
      }
      if (!ahbDone && dut->o_hreadyout) {
        *ahbData = dut->o_hrdata;
        ok = ok && (dut->o_hresp == 0);
        dut->i_hsel = 0;
        ahbDone = true;
      }
      tick();
      dut->i_rready = 0;
      if (++guard > TIMEOUT_CYCLES) return false;
    }
    return ok;
  };

  int passed = 0, failed = 0;
  auto check = [&](bool ok, const std::string &msg) {
    std::cout << (ok ? "  PASS: " : "  FAIL: ") << msg << std::endl;
    if (ok) passed++; else failed++;
  };

  std::cout << "=== NoC bridge integration 4: AXI CPU + AHB DMA (shared router) ->"
               " APB + AHB peripherals (shared router) ===" << std::endl;

  // Idle all inputs, hold reset.
  dut->i_clk = 0; dut->i_arst_n = 0;
  dut->i_awvalid = 0; dut->i_wvalid = 0; dut->i_bready = 0; dut->i_arvalid = 0;
  dut->i_rready = 0; dut->i_wstrb = 0;
  dut->i_hsel = 0; dut->i_htrans = HTRANS_IDLE;
  for (int i = 0; i < RESET_CYCLES; i++) tick();
  dut->i_arst_n = 1;
  tick();

  uint32_t rd = 0, rd2 = 0;

  // CPU (AXI, NI 0) -> both peripherals
  check(axiRead(APB_BASE + 0x0, &rd) && rd == 0xA0000000u,  "CPU AXI read  APB reg0 baseline");
  check(axiWrite(APB_BASE + 0x4, 0x11110001u),               "CPU AXI write APB reg1 = 0x11110001");
  check(axiRead(APB_BASE + 0x4, &rd) && rd == 0x11110001u,  "CPU AXI read  APB reg1");
  check(axiRead(AHB_BASE + 0x0, &rd) && rd == 0xB0000000u,  "CPU AXI read  AHB reg0 baseline");
  check(axiWrite(AHB_BASE + 0x8, 0x11110002u),               "CPU AXI write AHB reg2 = 0x11110002");
  check(axiRead(AHB_BASE + 0x8, &rd) && rd == 0x11110002u,  "CPU AXI read  AHB reg2");

  // DMA (AHB, NI 1) -> both peripherals
  check(ahbRead(APB_BASE + 0x8, &rd) && rd == 0xA2222222u,  "DMA AHB read  APB reg2 baseline");
  check(ahbWrite(APB_BASE + 0xC, 0x22220003u),               "DMA AHB write APB reg3 = 0x22220003");
  check(ahbRead(APB_BASE + 0xC, &rd) && rd == 0x22220003u,  "DMA AHB read  APB reg3");
  check(ahbRead(AHB_BASE + 0x8, &rd) && rd == 0x11110002u,  "DMA AHB read  AHB reg2 (CPU-written)");
  check(ahbWrite(AHB_BASE + 0xC, 0x22220004u),               "DMA AHB write AHB reg3 = 0x22220004");
  check(ahbRead(AHB_BASE + 0xC, &rd) && rd == 0x22220004u,  "DMA AHB read  AHB reg3");
  check(axiRead(APB_BASE + 0xC, &rd) && rd == 0x22220003u,  "CPU AXI read  APB reg3 (DMA-written)");

  // Concurrent: both initiators arbitrate for the shared initiator router port.
  bool ok = concurrentRead(APB_BASE + 0x4, &rd, AHB_BASE + 0xC, &rd2);
  check(ok && rd  == 0x11110001u, "CONCURRENT CPU AXI read APB reg1");
  check(ok && rd2 == 0x22220004u, "CONCURRENT DMA AHB read AHB reg3");

  ok = concurrentRead(AHB_BASE + 0xC, &rd, APB_BASE + 0x4, &rd2);
  check(ok && rd  == 0x22220004u, "CONCURRENT CPU AXI read AHB reg3 (crossed)");
  check(ok && rd2 == 0x11110001u, "CONCURRENT DMA AHB read APB reg1 (crossed)");

  // Concurrent to the same bridge: it serialises the two protocols.
  ok = concurrentRead(APB_BASE + 0x0, &rd, APB_BASE + 0xC, &rd2);
  check(ok && rd  == 0xA0000000u, "CONCURRENT CPU AXI read APB reg0 (same target)");
  check(ok && rd2 == 0x22220003u, "CONCURRENT DMA AHB read APB reg3 (same target)");

  m_trace->close();

  std::cout << "\n=== Results: " << passed << "/" << (passed + failed)
            << " passed ===" << std::endl;

  bool pass = (failed == 0) && (passed == 19);
  std::cout << (pass ? "TEST PASSED" : "TEST FAILED") << std::endl;

  delete dut;
  return pass ? EXIT_SUCCESS : EXIT_FAILURE;
}
