#include <cstdlib>
#include <iomanip>
#include <iostream>

#include "Vnoc.h"
#include <verilated.h>
#include <verilated_vcd_c.h>

#define RESET_DEASSERT 2
#define RESET_ASSERT 5

#ifndef GRID_WIDTH
#define GRID_WIDTH 4
#endif

#ifndef SRC_ROW
#define SRC_ROW 0
#endif
#ifndef SRC_COL
#define SRC_COL 0
#endif
#ifndef DST_ROW
#define DST_ROW 3
#endif
#ifndef DST_COL
#define DST_COL 2
#endif
#ifndef TEST_PAYLOAD
#define TEST_PAYLOAD 0x123456789ABCDEF0ULL
#endif
#ifndef TIMEOUT_CYCLES
#define TIMEOUT_CYCLES 256
#endif

#define NUM_ROUTERS (GRID_WIDTH * GRID_WIDTH)
#define PACKET_WIDTH 73
#define BUS_WORDS ((NUM_ROUTERS * PACKET_WIDTH + 31) / 32)
#define ROUTER_READY_MASK ((1U << NUM_ROUTERS) - 1U)

vluint64_t sim_time = 0;
vluint64_t posedge_cnt = 0;

static inline int routerIndex(int row, int col) {
  return row * GRID_WIDTH + col;
}

static inline uint32_t routerMask(int row, int col) {
  return 1U << routerIndex(row, col);
}

void dut_reset(Vnoc *dut, bool do_reset) {
  dut->i_arst_n = 1;

  if (do_reset ||
      (sim_time > RESET_DEASSERT + 1) && (sim_time < RESET_ASSERT + 1)) {
    dut->i_arst_n = 0;
    dut->i_niToRouterValid = 0;
    dut->i_routerToNiReady = 0;
    for (int i = 0; i < BUS_WORDS; i++) {
      dut->i_niToRouter[i] = 0;
    }
  }
}

void drivePacket(Vnoc *dut, int src_row, int src_col, int dst_row, int dst_col,
                 uint64_t payload) {
  const int BITS_PER_ELEMENT = 32;

  uint64_t packet_low = (dst_col & 0x3ULL) | ((dst_row & 0x3ULL) << 2) |
                        ((payload & 0xFFFFFFFFFFFFFFFULL) << 4);
  uint16_t packet_high = (payload >> 60) & 0x1FF;

  int start_bit = routerIndex(src_row, src_col) * PACKET_WIDTH;
  int element_index = start_bit / BITS_PER_ELEMENT;
  int bit_offset = start_bit % BITS_PER_ELEMENT;

  for (int i = 0; i < BUS_WORDS; i++) {
    dut->i_niToRouter[i] = 0;
  }
  dut->i_niToRouterValid = 0;

  uint32_t low_32 = packet_low & 0xFFFFFFFF;
  dut->i_niToRouter[element_index] |= low_32 << bit_offset;
  if (bit_offset > 0) {
    dut->i_niToRouter[element_index + 1] |= low_32 >> (32 - bit_offset);
  }

  uint32_t high_32 = (packet_low >> 32) & 0xFFFFFFFF;
  dut->i_niToRouter[element_index + 1] |= high_32 << bit_offset;
  if (bit_offset > 0) {
    dut->i_niToRouter[element_index + 2] |= high_32 >> (32 - bit_offset);
  }

  dut->i_niToRouter[element_index + 2] |= ((uint64_t)packet_high) << bit_offset;
  if (bit_offset > 23) {
    dut->i_niToRouter[element_index + 3] |= packet_high >> (32 - bit_offset);
  }

  dut->i_niToRouterValid = routerMask(src_row, src_col);
}

uint64_t extractPayloadFromRouter(Vnoc *dut, int row, int col) {
  const int BITS_PER_ELEMENT = 32;

  int start_bit = routerIndex(row, col) * PACKET_WIDTH;
  int element_index = start_bit / BITS_PER_ELEMENT;
  int bit_offset = start_bit % BITS_PER_ELEMENT;

  uint64_t packet_low = (uint64_t)(dut->o_routerToNi[element_index]) >> bit_offset;

  if (bit_offset > 0) {
    packet_low |= ((uint64_t)(dut->o_routerToNi[element_index + 1]) &
                   ((1ULL << bit_offset) - 1))
                  << (32 - bit_offset);
  }

  uint64_t upper_32 =
      (uint64_t)(dut->o_routerToNi[element_index + 1]) >> bit_offset;
  if (bit_offset > 0) {
    upper_32 |= ((uint64_t)(dut->o_routerToNi[element_index + 2]) &
                 ((1ULL << bit_offset) - 1))
                << (32 - bit_offset);
  }
  packet_low |= upper_32 << 32;

  uint16_t packet_high =
      (dut->o_routerToNi[element_index + 2] >> bit_offset) & 0x1FF;
  if (bit_offset > 23) {
    packet_high |= (dut->o_routerToNi[element_index + 3] &
                    ((1ULL << (bit_offset - 23)) - 1))
                   << (32 - bit_offset);
  }

  return ((uint64_t)packet_high << 60) | (packet_low >> 4);
}

int main(int argc, char **argv, char **env) {
  (void)env;
  Verilated::commandArgs(argc, argv);
  Vnoc *dut = new Vnoc;

  Verilated::traceEverOn(true);
  VerilatedVcdC *m_trace = new VerilatedVcdC;
  dut->trace(m_trace, 5);
  m_trace->open("waveform_single.vcd");

  bool waiting_accept = true;
  bool in_flight = false;
  vluint64_t sent_posedge = 0;

  std::cout << "Single-packet test: src=(" << SRC_ROW << "," << SRC_COL
            << ") dst=(" << DST_ROW << "," << DST_COL << ") payload=0x"
            << std::hex << std::setw(16) << std::setfill('0')
            << (uint64_t)TEST_PAYLOAD << std::dec << std::endl;

  while (sim_time < MAX_SIM_TIME) {
    dut_reset(dut, false);

    if (dut->i_arst_n) {
      dut->i_routerToNiReady = ROUTER_READY_MASK;
    }

    dut->i_niToRouterValid = 0;
    for (int i = 0; i < BUS_WORDS; i++) {
      dut->i_niToRouter[i] = 0;
    }

    if (dut->i_arst_n && waiting_accept) {
      drivePacket(dut, SRC_ROW, SRC_COL, DST_ROW, DST_COL, TEST_PAYLOAD);
    }

    dut->i_clk ^= 1;
    dut->eval();

    if (dut->i_clk == 1) {
      posedge_cnt++;

      if (!dut->i_arst_n) {
        waiting_accept = true;
        in_flight = false;
      } else {
        if (waiting_accept &&
            (dut->o_niToRouterReady & routerMask(SRC_ROW, SRC_COL))) {
          waiting_accept = false;
          in_flight = true;
          sent_posedge = posedge_cnt;
          std::cout << "Accepted at posedge " << posedge_cnt << ", ready=0x"
                    << std::hex << dut->o_niToRouterReady << std::dec
                    << std::endl;
        }

        if (in_flight) {
          uint32_t valid_mask = dut->o_routerToNiValid;
          if (valid_mask != 0) {
            std::cout << "Posedge " << posedge_cnt << ": o_routerToNiValid=0x"
                      << std::hex << valid_mask << std::dec << std::endl;
          }

          if (valid_mask & routerMask(DST_ROW, DST_COL)) {
            uint64_t payload = extractPayloadFromRouter(dut, DST_ROW, DST_COL);
            if (payload == (uint64_t)TEST_PAYLOAD) {
              std::cout << "PASS: Received expected payload at destination at "
                        << "posedge " << posedge_cnt << std::endl;
              m_trace->close();
              delete dut;
              return EXIT_SUCCESS;
            }

            std::cout << "FAIL: Destination payload mismatch. expected=0x"
                      << std::hex << (uint64_t)TEST_PAYLOAD << " got=0x"
                      << payload << std::dec << std::endl;
            m_trace->close();
            delete dut;
            return EXIT_FAILURE;
          }

          if ((posedge_cnt - sent_posedge) > TIMEOUT_CYCLES) {
            std::cout << "FAIL: Timeout after " << TIMEOUT_CYCLES
                      << " cycles waiting for destination. last valid mask=0x"
                      << std::hex << dut->o_routerToNiValid << std::dec
                      << std::endl;
            m_trace->close();
            delete dut;
            return EXIT_FAILURE;
          }
        }
      }
    }

    m_trace->dump(sim_time);
    sim_time++;
  }

  std::cout << "FAIL: Reached MAX_SIM_TIME without completion" << std::endl;
  m_trace->close();
  delete dut;
  return EXIT_FAILURE;
}
