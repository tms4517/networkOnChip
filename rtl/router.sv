// This module implements a simple router for a network-on-chip (NoC).

// It receives packets from a Network Interface (NI) and neighboring routers
// if their respective `i_<>Valid` signal is asserted and stores them in FIFOs.
// The `fifoHasPacket[x]` signal is asserted to indicate to an arbiter that
// the FIFO has received a packet.

// The arbiter selects one of the input FIFOs that has a packet following a
// round-robin scheme and outputs the selected packet, a `packetIsValid` signal
// and asserts the corresponding `fifoReadEn` signal to pop the FIFO.

// The router decodes the packets' destination coordinates and forwards it to a
// neighboring router based on a basic XY routing algorithm.
// If the packet's destination matches the current router's coordinates,
// it forwards the packet to the local NI.

// The forwarding is done by asserting the corresponding `o_<>Valid` signal and
// placing the packet on the `o_<>` bus. A handshake occurs when the
// corresponding `i_<>Ready` signal from the neighboring router or NI is also
// asserted.

// When a packet is forwarded the arbiter is informed via the `packetForwarded`
// signal so it can select the next packet to forward.

`default_nettype none

module router
  import pa_noc::*;
#(parameter int unsigned GRID_WIDTH = 4
, parameter int unsigned FIFO_ADDRESS_WIDTH = 2
, parameter bit [$clog2(GRID_WIDTH)-1:0] ROUTER_ROW = 0
, parameter bit [$clog2(GRID_WIDTH)-1:0] ROUTER_COL = 0
)
( input  var logic i_clk
, input  var logic i_arst_n

// From network interface
, input  var logic [PACKET_WIDTH-1:0] i_ni
, input  var logic                    i_niValid
, output var logic                    o_niReady

// To network interface
, output var logic [PACKET_WIDTH-1:0] o_ni
, output var logic                    o_niValid
, input  var logic                    i_niReady

// From North neighbouring router
, input  var logic [PACKET_WIDTH-1:0] i_north
, input  var logic                    i_northValid
, output var logic                    o_northReady

// From South neighbouring router
, input  var logic [PACKET_WIDTH-1:0] i_south
, input  var logic                    i_southValid
, output var logic                    o_southReady

// From East neighbouring router
, input  var logic [PACKET_WIDTH-1:0] i_east
, input  var logic                    i_eastValid
, output var logic                    o_eastReady

// From West neighbouring router
, input  var logic [PACKET_WIDTH-1:0] i_west
, input  var logic                    i_westValid
, output var logic                    o_westReady

// To North neighbouring router
, output var logic [PACKET_WIDTH-1:0] o_north
, output var logic                    o_northValid
, input  var logic                    i_northReady

// To South neighbouring router
, output var logic [PACKET_WIDTH-1:0] o_south
, output var logic                    o_southValid
, input  var logic                    i_southReady

// To East neighbouring router
, output var logic [PACKET_WIDTH-1:0] o_east
, output var logic                    o_eastValid
, input  var logic                    i_eastReady

// To West neighbouring router
, output var logic [PACKET_WIDTH-1:0] o_west
, output var logic                    o_westValid
, input  var logic                    i_westReady
);

  // {{{ Buffer inputs
  // If the FIFO is not full, it asserts the `o_<>Ready` signal to indicate it
  // can accept incoming packets. A handshake occurs and the FIFO stores the
  // packet when both `i_<>Valid` and `o_<>Ready` are asserted.

  // FIFO to buffer incoming packets from NI
  logic niFifoEmpty;
  logic niFifoFull;
  logic niFifoHasPacket;
  logic niFifoReadEn;
  logic [PACKET_WIDTH-1:0] niPacketFromFifo;

  always_comb
    niFifoHasPacket = !niFifoEmpty;

  // FIFO has a memory region to store incoming packets from NI.
  always_comb
    o_niReady = !niFifoFull;

  synchronousFifo
  #(.DATA_W (PACKET_WIDTH)
  , .ADDR_W (FIFO_ADDRESS_WIDTH)
  ) u_niFifo
  ( .i_clk
  , .i_arst_n
  , .i_writeEn   (i_niValid)
  , .i_readEn    (niFifoReadEn)
  , .i_writeData (i_ni)
  , .o_readData  (niPacketFromFifo)
  , .o_full      (niFifoFull)
  , .o_empty     (niFifoEmpty)
  );

  // FIFO to buffer incoming packets from North neighbouring router
  logic northFifoEmpty;
  logic northFifoFull;
  logic northFifoHasPacket;
  logic northFifoReadEn;
  logic [PACKET_WIDTH-1:0] northPacketFromFifo;

  always_comb
    northFifoHasPacket = !northFifoEmpty;

  always_comb
    o_northReady = !northFifoFull;

  synchronousFifo
  #(.DATA_W (PACKET_WIDTH)
  , .ADDR_W (FIFO_ADDRESS_WIDTH)
  ) u_northFifo
  ( .i_clk
  , .i_arst_n
  , .i_writeEn   (i_northValid)
  , .i_readEn    (northFifoReadEn)
  , .i_writeData (i_north)
  , .o_readData  (northPacketFromFifo)
  , .o_full      (northFifoFull)
  , .o_empty     (northFifoEmpty)
  );

  // FIFO to buffer incoming packets from South neighbouring router
  logic southFifoEmpty;
  logic southFifoFull;
  logic southFifoHasPacket;
  logic southFifoReadEn;
  logic [PACKET_WIDTH-1:0] southPacketFromFifo;

  always_comb
    southFifoHasPacket = !southFifoEmpty;

  always_comb
    o_southReady = !southFifoFull;

  synchronousFifo
  #(.DATA_W (PACKET_WIDTH)
  , .ADDR_W (FIFO_ADDRESS_WIDTH)
  ) u_southFifo
  ( .i_clk
  , .i_arst_n
  , .i_writeEn   (i_southValid)
  , .i_readEn    (southFifoReadEn)
  , .i_writeData (i_south)
  , .o_readData  (southPacketFromFifo)
  , .o_full      (southFifoFull)
  , .o_empty     (southFifoEmpty)
  );

  // FIFO to buffer incoming packets from East neighbouring router
  logic eastFifoEmpty;
  logic eastFifoFull;
  logic eastFifoHasPacket;
  logic eastFifoReadEn;
  logic [PACKET_WIDTH-1:0] eastPacketFromFifo;

  always_comb
    eastFifoHasPacket = !eastFifoEmpty;

  always_comb
    o_eastReady = !eastFifoFull;

  synchronousFifo
  #(.DATA_W (PACKET_WIDTH)
  , .ADDR_W (FIFO_ADDRESS_WIDTH)
  ) u_eastFifo
  ( .i_clk
  , .i_arst_n
  , .i_writeEn   (i_eastValid)
  , .i_readEn    (eastFifoReadEn)
  , .i_writeData (i_east)
  , .o_readData  (eastPacketFromFifo)
  , .o_full      (eastFifoFull)
  , .o_empty     (eastFifoEmpty)
  );

  // FIFO to buffer incoming packets from West neighbouring router
  logic westFifoEmpty;
  logic westFifoFull;
  logic westFifoHasPacket;
  logic westFifoReadEn;
  logic [PACKET_WIDTH-1:0] westPacketFromFifo;

  always_comb
    westFifoHasPacket = !westFifoEmpty;

  always_comb
    o_westReady = !westFifoFull;

  synchronousFifo
  #(.DATA_W (PACKET_WIDTH)
  , .ADDR_W (FIFO_ADDRESS_WIDTH)
  ) u_westFifo
  ( .i_clk
  , .i_arst_n
  , .i_writeEn   (i_westValid)
  , .i_readEn    (westFifoReadEn)
  , .i_writeData (i_west)
  , .o_readData  (westPacketFromFifo)
  , .o_full      (westFifoFull)
  , .o_empty     (westFifoEmpty)
  );
  // }}} Buffer inputs

  // {{{ Arbitrate between input FIFOs
  logic                                         packetForwarded;
  logic                                         packetIsValid;
  logic [PACKET_WIDTH-1:0]                      packet;
  logic [NUM_INPUT_FIFOS-1:0]                   fifoHasPacket;
  logic [NUM_INPUT_FIFOS-1:0]                   fifoReadEn;
  logic [NUM_INPUT_FIFOS-1:0][PACKET_WIDTH-1:0] fifoReadData;

  always_comb begin
    fifoHasPacket[NI] = niFifoHasPacket;
    fifoHasPacket[NORTH] = northFifoHasPacket;
    fifoHasPacket[SOUTH] = southFifoHasPacket;
    fifoHasPacket[EAST] = eastFifoHasPacket;
    fifoHasPacket[WEST] = westFifoHasPacket;
  end

  always_comb begin
    fifoReadData[NI]    = niPacketFromFifo;
    fifoReadData[NORTH] = northPacketFromFifo;
    fifoReadData[SOUTH] = southPacketFromFifo;
    fifoReadData[EAST]  = eastPacketFromFifo;
    fifoReadData[WEST]  = westPacketFromFifo;
  end

  always_comb
    niFifoReadEn    = fifoReadEn[NI];

  always_comb
    northFifoReadEn = fifoReadEn[NORTH];

  always_comb
    southFifoReadEn = fifoReadEn[SOUTH];

  always_comb
    eastFifoReadEn  = fifoReadEn[EAST];

  always_comb
    westFifoReadEn  = fifoReadEn[WEST];

  arbiter u_arbiter
  ( .i_clk
  , .i_arst_n
  , .i_fifoHasPacket (fifoHasPacket)
  , .i_fifoReadData  (fifoReadData)
  , .i_arbiterReady  (packetForwarded)
  , .o_fifoReadEn    (fifoReadEn)
  , .o_packet        (packet)
  , .o_packetIsValid (packetIsValid)
  );
  // }}} Arbitrate between input FIFOs

  // {{{ Decode destination coordinates from incoming packet
  localparam int unsigned COORD_WIDTH = $clog2(GRID_WIDTH);
  logic [COORD_WIDTH-1:0] destinationRow, destinationCol;

  always_comb
    destinationRow = packet[3:2];

  always_comb
    destinationCol = packet[1:0];
  // }}} Decode destination coordinates from incoming packet

  // {{{ Router coordinates match destination coordinates
  logic isDestination;
  logic niValid;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      o_ni <= '0;
    else
      o_ni <= niValid ? packet : '0;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      o_niValid <= '0;
    else
      o_niValid <= niValid;

  always_comb
    isDestination = (destinationRow == ROUTER_ROW)
                    && (destinationCol == ROUTER_COL);

  always_comb
    niValid = isDestination && packetIsValid;
  // }}} Router coordinates match destination coordinates

  // {{{ Forward packets to neighboring routers
  // The packet moves horizontally until it reaches the correct column, then
  // moves vertically to the correct row.
  logic [PACKET_WIDTH-1:0] eastPacket, westPacket, northPacket, southPacket;
  logic                    eastValid, westValid, northValid, southValid;

  // {{{ East output
  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      o_east <= '0;
    else
      o_east <= eastPacket;

  always_comb
    eastPacket = eastValid ? packet : '0;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      o_eastValid <= '0;
    else
      o_eastValid <= eastValid;

  // For edge routers at max column (GRID_WIDTH-1), comparison is always false
  // (optimized away by synthesis).
  /* verilator lint_off CMPCONST */
  always_comb
    eastValid = &{!isDestination
                , packetIsValid
                , destinationCol > ROUTER_COL
                };
  /* verilator lint_on CMPCONST */
  // }}} East output

  // {{{ West output
  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      o_west <= '0;
    else
      o_west <= westPacket;

  always_comb
    westPacket = westValid ? packet : '0;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      o_westValid <= '0;
    else
      o_westValid <= westValid;

  // For edge routers at column 0, comparison is always false
  // (optimized away by synthesis).
  /* verilator lint_off UNSIGNED */
  always_comb
    westValid = &{!isDestination
                , packetIsValid
                , destinationCol < ROUTER_COL
                };
  /* verilator lint_on UNSIGNED */
  // }}} West output

  // {{{ South output
  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      o_south <= '0;
    else
      o_south <= southPacket;

  always_comb
    southPacket = southValid ? packet : '0;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      o_southValid <= '0;
    else
      o_southValid <= southValid;

  // For edge routers at max row (GRID_WIDTH-1), comparison is always false
  // (optimized away by synthesis).
  /* verilator lint_off CMPCONST */
  always_comb
    southValid =  &{!isDestination
                  , packetIsValid
                  , destinationCol == ROUTER_COL
                  , destinationRow > ROUTER_ROW
                  };
  /* verilator lint_on CMPCONST */
  // }}} South output

  // {{{ North output
  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      o_north <= '0;
    else
      o_north <= northPacket;

  always_comb
    northPacket = northValid ? packet : '0;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      o_northValid <= '0;
    else
      o_northValid <= northValid;

  // For edge routers at row 0, comparison is always false
  // (optimized away by synthesis).
  /* verilator lint_off UNSIGNED */
  always_comb
    northValid = &{!isDestination
                  , packetIsValid
                  , destinationCol == ROUTER_COL
                  , destinationRow < ROUTER_ROW
                  };
  /* verilator lint_on UNSIGNED */
  // }}} North output

  always_comb
    packetForwarded = |{eastValid && i_eastReady
                      , westValid && i_westReady
                      , northValid && i_northReady
                      , southValid && i_southReady
                      , isDestination && i_niReady
                      };
  // }}} Forward packets to neighboring routers

endmodule

`resetall
