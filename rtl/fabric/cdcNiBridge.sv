// NI clock-domain-crossing bridge.
//
// Sits on a single NI leg between a network interface (running in its own clock
// domain) and the fabric NI port (running in the fabric clock domain).  Two
// asynchronous FIFOs carry the two packet streams:
//
//   ingress (NI -> fabric): written in the NI domain, read in the fabric domain.
//   egress  (fabric -> NI): written in the fabric domain, read in the NI domain.
//
// The ready/valid handshake maps directly onto the FIFO flags: ready is the
// negation of the destination-side full flag and valid is the negation of the
// source-side empty flag.  Each FIFO gates its own write/read internally, so the
// raw valid/ready lines can drive the enables.
//
// When multiple NIs share one router via niRouterPort, instantiate one bridge
// per NI on niRouterPort's local-NI-side ports; niRouterPort and the router then
// stay entirely in the fabric clock domain while every NI keeps an independent
// frequency.

`default_nettype none

module cdcNiBridge
#(parameter int unsigned PACKET_WIDTH    = 77
, parameter int unsigned FIFO_ADDR_WIDTH = pa_noc::FIFO_ADDRESS_W
)
( // NI clock domain.
  input  var logic i_niClk
, input  var logic i_niArst_n
  // Fabric clock domain.
, input  var logic i_fabClk
, input  var logic i_fabArst_n

  // NI side (NI clock domain).
, input  var logic [PACKET_WIDTH-1:0] i_niToRouter
, input  var logic                    i_niToRouterValid
, output var logic                    o_niToRouterReady
, output var logic [PACKET_WIDTH-1:0] o_routerToNi
, output var logic                    o_routerToNiValid
, input  var logic                    i_routerToNiReady

  // Fabric side (fabric clock domain) — connects to a router/niRouterPort NI slot.
, output var logic [PACKET_WIDTH-1:0] o_niToRouterFab
, output var logic                    o_niToRouterValidFab
, input  var logic                    i_niToRouterReadyFab
, input  var logic [PACKET_WIDTH-1:0] i_routerToNiFab
, input  var logic                    i_routerToNiValidFab
, output var logic                    o_routerToNiReadyFab
);

  // {{{ Ingress (NI -> fabric)
  logic ingressFull, ingressEmpty;

  asyncFifo
  #(.DATA_W (PACKET_WIDTH)
  , .ADDR_W (FIFO_ADDR_WIDTH)
  ) u_ingressFifo
  ( .i_writeClk      (i_niClk)
  , .i_writeArst_n   (i_niArst_n)
  , .i_writeEn   (i_niToRouterValid)
  , .i_writeData (i_niToRouter)
  , .o_full      (ingressFull)

  , .i_readClk      (i_fabClk)
  , .i_readArst_n   (i_fabArst_n)
  , .i_readEn    (i_niToRouterReadyFab)
  , .o_readData  (o_niToRouterFab)
  , .o_empty     (ingressEmpty)
  );

  always_comb o_niToRouterReady    = !ingressFull;
  always_comb o_niToRouterValidFab = !ingressEmpty;
  // }}} Ingress

  // {{{ Egress (fabric -> NI)
  logic egressFull, egressEmpty;

  asyncFifo
  #(.DATA_W (PACKET_WIDTH)
  , .ADDR_W (FIFO_ADDR_WIDTH)
  ) u_egressFifo
  ( .i_writeClk      (i_fabClk)
  , .i_writeArst_n   (i_fabArst_n)
  , .i_writeEn   (i_routerToNiValidFab)
  , .i_writeData (i_routerToNiFab)
  , .o_full      (egressFull)

  , .i_readClk      (i_niClk)
  , .i_readArst_n   (i_niArst_n)
  , .i_readEn    (i_routerToNiReady)
  , .o_readData  (o_routerToNi)
  , .o_empty     (egressEmpty)
  );

  always_comb o_routerToNiReadyFab = !egressFull;
  always_comb o_routerToNiValid    = !egressEmpty;
  // }}} Egress

endmodule

`resetall
