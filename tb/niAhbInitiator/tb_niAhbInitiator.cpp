// Testbench: niAhbInitiator
// Drives AHB-Lite write transactions through niAhbInitiator and verifies
// packets arrive at the correct destination router NI output.

#include <cstdlib>
#include <iomanip>
#include <iostream>

#include "Vtb_niAhbInitiator_top.h"
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
#define PAYLOAD_WIDTH 71
#define PACKET_WIDTH (PAYLOAD_WIDTH + COORD_WIDTH * 4) // 79

// AHB HTRANS encodings
#define HTRANS_IDLE   0
#define HTRANS_NONSEQ 2

vluint64_t sim_time = 0;
vluint64_t posedge_cnt = 0;

// ----------------------------------------------------------------
// AHB helper: drive a single AHB write transaction
// ----------------------------------------------------------------
enum AhbPhase { AHB_ADDR, AHB_DATA, AHB_ACCESS };

struct AhbTransaction {
  uint32_t addr;
  uint32_t wdata;
  uint8_t  size;
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
static uint32_t extractBits(Vtb_niAhbInitiator_top *dut, int start_bit, int width) {
  const int BITS_PER_WORD = 32;
  int word_idx = start_bit / BITS_PER_WORD;
  int bit_off  = start_bit % BITS_PER_WORD;

  uint64_t raw = (uint64_t)(dut->o_routerToNi_flat[word_idx]) >> bit_off;
  if (bit_off > 0) {
    raw |= (uint64_t)(dut->o_routerToNi_flat[word_idx + 1]) << (32 - bit_off);
  }
  return (uint32_t)(raw & ((1ULL << width) - 1));
}

// Decode AHB payload fields directly from packet bits for a given router.
// Packet layout (79 bits) — canonical payload:
//   [1:0]   = dstCol
//   [3:2]   = dstRow
//   [5:4]   = srcCol
//   [7:6]   = srcRow
//   [9:8]   = RESP
//   [10]    = WRITE
//   [14:11] = WSTRB
//   [46:15] = DATA
//   [78:47] = ADDR
struct DecodedPayload {
  uint32_t haddr;
  uint32_t hdata;
  bool     hwrite;
  uint8_t  wstrb;
};

static DecodedPayload decodePacketAtRouter(Vtb_niAhbInitiator_top *dut, int row, int col) {
  int pkt_start = routerIndex(row, col) * PACKET_WIDTH;
  DecodedPayload d;
  d.hwrite = extractBits(dut, pkt_start + 10, 1);
  d.wstrb  = extractBits(dut, pkt_start + 11, 4);
  d.hdata  = extractBits(dut, pkt_start + 15, 32);
  d.haddr  = extractBits(dut, pkt_start + 47, 32);
  return d;
}

int main(int argc, char **argv, char **env) {
  (void)env;
  Verilated::commandArgs(argc, argv);
  Vtb_niAhbInitiator_top *dut = new Vtb_niAhbInitiator_top;

  Verilated::traceEverOn(true);
  VerilatedVcdC *m_trace = new VerilatedVcdC;
  dut->trace(m_trace, 5);
  m_trace->open("waveform_niAhbInitiator.vcd");

  // Test transactions
  AhbTransaction tests[] = {
    // addr,        wdata,       size, write, dst_row, dst_col
    {0x00001000,  0xDEADBEEF,  2,    true,  0, 1},   // Entry 0 -> (0,1)
    {0x10000004,  0xCAFEBABE,  2,    true,  1, 0},   // Entry 1 -> (1,0)
    {0x20000008,  0x12345678,  2,    true,  1, 1},   // Entry 2 -> (1,1)
    {0x3000000C,  0xA5A5A5A5,  2,    true,  3, 3},   // Entry 3 -> (3,3)
  };
  const int NUM_TESTS = sizeof(tests) / sizeof(tests[0]);
  int current_test = 0;
  int tests_passed = 0;

  AhbPhase ahb_phase = AHB_ADDR;
  vluint64_t access_start = 0;
  bool waiting_for_dest = false;
  vluint64_t dest_wait_start = 0;
  bool waiting_complete = false;
  vluint64_t comp_start = 0;

  std::cout << "=== niAhbInitiator Testbench ===" << std::endl;
  std::cout << "Running " << NUM_TESTS << " AHB write transactions" << std::endl;

  // Reset
  dut->i_clk = 0;
  dut->i_arst_n = 0;
  dut->i_hsel = 0;
  dut->i_htrans = HTRANS_IDLE;
  dut->i_haddr = 0;
  dut->i_hwdata = 0;
  dut->i_hwrite = 0;
  dut->i_hsize = 0;

  while (sim_time < MAX_SIM_TIME) {
    dut->i_clk ^= 1;
    dut->eval();

    if (dut->i_clk == 1) {
      posedge_cnt++;

      // Hold reset for RESET_CYCLES
      if (posedge_cnt <= RESET_CYCLES) {
        dut->i_arst_n = 0;
        dut->i_hsel = 0;
        dut->i_htrans = HTRANS_IDLE;
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
        AhbTransaction &t = tests[current_test];
        int dst_idx = routerIndex(t.exp_dst_row, t.exp_dst_col);

        if (dut->o_routerToNiValid & (1U << dst_idx)) {
          DecodedPayload d = decodePacketAtRouter(dut, t.exp_dst_row, t.exp_dst_col);

          uint8_t exp_wstrb = (t.size >= 2) ? 0xF : (t.size == 1 ? 0x3 : 0x1);
          bool pass = (d.haddr == t.addr) &&
                      (d.hdata == t.wdata) &&
                      (d.hwrite == t.write) &&
                      (d.wstrb == exp_wstrb);

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
                      << " wdata=0x" << t.wdata << " hwrite=" << t.write
                      << " wstrb=0x" << (int)exp_wstrb << std::dec << std::endl;
            std::cout << "    Got:      addr=0x" << std::hex << d.haddr
                      << " wdata=0x" << d.hdata << " hwrite=" << d.hwrite
                      << " wstrb=0x" << (int)d.wstrb << std::dec << std::endl;
          }

          // Packet observed; now wait for the round-trip response to complete
          // the AHB access before starting the next transaction.
          waiting_for_dest = false;
          waiting_complete = true;
          comp_start = posedge_cnt;
        } else if ((posedge_cnt - dest_wait_start) > TIMEOUT_CYCLES) {
          std::cout << "  FAIL: Test " << current_test
                    << " — timeout waiting for packet at destination ("
                    << t.exp_dst_row << "," << t.exp_dst_col << ")"
                    << std::endl;
          m_trace->close();
          delete dut;
          return EXIT_FAILURE;
        }
      } else if (waiting_complete) {
        // Wait for the initiator to complete the AHB data phase (round-trip).
        if (dut->o_hreadyout) {
          if (dut->o_hresp) {
            std::cout << "  FAIL: Test " << current_test
                      << " — ERROR response on AHB transaction" << std::endl;
            m_trace->close();
            delete dut;
            return EXIT_FAILURE;
          }
          dut->i_hsel   = 0;
          dut->i_htrans = HTRANS_IDLE;
          waiting_complete = false;
          current_test++;
          ahb_phase = AHB_ADDR;
        } else if ((posedge_cnt - comp_start) > TIMEOUT_CYCLES) {
          std::cout << "  FAIL: Test " << current_test
                    << " — AHB HREADYOUT timeout" << std::endl;
          m_trace->close();
          delete dut;
          return EXIT_FAILURE;
        }
      } else {
        // AHB state machine
        AhbTransaction &t = tests[current_test];

        switch (ahb_phase) {
          case AHB_ADDR:
            // Drive the AHB address phase
            dut->i_hsel   = 1;
            dut->i_htrans = HTRANS_NONSEQ;
            dut->i_haddr  = t.addr;
            dut->i_hwrite = t.write ? 1 : 0;
            dut->i_hsize  = t.size;
            dut->i_hwdata = t.wdata;
            ahb_phase = AHB_DATA;
            std::cout << "Test " << current_test << ": AHB write addr=0x"
                      << std::hex << t.addr << " wdata=0x" << t.wdata
                      << std::dec << std::endl;
            break;

          case AHB_DATA:
            // Data phase: deassert new-transfer request, hold HWDATA stable
            dut->i_htrans = HTRANS_IDLE;
            ahb_phase = AHB_ACCESS;
            access_start = posedge_cnt;
            break;

          case AHB_ACCESS:
            // Request is now being forwarded into the mesh; poll for its arrival
            // at the destination router.  The AHB access completes separately
            // once the round-trip response returns (see waiting_complete).
            waiting_for_dest = true;
            dest_wait_start = posedge_cnt;
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
