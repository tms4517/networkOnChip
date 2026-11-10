// Testbench top for cdcNiBridge.
// The fabric side is wired as a combinational loopback (in the fabric clock
// domain) so a packet pushed in on the NI ingress returns on the NI egress
// after crossing both clock boundaries.

`default_nettype none

module tb_cdcNiBridge_top
#(parameter int unsigned PACKET_WIDTH    = 32
, parameter int unsigned FIFO_ADDR_WIDTH = 2
)
( input  var logic i_niClk
, input  var logic i_niArst_n
, input  var logic i_fabClk
, input  var logic i_fabArst_n

, input  var logic [PACKET_WIDTH-1:0] i_niToRouter
, input  var logic                    i_niToRouterValid
, output var logic                    o_niToRouterReady
, output var logic [PACKET_WIDTH-1:0] o_routerToNi
, output var logic                    o_routerToNiValid
, input  var logic                    i_routerToNiReady
);

  // Fabric-domain loopback nets.
  logic [PACKET_WIDTH-1:0] fabData;
  logic                    fabValid;
  logic                    fabReady;

  cdcNiBridge
  #(.PACKET_WIDTH    (PACKET_WIDTH)
  , .FIFO_ADDR_WIDTH (FIFO_ADDR_WIDTH)
  ) u_dut
  ( .i_niClk    (i_niClk)
  , .i_niArst_n (i_niArst_n)
  , .i_fabClk   (i_fabClk)
  , .i_fabArst_n (i_fabArst_n)

  , .i_niToRouter      (i_niToRouter)
  , .i_niToRouterValid (i_niToRouterValid)
  , .o_niToRouterReady (o_niToRouterReady)
  , .o_routerToNi      (o_routerToNi)
  , .o_routerToNiValid (o_routerToNiValid)
  , .i_routerToNiReady (i_routerToNiReady)

  , .o_niToRouterFab      (fabData)
  , .o_niToRouterValidFab (fabValid)
  , .i_niToRouterReadyFab (fabReady)
  , .i_routerToNiFab      (fabData)
  , .i_routerToNiValidFab (fabValid)
  , .o_routerToNiReadyFab (fabReady)
  );

endmodule

`resetall
