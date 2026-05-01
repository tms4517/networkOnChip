// Testbench: niApbInitiator
// Drives APB write transactions through niApbInitiator and verifies
// packets arrive at the correct destination router NI output.

#include <cstdlib>
#include <iomanip>
#include <iostream>

#include "Vtb_niApbInitiator_top.h"
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
#define MAX_SIM_TIME 5000
#endif

#define NUM_ROUTERS (GRID_WIDTH * GRID_WIDTH)
#define COORD_WIDTH 2 // clog2(4)
#define PAYLOAD_WIDTH 69
#define PACKET_WIDTH (PAYLOAD_WIDTH + COORD_WIDTH * 2) // 73

vluint64_t sim_time = 0;
vluint64_t posedge_cnt = 0;

// ----------------------------------------------------------------
// APB helper: drive a single APB write transaction
// Returns number of cycles until PREADY (0 = immediate, -1 = timeout)
// ----------------------------------------------------------------
enum ApbPhase { APB_IDLE, APB_SETUP, APB_ACCESS, APB_DONE };

struct ApbTransaction {
  uint32_t addr;
  uint32_t wdata;
  uint8_t  strb;
  bool     write;
  // Expected destination
  int      exp_dst_row;
  int      exp_dst_col;
};

static inline int routerIndex(int row, int col) {
  return row * GRID_WIDTH + col;
}

// Extract an arbitrary bit range from the flat output bus
// Returns up to 32 bits starting at 'start_bit' from the flat array
static uint32_t extractBits(Vtb_niApbInitiator_top *dut, int start_bit, int width) {
  const int BITS_PER_WORD = 32;
  int word_idx = start_bit / BITS_PER_WORD;
  int bit_off  = start_bit % BITS_PER_WORD;

  uint64_t raw = (uint64_t)(dut->o_routerToNi_flat[word_idx]) >> bit_off;
  if (bit_off > 0) {
    raw |= (uint64_t)(dut->o_routerToNi_flat[word_idx + 1]) << (32 - bit_off);
  }
  return (uint32_t)(raw & ((1ULL << width) - 1));
}

// Decode APB payload fields directly from packet bits for a given router.
// Packet layout (73 bits):
//   [1:0]   = dstCol
//   [3:2]   = dstRow
//   [7:4]   = PSTRB
//   [8]     = PWRITE
//   [40:9]  = PWDATA
//   [72:41] = PADDR
struct DecodedPayload {
  uint32_t paddr;
  uint32_t pwdata;
  bool     pwrite;
  uint8_t  pstrb;
};

static DecodedPayload decodePacketAtRouter(Vtb_niApbInitiator_top *dut, int row, int col) {
  int pkt_start = routerIndex(row, col) * PACKET_WIDTH;
  DecodedPayload d;
  d.pstrb  = extractBits(dut, pkt_start + 4,  4);
  d.pwrite = extractBits(dut, pkt_start + 8,  1);
  d.pwdata = extractBits(dut, pkt_start + 9,  32);
  d.paddr  = extractBits(dut, pkt_start + 41, 32);
  return d;
}

int main(int argc, char **argv, char **env) {
  (void)env;
  Verilated::commandArgs(argc, argv);
  Vtb_niApbInitiator_top *dut = new Vtb_niApbInitiator_top;

  Verilated::traceEverOn(true);
  VerilatedVcdC *m_trace = new VerilatedVcdC;
  dut->trace(m_trace, 5);
  m_trace->open("waveform_niApbInitiator.vcd");

  // Test transactions
  ApbTransaction tests[] = {
    // addr,        wdata,       strb, write, dst_row, dst_col
    {0x00001000,  0xDEADBEEF,  0xF,  true,  0, 1},   // Entry 0 -> (0,1)
    {0x10000004,  0xCAFEBABE,  0xF,  true,  1, 0},   // Entry 1 -> (1,0)
    {0x20000008,  0x12345678,  0xF,  true,  1, 1},   // Entry 2 -> (1,1)
    {0x3000000C,  0xA5A5A5A5,  0xF,  true,  3, 3},   // Entry 3 -> (3,3)
  };
  const int NUM_TESTS = sizeof(tests) / sizeof(tests[0]);
  int current_test = 0;
  int tests_passed = 0;

  ApbPhase apb_phase = APB_IDLE;
  vluint64_t access_start = 0;
  bool waiting_for_dest = false;
  vluint64_t dest_wait_start = 0;

  std::cout << "=== niApbInitiator Testbench ===" << std::endl;
  std::cout << "Running " << NUM_TESTS << " APB write transactions" << std::endl;

  // Reset
  dut->i_clk = 0;
  dut->i_arst_n = 0;
  dut->i_psel = 0;
  dut->i_penable = 0;
  dut->i_paddr = 0;
  dut->i_pwdata = 0;
  dut->i_pwrite = 0;
  dut->i_pstrb = 0;

  while (sim_time < MAX_SIM_TIME) {
    dut->i_clk ^= 1;
    dut->eval();

    if (dut->i_clk == 1) {
      posedge_cnt++;

      // Hold reset for RESET_CYCLES
      if (posedge_cnt <= RESET_CYCLES) {
        dut->i_arst_n = 0;
        dut->i_psel = 0;
        dut->i_penable = 0;
      } else {
        dut->i_arst_n = 1;
      }

      if (!dut->i_arst_n) {
        // In reset — do nothing
      } else if (current_test >= NUM_TESTS) {
        // All tests done
        break;
      } else if (waiting_for_dest) {
        // Check if destination router received the packet
        ApbTransaction &t = tests[current_test];
        int dst_idx = routerIndex(t.exp_dst_row, t.exp_dst_col);

        if (dut->o_routerToNiValid & (1U << dst_idx)) {
          DecodedPayload d = decodePacketAtRouter(dut, t.exp_dst_row, t.exp_dst_col);

          bool pass = (d.paddr == t.addr) &&
                      (d.pwdata == t.wdata) &&
                      (d.pwrite == t.write) &&
                      (d.pstrb == t.strb);

          if (pass) {
            std::cout << "  PASS: Test " << current_test
                      << " — packet arrived at (" << t.exp_dst_row << ","
                      << t.exp_dst_col << ") with correct payload" << std::endl;
            tests_passed++;
          } else {
            std::cout << "  FAIL: Test " << current_test
                      << " — payload mismatch at (" << t.exp_dst_row << ","
                      << t.exp_dst_col << ")" << std::endl;
            std::cout << "    Expected: addr=0x" << std::hex << t.addr
                      << " wdata=0x" << t.wdata << " pwrite=" << t.write
                      << " pstrb=0x" << (int)t.strb << std::dec << std::endl;
            std::cout << "    Got:      addr=0x" << std::hex << d.paddr
                      << " wdata=0x" << d.pwdata << " pwrite=" << d.pwrite
                      << " pstrb=0x" << (int)d.pstrb << std::dec << std::endl;
          }

          waiting_for_dest = false;
          current_test++;
          apb_phase = APB_IDLE;
        } else if ((posedge_cnt - dest_wait_start) > TIMEOUT_CYCLES) {
          std::cout << "  FAIL: Test " << current_test
                    << " — timeout waiting for packet at destination ("
                    << t.exp_dst_row << "," << t.exp_dst_col << ")"
                    << std::endl;
          m_trace->close();
          delete dut;
          return EXIT_FAILURE;
        }
      } else {
        // APB state machine
        ApbTransaction &t = tests[current_test];

        switch (apb_phase) {
          case APB_IDLE:
            // Drive setup phase
            dut->i_psel    = 1;
            dut->i_penable = 0;
            dut->i_paddr   = t.addr;
            dut->i_pwdata  = t.wdata;
            dut->i_pwrite  = t.write ? 1 : 0;
            dut->i_pstrb   = t.strb;
            apb_phase = APB_SETUP;
            std::cout << "Test " << current_test << ": APB write addr=0x"
                      << std::hex << t.addr << " wdata=0x" << t.wdata
                      << std::dec << std::endl;
            break;

          case APB_SETUP:
            // Drive access phase (assert PENABLE)
            dut->i_penable = 1;
            apb_phase = APB_ACCESS;
            access_start = posedge_cnt;
            break;

          case APB_ACCESS:
            // Wait for PREADY
            if (dut->o_pready) {
              if (dut->o_pslverr) {
                std::cout << "  FAIL: Test " << current_test
                          << " — SLVERR on APB transaction" << std::endl;
                m_trace->close();
                delete dut;
                return EXIT_FAILURE;
              }
              // Transaction accepted by niApbInitiator, deassert bus
              dut->i_psel    = 0;
              dut->i_penable = 0;
              // Now wait for packet at destination
              waiting_for_dest = true;
              dest_wait_start = posedge_cnt;
            } else if ((posedge_cnt - access_start) > TIMEOUT_CYCLES) {
              std::cout << "  FAIL: Test " << current_test
                        << " — APB PREADY timeout" << std::endl;
              m_trace->close();
              delete dut;
              return EXIT_FAILURE;
            }
            break;

          default:
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
