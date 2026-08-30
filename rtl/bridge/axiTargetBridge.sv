// AXI4-Lite peripheral target wrapper with per-initiator-protocol bridges.
//
// A target node for an AXI4-Lite peripheral reachable by AXI4-Lite, AHB-Lite and
// APB initiators.  Each incoming NoC packet carries the initiator protocol
// opcode (top PROTOCOL_WIDTH bits, above the payload).  This wrapper decodes the
// opcode, demuxes the packet to the matching per-protocol target NI (stripping
// the opcode), converts that NI's native bus to AXI via the corresponding bridge
// (AHB/APB) or directly (AXI), and muxes the active source onto the single AXI
// peripheral bus.  One transaction is served at a time (busy flag).

`default_nettype none

module axiTargetBridge
#(parameter int unsigned GRID_WIDTH        = 4
, parameter int unsigned MY_ROW            = 0
, parameter int unsigned MY_COL            = 0
, parameter int unsigned PAYLOAD_WIDTH     = pa_noc::AXI_LITE_PAYLOAD_WIDTH

, localparam int unsigned COORD_WIDTH      = $clog2(GRID_WIDTH)
, localparam int unsigned PROTOCOL_WIDTH   = pa_noc::PROTOCOL_WIDTH
, localparam int unsigned NI_PACKET_WIDTH  = PAYLOAD_WIDTH + (COORD_WIDTH * 4)
, localparam int unsigned FAB_PACKET_WIDTH = NI_PACKET_WIDTH + PROTOCOL_WIDTH
)
( input  var logic i_clk
, input  var logic i_arst_n

  // NoC router NI — router to target (request)
, input  var logic [FAB_PACKET_WIDTH-1:0] i_routerToNi
, input  var logic                        i_routerToNiValid
, output var logic                        o_routerToNiReady

  // NoC router NI — target to router (response)
, output var logic [FAB_PACKET_WIDTH-1:0] o_niToRouter
, output var logic                        o_niToRouterValid
, input  var logic                        i_niToRouterReady

  // AXI4-Lite peripheral interface (this module is the manager)
, output var logic [31:0] o_awaddr
, output var logic        o_awvalid
, input  var logic        i_awready
, output var logic [31:0] o_wdata
, output var logic [3:0]  o_wstrb
, output var logic        o_wvalid
, input  var logic        i_wready
, input  var logic [1:0]  i_bresp
, input  var logic        i_bvalid
, output var logic        o_bready
, output var logic [31:0] o_araddr
, output var logic        o_arvalid
, input  var logic        i_arready
, input  var logic [31:0] i_rdata
, input  var logic [1:0]  i_rresp
, input  var logic        i_rvalid
, output var logic        o_rready
);

  // {{{ Decode opcode
  // Opcode occupies the top PROTOCOL_WIDTH bits; the NI-facing packet is the
  // remaining low bits.
  pa_noc::ty_PROTOCOL opcode;
  logic               opcodeIsAxi, opcodeIsAhb, opcodeIsApb;

  always_comb
    opcode = pa_noc::ty_PROTOCOL'(i_routerToNi[FAB_PACKET_WIDTH-1 -: PROTOCOL_WIDTH]);

  always_comb
    opcodeIsAxi = (opcode == pa_noc::PROTO_AXI_LITE);

  always_comb
    opcodeIsAhb = (opcode == pa_noc::PROTO_AHB);

  always_comb
    opcodeIsApb = (opcode == pa_noc::PROTO_APB);
  // }}} Decode opcode

  logic [NI_PACKET_WIDTH-1:0] niReq;

  always_comb
    niReq = i_routerToNi[NI_PACKET_WIDTH-1:0];

  // {{{ Serialisation (one transaction in flight)
  // The node serves one transaction at a time.  While idle (!busy_q), an
  // incoming packet is accepted only if the target NI selected by its opcode is
  // ready; accepting latches busy_q and the active protocol. While busy,
  // o_routerToNiReady is held low so no further packet is accepted (requests are
  // gated off every target NI), and busy_q clears when the active target returns
  // to idle -- after it has driven the AXI bus and, for reads, sent its response.
  logic               busy_q;
  pa_noc::ty_PROTOCOL activeProto_q;

  // Per-protocol readiness: the addressed target NI matches the opcode and is
  // idle; exactly one is asserted (or none) at a time.
  logic axiReady, ahbReady, apbReady;
  logic axiProtoReady, ahbProtoReady, apbProtoReady, anyProtocolReady;

  always_comb
    axiProtoReady = opcodeIsAxi && axiReady;

  always_comb
    ahbProtoReady = opcodeIsAhb && ahbReady;

  always_comb
    apbProtoReady = opcodeIsApb && apbReady;

  always_comb
    anyProtocolReady = |{axiProtoReady, ahbProtoReady, apbProtoReady};

  always_comb
    o_routerToNiReady = !busy_q && anyProtocolReady;

  logic accept;

  always_comb
    accept = i_routerToNiValid && o_routerToNiReady;

  // Only the active target ever leaves idle, so all-idle == active-target-idle.
  logic activeIdle;

  always_comb
    activeIdle = &{axiReady, ahbReady, apbReady};

  logic               busy_d;
  pa_noc::ty_PROTOCOL activeProto_d;

  always_comb
    if (accept)
      busy_d = 1'b1;
    else if (busy_q && activeIdle)
      busy_d = 1'b0;
    else
      busy_d = busy_q;

  always_comb
    if (accept)
      activeProto_d = opcode;
    else if (busy_q && activeIdle)
      activeProto_d = pa_noc::PROTO_AXI_LITE;
    else
      activeProto_d = activeProto_q;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      busy_q <= 1'b0;
    else
      busy_q <= busy_d;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      activeProto_q <= pa_noc::PROTO_AXI_LITE;
    else
      activeProto_q <= activeProto_d;
  // }}} Serialisation

  // Per-target request valid (only during the accept cycle) and response ready.
  logic axiReqValid, ahbReqValid, apbReqValid;

  always_comb
    axiReqValid = i_routerToNiValid && !busy_q && opcodeIsAxi;

  always_comb
    ahbReqValid = i_routerToNiValid && !busy_q && opcodeIsAhb;

  always_comb
    apbReqValid = i_routerToNiValid && !busy_q && opcodeIsApb;

  // {{{ AXI-Lite target (native, no bridge)
  logic [NI_PACKET_WIDTH-1:0] axi_niToRouter;
  logic                       axi_niToRouterValid;

  // Response-ready is routed to this target NI only while it is the active
  // protocol, so only the active target drives the shared response channel.
  logic axi_niToRouterReady;

  always_comb
    axi_niToRouterReady = &{busy_q
                          , (activeProto_q == pa_noc::PROTO_AXI_LITE)
                          , i_niToRouterReady
                          };

  logic [31:0] axiT_awaddr, axiT_wdata, axiT_araddr;
  logic [3:0]  axiT_wstrb;
  logic        axiT_awvalid, axiT_wvalid, axiT_bready, axiT_arvalid, axiT_rready;

  niAxiLiteTarget
  #(.GRID_WIDTH    (GRID_WIDTH)
  , .MY_ROW        (MY_ROW)
  , .MY_COL        (MY_COL)
  , .PAYLOAD_WIDTH (PAYLOAD_WIDTH))
  u_axiTarget
  ( .i_clk    (i_clk)
  , .i_arst_n (i_arst_n)

  , .o_awaddr  (axiT_awaddr)
  , .o_awvalid (axiT_awvalid)
  , .i_awready (i_awready)
  , .o_wdata   (axiT_wdata)
  , .o_wstrb   (axiT_wstrb)
  , .o_wvalid  (axiT_wvalid)
  , .i_wready  (i_wready)
  , .i_bresp   (i_bresp)
  , .i_bvalid  (i_bvalid)
  , .o_bready  (axiT_bready)
  , .o_araddr  (axiT_araddr)
  , .o_arvalid (axiT_arvalid)
  , .i_arready (i_arready)
  , .i_rdata   (i_rdata)
  , .i_rresp   (i_rresp)
  , .i_rvalid  (i_rvalid)
  , .o_rready  (axiT_rready)

  , .i_routerToNi      (niReq)
  , .i_routerToNiValid (axiReqValid)
  , .o_routerToNiReady (axiReady)
  , .o_niToRouter      (axi_niToRouter)
  , .o_niToRouterValid (axi_niToRouterValid)
  , .i_niToRouterReady (axi_niToRouterReady)
  );
  // }}} AXI-Lite target (native, no bridge)

  // {{{ AHB-Lite target + AHB->AXI-Lite bridge
  logic [NI_PACKET_WIDTH-1:0] ahb_niToRouter;
  logic                       ahb_niToRouterValid;

  // Response-ready is routed to this target NI only while it is the active
  // protocol, so only the active target drives the shared response channel.
  logic ahb_niToRouterReady;

  always_comb
    ahb_niToRouterReady = &{busy_q
                          , (activeProto_q == pa_noc::PROTO_AHB)
                          , i_niToRouterReady
                          };

  logic [31:0] ahb_haddr, ahb_hwdata, ahb_hrdata;
  logic [2:0]  ahb_hsize;
  logic [1:0]  ahb_htrans;
  logic        ahb_hsel, ahb_hwrite, ahb_hready, ahb_hresp;

  logic [31:0] ahbBr_awaddr, ahbBr_wdata, ahbBr_araddr;
  logic [3:0]  ahbBr_wstrb;
  logic        ahbBr_awvalid, ahbBr_wvalid, ahbBr_bready, ahbBr_arvalid, ahbBr_rready;

  niAhbTarget
  #(.GRID_WIDTH    (GRID_WIDTH)
  , .MY_ROW        (MY_ROW)
  , .MY_COL        (MY_COL)
  , .PAYLOAD_WIDTH (PAYLOAD_WIDTH))
  u_ahbTarget
  ( .i_clk    (i_clk)
  , .i_arst_n (i_arst_n)

  , .o_hsel   (ahb_hsel)
  , .o_haddr  (ahb_haddr)
  , .o_hwrite (ahb_hwrite)
  , .o_hsize  (ahb_hsize)
  , .o_htrans (ahb_htrans)
  , .o_hwdata (ahb_hwdata)
  , .i_hrdata (ahb_hrdata)
  , .i_hready (ahb_hready)
  , .i_hresp  (ahb_hresp)

  , .i_routerToNi      (niReq)
  , .i_routerToNiValid (ahbReqValid)
  , .o_routerToNiReady (ahbReady)
  , .o_niToRouter      (ahb_niToRouter)
  , .o_niToRouterValid (ahb_niToRouterValid)
  , .i_niToRouterReady (ahb_niToRouterReady)
  );

  ahbToAxiLiteBridge u_ahbBridge
  ( .i_clk    (i_clk)
  , .i_arst_n (i_arst_n)

  , .i_hsel      (ahb_hsel)
  , .i_haddr     (ahb_haddr)
  , .i_hwrite    (ahb_hwrite)
  , .i_hsize     (ahb_hsize)
  , .i_htrans    (ahb_htrans)
  , .i_hwdata    (ahb_hwdata)
  , .o_hreadyout (ahb_hready)
  , .o_hresp     (ahb_hresp)
  , .o_hrdata    (ahb_hrdata)
  , .o_awaddr    (ahbBr_awaddr)
  , .o_awvalid   (ahbBr_awvalid)
  , .i_awready   (i_awready)
  , .o_wdata     (ahbBr_wdata)
  , .o_wstrb     (ahbBr_wstrb)
  , .o_wvalid    (ahbBr_wvalid)
  , .i_wready    (i_wready)
  , .i_bresp     (i_bresp)
  , .i_bvalid    (i_bvalid)
  , .o_bready    (ahbBr_bready)
  , .o_araddr    (ahbBr_araddr)
  , .o_arvalid   (ahbBr_arvalid)
  , .i_arready   (i_arready)
  , .i_rdata     (i_rdata)
  , .i_rresp     (i_rresp)
  , .i_rvalid    (i_rvalid)
  , .o_rready    (ahbBr_rready)
  );
  // }}} AHB-Lite target + bridge

  // {{{ APB target + APB->AXI-Lite bridge
  logic [NI_PACKET_WIDTH-1:0] apb_niToRouter;
  logic                       apb_niToRouterValid;

  // Response-ready is routed to this target NI only while it is the active
  // protocol, so only the active target drives the shared response channel.
  logic apb_niToRouterReady;

  always_comb
    apb_niToRouterReady = &{busy_q
                          , (activeProto_q == pa_noc::PROTO_APB)
                          , i_niToRouterReady
                          };

  logic [31:0] apb_paddr, apb_pwdata, apb_prdata;
  logic [3:0]  apb_pstrb;
  logic        apb_pwrite, apb_psel, apb_penable, apb_pready, apb_pslverr;

  logic [31:0] apbBr_awaddr, apbBr_wdata, apbBr_araddr;
  logic [3:0]  apbBr_wstrb;
  logic        apbBr_awvalid, apbBr_wvalid, apbBr_bready, apbBr_arvalid, apbBr_rready;

  niApbTarget
  #(.GRID_WIDTH    (GRID_WIDTH)
  , .MY_ROW        (MY_ROW)
  , .MY_COL        (MY_COL)
  , .PAYLOAD_WIDTH (PAYLOAD_WIDTH))
  u_apbTarget
  ( .i_clk    (i_clk)
  , .i_arst_n (i_arst_n)

  , .o_paddr   (apb_paddr)
  , .o_pwdata  (apb_pwdata)
  , .o_pwrite  (apb_pwrite)
  , .o_pstrb   (apb_pstrb)
  , .o_psel    (apb_psel)
  , .o_penable (apb_penable)
  , .i_pready  (apb_pready)
  , .i_pslverr (apb_pslverr)
  , .i_prdata  (apb_prdata)

  , .i_routerToNi      (niReq)
  , .i_routerToNiValid (apbReqValid)
  , .o_routerToNiReady (apbReady)
  , .o_niToRouter      (apb_niToRouter)
  , .o_niToRouterValid (apb_niToRouterValid)
  , .i_niToRouterReady (apb_niToRouterReady)
  );

  apbToAxiLiteBridge u_apbBridge
  ( .i_clk    (i_clk)
  , .i_arst_n (i_arst_n)

  , .i_paddr   (apb_paddr)
  , .i_pwdata  (apb_pwdata)
  , .i_pwrite  (apb_pwrite)
  , .i_pstrb   (apb_pstrb)
  , .i_psel    (apb_psel)
  , .i_penable (apb_penable)
  , .o_pready  (apb_pready)
  , .o_pslverr (apb_pslverr)
  , .o_prdata  (apb_prdata)
  , .o_awaddr  (apbBr_awaddr)
  , .o_awvalid (apbBr_awvalid)
  , .i_awready (i_awready)
  , .o_wdata   (apbBr_wdata)
  , .o_wstrb   (apbBr_wstrb)
  , .o_wvalid  (apbBr_wvalid)
  , .i_wready  (i_wready)
  , .i_bresp   (i_bresp)
  , .i_bvalid  (i_bvalid)
  , .o_bready  (apbBr_bready)
  , .o_araddr  (apbBr_araddr)
  , .o_arvalid (apbBr_arvalid)
  , .i_arready (i_arready)
  , .i_rdata   (i_rdata)
  , .i_rresp   (i_rresp)
  , .i_rvalid  (i_rvalid)
  , .o_rready  (apbBr_rready)
  );
  // }}} APB target + bridge

  // {{{ Response mux (re-tag with the active protocol opcode)
  always_comb
    if (activeProto_q == pa_noc::PROTO_AXI_LITE) begin
      o_niToRouterValid = busy_q && axi_niToRouterValid;
      o_niToRouter      = {activeProto_q, axi_niToRouter};
    end else if (activeProto_q == pa_noc::PROTO_AHB) begin
      o_niToRouterValid = busy_q && ahb_niToRouterValid;
      o_niToRouter      = {activeProto_q, ahb_niToRouter};
    end else begin
      o_niToRouterValid = busy_q && apb_niToRouterValid;
      o_niToRouter      = {activeProto_q, apb_niToRouter};
    end
  // }}} Response mux

  // {{{ AXI peripheral bus mux (active source only)
  always_comb
    if (activeProto_q == pa_noc::PROTO_AXI_LITE) begin
      o_awaddr  = axiT_awaddr;
      o_awvalid = axiT_awvalid;
      o_wdata   = axiT_wdata;
      o_wstrb   = axiT_wstrb;
      o_wvalid = axiT_wvalid;
      o_bready  = axiT_bready;
      o_araddr  = axiT_araddr;
      o_arvalid = axiT_arvalid;
      o_rready  = axiT_rready;
    end else if (activeProto_q == pa_noc::PROTO_AHB) begin
      o_awaddr  = ahbBr_awaddr;
      o_awvalid = ahbBr_awvalid;
      o_wdata   = ahbBr_wdata;
      o_wstrb   = ahbBr_wstrb;
      o_wvalid = ahbBr_wvalid;
      o_bready  = ahbBr_bready;
      o_araddr  = ahbBr_araddr;
      o_arvalid = ahbBr_arvalid;
      o_rready  = ahbBr_rready;
    end else begin
      o_awaddr  = apbBr_awaddr;
      o_awvalid = apbBr_awvalid;
      o_wdata   = apbBr_wdata;
      o_wstrb   = apbBr_wstrb;
      o_wvalid = apbBr_wvalid;
      o_bready  = apbBr_bready;
      o_araddr  = apbBr_araddr;
      o_arvalid = apbBr_arvalid;
      o_rready  = apbBr_rready;
    end
  // }}} AXI peripheral bus mux

endmodule

`resetall
