// Testbench: niAhbTarget
// Injects NoC packets at a source router and verifies that niAhbTarget
// correctly drives AHB-Lite transactions to its local slave.
// Also tests read transactions: injects a read request and checks that
// the response packet carrying HRDATA arrives back at the source router.

#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <iostream>

#include "Vtb_niAhbTarget_top.h"
#include <verilated.h>
#include <verilated_vcd_c.h>

#define RESET_CYCLES 5

#ifndef GRID_WIDTH
#define GRID_WIDTH 4
#endif
#ifndef TIMEOUT_CYCLES
#define TIMEOUT_CYCLES 512
#endif
#ifndef MAX_SIM_TIME
#define MAX_SIM_TIME 10000
#endif

#define COORD_WIDTH 2 // clog2(4)
#define PAYLOAD_WIDTH 71
#define PACKET_WIDTH (PAYLOAD_WIDTH + COORD_WIDTH * 4) // 79

// AHB HTRANS encodings
#define HTRANS_NONSEQ 2

// Source and destination coordinates (must match SV parameters)
#define SRC_ROW 0
#define SRC_COL 0
#define DST_ROW 1
#define DST_COL 1

vluint64_t sim_time = 0;
vluint64_t posedge_cnt = 0;

// ----------------------------------------------------------------
// Packet encoding helpers
// Packet layout (79 bits, LSB first):
//   [1:0]   = dstCol
//   [3:2]   = dstRow
//   [5:4]   = srcCol
//   [7:6]   = srcRow
//   [8]     = HRESP
//   [9]     = HWRITE
//   [12:10] = HSIZE
//   [14:13] = HTRANS
//   [46:15] = HDATA
//   [78:47] = HADDR
// ----------------------------------------------------------------

struct NocPacket {
  uint32_t haddr;
  uint32_t hdata;
  bool     hwrite;
  uint8_t  hsize;
  uint8_t  htrans;
  int      dst_row;
  int      dst_col;
  int      src_row;
  int      src_col;
};

// Set 'width' bits of 'val' at 'start' within a Verilator wide array.
static void setBits(WData *w, int start, int width, uint32_t val) {
  for (int b = 0; b < width; b++) {
    int bit = start + b;
    if ((val >> b) & 0x1) {
      w[bit / 32] |= (1u << (bit % 32));
    } else {
      w[bit / 32] &= ~(1u << (bit % 32));
    }
  }
}

// Extract up to 32 bits from a Verilator wide array.
static uint32_t getBits(const WData *w, int start, int width) {
  int word_idx = start / 32;
  int bit_off  = start % 32;
  uint64_t raw = (uint64_t)(w[word_idx]) >> bit_off;
  if (bit_off > 0) {
    raw |= (uint64_t)(w[word_idx + 1]) << (32 - bit_off);
  }
  return (uint32_t)(raw & ((1ULL << width) - 1));
}

// Pack a NocPacket into the Verilator wide type (3 x 32-bit words for 79 bits).
static void packPacket(const NocPacket &pkt, WData *out) {
  out[0] = 0;
  out[1] = 0;
  out[2] = 0;
  setBits(out, 0,  2, pkt.dst_col & 0x3);
  setBits(out, 2,  2, pkt.dst_row & 0x3);
  setBits(out, 4,  2, pkt.src_col & 0x3);
  setBits(out, 6,  2, pkt.src_row & 0x3);
  setBits(out, 8,  1, 0);                // HRESP = OKAY on a request
  setBits(out, 9,  1, pkt.hwrite ? 1 : 0);
  setBits(out, 10, 3, pkt.hsize & 0x7);
  setBits(out, 13, 2, pkt.htrans & 0x3);
  setBits(out, 15, 32, pkt.hdata);
  setBits(out, 47, 32, pkt.haddr);
}

// Decode response packet from the Verilator wide type.
static NocPacket unpackPacket(const WData *in) {
  NocPacket pkt;
  pkt.dst_col = getBits(in, 0,  2);
  pkt.dst_row = getBits(in, 2,  2);
  pkt.src_col = getBits(in, 4,  2);
  pkt.src_row = getBits(in, 6,  2);
  pkt.hwrite  = getBits(in, 9,  1);
  pkt.hsize   = getBits(in, 10, 3);
  pkt.htrans  = getBits(in, 13, 2);
  pkt.hdata   = getBits(in, 15, 32);
  pkt.haddr   = getBits(in, 47, 32);
  return pkt;
}

// ----------------------------------------------------------------
// Test definitions
// ----------------------------------------------------------------
struct TestCase {
  NocPacket req;
  // For reads: expected HRDATA in response
  uint32_t  exp_hrdata;
  const char *desc;
};

int main(int argc, char **argv, char **env) {
  (void)env;
  Verilated::commandArgs(argc, argv);
  Vtb_niAhbTarget_top *dut = new Vtb_niAhbTarget_top;

  Verilated::traceEverOn(true);
  VerilatedVcdC *m_trace = new VerilatedVcdC;
  dut->trace(m_trace, 5);
  m_trace->open("waveform_niAhbTarget.vcd");

  // Test cases
  TestCase tests[] = {
    // WRITE tests: inject write packet destined for (DST_ROW, DST_COL)
    { {0x00000000, 0xDEADBEEF, true,  2, HTRANS_NONSEQ, DST_ROW, DST_COL, SRC_ROW, SRC_COL}, 0, "Write reg[0] = 0xDEADBEEF" },
    { {0x00000004, 0xCAFEBABE, true,  2, HTRANS_NONSEQ, DST_ROW, DST_COL, SRC_ROW, SRC_COL}, 0, "Write reg[1] = 0xCAFEBABE" },
    // READ tests: read back values (slave returns stored data)
    { {0x00000000, 0x00000000, false, 2, HTRANS_NONSEQ, DST_ROW, DST_COL, SRC_ROW, SRC_COL}, 0xDEADBEEF, "Read reg[0] expect 0xDEADBEEF" },
    { {0x00000004, 0x00000000, false, 2, HTRANS_NONSEQ, DST_ROW, DST_COL, SRC_ROW, SRC_COL}, 0xCAFEBABE, "Read reg[1] expect 0xCAFEBABE" },
    // Read unmodified registers (slave resets to known values)
    { {0x00000008, 0x00000000, false, 2, HTRANS_NONSEQ, DST_ROW, DST_COL, SRC_ROW, SRC_COL}, 0xCCCC2222, "Read reg[2] expect 0xCCCC2222" },
    { {0x0000000C, 0x00000000, false, 2, HTRANS_NONSEQ, DST_ROW, DST_COL, SRC_ROW, SRC_COL}, 0xDDDD3333, "Read reg[3] expect 0xDDDD3333" },
  };
  const int NUM_TESTS = sizeof(tests) / sizeof(tests[0]);
  int current_test = 0;
  int tests_passed = 0;

  enum Phase { PH_IDLE, PH_INJECT, PH_WAIT_ACCEPT, PH_WAIT_AHB, PH_WAIT_RESP, PH_DRAIN };
  Phase phase = PH_IDLE;
  vluint64_t phase_start = 0;

  std::cout << "=== niAhbTarget Testbench ===" << std::endl;
  std::cout << "Running " << NUM_TESTS << " tests" << std::endl;

  // Reset signals
  dut->i_clk = 0;
  dut->i_arst_n = 0;
  dut->i_srcNiToRouterValid = 0;
  dut->i_srcRouterToNiReady = 1;
  memset(dut->i_srcNiToRouter, 0, sizeof(dut->i_srcNiToRouter));

  while (sim_time < MAX_SIM_TIME) {
    dut->i_clk ^= 1;
    dut->eval();

    if (dut->i_clk == 1) {
      posedge_cnt++;

      // Hold reset
      if (posedge_cnt <= RESET_CYCLES) {
        dut->i_arst_n = 0;
      } else {
        dut->i_arst_n = 1;
      }

      if (!dut->i_arst_n) {
        // In reset
      } else if (current_test >= NUM_TESTS) {
        break;
      } else {
        TestCase &t = tests[current_test];

        switch (phase) {
          case PH_IDLE:
            // Prepare to inject packet
            phase = PH_INJECT;
            std::cout << "Test " << current_test << ": " << t.desc << std::endl;
            break;

          case PH_INJECT:
            // Drive packet at source NI
            packPacket(t.req, dut->i_srcNiToRouter);
            dut->i_srcNiToRouterValid = 1;
            phase = PH_WAIT_ACCEPT;
            phase_start = posedge_cnt;
            break;

          case PH_WAIT_ACCEPT:
            // Wait for source router to accept the packet
            if (dut->o_srcNiToRouterReady) {
              // Packet accepted, deassert valid next cycle
              dut->i_srcNiToRouterValid = 0;
              if (t.req.hwrite) {
                // For writes: wait for the AHB transaction to complete
                phase = PH_WAIT_AHB;
              } else {
                // For reads: wait for response packet at source router
                phase = PH_WAIT_RESP;
              }
              phase_start = posedge_cnt;
            } else if ((posedge_cnt - phase_start) > TIMEOUT_CYCLES) {
              std::cout << "  FAIL: Timeout waiting for source router to accept packet"
                        << std::endl;
              m_trace->close();
              delete dut;
              return EXIT_FAILURE;
            }
            break;

          case PH_WAIT_AHB:
            // For writes: wait for the AHB access to appear then complete.
            // We look for the moment HSEL goes low again (transaction done).
            if ((posedge_cnt - phase_start) > TIMEOUT_CYCLES) {
              std::cout << "  FAIL: Timeout waiting for AHB write to complete"
                        << std::endl;
              m_trace->close();
              delete dut;
              return EXIT_FAILURE;
            }
            if ((posedge_cnt - phase_start) > 5 && !dut->o_hsel) {
              // Transaction has completed
              std::cout << "  PASS: Write transaction completed" << std::endl;
              tests_passed++;
              current_test++;
              phase = PH_IDLE;
            }
            break;

          case PH_WAIT_RESP:
            // For reads: wait for response packet at source NI
            if (dut->o_srcRouterToNiValid) {
              NocPacket resp = unpackPacket(dut->o_srcRouterToNi);
              // HRDATA is in the HDATA field position
              uint32_t hrdata = resp.hdata;

              if (hrdata == t.exp_hrdata) {
                std::cout << "  PASS: Read response 0x" << std::hex << hrdata
                          << std::dec << " matches expected" << std::endl;
                tests_passed++;
              } else {
                std::cout << "  FAIL: Read response 0x" << std::hex << hrdata
                          << " expected 0x" << t.exp_hrdata << std::dec
                          << std::endl;
              }
              current_test++;
              phase = PH_DRAIN;
              phase_start = posedge_cnt;
            } else if ((posedge_cnt - phase_start) > TIMEOUT_CYCLES) {
              std::cout << "  FAIL: Timeout waiting for read response packet"
                        << std::endl;
              m_trace->close();
              delete dut;
              return EXIT_FAILURE;
            }
            break;

          case PH_DRAIN:
            // Wait for response valid to deassert before starting next test
            if (!dut->o_srcRouterToNiValid) {
              phase = PH_IDLE;
            } else if ((posedge_cnt - phase_start) > TIMEOUT_CYCLES) {
              std::cout << "  FAIL: Timeout draining response" << std::endl;
              m_trace->close();
              delete dut;
              return EXIT_FAILURE;
            }
            break;
        }
      }
    }

    m_trace->dump(sim_time);
    sim_time++;
  }

  m_trace->close();

  std::cout << "\n=== Results: " << tests_passed << "/" << NUM_TESTS
            << " passed ===" << std::endl;

  delete dut;
  return (tests_passed == NUM_TESTS) ? EXIT_SUCCESS : EXIT_FAILURE;
}
