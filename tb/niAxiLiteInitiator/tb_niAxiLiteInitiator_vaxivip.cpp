// Testbench: niAxiLiteInitiator — vaxivip axil_master variant
// ---------------------------------------------------------------------------
// This is a prototype that replaces the hand-written AXI4-Lite driving of
// tb_niAxiLiteInitiator.cpp with the vaxivip AXI4-Lite Master BFM
// (https://github.com/dozecat/vaxivip). The DUT's local AXI4-Lite *subordinate*
// port is now driven by an `axil_master` instead of by manual signal toggling.
//
// What stays the same:
//   * The harness (tb_niAxiLiteInitiator_top.sv) is unchanged, so the verilaxi
//     `axil_checker` SVA instance inside it is still bound to the same bus and
//     still checks protocol legality every cycle.
//   * The NoC "responder" side (observe request packets / inject responses) is
//     still modelled here in C++, because that is NoC-specific and not part of
//     the AXI VIP.
//
// What changes:
//   * We no longer manually sequence AWVALID/WVALID/BREADY/ARVALID/RREADY. The
//     BFM does that. We just call mst.write()/mst.read() and let the BFM run.
//   * The BFM always drives a *full* write strobe (0xF), so the responder-side
//     packet check expects wstrb == 0xF for writes.
//   * The BFM returns read *data* via get_read_data(); it does not return the
//     response code (it only warns on non-OKAY). Response-code legality is left
//     to the axil_checker SVA in the harness.
//
// Simulation loop convention (required by vaxivip):
//   Every rising edge:  update_input()  -> eval() -> [do work + update_output()]
//                       -> eval().
//   update_input() must be called *before* eval() so the BFM samples the DUT
//   outputs as they were at the clock edge; update_output() drives the new bus
//   values that the DUT will sample on the *next* edge.
// ---------------------------------------------------------------------------

#include <cstdint>
#include <cstdlib>
#include <iostream>

#include "Vtb_niAxiLiteInitiator_top.h"
#include <verilated.h>
#include <verilated_vcd_c.h>

// vaxivip AXI4-Lite Master BFM (vendored under tb/vip)
#include "axil_ptr.hpp"
#include "axil_master.hpp"

#define RESET_CYCLES 5

#ifndef GRID_WIDTH
#define GRID_WIDTH 4
#endif

// Packet geometry (mirrors the SystemVerilog localparams for GRID_WIDTH=4).
#define COORD_WIDTH 2 // clog2(4)
#define PAYLOAD_WIDTH 71
#define PACKET_WIDTH (PAYLOAD_WIDTH + COORD_WIDTH * 4) // 79
#define PKT_WORDS 3                                    // ceil(79/32)

#define SRC_ROW 0
#define SRC_COL 0
#define RSP_ROW (GRID_WIDTH - 1)
#define RSP_COL (GRID_WIDTH - 1)

// Packet field bit offsets (absolute, LSB based) — identical to the original TB.
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

// ---- Bit-packing helpers (unchanged from the original TB) ------------------
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
  bool     write;
  uint32_t rdata; // expected read data (reads only)
};

int main(int argc, char **argv, char **env) {
  (void)env;
  Verilated::commandArgs(argc, argv);
  Vtb_niAxiLiteInitiator_top *dut = new Vtb_niAxiLiteInitiator_top;

  // Diagnostic switch: `+noassert` disables the SVA at runtime so the data
  // path can be observed end-to-end even when a checker rule would otherwise
  // $stop. By default the axil_checker stays fully active.
  if (Verilated::commandArgsPlusMatch("noassert")[0])
    Verilated::assertOn(false);

  Verilated::traceEverOn(true);
  VerilatedVcdC *m_trace = new VerilatedVcdC;
  dut->trace(m_trace, 5);
  m_trace->open("waveform_niAxiLiteInitiator_vaxivip.vcd");

  // -------------------------------------------------------------------------
  // 1. Bind the BFM signal pointers to the DUT's AXI4-Lite subordinate port.
  //    The DUT is a *subordinate*, so from the BFM's (master) point of view:
  //      - AW/W/AR address+valid and B/R ready are BFM *outputs* -> DUT inputs
  //      - AW/W/AR ready and B/R data+resp+valid are BFM *inputs* <- DUT outputs
  //    awprot/arprot are not present on this DUT; the BFM never dereferences
  //    them, but axil_ptr::check() requires non-NULL unique pointers, so we
  //    point them at harmless dummy locals.
  // -------------------------------------------------------------------------
  CData dummy_awprot = 0;
  CData dummy_arprot = 0;

  axil_ptr<32, 32> axi; // DATA_WIDTH=32, ADDR_WIDTH=32
  axi.awaddr  = &dut->i_awaddr;
  axi.awprot  = &dummy_awprot;
  axi.awready = &dut->o_awready;
  axi.awvalid = &dut->i_awvalid;
  axi.wdata   = &dut->i_wdata;
  axi.wstrb   = &dut->i_wstrb;
  axi.wvalid  = &dut->i_wvalid;
  axi.wready  = &dut->o_wready;
  axi.bresp   = &dut->o_bresp;
  axi.bvalid  = &dut->o_bvalid;
  axi.bready  = &dut->i_bready;
  axi.araddr  = &dut->i_araddr;
  axi.arprot  = &dummy_arprot;
  axi.arready = &dut->o_arready;
  axi.arvalid = &dut->i_arvalid;
  axi.rdata   = &dut->o_rdata;
  axi.rresp   = &dut->o_rresp;
  axi.rvalid  = &dut->o_rvalid;
  axi.rready  = &dut->i_rready;

  if (!axi.check()) {
    std::cerr << "FATAL: axil_ptr binding incomplete/duplicated" << std::endl;
    return EXIT_FAILURE;
  }

  // Construct the master BFM (implicitly converts axil_ptr -> axil_master_ptr).
  // NOTE: the constructor calls clear(), which writes through the bound
  // pointers, so the DUT object and its signals must already exist.
  axil_master<32, 32> mst(axi);

  // -------------------------------------------------------------------------
  // 2. Test vector. The BFM drives full strobe, so writes are always 0xF.
  // -------------------------------------------------------------------------
  AxiTxn tests[] = {
    // addr,        wdata,       write, rdata
    {0x00001000, 0xDEADBEEF, true,  0x00000000},
    {0x00002004, 0x00000000, false, 0xCAFEBABE},
    {0x00003008, 0x12345678, true,  0x00000000},
    {0x0000400C, 0x00000000, false, 0xA5A5A5A5},
  };
  const int NUM_TESTS = sizeof(tests) / sizeof(tests[0]);

  std::cout << "=== niAxiLiteInitiator Testbench (vaxivip axil_master) ==="
            << std::endl;
  std::cout << "Running " << NUM_TESTS << " AXI4-Lite transactions" << std::endl;

  // -------------------------------------------------------------------------
  // 3. Sequencer + NoC-responder state, all advanced once per rising edge.
  // -------------------------------------------------------------------------
  int  seqIdx      = 0;      // which test the sequencer is currently driving
  bool seqBusy     = false;  // a transaction has been handed to the BFM
  int  tests_passed = 0;
  bool failed      = false;

  // NoC responder FSM: consumes each request packet the DUT emits at (RSP row,
  // col) and injects the matching response packet. Because the initiator is
  // single-outstanding and we issue one transaction at a time, requests arrive
  // strictly in test order, so respIdx tracks tests[].
  enum { R_WAIT_REQ, R_SEND_RSP } rstate = R_WAIT_REQ;
  int respIdx = 0;

  // Initialise NoC-side inputs (BFM owns the AXI-side inputs).
  dut->i_clk = 0;
  dut->i_arst_n = 0;
  dut->i_rspRouterToNiReady = 0;
  dut->i_rspNiToRouterValid = 0;
  for (int k = 0; k < PKT_WORDS; k++)
    dut->i_rspNiToRouter[k] = 0;

  const uint64_t MAX_EDGES = 4000;
  uint64_t edges = 0;   // rising-edge counter (also the wave timestamp)
  uint64_t simt  = 0;

  // Free-running clock loop. Each iteration is a half period; real work happens
  // on the rising edge (dut->i_clk == 1 after the toggle).
  //
  // Handshake rule of thumb (same convention the BFM uses): a ready/valid
  // handshake "completes" at a rising edge when BOTH sides were high entering
  // that edge. So we sample the DUT *outputs* BEFORE eval() (the value the DUT
  // presents at the edge) and combine them with the *inputs we drove on the
  // previous cycle* (still held in dut->i_* until we overwrite them after eval).
  while (!Verilated::gotFinish() && edges < MAX_EDGES && !failed) {
    dut->i_clk = !dut->i_clk;

    // Release reset after RESET_CYCLES rising edges.
    if (edges >= RESET_CYCLES)
      dut->i_arst_n = 1;

    // Edge-sampled DUT outputs (only meaningful on the rising edge).
    bool s_reqValid = false; // o_rspRouterToNiValid
    bool s_niReady  = false; // o_rspNiToRouterReady
    bool s_bvalid   = false; // o_bvalid
    uint32_t s_pkt[PKT_WORDS] = {0, 0, 0};

    if (dut->i_clk) {
      // (a) Sample DUT outputs at the edge, before evaluating new logic.
      mst.update_input();
      s_reqValid = dut->o_rspRouterToNiValid;
      s_niReady  = dut->o_rspNiToRouterReady;
      s_bvalid   = dut->o_bvalid;
      for (int k = 0; k < PKT_WORDS; k++)
        s_pkt[k] = dut->o_rspRouterToNi[k];
    }

    dut->eval();

    if (dut->i_clk) {
      // Handshakes that completed at THIS edge (inputs still hold last cycle's
      // driven values here, before we overwrite them below).
      bool reqAccepted = s_reqValid && dut->i_rspRouterToNiReady;
      bool rspAccepted = s_niReady  && dut->i_rspNiToRouterValid;
      bool bAccepted   = s_bvalid   && dut->i_bready;

      // --------------------------------------------------------------------
      // (b) Sequencer: hand one transaction at a time to the BFM. We only
      //     move to the next once the current one has fully completed, which
      //     keeps request ordering deterministic for the responder.
      // --------------------------------------------------------------------
      if (!seqBusy && seqIdx < NUM_TESTS && dut->i_arst_n) {
        AxiTxn &t = tests[seqIdx];
        std::cout << "Test " << seqIdx << ": AXI "
                  << (t.write ? "WRITE" : "READ ") << " addr=0x" << std::hex
                  << t.addr << std::dec << std::endl;
        if (t.write)
          mst.write(t.addr, t.wdata);
        else
          mst.read(t.addr);
        seqBusy = true;
      }

      // --------------------------------------------------------------------
      // (c) NoC responder FSM (registered ready/valid handshakes).
      // --------------------------------------------------------------------
      switch (rstate) {
      case R_WAIT_REQ:
        // Stay ready to accept a request packet at the responder node.
        dut->i_rspRouterToNiReady = 1;
        if (reqAccepted) {
          // Verify the request packet that was actually accepted this edge.
          AxiTxn &t = tests[respIdx];
          uint32_t p_addr  = getBits(s_pkt, OFF_ADDR, 32);
          uint32_t p_data  = getBits(s_pkt, OFF_DATA, 32);
          uint32_t p_wstrb = getBits(s_pkt, OFF_WSTRB, 4);
          uint32_t p_write = getBits(s_pkt, OFF_WRITE, 1);
          uint32_t exp_data  = t.write ? t.wdata : 0;
          uint32_t exp_wstrb = t.write ? 0xF : 0; // BFM drives full strobe
          if (p_addr != t.addr || p_data != exp_data ||
              p_wstrb != exp_wstrb || p_write != (t.write ? 1u : 0u)) {
            std::cout << "    req pkt: addr=0x" << std::hex << p_addr
                      << " data=0x" << p_data << " wstrb=0x" << p_wstrb
                      << " write=" << p_write << std::dec << std::endl;
            std::cout << "  FAIL: Test " << respIdx
                      << " — request packet mismatch" << std::endl;
            failed = true;
          } else {
            std::cout << "  request packet OK" << std::endl;
          }

          // Build and start driving the response packet.
          uint32_t rsp[PKT_WORDS] = {0, 0, 0};
          setBits(rsp, OFF_DSTCOL, COORD_WIDTH, SRC_COL);
          setBits(rsp, OFF_DSTROW, COORD_WIDTH, SRC_ROW);
          setBits(rsp, OFF_SRCCOL, COORD_WIDTH, RSP_COL);
          setBits(rsp, OFF_SRCROW, COORD_WIDTH, RSP_ROW);
          setBits(rsp, OFF_RESP, 2, RESP_OKAY);
          setBits(rsp, OFF_WRITE, 1, t.write ? 1 : 0);
          setBits(rsp, OFF_DATA, 32, t.write ? 0 : t.rdata);
          setBits(rsp, OFF_ADDR, 32, t.addr);
          for (int k = 0; k < PKT_WORDS; k++)
            dut->i_rspNiToRouter[k] = rsp[k];

          dut->i_rspRouterToNiReady = 0; // request consumed
          dut->i_rspNiToRouterValid = 1;
          rstate = R_SEND_RSP;
        }
        break;

      case R_SEND_RSP:
        // Hold the response valid until the NoC accepts it.
        if (rspAccepted) {
          dut->i_rspNiToRouterValid = 0;
          respIdx++;
          rstate = R_WAIT_REQ;
        }
        break;
      }

      // --------------------------------------------------------------------
      // (d) Completion detection for the sequencer.
      //     - Read: BFM hands us the captured data via get_read_data().
      //     - Write: the B-channel handshake completed this edge.
      // --------------------------------------------------------------------
      if (seqBusy) {
        AxiTxn &t = tests[seqIdx];
        if (!t.write) {
          uint64_t rdata;
          if (mst.get_read_data(rdata)) {
            if ((uint32_t)rdata == t.rdata) {
              std::cout << "  PASS: Test " << seqIdx << " — RDATA=0x" << std::hex
                        << (uint32_t)rdata << std::dec << std::endl;
              tests_passed++;
            } else {
              std::cout << "    got RDATA=0x" << std::hex << (uint32_t)rdata
                        << " exp=0x" << t.rdata << std::dec << std::endl;
              std::cout << "  FAIL: Test " << seqIdx << " — RDATA mismatch"
                        << std::endl;
              failed = true;
            }
            seqBusy = false;
            seqIdx++;
          }
        } else {
          if (bAccepted) {
            std::cout << "  PASS: Test " << seqIdx << " — BRESP=0x" << std::hex
                      << (int)dut->o_bresp << std::dec << std::endl;
            tests_passed++;
            seqBusy = false;
            seqIdx++;
          }
        }
      }

      // (e) Drive the BFM's new AXI bus values for the next edge.
      mst.update_output();
    }

    dut->eval();
    m_trace->dump(simt++);

    if (dut->i_clk)
      edges++;

    // Finish once all transactions have completed.
    if (seqIdx >= NUM_TESTS && !seqBusy)
      break;
  }

  m_trace->close();

  bool all_done = (tests_passed == NUM_TESTS) && !failed;
  std::cout << "\n=== Results: " << tests_passed << "/" << NUM_TESTS
            << " passed ===" << std::endl;

  delete dut;
  return all_done ? EXIT_SUCCESS : EXIT_FAILURE;
}
