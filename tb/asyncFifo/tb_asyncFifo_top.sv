// Testbench top for asyncFifo: exposes the dual-clock FIFO ports directly.

`default_nettype none

module tb_asyncFifo_top
#(parameter int unsigned DATA_W = 32
, parameter int unsigned ADDR_W = 2
)
( input  var logic              i_writeClk
, input  var logic              i_writeArst_n
, input  var logic              i_writeEn
, input  var logic [DATA_W-1:0] i_writeData
, output var logic              o_full

, input  var logic              i_readClk
, input  var logic              i_readArst_n
, input  var logic              i_readEn
, output var logic [DATA_W-1:0] o_readData
, output var logic              o_empty
);

  asyncFifo
  #(.DATA_W (DATA_W)
  , .ADDR_W (ADDR_W)
  ) u_dut
  ( .i_writeClk      (i_writeClk)
  , .i_writeArst_n   (i_writeArst_n)
  , .i_writeEn   (i_writeEn)
  , .i_writeData (i_writeData)
  , .o_full      (o_full)

  , .i_readClk      (i_readClk)
  , .i_readArst_n   (i_readArst_n)
  , .i_readEn    (i_readEn)
  , .o_readData  (o_readData)
  , .o_empty     (o_empty)
  );

endmodule

`resetall
