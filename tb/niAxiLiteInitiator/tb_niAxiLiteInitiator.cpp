// Testbench: niAxiLiteInitiator
// Drives AXI4-Lite write and read transactions into niAxiLiteInitiator, acts as
// a remote responder (observing request packets and injecting response packets)
// and verifies both the emitted request packets and the AXI B/R responses.

#include <cstdint>
#include <cstdlib>
#include <functional>
#include <iomanip>
#include <iostream>

#include "Vtb_niAxiLiteInitiator_top.h"
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
#define PKT_WORDS 3                                    // ceil(79/32)

#define SRC_ROW 0
#define SRC_COL 0
#define RSP_ROW (GRID_WIDTH - 1)
#define RSP_COL (GRID_WIDTH - 1)

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

#define RESP_OKAY 0

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
  uint32_t rdata;
  uint8_t  resp;
};

int main(int argc, char **argv, char **env) {
  (void)env;
  Verilated::commandArgs(argc, argv);
  Vtb_niAxiLiteInitiator_top *dut = new Vtb_niAxiLiteInitiator_top;

  Verilated::traceEverOn(true);
  VerilatedVcdC *m_trace = new VerilatedVcdC;
  dut->trace(m_trace, 5);
  m_trace->open("waveform_niAxiLiteInitiator.vcd");

  // Advance exactly one clock cycle: inputs set before the call are sampled on
  // the rising edge; registered outputs are valid after the call returns.
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

  // Wait for a condition to become true, ticking the clock; false on timeout.
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
    // addr,        wdata,       strb, write, rdata,       resp
    {0x00001000, 0xDEADBEEF, 0xF, true,  0x00000000, RESP_OKAY},
    {0x00002004, 0x00000000, 0x0, false, 0xCAFEBABE, RESP_OKAY},
    {0x00003008, 0x12345678, 0x3, true,  0x00000000, RESP_OKAY},
    {0x0000400C, 0x00000000, 0x0, false, 0xA5A5A5A5, RESP_OKAY},
  };
  const int NUM_TESTS = sizeof(tests) / sizeof(tests[0]);
  int tests_passed = 0;

  std::cout << "=== niAxiLiteInitiator Testbench ===" << std::endl;
  std::cout << "Running " << NUM_TESTS << " AXI4-Lite transactions" << std::endl;

  // Initialize inputs
  dut->i_clk = 0;
  dut->i_arst_n = 0;
  dut->i_awaddr = 0;
  dut->i_awvalid = 0;
  dut->i_wdata = 0;
  dut->i_wstrb = 0;
  dut->i_wvalid = 0;
  dut->i_bready = 0;
  dut->i_araddr = 0;
  dut->i_arvalid = 0;
  dut->i_rready = 0;
  dut->i_rspRouterToNiReady = 0;
  dut->i_rspNiToRouterValid = 0;
  for (int k = 0; k < PKT_WORDS; k++)
    dut->i_rspNiToRouter[k] = 0;

  // Reset
  for (int i = 0; i < RESET_CYCLES; i++)
    tick();
  dut->i_arst_n = 1;
  tick();

  for (int ti = 0; ti < NUM_TESTS && !failed; ti++) {
    AxiTxn &t = tests[ti];
    std::cout << "Test " << ti << ": AXI " << (t.write ? "WRITE" : "READ ")
              << " addr=0x" << std::hex << t.addr << std::dec << std::endl;

    // ---- Drive the AXI request (accepted on the next rising edge) ----
    if (t.write) {
      dut->i_awaddr = t.addr;
      dut->i_awvalid = 1;
      dut->i_wdata = t.wdata;
      dut->i_wstrb = t.strb;
      dut->i_wvalid = 1;
    } else {
      dut->i_araddr = t.addr;
      dut->i_arvalid = 1;
    }
    tick(); // IDLE -> WR_SEND / RD_SEND (request latched)
    dut->i_awvalid = 0;
    dut->i_wvalid = 0;
    dut->i_arvalid = 0;

    // ---- Observe request packet at the responder node ----
    if (!waitFor([&]() { return dut->o_rspRouterToNiValid != 0; })) {
      fail(ti, "timeout waiting for request packet at responder");
      break;
    }
    uint32_t reqPkt[PKT_WORDS];
    for (int k = 0; k < PKT_WORDS; k++)
      reqPkt[k] = dut->o_rspRouterToNi[k];

    uint32_t p_addr = getBits(reqPkt, OFF_ADDR, 32);
    uint32_t p_data = getBits(reqPkt, OFF_DATA, 32);
    uint32_t p_wstrb = getBits(reqPkt, OFF_WSTRB, 4);
    uint32_t p_write = getBits(reqPkt, OFF_WRITE, 1);
    uint32_t exp_data = t.write ? t.wdata : 0;
    uint32_t exp_wstrb = t.write ? t.strb : 0;
    if (p_addr != t.addr || p_data != exp_data || p_wstrb != exp_wstrb ||
        p_write != (t.write ? 1u : 0u)) {
      std::cout << "    req pkt: addr=0x" << std::hex << p_addr << " data=0x"
                << p_data << " wstrb=0x" << p_wstrb << " write=" << p_write
                << std::dec << std::endl;
      fail(ti, "request packet mismatch");
      break;
    }
    std::cout << "  request packet OK" << std::endl;

    // Accept the request packet at the responder.
    dut->i_rspRouterToNiReady = 1;
    tick();
    dut->i_rspRouterToNiReady = 0;

    // ---- Inject the response packet back to the initiator ----
    uint32_t rsp[PKT_WORDS] = {0, 0, 0};
    setBits(rsp, OFF_DSTCOL, COORD_WIDTH, SRC_COL);
    setBits(rsp, OFF_DSTROW, COORD_WIDTH, SRC_ROW);
    setBits(rsp, OFF_SRCCOL, COORD_WIDTH, RSP_COL);
    setBits(rsp, OFF_SRCROW, COORD_WIDTH, RSP_ROW);
    setBits(rsp, OFF_RESP, 2, t.resp);
    setBits(rsp, OFF_WRITE, 1, t.write ? 1 : 0);
    setBits(rsp, OFF_DATA, 32, t.write ? 0 : t.rdata);
    setBits(rsp, OFF_ADDR, 32, t.addr);
    for (int k = 0; k < PKT_WORDS; k++)
      dut->i_rspNiToRouter[k] = rsp[k];
    dut->i_rspNiToRouterValid = 1;

    if (!waitFor([&]() { return dut->o_rspNiToRouterReady != 0; })) {
      fail(ti, "timeout waiting for NoC to accept response");
      break;
    }
    tick(); // response accepted into the mesh
    dut->i_rspNiToRouterValid = 0;

    // ---- Check the AXI response (B or R) ----
    if (t.write) {
      if (!waitFor([&]() { return dut->o_bvalid != 0; })) {
        fail(ti, "timeout waiting for BVALID");
        break;
      }
      dut->i_bready = 1;
      if (dut->o_bresp == t.resp) {
        std::cout << "  PASS: Test " << ti << " — BRESP=0x" << std::hex
                  << (int)dut->o_bresp << std::dec << std::endl;
        tests_passed++;
      } else {
        fail(ti, "BRESP mismatch");
      }
      tick();
      dut->i_bready = 0;
    } else {
      if (!waitFor([&]() { return dut->o_rvalid != 0; })) {
        fail(ti, "timeout waiting for RVALID");
        break;
      }
      dut->i_rready = 1;
      if (dut->o_rdata == t.rdata && dut->o_rresp == t.resp) {
        std::cout << "  PASS: Test " << ti << " — RDATA=0x" << std::hex
                  << dut->o_rdata << " RRESP=0x" << (int)dut->o_rresp << std::dec
                  << std::endl;
        tests_passed++;
      } else {
        std::cout << "    got RDATA=0x" << std::hex << dut->o_rdata
                  << " RRESP=0x" << (int)dut->o_rresp << std::dec << std::endl;
        fail(ti, "RDATA/RRESP mismatch");
      }
      tick();
      dut->i_rready = 0;
    }

    // Idle a couple of cycles between transactions.
    tick();
    tick();
  }

  m_trace->close();

  std::cout << "\n=== Results: " << tests_passed << "/" << NUM_TESTS
            << " passed ===" << std::endl;

  delete dut;
  return (!failed && tests_passed == NUM_TESTS) ? EXIT_SUCCESS : EXIT_FAILURE;
}
