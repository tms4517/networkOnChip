#include <cmath>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <stdlib.h>
#include <vector>

#include "Vnoc.h"            // Verilated DUT.
#include <verilated.h>       // Common verilator routines.
#include <verilated_vcd_c.h> // Write waverforms to a VCD file.

#define RESET_CYCLES 6   // Keep async reset asserted for initial cycles.
#define GRID_WIDTH 4     // Number of routers along one dimension of the grid.
#define NUM_ROUTERS (GRID_WIDTH * GRID_WIDTH)
#define PACKET_WIDTH 73
#define BUS_WORDS ((NUM_ROUTERS * PACKET_WIDTH + 31) / 32)
#define ROUTER_READY_MASK ((1U << NUM_ROUTERS) - 1U)
#define INJECTION_PERIOD 10
#define RECEIVE_TIMEOUT 1024
#define POST_RX_QUIET_CYCLES 6

vluint64_t sim_time = 0;
vluint64_t posedge_cnt = 0;

struct PacketTxn {
  bool in_flight;
  bool waiting_accept;
  int src_row;
  int src_col;
  int dst_row;
  int dst_col;
  uint64_t payload;
  vluint64_t sent_posedge;
};

static PacketTxn g_txn = {false, false, 0, 0, 0, 0, 0, 0};
static int g_quiet_cycles_remaining = 0;

static inline int routerIndex(int row, int col) {
  return row * GRID_WIDTH + col;
}

static inline uint32_t routerMask(int row, int col) {
  return 1U << routerIndex(row, col);
}

// Hold reset active at startup to initialize all sequential state
// deterministically before traffic generation.
void dut_reset(Vnoc *dut, bool do_reset) {
  dut->i_arst_n = 1;

  if (do_reset || (sim_time < RESET_CYCLES)) {
    dut->i_arst_n = 0;
    dut->i_niToRouterValid = 0;
    dut->i_routerToNiReady = 0;
    g_txn.in_flight = false;
    g_txn.waiting_accept = false;
    g_quiet_cycles_remaining = 0;

    // Clear all elements
    for (int i = 0; i < BUS_WORDS; i++) {
      dut->i_niToRouter[i] = 0;
    }
  }
}

// Each router input packet `i_niToRouter` is 73 bits wide.
// For a grid width of 4, there are 16 routers, so the total input bus width is
// 73*16 = 1168 bits. This is represented as an array of 37 elements where each
// element is 32 bits wide (37*32 = 1184 bits).
// So each router input packet spans across 2 elements in the array (64 bits)
// with 9 bits in the third element.
// See, `./obj_dir/Vnoc.h`, VL_INW(i_niToRouter,1167,0,37).
void writePacketToRandomRouter(Vnoc *dut, int row, int col, int destination_row,
                               int destination_col, uint64_t payload) {

  const int BITS_PER_PACKET = PACKET_WIDTH;
  const int BITS_PER_ELEMENT = 32;

  // Construct 73-bit packet: payload(69)|destination_row(2)|destination_col(2)
  // Note: Using only lower 64 bits of the 69-bit payload for simplicity.
  // 0x3ULL is a bitwise mask that extracts only the lowest 2 bits, the ULL
  // suffix ensures it is treated as an unsigned long long literal.
  uint64_t packet_low = (destination_col & 0x3ULL) |
                        ((destination_row & 0x3ULL) << 2) |
                        ((payload & 0xFFFFFFFFFFFFFFFULL) << 4);
  // Upper 9 bits (4 from payload shift + 5 more)
  uint16_t packet_high = (payload >> 60) & 0x1FF;

  int router_id = routerIndex(row, col);
  int start_bit = router_id * BITS_PER_PACKET;

  int element_index = start_bit / BITS_PER_ELEMENT;
  int bit_offset = start_bit % BITS_PER_ELEMENT;

  // Keep this TB single-transaction by driving only one NI input at a time.
  for (int i = 0; i < BUS_WORDS; i++) {
    dut->i_niToRouter[i] = 0;
  }
  dut->i_niToRouterValid = 0;

  // Write lower 32 bits of packet_low
  uint32_t low_32 = packet_low & 0xFFFFFFFF;
  dut->i_niToRouter[element_index] |= low_32 << bit_offset;
  // Handle overflow to next element if bit_offset > 0
  if (bit_offset > 0) {
    dut->i_niToRouter[element_index + 1] |= low_32 >> (32 - bit_offset);
  }

  // Write upper 32 bits of packet_low
  uint32_t high_32 = (packet_low >> 32) & 0xFFFFFFFF;
  dut->i_niToRouter[element_index + 1] |= high_32 << bit_offset;
  // Handle overflow to next element if bit_offset > 0
  if (bit_offset > 0) {
    dut->i_niToRouter[element_index + 2] |= high_32 >> (32 - bit_offset);
  }

  // Write remaining 9 bits from packet_high
  dut->i_niToRouter[element_index + 2] |= ((uint64_t)packet_high) << bit_offset;
  // Handle overflow to next element if needed (only if bit_offset > 23, since
  // packet_high is 9 bits)
  if (bit_offset > 23) {
    dut->i_niToRouter[element_index + 3] |= packet_high >> (32 - bit_offset);
  }

  dut->i_niToRouterValid = routerMask(row, col);

}

void logPacketSent(int row, int col, int destination_row, int destination_col,
                   uint64_t payload) {
  std::cout << "Time: " << sim_time << ", Posedge Cnt: " << posedge_cnt
            << std::endl;
  std::cout << " Sent packet from router (" << row << "," << col
            << ") to router (" << destination_row << "," << destination_col
            << ") with payload: 0x" << std::hex << std::setw(16)
            << std::setfill('0') << payload << std::dec << std::endl;
}

uint64_t extractPayloadFromRouter(Vnoc *dut, int row, int col) {
  const int BITS_PER_PACKET = PACKET_WIDTH;
  const int BITS_PER_ELEMENT = 32;

  int router_id = routerIndex(row, col);
  int start_bit = router_id * BITS_PER_PACKET;

  int element_index = start_bit / BITS_PER_ELEMENT;
  int bit_offset = start_bit % BITS_PER_ELEMENT;

  // Read and reconstruct packet_low (64 bits)
  // Need to account for bits spanning across element boundaries
  uint64_t packet_low = 0;

  // Get bits from element_index (shifted right to align)
  packet_low = (uint64_t)(dut->o_routerToNi[element_index]) >> bit_offset;

  // Get remaining bits from element_index + 1 that belong to lower 32 bits
  if (bit_offset > 0) {
    packet_low |= ((uint64_t)(dut->o_routerToNi[element_index + 1]) &
                   ((1ULL << bit_offset) - 1))
                  << (32 - bit_offset);
  }

  // Get bits 63:32 from element_index + 1 and element_index + 2
  uint64_t upper_32 =
      (uint64_t)(dut->o_routerToNi[element_index + 1]) >> bit_offset;
  if (bit_offset > 0) {
    upper_32 |= ((uint64_t)(dut->o_routerToNi[element_index + 2]) &
                 ((1ULL << bit_offset) - 1))
                << (32 - bit_offset);
  }
  packet_low |= upper_32 << 32;

  // Read remaining 9 bits from packet_high (starting at bit 64 of the packet)
  uint16_t packet_high =
      (dut->o_routerToNi[element_index + 2] >> bit_offset) & 0x1FF;
  // If bit_offset > 23, packet_high spans into element_index + 3
  if (bit_offset > 23) {
    packet_high |= (dut->o_routerToNi[element_index + 3] &
                    ((1ULL << (bit_offset - 23)) - 1))
                   << (32 - bit_offset);
  }

  return ((uint64_t)packet_high << 60) | (packet_low >> 4);
}

bool readPacketFromDestinationRouter(Vnoc *dut, int row, int col,
                                     uint64_t expected_payload) {
  uint32_t valid_mask = dut->o_routerToNiValid;

  if ((valid_mask & routerMask(row, col)) == 0) {
    // If expected payload appears at the wrong NI, report routing error
    // immediately instead of waiting for timeout.
    if (valid_mask != 0) {
      for (int rr = 0; rr < GRID_WIDTH; rr++) {
        for (int cc = 0; cc < GRID_WIDTH; cc++) {
          if ((valid_mask & routerMask(rr, cc)) == 0) {
            continue;
          }

          uint64_t payload = extractPayloadFromRouter(dut, rr, cc);
          if (payload == expected_payload) {
            std::cout << "Time: " << sim_time << ", Posedge Cnt: " << posedge_cnt
                      << std::endl;
            std::cout << " ERROR: Packet reached wrong router (" << rr << ","
                      << cc << "), expected (" << row << "," << col << ")"
                      << std::endl;
            std::cout << "******************" << std::endl;
            exit(EXIT_FAILURE);
          }
        }
      }
    }
    return false;
  }

  uint64_t received_payload = extractPayloadFromRouter(dut, row, col);

  // Check if the received payload matches the expected payload
  if (received_payload == expected_payload) {
    std::cout << "Time: " << sim_time << ", Posedge Cnt: " << posedge_cnt
              << std::endl;
    std::cout << " Received expected packet at router (" << row << "," << col
              << ") with payload: 0x" << std::hex << std::setw(16)
              << std::setfill('0') << received_payload << std::dec << std::endl;
    std::cout << "******************" << std::endl;
    return true;
  } else {
    std::cout << "Time: " << sim_time << ", Posedge Cnt: " << posedge_cnt
              << std::endl;
    std::cout << " ERROR: Mismatched packet at router (" << row << "," << col
              << "). Expected payload: 0x" << std::hex << std::setw(16)
              << std::setfill('0') << expected_payload << ", but received: 0x"
              << std::setw(16) << std::setfill('0') << received_payload
              << std::dec << std::endl;
    std::cout << "******************" << std::endl;
    exit(EXIT_FAILURE);
  }

  return false;
}

int main(int argc, char **argv, char **env) {
  srand(time(NULL));
  Verilated::commandArgs(argc, argv);
  Vnoc *dut = new Vnoc; // Instantiate DUT.

  // {{{ Set-up waveform dumping.

  Verilated::traceEverOn(true);
  VerilatedVcdC *m_trace = new VerilatedVcdC;
  dut->trace(m_trace, 5);
  m_trace->open("waveform.vcd");

  // }}} Set-up waveform dumping.

  while (sim_time < MAX_SIM_TIME) {
    dut_reset(dut, false);

    // Always ready to receive packets at all NI endpoints.
    if (dut->i_arst_n) {
      dut->i_routerToNiReady = ROUTER_READY_MASK;
    }

    // Default to no NI injection. If there is a pending transaction, keep
    // driving valid/data until the source router accepts it.
    dut->i_niToRouterValid = 0;
    for (int i = 0; i < BUS_WORDS; i++) {
      dut->i_niToRouter[i] = 0;
    }
    if (dut->i_arst_n && g_txn.waiting_accept) {
      writePacketToRandomRouter(dut, g_txn.src_row, g_txn.src_col, g_txn.dst_row,
                                g_txn.dst_col, g_txn.payload);
    }

    dut->i_clk ^= 1; // Toggle clk to create pos and neg edge.

    dut->eval(); // Evaluate all the signals in the DUT on each clock edge.

    if (dut->i_clk == 1) {
      posedge_cnt++;

      if (dut->i_arst_n && g_txn.waiting_accept &&
          (dut->o_niToRouterReady & routerMask(g_txn.src_row, g_txn.src_col))) {
        g_txn.waiting_accept = false;
        g_txn.in_flight = true;
        g_txn.sent_posedge = posedge_cnt;
        logPacketSent(g_txn.src_row, g_txn.src_col, g_txn.dst_row, g_txn.dst_col,
                      g_txn.payload);
      }

      if (dut->i_arst_n && g_quiet_cycles_remaining > 0) {
        if (dut->o_routerToNiValid == 0) {
          g_quiet_cycles_remaining--;
        } else {
          g_quiet_cycles_remaining = POST_RX_QUIET_CYCLES;
        }
      }

      // Queue one packet periodically when no older packet is outstanding.
      if (dut->i_arst_n && !g_txn.in_flight && !g_txn.waiting_accept &&
          (g_quiet_cycles_remaining == 0) &&
          (posedge_cnt % INJECTION_PERIOD == 0)) {
        g_txn.src_row = rand() % GRID_WIDTH;
        g_txn.src_col = rand() % GRID_WIDTH;
        g_txn.dst_row = rand() % GRID_WIDTH;
        g_txn.dst_col = rand() % GRID_WIDTH;
        g_txn.payload = ((uint64_t)rand() << 32) | rand();
        g_txn.waiting_accept = true;
      }

      if (dut->i_arst_n && g_txn.in_flight) {
        bool received = readPacketFromDestinationRouter(
            dut, g_txn.dst_row, g_txn.dst_col, g_txn.payload);

        if (received) {
          g_txn.in_flight = false;
          g_quiet_cycles_remaining = POST_RX_QUIET_CYCLES;
        } else if ((posedge_cnt - g_txn.sent_posedge) > RECEIVE_TIMEOUT) {
          std::cout << "Time: " << sim_time << ", Posedge Cnt: " << posedge_cnt
                    << std::endl;
          std::cout << " ERROR: Timed out waiting for packet at router ("
                    << g_txn.dst_row << "," << g_txn.dst_col
                    << "). Payload: 0x" << std::hex << std::setw(16)
                    << std::setfill('0') << g_txn.payload << std::dec
                    << std::endl;
          std::cout << "******************" << std::endl;
          exit(EXIT_FAILURE);
        }
      }

      if (!dut->i_arst_n) {
        g_txn.in_flight = false;
        g_txn.waiting_accept = false;
        g_quiet_cycles_remaining = 0;
      }
    }

    // Write all the traced signal values into the waveform dump file.
    m_trace->dump(sim_time);

    sim_time++;
  }

  m_trace->close();
  delete dut;
  exit(EXIT_SUCCESS);
}
