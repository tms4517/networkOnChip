`default_nettype none

module synchronousFifo
#(parameter int unsigned DATA_W = 8
, parameter int unsigned ADDR_W = 4
)
( input  var logic              i_clk
, input  var logic              i_arst_n
, input  var logic              i_writeEn
, input  var logic              i_readEn
, input  var logic [DATA_W-1:0] i_writeData
, output var logic [DATA_W-1:0] o_readData
, output var logic              o_full
, output var logic              o_empty
);

  // NOTE: The read and write pointer have an extra bit to help with full/empty
  // detection.
  // {{{ Write pointer
  logic [ADDR_W:0] writePointer_q;

  always_ff @(posedge i_clk, negedge i_arst_n)
    if (!i_arst_n)
      writePointer_q <= '0;
    else if (i_writeEn && !o_full)
      writePointer_q <= writePointer_q + 1'b1;
    else
      writePointer_q <= writePointer_q;
  // }}} Write pointer

  // {{{ Read pointer
  logic [ADDR_W:0] readPointer_q;

  always_ff @(posedge i_clk, negedge i_arst_n)
    if (!i_arst_n)
      readPointer_q <= '0;
    else if (i_readEn && !o_empty)
      readPointer_q <= readPointer_q + 1'b1;
    else
      readPointer_q <= readPointer_q;
  // }}} Read pointer

  // {{{ Full/empty logic
  // Full occurs when the two MSBs of the writePointer and readPointer are not
  // equal but the rest of the bits are equal.
  always_comb
    o_full = (writePointer_q == {~readPointer_q[ADDR_W]
                                , readPointer_q [ADDR_W-1:0]
                                });

  // Empty occurs when the read pointer catches up to the write pointer.
  always_comb o_empty = (readPointer_q == writePointer_q);
  // }}} Full/empty logic

  // {{{ FIFO memory
  localparam int unsigned DEPTH = 1 << ADDR_W;
  logic [DATA_W-1:0] mem [DEPTH-1:0];

  always_ff @(posedge i_clk)
    if (i_writeEn && !o_full)
      mem[writePointer_q[ADDR_W-1:0]] <= i_writeData;

  always_comb
    o_readData = mem[readPointer_q[ADDR_W-1:0]];
  // }}} FIFO memory

endmodule

`resetall
