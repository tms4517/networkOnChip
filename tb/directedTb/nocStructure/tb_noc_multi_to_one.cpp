#include <cstdlib>
#include <iomanip>
#include <iostream>

#include "Vnoc.h"
#include <verilated.h>
#include <verilated_vcd_c.h>

#define RESET_CYCLES 6

#ifndef GRID_WIDTH
#define GRID_WIDTH 4
#endif

#ifndef DST_ROW
#define DST_ROW 1
#endif
#ifndef DST_COL
#define DST_COL 1
#endif
#ifndef TIMEOUT_CYCLES
#define TIMEOUT_CYCLES 512
#endif

#define NUM_ROUTERS (GRID_WIDTH * GRID_WIDTH)
#define PACKET_WIDTH 77
#define BUS_WORDS ((NUM_ROUTERS * PACKET_WIDTH + 31) / 32)
#define ROUTER_READY_MASK ((1U << NUM_ROUTERS) - 1U)
#define NUM_SENDERS 4

vluint64_t sim_time = 0;
vluint64_t posedge_cnt = 0;

struct SenderCfg {
  int src_row;
  int src_col;
  uint64_t payload;
};

struct SenderState {
  bool waiting_accept;
  bool accepted;
  bool received;
  vluint64_t accepted_posedge;
};

static inline int routerIndex(int row, int col) {
  return row * GRID_WIDTH + col;
}

static inline uint32_t routerMask(int row, int col) {
  return 1U << routerIndex(row, col);
}

void dut_reset(Vnoc *dut, bool do_reset) {
  dut->i_arst_n = 1;

  if (do_reset || (sim_time < RESET_CYCLES)) {
    dut->i_arst_n = 0;
    dut->i_niToRouterValid = 0;
    dut->i_routerToNiReady = 0;
    for (int i = 0; i < BUS_WORDS; i++) {
      dut->i_niToRouter[i] = 0;
    }
  }
}

void addPacketToInputBus(Vnoc *dut, int src_row, int src_col, int dst_row,
                         int dst_col, uint64_t payload) {
  const int BITS_PER_ELEMENT = 32;

  // 77-bit packet: {payload(69), srcRow(2), srcCol(2), dstRow(2), dstCol(2)}
  uint64_t packet_low = (dst_col & 0x3ULL) | ((dst_row & 0x3ULL) << 2) |
                        ((src_col & 0x3ULL) << 4) | ((src_row & 0x3ULL) << 6) |
                        ((payload & 0x00FFFFFFFFFFFFFFULL) << 8);
  uint16_t packet_high = (payload >> 56) & 0x1FFF;

  int start_bit = routerIndex(src_row, src_col) * PACKET_WIDTH;
  int element_index = start_bit / BITS_PER_ELEMENT;
  int bit_offset = start_bit % BITS_PER_ELEMENT;

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

  dut->i_niToRouter[element_index + 2] |= ((uint32_t)packet_high) << bit_offset;
  if (bit_offset > 0) {
    dut->i_niToRouter[element_index + 3] |= packet_high >> (32 - bit_offset);
  }

  dut->i_niToRouterValid |= routerMask(src_row, src_col);
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
      (dut->o_routerToNi[element_index + 2] >> bit_offset) & 0x1FFF;
  if (bit_offset > 0) {
    packet_high |= (dut->o_routerToNi[element_index + 3] &
                    ((1ULL << bit_offset) - 1))
                   << (32 - bit_offset);
  }

  // Payload is at bits [76:8] — shift right by 8
  return ((uint64_t)(packet_high & 0x1FFF) << 56) | (packet_low >> 8);
}

int main(int argc, char **argv, char **env) {
  (void)env;
  Verilated::commandArgs(argc, argv);
  Vnoc *dut = new Vnoc;

  Verilated::traceEverOn(true);
  VerilatedVcdC *m_trace = new VerilatedVcdC;
  dut->trace(m_trace, 5);
  m_trace->open("waveform_multi_to_one.vcd");

  SenderCfg senders[NUM_SENDERS] = {
      {0, 0, 0xAAA0000000000001ULL},
      {0, 3, 0xAAA0000000000002ULL},
      {3, 0, 0xAAA0000000000003ULL},
      {3, 3, 0xAAA0000000000004ULL},
  };

  SenderState state[NUM_SENDERS];
  for (int i = 0; i < NUM_SENDERS; i++) {
    state[i].waiting_accept = true;
    state[i].accepted = false;
    state[i].received = false;
    state[i].accepted_posedge = 0;
  }

  std::cout << "Multi-to-one contention test: " << NUM_SENDERS
            << " senders -> dst=(" << DST_ROW << "," << DST_COL << ")"
            << std::endl;

  while (sim_time < MAX_SIM_TIME) {
    dut_reset(dut, false);

    if (dut->i_arst_n) {
      dut->i_routerToNiReady = ROUTER_READY_MASK;
    }

    dut->i_niToRouterValid = 0;
    for (int i = 0; i < BUS_WORDS; i++) {
      dut->i_niToRouter[i] = 0;
    }

    if (dut->i_arst_n) {
      for (int i = 0; i < NUM_SENDERS; i++) {
        if (state[i].waiting_accept) {
          addPacketToInputBus(dut, senders[i].src_row, senders[i].src_col,
                              DST_ROW, DST_COL, senders[i].payload);
        }
      }
    }

    dut->i_clk ^= 1;
    dut->eval();

    if (dut->i_clk == 1) {
      posedge_cnt++;

      if (!dut->i_arst_n) {
        for (int i = 0; i < NUM_SENDERS; i++) {
          state[i].waiting_accept = true;
          state[i].accepted = false;
          state[i].received = false;
          state[i].accepted_posedge = 0;
        }
      } else {
        for (int i = 0; i < NUM_SENDERS; i++) {
          if (state[i].waiting_accept &&
              (dut->o_niToRouterReady &
               routerMask(senders[i].src_row, senders[i].src_col))) {
            state[i].waiting_accept = false;
            state[i].accepted = true;
            state[i].accepted_posedge = posedge_cnt;
            std::cout << "Accepted sender " << i << " src=(" << senders[i].src_row
                      << "," << senders[i].src_col << ") payload=0x" << std::hex
                      << senders[i].payload << std::dec << " at posedge "
                      << posedge_cnt << std::endl;
          }
        }

        uint32_t dst_mask = routerMask(DST_ROW, DST_COL);
        if (dut->o_routerToNiValid & dst_mask) {
          uint64_t rx_payload = extractPayloadFromRouter(dut, DST_ROW, DST_COL);
          int matched_idx = -1;

          for (int i = 0; i < NUM_SENDERS; i++) {
            if (rx_payload == senders[i].payload) {
              matched_idx = i;
              if (!state[i].received) {
                state[i].received = true;
                std::cout << "Received sender " << i
                          << " payload at dst on posedge " << posedge_cnt
                          << std::endl;
              }
              break;
            }
          }

          if (matched_idx < 0) {
            std::cout << "FAIL: Destination received unexpected payload 0x"
                      << std::hex << rx_payload << std::dec << std::endl;
            m_trace->close();
            delete dut;
            return EXIT_FAILURE;
          }
        }

        bool all_received = true;
        for (int i = 0; i < NUM_SENDERS; i++) {
          if (!state[i].received) {
            all_received = false;
          }

          if (state[i].accepted && !state[i].received &&
              (posedge_cnt - state[i].accepted_posedge) > TIMEOUT_CYCLES) {
            std::cout << "FAIL: Timeout waiting for sender " << i
                      << " payload at destination" << std::endl;
            m_trace->close();
            delete dut;
            return EXIT_FAILURE;
          }
        }

        if (all_received) {
          std::cout << "PASS: Received all " << NUM_SENDERS
                    << " payloads at destination" << std::endl;
          m_trace->close();
          delete dut;
          return EXIT_SUCCESS;
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
