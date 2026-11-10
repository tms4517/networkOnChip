// Copyright (c) 2026 Tej Sanghavi.
// Formal testbench for the NoC `router`: instantiates the DUT and the
// assertion module. Clock, reset, all input packets/valids and all downstream
// readys are left undriven so JasperGold treats them as free primary inputs.
// The router sits in the middle of the grid (row 1, column 1) so all four
// neighbour directions are reachable. A small PACKET_WIDTH keeps the state
// space small while still carrying payload bits above the coordinates.

`default_nettype none
/* verilator lint_off UNDRIVEN */
/* verilator lint_off UNUSEDSIGNAL */

module routerTb
  import pa_noc::*;
#(parameter int unsigned GRID_WIDTH = 4
, parameter int unsigned PACKET_WIDTH = 8
, parameter int unsigned FIFO_ADDRESS_WIDTH = pa_noc::FIFO_ADDRESS_W
, localparam int unsigned COORD_WIDTH = $clog2(GRID_WIDTH)
, parameter bit [COORD_WIDTH-1:0] ROUTER_ROW = 1
, parameter bit [COORD_WIDTH-1:0] ROUTER_COL = 1
, localparam int unsigned NUM_PORTS = NUM_INPUT_FIFOS
, localparam int unsigned PORT_WIDTH = $clog2(NUM_PORTS)
);

  logic i_clk;
  logic i_arst_n;

  logic [NUM_PORTS-1:0][PACKET_WIDTH-1:0] inData;
  logic [NUM_PORTS-1:0]                   inValid;
  logic [NUM_PORTS-1:0]                   inReady;

  logic [NUM_PORTS-1:0][PACKET_WIDTH-1:0] outData;
  logic [NUM_PORTS-1:0]                   outValid;
  logic [NUM_PORTS-1:0]                   outReady;

  logic [PORT_WIDTH-1:0] trackPort;
  logic                  trackPick;

  router
  #(.GRID_WIDTH         (GRID_WIDTH)
  , .PACKET_WIDTH       (PACKET_WIDTH)
  , .FIFO_ADDRESS_WIDTH (FIFO_ADDRESS_WIDTH)
  , .ROUTER_ROW         (ROUTER_ROW)
  , .ROUTER_COL         (ROUTER_COL)
  ) u_dut
  ( .i_clk        (i_clk)
  , .i_arst_n     (i_arst_n)
  , .i_ni         (inData[NI])
  , .i_niValid    (inValid[NI])
  , .o_niReady    (inReady[NI])
  , .i_north      (inData[NORTH])
  , .i_northValid (inValid[NORTH])
  , .o_northReady (inReady[NORTH])
  , .i_south      (inData[SOUTH])
  , .i_southValid (inValid[SOUTH])
  , .o_southReady (inReady[SOUTH])
  , .i_east       (inData[EAST])
  , .i_eastValid  (inValid[EAST])
  , .o_eastReady  (inReady[EAST])
  , .i_west       (inData[WEST])
  , .i_westValid  (inValid[WEST])
  , .o_westReady  (inReady[WEST])
  , .o_ni         (outData[NI])
  , .o_niValid    (outValid[NI])
  , .i_niReady    (outReady[NI])
  , .o_north      (outData[NORTH])
  , .o_northValid (outValid[NORTH])
  , .i_northReady (outReady[NORTH])
  , .o_south      (outData[SOUTH])
  , .o_southValid (outValid[SOUTH])
  , .i_southReady (outReady[SOUTH])
  , .o_east       (outData[EAST])
  , .o_eastValid  (outValid[EAST])
  , .i_eastReady  (outReady[EAST])
  , .o_west       (outData[WEST])
  , .o_westValid  (outValid[WEST])
  , .i_westReady  (outReady[WEST])
  );

  // White-box taps into the router's arbiter and input FIFOs. The FIFO
  // pointers/memory are only used by helper invariants that make the
  // data-integrity proof inductive.
  logic [NUM_PORTS-1:0] grant;

  always_comb
    grant = u_dut.u_arbiter.grant;

  logic [NUM_PORTS-1:0] fifoReadEn;

  always_comb
    fifoReadEn = u_dut.fifoReadEn;

  logic [PACKET_WIDTH-1:0] arbiterPacket;

  always_comb
    arbiterPacket = u_dut.packet;

  logic arbiterPacketIsValid;

  always_comb
    arbiterPacketIsValid = u_dut.packetIsValid;

  localparam int unsigned DEPTH = 1 << FIFO_ADDRESS_WIDTH;

  logic [NUM_PORTS-1:0][FIFO_ADDRESS_WIDTH:0] fifoReadPointer;

  always_comb
    fifoReadPointer[NI] = u_dut.u_niFifo.readPointer_q;

  always_comb
    fifoReadPointer[NORTH] = u_dut.u_northFifo.readPointer_q;

  always_comb
    fifoReadPointer[SOUTH] = u_dut.u_southFifo.readPointer_q;

  always_comb
    fifoReadPointer[EAST] = u_dut.u_eastFifo.readPointer_q;

  always_comb
    fifoReadPointer[WEST] = u_dut.u_westFifo.readPointer_q;

  logic [NUM_PORTS-1:0][FIFO_ADDRESS_WIDTH:0] fifoWritePointer;

  always_comb
    fifoWritePointer[NI] = u_dut.u_niFifo.writePointer_q;

  always_comb
    fifoWritePointer[NORTH] = u_dut.u_northFifo.writePointer_q;

  always_comb
    fifoWritePointer[SOUTH] = u_dut.u_southFifo.writePointer_q;

  always_comb
    fifoWritePointer[EAST] = u_dut.u_eastFifo.writePointer_q;

  always_comb
    fifoWritePointer[WEST] = u_dut.u_westFifo.writePointer_q;

  logic [NUM_PORTS-1:0][DEPTH-1:0][PACKET_WIDTH-1:0] fifoMem;

  for (genvar k = 0; k < DEPTH; k++) begin: genFifoMemTap

    always_comb
      fifoMem[NI][k] = u_dut.u_niFifo.mem[k];

    always_comb
      fifoMem[NORTH][k] = u_dut.u_northFifo.mem[k];

    always_comb
      fifoMem[SOUTH][k] = u_dut.u_southFifo.mem[k];

    always_comb
      fifoMem[EAST][k] = u_dut.u_eastFifo.mem[k];

    always_comb
      fifoMem[WEST][k] = u_dut.u_westFifo.mem[k];

  end: genFifoMemTap

  routerAssertions
  #(.GRID_WIDTH         (GRID_WIDTH)
  , .PACKET_WIDTH       (PACKET_WIDTH)
  , .FIFO_ADDRESS_WIDTH (FIFO_ADDRESS_WIDTH)
  , .ROUTER_ROW         (ROUTER_ROW)
  , .ROUTER_COL         (ROUTER_COL)
  ) u_assertions
  ( .i_clk                  (i_clk)
  , .i_arst_n               (i_arst_n)
  , .i_inData               (inData)
  , .i_inValid              (inValid)
  , .i_inReady              (inReady)
  , .i_outData              (outData)
  , .i_outValid             (outValid)
  , .i_outReady             (outReady)
  , .i_grant                (grant)
  , .i_fifoReadEn           (fifoReadEn)
  , .i_arbiterPacket        (arbiterPacket)
  , .i_arbiterPacketIsValid (arbiterPacketIsValid)
  , .i_fifoReadPointer      (fifoReadPointer)
  , .i_fifoWritePointer     (fifoWritePointer)
  , .i_fifoMem              (fifoMem)
  , .i_trackPort            (trackPort)
  , .i_trackPick            (trackPick)
  );

endmodule

/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNDRIVEN */
`resetall
