// Testbench: NoC APB integration #2 — NI ID demux
//
// Both initiators share ONE router NI port and both targets share ANOTHER
// router NI port (MAX_NI_PER_ROUTER = 2).  Delivery therefore depends entirely
// on the destination NI-ID field in the packet being demuxed correctly in both
// directions.  Two independent APB driver state machines keep traffic from both
// initiators in flight concurrently.
//
// Address map (shared by both initiators):
//   0x0000_0000 - 0x0FFF_FFFF -> Target A (NI_ID 0, regs preset to 0xA000_0000 + n)
//   0x1000_0000 - 0x1FFF_FFFF -> Target B (NI_ID 1, regs preset to 0xB000_0000 + n)
// Register select = paddr[3:2].

#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <vector>

#include "Vtb_nocApbIntegration2_top.h"
#include <verilated.h>
#include <verilated_vcd_c.h>

#ifndef MAX_SIM_TIME
#define MAX_SIM_TIME 20000
#endif
#ifndef TIMEOUT_CYCLES
#define TIMEOUT_CYCLES 1024
#endif
#define RESET_CYCLES 6

vluint64_t sim_time = 0;
vluint64_t posedge_cnt = 0;

using Dut = Vtb_nocApbIntegration2_top;

// ---------------------------------------------------------------------------
// APB accessor helpers — select initiator 0 or 1 by index
// ---------------------------------------------------------------------------
static void apbDrive(Dut *dut, int idx, uint32_t addr, uint32_t wdata,
                     bool write, uint8_t strb, bool psel, bool penable) {
  if (idx == 0) {
    dut->i_paddr0   = addr;
    dut->i_pwdata0  = wdata;
    dut->i_pwrite0  = write ? 1 : 0;
    dut->i_pstrb0   = strb;
    dut->i_psel0    = psel ? 1 : 0;
    dut->i_penable0 = penable ? 1 : 0;
  } else {
    dut->i_paddr1   = addr;
    dut->i_pwdata1  = wdata;
    dut->i_pwrite1  = write ? 1 : 0;
    dut->i_pstrb1   = strb;
    dut->i_psel1    = psel ? 1 : 0;
    dut->i_penable1 = penable ? 1 : 0;
  }
}

static bool apbPready(Dut *dut, int idx) {
  return idx == 0 ? dut->o_pready0 : dut->o_pready1;
}
static bool apbPslverr(Dut *dut, int idx) {
  return idx == 0 ? dut->o_pslverr0 : dut->o_pslverr1;
}
static uint32_t apbPrdata(Dut *dut, int idx) {
  return idx == 0 ? dut->o_prdata0 : dut->o_prdata1;
}

// ---------------------------------------------------------------------------
// Per-initiator transaction / driver definitions
// ---------------------------------------------------------------------------
struct Txn {
  uint32_t addr;
  uint32_t wdata;     // for writes
  bool     write;
  uint32_t exp_rdata; // for reads
};

enum ApbPhase { APB_IDLE, APB_SETUP, APB_ACCESS };

struct Driver {
  int                index;
  std::vector<Txn>   txns;
  size_t             cur;
  ApbPhase           phase;
  vluint64_t         phase_start;
  int                passed;
  int                failed;
  bool               done;
};

static void driverInit(Driver &d, int idx, std::vector<Txn> t) {
  d.index       = idx;
  d.txns        = std::move(t);
  d.cur         = 0;
  d.phase       = APB_IDLE;
  d.phase_start = 0;
  d.passed      = 0;
  d.failed      = 0;
  d.done        = false;
}

// Advance one initiator's APB driver by one posedge. Returns false on fatal
// error (timeout / SLVERR).
static bool driverStep(Dut *dut, Driver &d) {
  if (d.done) {
    apbDrive(dut, d.index, 0, 0, false, 0, false, false);
    return true;
  }

  if (d.cur >= d.txns.size()) {
    d.done = true;
    apbDrive(dut, d.index, 0, 0, false, 0, false, false);
    return true;
  }

  Txn &t = d.txns[d.cur];

  switch (d.phase) {
    case APB_IDLE:
      apbDrive(dut, d.index, t.addr, t.wdata, t.write, 0xF, true, false);
      d.phase = APB_SETUP;
      break;

    case APB_SETUP:
      apbDrive(dut, d.index, t.addr, t.wdata, t.write, 0xF, true, true);
      d.phase = APB_ACCESS;
      d.phase_start = posedge_cnt;
      break;

    case APB_ACCESS:
      if (apbPready(dut, d.index)) {
        if (apbPslverr(dut, d.index)) {
          std::cout << "  FAIL: init" << d.index << " txn " << d.cur
                    << " — SLVERR at addr=0x" << std::hex << t.addr << std::dec
                    << std::endl;
          d.failed++;
          return false;
        }

        if (!t.write) {
          uint32_t got = apbPrdata(dut, d.index);
          if (got == t.exp_rdata) {
            std::cout << "  PASS: init" << d.index << " READ  addr=0x"
                      << std::hex << t.addr << " -> 0x" << got << std::dec
                      << std::endl;
            d.passed++;
          } else {
            std::cout << "  FAIL: init" << d.index << " READ  addr=0x"
                      << std::hex << t.addr << " expected 0x" << t.exp_rdata
                      << " got 0x" << got << std::dec << std::endl;
            d.failed++;
          }
        } else {
          std::cout << "  PASS: init" << d.index << " WRITE addr=0x"
                    << std::hex << t.addr << " data=0x" << t.wdata << std::dec
                    << std::endl;
          d.passed++;
        }

        // Deassert bus and move to next transaction.
        apbDrive(dut, d.index, 0, 0, false, 0, false, false);
        d.cur++;
        d.phase = APB_IDLE;
      } else if ((posedge_cnt - d.phase_start) > TIMEOUT_CYCLES) {
        std::cout << "  FAIL: init" << d.index << " txn " << d.cur
                  << " — PREADY timeout at addr=0x" << std::hex << t.addr
                  << std::dec << std::endl;
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
  m_trace->open("waveform_nocApbIntegration2.vcd");

  // Initiator 0 (NI_ID 0): reads baseline of both targets, then writes/reads reg1.
  Driver d0;
  driverInit(d0, 0, {
    {0x00000000u, 0,           false, 0xA0000000u}, // read  TgtA reg0
    {0x10000000u, 0,           false, 0xB0000000u}, // read  TgtB reg0
    {0x00000004u, 0x00000001u, true,  0},           // write TgtA reg1
    {0x00000004u, 0,           false, 0x00000001u}, // read  TgtA reg1
    {0x10000004u, 0x00000002u, true,  0},           // write TgtB reg1
    {0x10000004u, 0,           false, 0x00000002u}, // read  TgtB reg1
  });

  // Initiator 1 (NI_ID 1): reads baseline of both targets, then writes/reads reg2.
  Driver d1;
  driverInit(d1, 1, {
    {0x00000000u, 0,           false, 0xA0000000u}, // read  TgtA reg0
    {0x10000000u, 0,           false, 0xB0000000u}, // read  TgtB reg0
    {0x00000008u, 0x000000AAu, true,  0},           // write TgtA reg2
    {0x00000008u, 0,           false, 0x000000AAu}, // read  TgtA reg2
    {0x10000008u, 0x000000BBu, true,  0},           // write TgtB reg2
    {0x10000008u, 0,           false, 0x000000BBu}, // read  TgtB reg2
  });

  std::cout << "=== NoC APB integration test #2: NI ID demux "
               "(2 initiators + 2 targets sharing routers) ===" << std::endl;

  bool fatal = false;

  // Reset
  dut->i_clk = 0;
  dut->i_arst_n = 0;
  apbDrive(dut, 0, 0, 0, false, 0, false, false);
  apbDrive(dut, 1, 0, 0, false, 0, false, false);

  while (sim_time < MAX_SIM_TIME) {
    dut->i_clk ^= 1;
    dut->eval();

    if (dut->i_clk == 1) {
      posedge_cnt++;

      if (posedge_cnt <= RESET_CYCLES) {
        dut->i_arst_n = 0;
        apbDrive(dut, 0, 0, 0, false, 0, false, false);
        apbDrive(dut, 1, 0, 0, false, 0, false, false);
      } else {
        dut->i_arst_n = 1;

        if (!driverStep(dut, d0)) { fatal = true; }
        if (!driverStep(dut, d1)) { fatal = true; }

        if (fatal) {
          m_trace->dump(sim_time);
          break;
        }

        if (d0.done && d1.done) {
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

  int total_pass = d0.passed + d1.passed;
  int total_fail = d0.failed + d1.failed;
  size_t total_txn = d0.txns.size() + d1.txns.size();
  bool completed = d0.done && d1.done;

  std::cout << "\n=== Results ===" << std::endl;
  std::cout << "  init0 (NI_ID 0): " << d0.passed << " passed, " << d0.failed
            << " failed" << std::endl;
  std::cout << "  init1 (NI_ID 1): " << d1.passed << " passed, " << d1.failed
            << " failed" << std::endl;
  std::cout << "  total: " << total_pass << "/" << total_txn << " passed"
            << std::endl;

  delete dut;

  bool ok = !fatal && completed && (total_fail == 0) &&
            ((size_t)total_pass == total_txn);
  std::cout << (ok ? "TEST PASSED" : "TEST FAILED") << std::endl;
  return ok ? EXIT_SUCCESS : EXIT_FAILURE;
}
