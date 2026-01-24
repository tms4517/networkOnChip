// Simple synchronous FIFO with valid/ready handshaking
`default_nettype none

module fifo
#(parameter int unsigned WIDTH = 73
, parameter int unsigned DEPTH = 4
, localparam int unsigned ADDR_WIDTH = $clog2(DEPTH)
)
( input  var logic i_clk
, input  var logic i_arst_n

// Write port
, input  var logic [WIDTH-1:0] i_data
, input  var logic i_valid
, output var logic o_ready

// Read port
, output var logic [WIDTH-1:0] o_data
, output var logic o_valid
, input  var logic i_ready
);

  logic [WIDTH-1:0] mem [DEPTH];
  logic [ADDR_WIDTH:0] wr_ptr, rd_ptr;
  logic empty, full;

  // Empty when write and read pointers match
  assign empty = (wr_ptr == rd_ptr);

  // Full when MSBs differ but lower bits match
  assign full = (wr_ptr[ADDR_WIDTH] != rd_ptr[ADDR_WIDTH])
              && (wr_ptr[ADDR_WIDTH-1:0] == rd_ptr[ADDR_WIDTH-1:0]);

  assign o_ready = ~full;
  assign o_valid = ~empty;
  assign o_data = mem[rd_ptr[ADDR_WIDTH-1:0]];

  // Write logic
  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      wr_ptr <= '0;
    else if (i_valid && o_ready)
      wr_ptr <= wr_ptr + 1;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      mem <= '{default: '0};
    else if (i_valid && o_ready)
      mem[wr_ptr[ADDR_WIDTH-1:0]] <= i_data;

  // Read logic
  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      rd_ptr <= '0;
    else if (o_valid && i_ready)
      rd_ptr <= rd_ptr + 1;

endmodule

`resetall
