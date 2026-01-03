#include <cmath>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <stdlib.h>
#include <vector>

#include "Vnoc.h"            // Verilated DUT.
#include <verilated.h>       // Common verilator routines.
#include <verilated_vcd_c.h> // Write waverforms to a VCD file.

#define MAX_SIM_TIME 1000 // Number of clk edges.
#define RESET_DEASSERT 2  // Clk edge number to deassert arst.
#define RESET_ASSERT 5    // Clk edge number to assert arst.
#define GRID_WIDTH 4      // Number of routers along one dimension of the grid.

vluint64_t sim_time = 0;
vluint64_t posedge_cnt = 0;
vluint64_t packet_sent_cnt = 0;

// Deassert arst_n only on the first clock edge.
// Note: By default all signals are initialized to 0, so there's no need to
// drive the other inputs to '0.
void dut_reset(Vnoc *dut) {
  dut->i_arst_n = 1;

  if ((sim_time > RESET_DEASSERT+1) && (sim_time < RESET_ASSERT+1)) {
    dut->i_arst_n = 0;

    // Clear all elements
    for (int i = 0; i < 37; i++) {
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
void writePacketToRandomRouter(Vnoc *dut, int row, int col, int destination_row, int destination_col, uint64_t payload) {

  const int BITS_PER_PACKET = 73;
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

  int router_id = row * GRID_WIDTH + col;
  int start_bit = router_id * BITS_PER_PACKET;

  int element_index = start_bit / BITS_PER_ELEMENT;
  int bit_offset = start_bit % BITS_PER_ELEMENT;

  // Write lower 32 bits of the packet
  dut->i_niToRouter[element_index] |= (packet_low & 0xFFFFFFFF) << bit_offset;

  // Write next 32 bits of the packet
  dut->i_niToRouter[element_index + 1] |=
      ((packet_low >> 32) & 0xFFFFFFFF) << bit_offset;

  // Write remaining 9 bits from packet_high into third element
  // packet_high continues at the same bit_offset in element[2] as packet_low
  // in element[0]
  dut->i_niToRouter[element_index + 2] |=
      ((uint64_t)packet_high) << bit_offset;
}

void readPacketFromDestinationRouter(Vnoc *dut, int row, int col, uint64_t expected_payload) {
  const int BITS_PER_PACKET = 73;
  const int BITS_PER_ELEMENT = 32;

  int router_id = row * GRID_WIDTH + col;
  int start_bit = router_id * BITS_PER_PACKET;

  int element_index = start_bit / BITS_PER_ELEMENT;
  int bit_offset = start_bit % BITS_PER_ELEMENT;

  // Read lower 32 bits of the output packet
  uint64_t packet_low = (dut->o_routerToNi[element_index] >> bit_offset) & 0xFFFFFFFF;

  // Read next 32 bits of the output packet
  packet_low |= ((uint64_t)(dut->o_routerToNi[element_index + 1] >> bit_offset) & 0xFFFFFFFF) << 32;

  // Read remaining 9 bits from third element
  uint16_t packet_high = (dut->o_routerToNi[element_index + 2] >> bit_offset) & 0x1FF;

  // Reconstruct full payload from received packet
  uint64_t received_payload = ((uint64_t)packet_high << 60) | (packet_low >> 4);

  // Check if the received payload matches the expected payload
  if (received_payload == expected_payload) {
    std::cout << "Time: " << sim_time
              << " Received expected packet at router (" << row
              << "," << col << ") with payload: 0x"
              << std::hex << std::setw(16) << std::setfill('0')
              << received_payload << std::dec << std::endl;
  } else {
    std::cout << "Time: " << sim_time
              << " ERROR: Mismatched packet at router (" << row
              << "," << col << "). Expected payload: 0x"
              << std::hex << std::setw(16) << std::setfill('0')
              << expected_payload << ", but received: 0x"
              << std::setw(16) << std::setfill('0')
              << received_payload << std::dec << std::endl;
  }
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
    dut_reset(dut);

    dut->i_clk ^= 1; // Toggle clk to create pos and neg edge.

    dut->eval(); // Evaluate all the signals in the DUT on each clock edge.

    if (dut->i_clk == 1) {
      posedge_cnt++;

      if (sim_time > RESET_ASSERT+1) {
        int rand_row, rand_col, rand_destination_row, rand_destination_col;
        uint64_t rand_payload;
        // send a packet to a random router every 10 posedge clk
        if (posedge_cnt % 10 == 0) {
          rand_row = rand() % GRID_WIDTH;
          rand_col = rand() % GRID_WIDTH;
          rand_destination_row = rand() % GRID_WIDTH;
          rand_destination_col = rand() % GRID_WIDTH;
          rand_payload = ((uint64_t)rand() << 32) | rand();

          writePacketToRandomRouter(dut, rand_row, rand_col, rand_destination_row, rand_destination_col, rand_payload);

          // Record the clock cycle edge count when the packet was sent
          packet_sent_cnt = posedge_cnt;

        std::cout << "Time: " << sim_time
                  << " Sent packet from router (" << rand_row
                  << "," << rand_col << ") to router (" << rand_destination_row
                  << "," << rand_destination_col << ") with payload: 0x"
                  << std::hex << std::setw(16) << std::setfill('0')
                  << rand_payload << std::dec << std::endl;
        }

        // After 8 clock cycles, read back the packet from the destination
        // router to verify it was received correctly.
        if (posedge_cnt == (packet_sent_cnt + (GRID_WIDTH * 2)) &&
            packet_sent_cnt != 0) {
          readPacketFromDestinationRouter(dut, rand_destination_row, rand_destination_col, rand_payload);
        }
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
