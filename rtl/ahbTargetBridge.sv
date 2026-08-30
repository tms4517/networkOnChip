// AHB-Lite peripheral target wrapper with per-initiator-protocol bridges.
//
// A target node for an AHB-Lite peripheral reachable by AXI4-Lite, AHB-Lite and
// APB initiators.  Each incoming NoC packet carries the initiator protocol
// opcode (top PROTOCOL_WIDTH bits, above the payload).  This wrapper decodes the
// opcode, demuxes the packet to the matching per-protocol target NI (stripping
// the opcode), converts that NI's native bus to AHB via the corresponding bridge
// (AXI-Lite/APB) or directly (AHB), and muxes the active source onto the single
// AHB peripheral bus.  One transaction is served at a time (busy flag).

`default_nettype none

module ahbTargetBridge
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

  // AHB-Lite peripheral interface (this module is the manager)
, output var logic        o_hsel
, output var logic [31:0] o_haddr
, output var logic        o_hwrite
, output var logic [2:0]  o_hsize
, output var logic [1:0]  o_htrans
, output var logic [31:0] o_hwdata
, input  var logic [31:0] i_hrdata
, input  var logic        i_hready
, input  var logic        i_hresp
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
  // to idle -- after it has driven the AHB bus and, for reads, sent its response.
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

  // {{{ AXI-Lite target + AXI-Lite->AHB bridge
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

  logic [31:0] axi_awaddr, axi_wdata, axi_araddr, axi_rdata;
  logic [3:0]  axi_wstrb;
  logic [1:0]  axi_bresp, axi_rresp;
  logic axi_awvalid, axi_awready, axi_wvalid, axi_wready;
  logic axi_bvalid, axi_bready, axi_arvalid, axi_arready;
  logic axi_rvalid, axi_rready;

  logic [31:0] axiBr_haddr, axiBr_hwdata;
  logic [2:0]  axiBr_hsize;
  logic [1:0]  axiBr_htrans;
  logic        axiBr_hsel, axiBr_hwrite;

  niAxiLiteTarget
  #(.GRID_WIDTH    (GRID_WIDTH)
  , .MY_ROW        (MY_ROW)
  , .MY_COL        (MY_COL)
  , .PAYLOAD_WIDTH (PAYLOAD_WIDTH))
  u_axiTarget
  ( .i_clk    (i_clk)
  , .i_arst_n (i_arst_n)

  , .o_awaddr  (axi_awaddr)
  , .o_awvalid (axi_awvalid)
  , .i_awready (axi_awready)
  , .o_wdata   (axi_wdata)
  , .o_wstrb   (axi_wstrb)
  , .o_wvalid  (axi_wvalid)
  , .i_wready  (axi_wready)
  , .i_bresp   (axi_bresp)
  , .i_bvalid  (axi_bvalid)
  , .o_bready  (axi_bready)
  , .o_araddr  (axi_araddr)
  , .o_arvalid (axi_arvalid)
  , .i_arready (axi_arready)
  , .i_rdata   (axi_rdata)
  , .i_rresp   (axi_rresp)
  , .i_rvalid  (axi_rvalid)
  , .o_rready  (axi_rready)

  , .i_routerToNi      (niReq)
  , .i_routerToNiValid (axiReqValid)
  , .o_routerToNiReady (axiReady)
  , .o_niToRouter      (axi_niToRouter)
  , .o_niToRouterValid (axi_niToRouterValid)
  , .i_niToRouterReady (axi_niToRouterReady)
  );

  axiLiteToAhbBridge u_axiBridge
  ( .i_clk    (i_clk)
  , .i_arst_n (i_arst_n)

  , .i_awaddr  (axi_awaddr)
  , .i_awvalid (axi_awvalid)
  , .o_awready (axi_awready)
  , .i_wdata   (axi_wdata)
  , .i_wstrb   (axi_wstrb)
  , .i_wvalid  (axi_wvalid)
  , .o_wready  (axi_wready)
  , .o_bresp   (axi_bresp)
  , .o_bvalid  (axi_bvalid)
  , .i_bready  (axi_bready)
  , .i_araddr  (axi_araddr)
  , .i_arvalid (axi_arvalid)
  , .o_arready (axi_arready)
  , .o_rdata   (axi_rdata)
  , .o_rresp   (axi_rresp)
  , .o_rvalid  (axi_rvalid)
  , .i_rready  (axi_rready)
  , .o_hsel    (axiBr_hsel)
  , .o_haddr   (axiBr_haddr)
  , .o_hwrite  (axiBr_hwrite)
  , .o_hsize   (axiBr_hsize)
  , .o_htrans  (axiBr_htrans)
  , .o_hwdata  (axiBr_hwdata)
  , .i_hrdata  (i_hrdata)
  , .i_hready  (i_hready)
  , .i_hresp   (i_hresp)
  );
  // }}} AXI-Lite target + bridge

  // {{{ AHB-Lite target (native, no bridge)
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

  logic [31:0] ahbT_haddr, ahbT_hwdata;
  logic [2:0]  ahbT_hsize;
  logic [1:0]  ahbT_htrans;
  logic        ahbT_hsel, ahbT_hwrite;

  niAhbTarget
  #(.GRID_WIDTH    (GRID_WIDTH)
  , .MY_ROW        (MY_ROW)
  , .MY_COL        (MY_COL)
  , .PAYLOAD_WIDTH (PAYLOAD_WIDTH))
  u_ahbTarget
  ( .i_clk    (i_clk)
  , .i_arst_n (i_arst_n)

  , .o_hsel   (ahbT_hsel)
  , .o_haddr  (ahbT_haddr)
  , .o_hwrite (ahbT_hwrite)
  , .o_hsize  (ahbT_hsize)
  , .o_htrans (ahbT_htrans)
  , .o_hwdata (ahbT_hwdata)
  , .i_hrdata (i_hrdata)
  , .i_hready (i_hready)
  , .i_hresp  (i_hresp)

  , .i_routerToNi      (niReq)
  , .i_routerToNiValid (ahbReqValid)
  , .o_routerToNiReady (ahbReady)
  , .o_niToRouter      (ahb_niToRouter)
  , .o_niToRouterValid (ahb_niToRouterValid)
  , .i_niToRouterReady (ahb_niToRouterReady)
  );
  // }}} AHB-Lite target (native, no bridge)

  // {{{ APB target + APB->AHB bridge
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

  logic [31:0] apbBr_haddr, apbBr_hwdata;
  logic [2:0]  apbBr_hsize;
  logic [1:0]  apbBr_htrans;
  logic        apbBr_hsel, apbBr_hwrite;

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

  apbToAhbBridge u_apbBridge
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
  , .o_hsel    (apbBr_hsel)
  , .o_haddr   (apbBr_haddr)
  , .o_hwrite  (apbBr_hwrite)
  , .o_hsize   (apbBr_hsize)
  , .o_htrans  (apbBr_htrans)
  , .o_hwdata  (apbBr_hwdata)
  , .i_hrdata  (i_hrdata)
  , .i_hready  (i_hready)
  , .i_hresp   (i_hresp)
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

  // {{{ AHB peripheral bus mux (active source only)
  always_comb
    if (activeProto_q == pa_noc::PROTO_AXI_LITE) begin
      o_hsel   = axiBr_hsel;
      o_haddr  = axiBr_haddr;
      o_hwrite = axiBr_hwrite;
      o_hsize  = axiBr_hsize;
      o_htrans = axiBr_htrans;
      o_hwdata = axiBr_hwdata;
    end else if (activeProto_q == pa_noc::PROTO_AHB) begin
      o_hsel   = ahbT_hsel;
      o_haddr  = ahbT_haddr;
      o_hwrite = ahbT_hwrite;
      o_hsize  = ahbT_hsize;
      o_htrans = ahbT_htrans;
      o_hwdata = ahbT_hwdata;
    end else begin
      o_hsel   = apbBr_hsel;
      o_haddr  = apbBr_haddr;
      o_hwrite = apbBr_hwrite;
      o_hsize  = apbBr_hsize;
      o_htrans = apbBr_htrans;
      o_hwdata = apbBr_hwdata;
    end
  // }}} AHB peripheral bus mux

endmodule

`resetall
