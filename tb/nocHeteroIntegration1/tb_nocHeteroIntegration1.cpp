// Testbench: NoC heterogeneous-protocol integration
//
// A single AHB-Lite initiator drives transactions that are routed across the
// NoC to targets on DIFFERENT AMBA protocols:
//   0x0000_0000 - 0x0FFF_FFFF -> AXI4-Lite target A (regs preset 0xA000_0000+n)
//   0x1000_0000 - 0x1FFF_FFFF -> APB       target B (regs preset 0xB000_0000+n)
// Register select = haddr[3:2].  This proves the canonical NoC payload lets an
// AHB master transparently access AXI-Lite and APB peripherals with no bridge.

#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <vector>

#include "Vtb_nocHeteroIntegration1_top.h"
#include <verilated.h>
#include <verilated_vcd_c.h>

#ifndef MAX_SIM_TIME
#define MAX_SIM_TIME 20000
#endif
#ifndef TIMEOUT_CYCLES
#define TIMEOUT_CYCLES 1024
#endif
#define RESET_CYCLES 6

// AHB HTRANS encodings
#define HTRANS_IDLE   0
#define HTRANS_NONSEQ 2
// AHB HSIZE: 2 = word (32-bit)
#define HSIZE_WORD 2

vluint64_t sim_time = 0;
vluint64_t posedge_cnt = 0;

using Dut = Vtb_nocHeteroIntegration1_top;

static void ahbDrive(Dut *dut, uint32_t addr, uint32_t wdata, bool write,
                     uint8_t size, bool hsel, uint8_t htrans) {
  dut->i_haddr  = addr;
  dut->i_hwdata = wdata;
  dut->i_hwrite = write ? 1 : 0;
  dut->i_hsize  = size;
  dut->i_hsel   = hsel ? 1 : 0;
  dut->i_htrans = htrans;
}

struct Txn {
  uint32_t addr;
  uint32_t wdata;     // for writes
  bool     write;
  uint32_t exp_rdata; // for reads
  const char *name;
};

enum AhbPhase { AHB_ADDR, AHB_DATA, AHB_ACCESS };

struct Driver {
  std::vector<Txn> txns;
  size_t           cur;
  AhbPhase         phase;
  vluint64_t       phase_start;
  int              passed;
  int              failed;
  bool             done;
};

static void driverInit(Driver &d, std::vector<Txn> t) {
  d.txns        = std::move(t);
  d.cur         = 0;
  d.phase       = AHB_ADDR;
  d.phase_start = 0;
  d.passed      = 0;
  d.failed      = 0;
  d.done        = false;
}

// Advance the AHB driver by one posedge. Returns false on fatal error.
static bool driverStep(Dut *dut, Driver &d) {
  if (d.done || d.cur >= d.txns.size()) {
    d.done = true;
    ahbDrive(dut, 0, 0, false, HSIZE_WORD, false, HTRANS_IDLE);
    return true;
  }

  Txn &t = d.txns[d.cur];

  switch (d.phase) {
    case AHB_ADDR:
      ahbDrive(dut, t.addr, t.wdata, t.write, HSIZE_WORD, true, HTRANS_NONSEQ);
      d.phase = AHB_DATA;
      break;

    case AHB_DATA:
      ahbDrive(dut, t.addr, t.wdata, t.write, HSIZE_WORD, true, HTRANS_IDLE);
      d.phase = AHB_ACCESS;
      d.phase_start = posedge_cnt;
      break;

    case AHB_ACCESS:
      if (dut->o_hreadyout) {
        if (dut->o_hresp) {
          std::cout << "  FAIL: " << t.name << " — ERROR response at addr=0x"
                    << std::hex << t.addr << std::dec << std::endl;
          d.failed++;
          return false;
        }

        if (!t.write) {
          uint32_t got = dut->o_hrdata;
          if (got == t.exp_rdata) {
            std::cout << "  PASS: " << t.name << " READ  addr=0x" << std::hex
                      << t.addr << " -> 0x" << got << std::dec << std::endl;
            d.passed++;
          } else {
            std::cout << "  FAIL: " << t.name << " READ  addr=0x" << std::hex
                      << t.addr << " expected 0x" << t.exp_rdata << " got 0x"
                      << got << std::dec << std::endl;
            d.failed++;
          }
        } else {
          std::cout << "  PASS: " << t.name << " WRITE addr=0x" << std::hex
                    << t.addr << " data=0x" << t.wdata << std::dec << std::endl;
          d.passed++;
        }

        ahbDrive(dut, 0, 0, false, HSIZE_WORD, false, HTRANS_IDLE);
        d.cur++;
        d.phase = AHB_ADDR;
      } else if ((posedge_cnt - d.phase_start) > TIMEOUT_CYCLES) {
        std::cout << "  FAIL: " << t.name << " — HREADYOUT timeout at addr=0x"
                  << std::hex << t.addr << std::dec << std::endl;
        d.failed++;
        return false;
      }
      break;
  }
  return true;
}

int main(int argc, char **argv, char **env) {
  (void)env;
  Verilated::commandArgs(argc, argv);
  Dut *dut = new Dut;

  Verilated::traceEverOn(true);
  VerilatedVcdC *m_trace = new VerilatedVcdC;
  dut->trace(m_trace, 5);
  m_trace->open("waveform_nocHeteroIntegration1.vcd");

  // AHB master exercises an AXI-Lite peripheral and an APB peripheral.
  Driver d;
  driverInit(d, {
    {0x00000000u, 0,           false, 0xA0000000u, "AHB->AXI reg0"}, // baseline
    {0x10000000u, 0,           false, 0xB0000000u, "AHB->APB reg0"}, // baseline
    {0x00000004u, 0x1234ABCDu, true,  0,           "AHB->AXI reg1"}, // write AXI
    {0x00000004u, 0,           false, 0x1234ABCDu, "AHB->AXI reg1"}, // read  AXI
    {0x10000004u, 0x5678EF01u, true,  0,           "AHB->APB reg1"}, // write APB
    {0x10000004u, 0,           false, 0x5678EF01u, "AHB->APB reg1"}, // read  APB
  });

  std::cout << "=== NoC heterogeneous integration: AHB master -> AXI + APB ==="
            << std::endl;

  bool fatal = false;

  dut->i_clk = 0;
  dut->i_arst_n = 0;
  ahbDrive(dut, 0, 0, false, HSIZE_WORD, false, HTRANS_IDLE);

  while (sim_time < MAX_SIM_TIME) {
    dut->i_clk ^= 1;
    dut->eval();

    if (dut->i_clk == 1) {
      posedge_cnt++;

      if (posedge_cnt <= RESET_CYCLES) {
        dut->i_arst_n = 0;
        ahbDrive(dut, 0, 0, false, HSIZE_WORD, false, HTRANS_IDLE);
      } else {
        dut->i_arst_n = 1;

        if (!driverStep(dut, d)) { fatal = true; }

        if (fatal) {
          m_trace->dump(sim_time);
          break;
        }

        if (d.done) {
          m_trace->dump(sim_time);
          sim_time++;
          break;
        }
      }
    }

    m_trace->dump(sim_time);
    sim_time++;
  }

  m_trace->close();

  int total_pass = d.passed;
  int total_fail = d.failed;
  size_t total_txn = d.txns.size();
  bool completed = d.done;

  std::cout << "\n=== Results ===" << std::endl;
  std::cout << "  total: " << total_pass << "/" << total_txn << " passed"
            << std::endl;

  delete dut;

  bool ok = !fatal && completed && (total_fail == 0) &&
            ((size_t)total_pass == total_txn);
  std::cout << (ok ? "TEST PASSED" : "TEST FAILED") << std::endl;
  return ok ? EXIT_SUCCESS : EXIT_FAILURE;
}
