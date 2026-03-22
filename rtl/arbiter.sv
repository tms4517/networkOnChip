// Arbiter between router input FIFOs.
//
// - Uses `roundRobinArbiter` to generate a fair one-hot grant across all
//   FIFOs that currently hold packets.
// - Muxes the granted FIFO payload onto `o_packet` and asserts
//   `o_packetIsValid` when the granted FIFO is non-empty.
// - Asserts `o_fifoReadEn` only when downstream logic indicates the packet was
//   accepted (`i_arbiterReady`), preventing premature FIFO pops.

`default_nettype none

module arbiter
#(localparam int unsigned PACKET_WIDTH    = pa_noc::PACKET_WIDTH
, localparam int unsigned NUM_INPUT_FIFOS = 5
)
( input  var logic                                         i_clk
, input  var logic                                         i_arst_n
, input  var logic [NUM_INPUT_FIFOS-1:0]                   i_fifoHasPacket
, input  var logic [NUM_INPUT_FIFOS-1:0][PACKET_WIDTH-1:0] i_fifoReadData
, input  var logic                                         i_arbiterReady
, output var logic [NUM_INPUT_FIFOS-1:0]                   o_fifoReadEn
, output var logic [PACKET_WIDTH-1:0]                      o_packet
, output var logic                                         o_packetIsValid
);

  logic [NUM_INPUT_FIFOS-1:0] grant;

  roundRobinArbiter
  #(.NUM_CLIENTS (NUM_INPUT_FIFOS)
  ) u_roundRobinArbiter
  ( .i_clk
  , .i_rst_n   (i_arst_n)
  , .i_request (i_fifoHasPacket)
  , .i_ack     (i_arbiterReady && o_packetIsValid)
  , .o_grant   (grant)
  );

  logic [NUM_INPUT_FIFOS-1:0][PACKET_WIDTH-1:0] packetSource;

  for (genvar i = 0; i < NUM_INPUT_FIFOS; i++) begin: genPacketMux
    packetSource[i] = grant[i] ? i_fifoReadData[i] : '0;
  end: genPacketMux

  always_comb
    o_packet = |packetSource;

  always_comb
    o_packetIsValid = |(grant & i_fifoHasPacket);

  always_comb
    o_fifoReadEn = grant & {NUM_INPUT_FIFOS{i_arbiterReady && o_packetIsValid}};

endmodule

`resetall
