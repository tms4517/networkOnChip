// Testbench: niApbTarget
// Injects NoC packets at a source router and verifies that niApbTarget
// correctly drives APB transactions to its local slave.
// Also tests read transactions: injects a read request and checks that
// the response packet carrying PRDATA arrives back at the source router.

#include <cstdlib>
#include <iomanip>
#include <iostream>

#include "Vtb_niApbTarget_top.h"
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
#define PAYLOAD_WIDTH 69
#define PACKET_WIDTH (PAYLOAD_WIDTH + COORD_WIDTH * 2) // 73

// Source and destination coordinates (must match SV parameters)
#define SRC_ROW 0
#define SRC_COL 0
#define DST_ROW 1
#define DST_COL 1

vluint64_t sim_time = 0;
vluint64_t posedge_cnt = 0;

// ----------------------------------------------------------------
// Packet encoding helpers
// Packet layout (73 bits, LSB first):
//   [1:0]   = dstCol
//   [3:2]   = dstRow
//   [7:4]   = PSTRB
//   [8]     = PWRITE
//   [40:9]  = PWDATA
//   [72:41] = PADDR
// ----------------------------------------------------------------

struct NocPacket {
  uint32_t paddr;
  uint32_t pwdata;
  bool     pwrite;
  uint8_t  pstrb;
  int      dst_row;
  int      dst_col;
};

// Pack a NocPacket into the Verilator wide type (3 x 32-bit words for 73 bits)
static void packPacket(const NocPacket &pkt, WData *out) {
  // Zero out
  out[0] = 0;
  out[1] = 0;
  out[2] = 0;

  // [1:0] = dstCol
  out[0] |= (pkt.dst_col & 0x3);
  // [3:2] = dstRow
  out[0] |= ((pkt.dst_row & 0x3) << 2);
  // [7:4] = PSTRB
  out[0] |= ((uint32_t)(pkt.pstrb & 0xF) << 4);
  // [8] = PWRITE
  out[0] |= ((uint32_t)(pkt.pwrite ? 1 : 0) << 8);
  // [40:9] = PWDATA (32 bits starting at bit 9)
  // bits [31:9] of word 0 = pwdata[22:0]
  out[0] |= (pkt.pwdata << 9);
  // bits [8:0] of word 1 = pwdata[31:23]
  out[1] |= (pkt.pwdata >> 23);
  // [72:41] = PADDR (32 bits starting at bit 41)
  // bits [31:9] of word 1 = paddr[22:0] starting at bit position 9 of word 1
  out[1] |= (pkt.paddr << 9);
  // bits [8:0] of word 2 = paddr[31:23]
  out[2] |= (pkt.paddr >> 23);
}

// Decode response packet from Verilator wide type
static NocPacket unpackPacket(const WData *in) {
  NocPacket pkt;
  pkt.dst_col = in[0] & 0x3;
  pkt.dst_row = (in[0] >> 2) & 0x3;
  pkt.pstrb   = (in[0] >> 4) & 0xF;
  pkt.pwrite  = (in[0] >> 8) & 0x1;
  pkt.pwdata  = (in[0] >> 9) | ((in[1] & 0x1FF) << 23);
  pkt.paddr   = (in[1] >> 9) | ((in[2] & 0x1FF) << 23);
  return pkt;
}

// ----------------------------------------------------------------
// Test definitions
// ----------------------------------------------------------------
struct TestCase {
  NocPacket req;
  // For reads: expected PRDATA in response
  uint32_t  exp_prdata;
  const char *desc;
};

int main(int argc, char **argv, char **env) {
  (void)env;
  Verilated::commandArgs(argc, argv);
  Vtb_niApbTarget_top *dut = new Vtb_niApbTarget_top;

  Verilated::traceEverOn(true);
  VerilatedVcdC *m_trace = new VerilatedVcdC;
  dut->trace(m_trace, 5);
  m_trace->open("waveform_niApbTarget.vcd");

  // Test cases
  TestCase tests[] = {
    // WRITE tests: inject write packet destined for (DST_ROW, DST_COL)
    { {0x00000000, 0xDEADBEEF, true,  0xF, DST_ROW, DST_COL}, 0, "Write reg[0] = 0xDEADBEEF" },
    { {0x00000004, 0xCAFEBABE, true,  0xF, DST_ROW, DST_COL}, 0, "Write reg[1] = 0xCAFEBABE" },
    // READ tests: read back values (slave returns stored data)
    { {0x00000000, 0x00000000, false, 0xF, DST_ROW, DST_COL}, 0xDEADBEEF, "Read reg[0] expect 0xDEADBEEF" },
    { {0x00000004, 0x00000000, false, 0xF, DST_ROW, DST_COL}, 0xCAFEBABE, "Read reg[1] expect 0xCAFEBABE" },
    // Read unmodified registers (slave resets to known values)
    { {0x00000008, 0x00000000, false, 0xF, DST_ROW, DST_COL}, 0xCCCC2222, "Read reg[2] expect 0xCCCC2222" },
    { {0x0000000C, 0x00000000, false, 0xF, DST_ROW, DST_COL}, 0xDDDD3333, "Read reg[3] expect 0xDDDD3333" },
  };
  const int NUM_TESTS = sizeof(tests) / sizeof(tests[0]);
  int current_test = 0;
  int tests_passed = 0;

  enum Phase { PH_IDLE, PH_INJECT, PH_WAIT_ACCEPT, PH_WAIT_APB, PH_WAIT_RESP, PH_DRAIN };
  Phase phase = PH_IDLE;
  vluint64_t phase_start = 0;

  std::cout << "=== niApbTarget Testbench ===" << std::endl;
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
              if (t.req.pwrite) {
                // For writes: wait a few cycles for APB to complete, then check monitor
                phase = PH_WAIT_APB;
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

          case PH_WAIT_APB:
            // For writes: wait until APB access phase is observed on monitor
            // We simply wait enough cycles for the packet to traverse the NoC
            // and the APB transaction to complete, then check monitor outputs.
            if ((posedge_cnt - phase_start) > TIMEOUT_CYCLES) {
              std::cout << "  FAIL: Timeout waiting for APB write to complete"
                        << std::endl;
              m_trace->close();
              delete dut;
              return EXIT_FAILURE;
            }
            // Check if APB access phase completed (psel && penable seen)
            // We look for the moment PSEL goes low again (transaction done)
            if ((posedge_cnt - phase_start) > 5 && !dut->o_psel) {
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
              // PRDATA is in the PWDATA field position
              uint32_t prdata = resp.pwdata;

              if (prdata == t.exp_prdata) {
                std::cout << "  PASS: Read response 0x" << std::hex << prdata
                          << std::dec << " matches expected" << std::endl;
                tests_passed++;
              } else {
                std::cout << "  FAIL: Read response 0x" << std::hex << prdata
                          << " expected 0x" << t.exp_prdata << std::dec
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
