// Testbench: niAxiLiteTarget
// Injects NoC request packets at a source router and verifies that
// niAxiLiteTarget drives the correct AXI4-Lite transaction to its local
// subordinate and returns a response packet (BRESP for writes, RDATA/RRESP for
// reads) back to the source router.

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <iomanip>
#include <iostream>

#include "Vtb_niAxiLiteTarget_top.h"
#include <verilated.h>
#include <verilated_vcd_c.h>

#define RESET_CYCLES 5

#ifndef GRID_WIDTH
#define GRID_WIDTH 4
#endif
#ifndef TIMEOUT_CYCLES
#define TIMEOUT_CYCLES 512
#endif

#define COORD_WIDTH 2 // clog2(4)
#define PAYLOAD_WIDTH 71
#define PACKET_WIDTH (PAYLOAD_WIDTH + COORD_WIDTH * 4) // 79
#define PKT_WORDS 3

#define SRC_ROW 0
#define SRC_COL 0
#define DST_ROW 1
#define DST_COL 1

// Packet field bit offsets (absolute, LSB based).
#define OFF_DSTCOL 0
#define OFF_DSTROW COORD_WIDTH
#define OFF_SRCCOL (2 * COORD_WIDTH)
#define OFF_SRCROW (3 * COORD_WIDTH)
#define OFF_PAYLOAD (4 * COORD_WIDTH) // 8
#define OFF_RESP (OFF_PAYLOAD + 0)    // 8
#define OFF_WRITE (OFF_PAYLOAD + 2)   // 10
#define OFF_WSTRB (OFF_PAYLOAD + 3)   // 11
#define OFF_DATA (OFF_PAYLOAD + 7)    // 15
#define OFF_ADDR (OFF_PAYLOAD + 39)   // 47

vluint64_t sim_time = 0;
vluint64_t posedge_cnt = 0;

static uint32_t getBits(const uint32_t *w, int start, int width) {
  int wi = start / 32;
  int off = start % 32;
  uint64_t raw = (uint64_t)w[wi] >> off;
  if (off > 0)
    raw |= (uint64_t)w[wi + 1] << (32 - off);
  uint64_t mask = (width == 32) ? 0xFFFFFFFFULL : ((1ULL << width) - 1);
  return (uint32_t)(raw & mask);
}

static void setBits(uint32_t *w, int start, int width, uint32_t val) {
  for (int b = 0; b < width; b++) {
    int bit = start + b;
    int wi = bit / 32;
    int off = bit % 32;
    uint32_t m = 1u << off;
    if ((val >> b) & 1u)
      w[wi] |= m;
    else
      w[wi] &= ~m;
  }
}

struct AxiTxn {
  uint32_t addr;
  uint32_t wdata;
  uint8_t  strb;
  bool     write;
  uint32_t exp_rdata; // for reads
  const char *desc;
};

int main(int argc, char **argv, char **env) {
  (void)env;
  Verilated::commandArgs(argc, argv);
  Vtb_niAxiLiteTarget_top *dut = new Vtb_niAxiLiteTarget_top;

  Verilated::traceEverOn(true);
  VerilatedVcdC *m_trace = new VerilatedVcdC;
  dut->trace(m_trace, 5);
  m_trace->open("waveform_niAxiLiteTarget.vcd");

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
  auto fail = [&](int test, const char *msg) {
    std::cout << "  FAIL: Test " << test << " — " << msg << std::endl;
    failed = true;
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

  AxiTxn tests[] = {
    {0x00000000, 0xDEADBEEF, 0xF, true,  0, "Write reg[0] = 0xDEADBEEF"},
    {0x00000004, 0xCAFEBABE, 0xF, true,  0, "Write reg[1] = 0xCAFEBABE"},
    {0x00000000, 0x00000000, 0x0, false, 0xDEADBEEF, "Read reg[0]"},
    {0x00000004, 0x00000000, 0x0, false, 0xCAFEBABE, "Read reg[1]"},
    {0x00000008, 0x00000000, 0x0, false, 0xCCCC2222, "Read reg[2]"},
    {0x0000000C, 0x00000000, 0x0, false, 0xDDDD3333, "Read reg[3]"},
  };
  const int NUM_TESTS = sizeof(tests) / sizeof(tests[0]);
  int tests_passed = 0;

  std::cout << "=== niAxiLiteTarget Testbench ===" << std::endl;
  std::cout << "Running " << NUM_TESTS << " tests" << std::endl;

  dut->i_clk = 0;
  dut->i_arst_n = 0;
  dut->i_srcNiToRouterValid = 0;
  dut->i_srcRouterToNiReady = 1; // always drain responses at the source node
  for (int k = 0; k < PKT_WORDS; k++)
    dut->i_srcNiToRouter[k] = 0;

  for (int i = 0; i < RESET_CYCLES; i++)
    tick();
  dut->i_arst_n = 1;
  tick();

  for (int ti = 0; ti < NUM_TESTS && !failed; ti++) {
    AxiTxn &t = tests[ti];
    std::cout << "Test " << ti << ": " << t.desc << std::endl;

    // ---- Build and inject the request packet ----
    uint32_t req[PKT_WORDS] = {0, 0, 0};
    setBits(req, OFF_DSTCOL, COORD_WIDTH, DST_COL);
    setBits(req, OFF_DSTROW, COORD_WIDTH, DST_ROW);
    setBits(req, OFF_SRCCOL, COORD_WIDTH, SRC_COL);
    setBits(req, OFF_SRCROW, COORD_WIDTH, SRC_ROW);
    setBits(req, OFF_RESP, 2, 0);
    setBits(req, OFF_WRITE, 1, t.write ? 1 : 0);
    setBits(req, OFF_WSTRB, 4, t.write ? t.strb : 0);
    setBits(req, OFF_DATA, 32, t.write ? t.wdata : 0);
    setBits(req, OFF_ADDR, 32, t.addr);
    for (int k = 0; k < PKT_WORDS; k++)
      dut->i_srcNiToRouter[k] = req[k];
    dut->i_srcNiToRouterValid = 1;

    if (!waitFor([&]() { return dut->o_srcNiToRouterReady != 0; })) {
      fail(ti, "timeout waiting for source router to accept request");
      break;
    }
    tick(); // request accepted into the mesh
    dut->i_srcNiToRouterValid = 0;

    // ---- Wait for the response packet at the source node ----
    if (!waitFor([&]() { return dut->o_srcRouterToNiValid != 0; })) {
      fail(ti, "timeout waiting for response packet");
      break;
    }
    uint32_t resp[PKT_WORDS];
    for (int k = 0; k < PKT_WORDS; k++)
      resp[k] = dut->o_srcRouterToNi[k];
    uint32_t r_resp = getBits(resp, OFF_RESP, 2);
    uint32_t r_data = getBits(resp, OFF_DATA, 32);

    if (t.write) {
      if (r_resp == 0) {
        std::cout << "  PASS: write response BRESP=OKAY" << std::endl;
        tests_passed++;
      } else {
        fail(ti, "unexpected BRESP");
      }
    } else {
      if (r_data == t.exp_rdata && r_resp == 0) {
        std::cout << "  PASS: read RDATA=0x" << std::hex << r_data
                  << " RRESP=OKAY" << std::dec << std::endl;
        tests_passed++;
      } else {
        std::cout << "    got RDATA=0x" << std::hex << r_data << " (exp 0x"
                  << t.exp_rdata << ") RRESP=0x" << r_resp << std::dec
                  << std::endl;
        fail(ti, "read data/resp mismatch");
      }
    }

    // Drain the response and idle before the next test.
    if (!waitFor([&]() { return dut->o_srcRouterToNiValid == 0; })) {
      fail(ti, "timeout draining response");
      break;
    }
    tick();
    tick();
  }

  m_trace->close();

  std::cout << "\n=== Results: " << tests_passed << "/" << NUM_TESTS
            << " passed ===" << std::endl;

  delete dut;
  return (!failed && tests_passed == NUM_TESTS) ? EXIT_SUCCESS : EXIT_FAILURE;
}
