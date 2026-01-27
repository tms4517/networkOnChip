// TODO: Summarise module functionality

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

endmodule

`resetall
