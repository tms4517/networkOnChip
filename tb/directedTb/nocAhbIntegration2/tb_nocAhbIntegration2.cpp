// Testbench: NoC AHB integration #2 — NI ID demux
//
// Both initiators share ONE router NI port and both targets share ANOTHER
// router NI port (MAX_NI_PER_ROUTER = 2).  Delivery therefore depends entirely
// on the destination NI-ID field in the packet being demuxed correctly in both
// directions.  Two independent AHB-Lite driver state machines keep traffic from
// both initiators in flight concurrently.
//
// Address map (shared by both initiators):
//   0x0000_0000 - 0x0FFF_FFFF -> Target A (NI_ID 0, regs preset to 0xA000_0000 + n)
//   0x1000_0000 - 0x1FFF_FFFF -> Target B (NI_ID 1, regs preset to 0xB000_0000 + n)
// Register select = haddr[3:2].

#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <vector>

#include "Vtb_nocAhbIntegration2_top.h"
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

using Dut = Vtb_nocAhbIntegration2_top;

// ---------------------------------------------------------------------------
// AHB accessor helpers — select initiator 0 or 1 by index
// ---------------------------------------------------------------------------
static void ahbDrive(Dut *dut, int idx, uint32_t addr, uint32_t wdata,
                     bool write, uint8_t size, bool hsel, uint8_t htrans) {
  if (idx == 0) {
    dut->i_haddr0  = addr;
    dut->i_hwdata0 = wdata;
    dut->i_hwrite0 = write ? 1 : 0;
    dut->i_hsize0  = size;
    dut->i_hsel0   = hsel ? 1 : 0;
    dut->i_htrans0 = htrans;
  } else {
    dut->i_haddr1  = addr;
    dut->i_hwdata1 = wdata;
    dut->i_hwrite1 = write ? 1 : 0;
    dut->i_hsize1  = size;
    dut->i_hsel1   = hsel ? 1 : 0;
    dut->i_htrans1 = htrans;
  }
}

static bool ahbHreadyout(Dut *dut, int idx) {
  return idx == 0 ? dut->o_hreadyout0 : dut->o_hreadyout1;
}
static bool ahbHresp(Dut *dut, int idx) {
  return idx == 0 ? dut->o_hresp0 : dut->o_hresp1;
}
static uint32_t ahbHrdata(Dut *dut, int idx) {
  return idx == 0 ? dut->o_hrdata0 : dut->o_hrdata1;
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

enum AhbPhase { AHB_ADDR, AHB_DATA, AHB_ACCESS };

struct Driver {
  int                index;
  std::vector<Txn>   txns;
  size_t             cur;
  AhbPhase           phase;
  vluint64_t         phase_start;
  int                passed;
  int                failed;
  bool               done;
};

static void driverInit(Driver &d, int idx, std::vector<Txn> t) {
  d.index       = idx;
  d.txns        = std::move(t);
  d.cur         = 0;
  d.phase       = AHB_ADDR;
  d.phase_start = 0;
  d.passed      = 0;
  d.failed      = 0;
  d.done        = false;
}

// Advance one initiator's AHB driver by one posedge. Returns false on fatal
// error (timeout / ERROR response).
static bool driverStep(Dut *dut, Driver &d) {
  if (d.done) {
    ahbDrive(dut, d.index, 0, 0, false, HSIZE_WORD, false, HTRANS_IDLE);
    return true;
  }

  if (d.cur >= d.txns.size()) {
    d.done = true;
    ahbDrive(dut, d.index, 0, 0, false, HSIZE_WORD, false, HTRANS_IDLE);
    return true;
  }

  Txn &t = d.txns[d.cur];

  switch (d.phase) {
    case AHB_ADDR:
      // Address phase: present control + hold write data stable.
      ahbDrive(dut, d.index, t.addr, t.wdata, t.write, HSIZE_WORD, true,
               HTRANS_NONSEQ);
      d.phase = AHB_DATA;
      break;

    case AHB_DATA:
      // Data phase: deassert new-transfer request, keep HWDATA stable.
      ahbDrive(dut, d.index, t.addr, t.wdata, t.write, HSIZE_WORD, true,
               HTRANS_IDLE);
      d.phase = AHB_ACCESS;
      d.phase_start = posedge_cnt;
      break;

    case AHB_ACCESS:
      if (ahbHreadyout(dut, d.index)) {
        if (ahbHresp(dut, d.index)) {
          std::cout << "  FAIL: init" << d.index << " txn " << d.cur
                    << " — ERROR response at addr=0x" << std::hex << t.addr
                    << std::dec << std::endl;
          d.failed++;
          return false;
        }

        if (!t.write) {
          uint32_t got = ahbHrdata(dut, d.index);
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
        ahbDrive(dut, d.index, 0, 0, false, HSIZE_WORD, false, HTRANS_IDLE);
        d.cur++;
        d.phase = AHB_ADDR;
      } else if ((posedge_cnt - d.phase_start) > TIMEOUT_CYCLES) {
        std::cout << "  FAIL: init" << d.index << " txn " << d.cur
                  << " — HREADYOUT timeout at addr=0x" << std::hex << t.addr
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
  m_trace->open("waveform_nocAhbIntegration2.vcd");

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

  std::cout << "=== NoC AHB integration test #2: NI ID demux "
               "(2 initiators + 2 targets sharing routers) ===" << std::endl;

  bool fatal = false;

  // Reset
  dut->i_clk = 0;
  dut->i_arst_n = 0;
  ahbDrive(dut, 0, 0, 0, false, HSIZE_WORD, false, HTRANS_IDLE);
  ahbDrive(dut, 1, 0, 0, false, HSIZE_WORD, false, HTRANS_IDLE);

  while (sim_time < MAX_SIM_TIME) {
    dut->i_clk ^= 1;
    dut->eval();

    if (dut->i_clk == 1) {
      posedge_cnt++;

      if (posedge_cnt <= RESET_CYCLES) {
        dut->i_arst_n = 0;
        ahbDrive(dut, 0, 0, 0, false, HSIZE_WORD, false, HTRANS_IDLE);
        ahbDrive(dut, 1, 0, 0, false, HSIZE_WORD, false, HTRANS_IDLE);
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
