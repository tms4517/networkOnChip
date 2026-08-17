// APB peripheral target wrapper with per-initiator-protocol bridges.

// A target node for an APB peripheral that can be reached by AXI4-Lite, AHB-Lite
// and APB initiators.  Each incoming NoC packet carries the initiator protocol
// opcode (top PROTOCOL_WIDTH bits, above the payload). This wrapper decodes the
// opcode, demuxes the packet to the matching per-protocol target NI (stripping
// the opcode), converts that NI's native bus to APB via the corresponding
// bridge (AXI-Lite/AHB) or directly (APB), and muxes the active source onto the
// single APB peripheral bus. One transaction is served at a time (serialised by
// a busy flag).

`default_nettype none

module apbTargetBridge
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

  // APB peripheral interface (this module is the APB master)
, output var logic [31:0] o_paddr
, output var logic [31:0] o_pwdata
, output var logic        o_pwrite
, output var logic [3:0]  o_pstrb
, output var logic        o_psel
, output var logic        o_penable
, input  var logic        i_pready
, input  var logic        i_pslverr
, input  var logic [31:0] i_prdata
);

  // {{{ Decode opcode
  // Opcode occupies the top PROTOCOL_WIDTH bits; the NI-facing packet is the
  // remaining low bits.
  pa_noc::ty_PROTOCOL opcode, opcodeIsAxi, opcodeIsAhb, opcodeIsApb;

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
  // ready; accepting latches busy_q and the active protocol.  While busy,
  // o_routerToNiReady is held low so no further packet is accepted (requests are
  // gated off every target NI), and busy_q clears when the active target returns
  // to idle -- after it has driven the APB bus and, for reads, sent its response.
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

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      busy_q <= 1'b0;
    else if (accept)
      busy_q <= 1'b1;
    else if (busy_q && activeIdle)
      busy_q <= 1'b0;
    else
      busy_q <= busy_q;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      activeProto_q <= pa_noc::PROTO_AXI_LITE;
    else if (accept)
      activeProto_q <= opcode;
    else if (busy_q && activeIdle)
      activeProto_q <= pa_noc::PROTO_AXI_LITE;
    else
      activeProto_q <= activeProto_q;
  // }}} Serialisation

  // Per-target request valid (only during the accept cycle) and response ready.
  logic axiReqValid, ahbReqValid, apbReqValid;

  always_comb
    axiReqValid = i_routerToNiValid && !busy_q && opcodeIsAxi;

  always_comb
    ahbReqValid = i_routerToNiValid && !busy_q && opcodeIsAhb;

  always_comb
    apbReqValid = i_routerToNiValid && !busy_q && opcodeIsApb;

  // {{{ AXI-Lite target + AXI-Lite->APB bridge
  logic [NI_PACKET_WIDTH-1:0] axi_niToRouter;
  logic                       axi_niToRouterValid;

  logic [31:0] axi_awaddr;
  logic axi_awvalid, axi_awready;
  logic [31:0] axi_wdata;
  logic [3:0] axi_wstrb;
  logic axi_wvalid, axi_wready;
  logic [1:0]  axi_bresp;
  logic axi_bvalid, axi_bready;
  logic [31:0] axi_araddr;
  logic axi_arvalid, axi_arready;
  logic [31:0] axi_rdata;
  logic [1:0] axi_rresp;
  logic axi_rvalid, axi_rready;

  logic [31:0] axiBr_paddr, axiBr_pwdata;
  logic axiBr_pwrite;
  logic [3:0]  axiBr_pstrb;
  logic axiBr_psel, axiBr_penable;

  axiLiteToApbBridge u_axiBridge
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
  , .o_paddr   (axiBr_paddr)
  , .o_pwdata  (axiBr_pwdata)
  , .o_pwrite  (axiBr_pwrite)
  , .o_pstrb   (axiBr_pstrb)
  , .o_psel    (axiBr_psel)
  , .o_penable (axiBr_penable)
  , .i_pready  (i_pready)
  , .i_pslverr (i_pslverr)
  , .i_prdata  (i_prdata)
  );

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
  , .i_niToRouterReady (busy_q && (activeProto_q == pa_noc::PROTO_AXI_LITE) && i_niToRouterReady)
  );
  // }}} AXI-Lite target + bridge

  // {{{ AHB-Lite target + AHB-Lite->APB bridge
  logic [NI_PACKET_WIDTH-1:0] ahb_niToRouter;
  logic                       ahb_niToRouterValid;

  logic        ahb_hsel;
  logic [31:0] ahb_haddr;
  logic ahb_hwrite;
  logic [2:0]  ahb_hsize;
  logic [1:0]  ahb_htrans;
  logic [31:0] ahb_hwdata;
  logic [31:0] ahb_hrdata;
  logic ahb_hready, ahb_hresp;

  logic [31:0] ahbBr_paddr, ahbBr_pwdata;
  logic ahbBr_pwrite;
  logic [3:0]  ahbBr_pstrb;
  logic ahbBr_psel, ahbBr_penable;

  ahbToApbBridge u_ahbBridge
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
  , .o_paddr     (ahbBr_paddr)
  , .o_pwdata    (ahbBr_pwdata)
  , .o_pwrite    (ahbBr_pwrite)
  , .o_pstrb     (ahbBr_pstrb)
  , .o_psel      (ahbBr_psel)
  , .o_penable   (ahbBr_penable)
  , .i_pready    (i_pready)
  , .i_pslverr   (i_pslverr)
  , .i_prdata    (i_prdata)
  );

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

  , .i_routerToNi (niReq)
  , .i_routerToNiValid (ahbReqValid)
  , .o_routerToNiReady (ahbReady)
  , .o_niToRouter (ahb_niToRouter)
  , .o_niToRouterValid (ahb_niToRouterValid)
  , .i_niToRouterReady (busy_q && (activeProto_q == pa_noc::PROTO_AHB) && i_niToRouterReady)
  );
  // }}} AHB-Lite target + bridge

  // {{{ APB target (native, no bridge)
  logic [NI_PACKET_WIDTH-1:0] apb_niToRouter;
  logic                       apb_niToRouterValid;

  logic [31:0] apbT_paddr, apbT_pwdata;
  logic apbT_pwrite;
  logic [3:0]  apbT_pstrb;
  logic apbT_psel, apbT_penable;

  niApbTarget
  #(.GRID_WIDTH (GRID_WIDTH)
  , .MY_ROW     (MY_ROW)
  , .MY_COL     (MY_COL)
  , .PAYLOAD_WIDTH (PAYLOAD_WIDTH))
  u_apbTarget
  ( .i_clk    (i_clk)
  , .i_arst_n (i_arst_n)

  , .o_paddr   (apbT_paddr)
  , .o_pwdata  (apbT_pwdata)
  , .o_pwrite  (apbT_pwrite)
  , .o_pstrb   (apbT_pstrb)
  , .o_psel    (apbT_psel)
  , .o_penable (apbT_penable)
  , .i_pready  (i_pready)
  , .i_pslverr (i_pslverr)
  , .i_prdata  (i_prdata)

  , .i_routerToNi      (niReq)
  , .i_routerToNiValid (apbReqValid)
  , .o_routerToNiReady (apbReady)
  , .o_niToRouter      (apb_niToRouter)
  , .o_niToRouterValid (apb_niToRouterValid)
  , .i_niToRouterReady (busy_q && (activeProto_q == pa_noc::PROTO_APB) && i_niToRouterReady)
  );
  // }}} APB target (native, no bridge)

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

  // {{{ APB peripheral bus mux (active source only)
  always_comb
    if (activeProto_q == pa_noc::PROTO_AXI_LITE) begin
      o_paddr   = axiBr_paddr;
      o_pwdata  = axiBr_pwdata;
      o_pwrite  = axiBr_pwrite;
      o_pstrb   = axiBr_pstrb;
      o_psel    = axiBr_psel;
      o_penable = axiBr_penable;
    end else if (activeProto_q == pa_noc::PROTO_AHB) begin
      o_paddr   = ahbBr_paddr;
      o_pwdata  = ahbBr_pwdata;
      o_pwrite  = ahbBr_pwrite;
      o_pstrb   = ahbBr_pstrb;
      o_psel    = ahbBr_psel;
      o_penable = ahbBr_penable;
    end else begin
      o_paddr   = apbT_paddr;
      o_pwdata  = apbT_pwdata;
      o_pwrite  = apbT_pwrite;
      o_pstrb   = apbT_pstrb;
      o_psel    = apbT_psel;
      o_penable = apbT_penable;
    end
  // }}} APB peripheral bus mux

endmodule

`resetall
