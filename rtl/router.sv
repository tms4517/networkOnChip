// This module implements a simple router for a network-on-chip (NoC).
// It receives packets from Network Interfaces (NI) and forward them to
// neighboring routers based on the destination router's coordinates.
// If the packet's destination matches the current router's coordinates,
// it forwards the packet to the local NI.
// The router uses a basic XY routing algorithm to decide which neighbouring
// router to send the packet to next.

`default_nettype none

module router
#(parameter int unsigned GRID_WIDTH = 4
, parameter bit [$clog2(GRID_WIDTH)-1:0] ROUTER_ROW = 0
, parameter bit [$clog2(GRID_WIDTH)-1:0] ROUTER_COL = 0
, localparam int unsigned APB_PACKET_WIDTH = pa_noc::APB_PACKET_WIDTH
)
( input  var logic i_clk
, input  var logic i_arst_n

// To/from network interfaces
, input  var logic [APB_PACKET_WIDTH-1:0] i_apbPacket_data
, input  var logic i_apbPacket_valid
, output var logic o_apbPacket_ready
, output var logic [APB_PACKET_WIDTH-1:0] o_apbPacket_data
, output var logic o_apbPacket_valid
, input  var logic i_apbPacket_ready

  // To/from neighboring routers
, input  var logic [APB_PACKET_WIDTH-1:0] i_north_data
, input  var logic i_north_valid
, output var logic o_north_ready
, input  var logic [APB_PACKET_WIDTH-1:0] i_south_data
, input  var logic i_south_valid
, output var logic o_south_ready
, input  var logic [APB_PACKET_WIDTH-1:0] i_east_data
, input  var logic i_east_valid
, output var logic o_east_ready
, input  var logic [APB_PACKET_WIDTH-1:0] i_west_data
, input  var logic i_west_valid
, output var logic o_west_ready
, output var logic [APB_PACKET_WIDTH-1:0] o_north_data
, output var logic o_north_valid
, input  var logic i_north_ready
, output var logic [APB_PACKET_WIDTH-1:0] o_south_data
, output var logic o_south_valid
, input  var logic i_south_ready
, output var logic [APB_PACKET_WIDTH-1:0] o_east_data
, output var logic o_east_valid
, input  var logic i_east_ready
, output var logic [APB_PACKET_WIDTH-1:0] o_west_data
, output var logic o_west_valid
, input  var logic i_west_ready
);

  // {{{ Input FIFOs
  localparam int unsigned NUM_INPUTS = 5;
  logic [NUM_INPUTS-1:0][APB_PACKET_WIDTH-1:0] fifo_data_out;
  logic [NUM_INPUTS-1:0] fifo_valid_out;
  logic [NUM_INPUTS-1:0] fifo_ready_in;

  // FIFO 0: Network Interface
  fifo #(.WIDTH(APB_PACKET_WIDTH), .DEPTH(4))
  u_fifo_ni (
    .i_clk(i_clk),
    .i_arst_n(i_arst_n),
    .i_data(i_apbPacket_data),
    .i_valid(i_apbPacket_valid),
    .o_ready(o_apbPacket_ready),
    .o_data(fifo_data_out[0]),
    .o_valid(fifo_valid_out[0]),
    .i_ready(fifo_ready_in[0])
  );

  // FIFO 1: North
  fifo #(.WIDTH(APB_PACKET_WIDTH), .DEPTH(4))
  u_fifo_north (
    .i_clk(i_clk),
    .i_arst_n(i_arst_n),
    .i_data(i_north_data),
    .i_valid(i_north_valid),
    .o_ready(o_north_ready),
    .o_data(fifo_data_out[1]),
    .o_valid(fifo_valid_out[1]),
    .i_ready(fifo_ready_in[1])
  );

  // FIFO 2: South
  fifo #(.WIDTH(APB_PACKET_WIDTH), .DEPTH(4))
  u_fifo_south (
    .i_clk(i_clk),
    .i_arst_n(i_arst_n),
    .i_data(i_south_data),
    .i_valid(i_south_valid),
    .o_ready(o_south_ready),
    .o_data(fifo_data_out[2]),
    .o_valid(fifo_valid_out[2]),
    .i_ready(fifo_ready_in[2])
  );

  // FIFO 3: East
  fifo #(.WIDTH(APB_PACKET_WIDTH), .DEPTH(4))
  u_fifo_east (
    .i_clk(i_clk),
    .i_arst_n(i_arst_n),
    .i_data(i_east_data),
    .i_valid(i_east_valid),
    .o_ready(o_east_ready),
    .o_data(fifo_data_out[3]),
    .o_valid(fifo_valid_out[3]),
    .i_ready(fifo_ready_in[3])
  );

  // FIFO 4: West
  fifo #(.WIDTH(APB_PACKET_WIDTH), .DEPTH(4))
  u_fifo_west (
    .i_clk(i_clk),
    .i_arst_n(i_arst_n),
    .i_data(i_west_data),
    .i_valid(i_west_valid),
    .o_ready(o_west_ready),
    .o_data(fifo_data_out[4]),
    .o_valid(fifo_valid_out[4]),
    .i_ready(fifo_ready_in[4])
  );
  // }}} Input FIFOs

  // {{{ Arbiter
  logic [APB_PACKET_WIDTH-1:0] arbiter_data;
  logic arbiter_valid;
  logic arbiter_ready;

  arbiter #(.NUM_INPUTS(NUM_INPUTS), .WIDTH(APB_PACKET_WIDTH))
  u_arbiter (
    .i_clk(i_clk),
    .i_arst_n(i_arst_n),
    .i_data(fifo_data_out),
    .i_valid(fifo_valid_out),
    .o_ready(fifo_ready_in),
    .o_data(arbiter_data),
    .o_valid(arbiter_valid),
    .i_ready(arbiter_ready)
  );
  // }}} Arbiter

  logic [APB_PACKET_WIDTH-1:0] apbPacket;
  assign apbPacket = arbiter_data;

  // {{{ Decode destination coordinates from incoming packet
  localparam int unsigned COORD_WIDTH = $clog2(GRID_WIDTH);
  logic [COORD_WIDTH-1:0] destinationRow, destinationCol;

  always_comb
    destinationRow = apbPacket[3:2];

  always_comb
    destinationCol = apbPacket[1:0];
  // }}} Decode destination coordinates from incoming packet

  // {{{ Router coordinates match destination coordinates
  logic isDestination;

  always_comb
    isDestination = (destinationRow == ROUTER_ROW)
                    && (destinationCol == ROUTER_COL);

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n) begin
      o_apbPacket_data <= '0;
      o_apbPacket_valid <= 1'b0;
    end
    else begin
      o_apbPacket_data <= isDestination ? apbPacket : '0;
      o_apbPacket_valid <= isDestination && arbiter_valid;
    end

  assign arbiter_ready = isDestination ? i_apbPacket_ready : 1'b0;
  // }}} Router coordinates match destination coordinates

  // {{{ Forward packets to neighboring routers
  // The packet moves horizontally until it reaches the correct column, then
  // moves vertically to the correct row.
  logic [APB_PACKET_WIDTH-1:0] eastPacket, westPacket, northPacket, southPacket;
  logic eastValid, westValid, northValid, southValid;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n) begin
      o_east_data <= '0;
      o_east_valid <= 1'b0;
    end
    else begin
      o_east_data <= eastPacket;
      o_east_valid <= eastValid && arbiter_valid;
    end

  always_comb
    eastPacket = &{!isDestination
                  , destinationCol > ROUTER_COL
                  } ? apbPacket : '0;

  always_comb
    eastValid = &{!isDestination
                , destinationCol > ROUTER_COL
                };

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n) begin
      o_west_data <= '0;
      o_west_valid <= 1'b0;
    end
    else begin
      o_west_data <= westPacket;
      o_west_valid <= westValid && arbiter_valid;
    end

  always_comb
    westPacket = &{!isDestination
                  , destinationCol < ROUTER_COL
                  } ? apbPacket : '0;

  always_comb
    westValid = &{!isDestination
               , destinationCol < ROUTER_COL
               };

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n) begin
      o_south_data <= '0;
      o_south_valid <= 1'b0;
    end
    else begin
      o_south_data <= southPacket;
      o_south_valid <= southValid && arbiter_valid;
    end

  always_comb
    southPacket = &{!isDestination
                  , destinationCol == ROUTER_COL
                  , destinationRow > ROUTER_ROW
                  } ? apbPacket : '0;

  always_comb
    southValid = &{!isDestination
                , destinationCol == ROUTER_COL
                , destinationRow > ROUTER_ROW
                };

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n) begin
      o_north_data <= '0;
      o_north_valid <= 1'b0;
    end
    else begin
      o_north_data <= northPacket;
      o_north_valid <= northValid && arbiter_valid;
    end

  always_comb
    northPacket = &{!isDestination
                  , destinationCol == ROUTER_COL
                  , destinationRow < ROUTER_ROW
                  } ? apbPacket : '0;

  always_comb
    northValid = &{!isDestination
               , destinationCol == ROUTER_COL
               , destinationRow < ROUTER_ROW
               };

  // Backpressure: router is ready only when output path is available
  assign arbiter_ready = (eastValid && i_east_ready) || (westValid && i_west_ready) ||
                         (northValid && i_north_ready) || (southValid && i_south_ready) ||
                         isDestination ? i_apbPacket_ready : 1'b0;
  // }}} Forward packets to neighboring routers

endmodule

`resetall
