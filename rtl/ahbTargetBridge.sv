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

  pa_noc::ty_PROTOCOL opcode;

  always_comb
    opcode = pa_noc::ty_PROTOCOL'(i_routerToNi[FAB_PACKET_WIDTH-1 -: PROTOCOL_WIDTH]);

  logic [NI_PACKET_WIDTH-1:0] niReq;

  always_comb
    niReq = i_routerToNi[NI_PACKET_WIDTH-1:0];

  // {{{ Serialisation (one transaction in flight)
  logic               busy_q;
  pa_noc::ty_PROTOCOL activeProto_q;

  logic axiReady, ahbReady, apbReady;
  logic accept;

  always_comb
    o_routerToNiReady = !busy_q
                      && ( (opcode == pa_noc::PROTO_AXI_LITE) ? axiReady
                         : (opcode == pa_noc::PROTO_AHB)      ? ahbReady
                         : (opcode == pa_noc::PROTO_APB)      ? apbReady
                         : 1'b0);

  always_comb
    accept = i_routerToNiValid && o_routerToNiReady;

  logic activeIdle;

  always_comb
    activeIdle = (activeProto_q == pa_noc::PROTO_AXI_LITE) ? axiReady
               : (activeProto_q == pa_noc::PROTO_AHB)      ? ahbReady
               : apbReady;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n) begin
      busy_q        <= 1'b0;
      activeProto_q <= pa_noc::PROTO_AXI_LITE;
    end else if (accept) begin
      busy_q        <= 1'b1;
      activeProto_q <= opcode;
    end else if (busy_q && activeIdle) begin
      busy_q        <= 1'b0;
    end
  // }}} Serialisation

  logic axiReqValid, ahbReqValid, apbReqValid;

  always_comb
    axiReqValid = i_routerToNiValid && !busy_q && (opcode == pa_noc::PROTO_AXI_LITE);

  always_comb
    ahbReqValid = i_routerToNiValid && !busy_q && (opcode == pa_noc::PROTO_AHB);

  always_comb
    apbReqValid = i_routerToNiValid && !busy_q && (opcode == pa_noc::PROTO_APB);

  // {{{ AXI-Lite target + AXI-Lite->AHB bridge
  logic [NI_PACKET_WIDTH-1:0] axi_niToRouter;
  logic                       axi_niToRouterValid;

  logic [31:0] axi_awaddr; logic axi_awvalid, axi_awready;
  logic [31:0] axi_wdata;  logic [3:0] axi_wstrb; logic axi_wvalid, axi_wready;
  logic [1:0]  axi_bresp;  logic axi_bvalid, axi_bready;
  logic [31:0] axi_araddr; logic axi_arvalid, axi_arready;
  logic [31:0] axi_rdata;  logic [1:0] axi_rresp; logic axi_rvalid, axi_rready;

  logic        axiBr_hsel;  logic [31:0] axiBr_haddr; logic axiBr_hwrite;
  logic [2:0]  axiBr_hsize; logic [1:0]  axiBr_htrans; logic [31:0] axiBr_hwdata;

  niAxiLiteTarget
  #(.GRID_WIDTH (GRID_WIDTH), .MY_ROW (MY_ROW), .MY_COL (MY_COL)
  , .PAYLOAD_WIDTH (PAYLOAD_WIDTH))
  u_axiTarget
  ( .i_clk (i_clk), .i_arst_n (i_arst_n)
  , .o_awaddr (axi_awaddr), .o_awvalid (axi_awvalid), .i_awready (axi_awready)
  , .o_wdata (axi_wdata), .o_wstrb (axi_wstrb), .o_wvalid (axi_wvalid), .i_wready (axi_wready)
  , .i_bresp (axi_bresp), .i_bvalid (axi_bvalid), .o_bready (axi_bready)
  , .o_araddr (axi_araddr), .o_arvalid (axi_arvalid), .i_arready (axi_arready)
  , .i_rdata (axi_rdata), .i_rresp (axi_rresp), .i_rvalid (axi_rvalid), .o_rready (axi_rready)
  , .i_routerToNi (niReq), .i_routerToNiValid (axiReqValid), .o_routerToNiReady (axiReady)
  , .o_niToRouter (axi_niToRouter), .o_niToRouterValid (axi_niToRouterValid)
  , .i_niToRouterReady (busy_q && (activeProto_q == pa_noc::PROTO_AXI_LITE) && i_niToRouterReady)
  );

  axiLiteToAhbBridge u_axiBridge
  ( .i_clk (i_clk), .i_arst_n (i_arst_n)
  , .i_awaddr (axi_awaddr), .i_awvalid (axi_awvalid), .o_awready (axi_awready)
  , .i_wdata (axi_wdata), .i_wstrb (axi_wstrb), .i_wvalid (axi_wvalid), .o_wready (axi_wready)
  , .o_bresp (axi_bresp), .o_bvalid (axi_bvalid), .i_bready (axi_bready)
  , .i_araddr (axi_araddr), .i_arvalid (axi_arvalid), .o_arready (axi_arready)
  , .o_rdata (axi_rdata), .o_rresp (axi_rresp), .o_rvalid (axi_rvalid), .i_rready (axi_rready)
  , .o_hsel (axiBr_hsel), .o_haddr (axiBr_haddr), .o_hwrite (axiBr_hwrite)
  , .o_hsize (axiBr_hsize), .o_htrans (axiBr_htrans), .o_hwdata (axiBr_hwdata)
  , .i_hrdata (i_hrdata), .i_hready (i_hready), .i_hresp (i_hresp)
  );
  // }}} AXI-Lite target + bridge

  // {{{ AHB-Lite target (native, no bridge)
  logic [NI_PACKET_WIDTH-1:0] ahb_niToRouter;
  logic                       ahb_niToRouterValid;

  logic        ahbT_hsel;  logic [31:0] ahbT_haddr; logic ahbT_hwrite;
  logic [2:0]  ahbT_hsize; logic [1:0]  ahbT_htrans; logic [31:0] ahbT_hwdata;

  niAhbTarget
  #(.GRID_WIDTH (GRID_WIDTH), .MY_ROW (MY_ROW), .MY_COL (MY_COL)
  , .PAYLOAD_WIDTH (PAYLOAD_WIDTH))
  u_ahbTarget
  ( .i_clk (i_clk), .i_arst_n (i_arst_n)
  , .o_hsel (ahbT_hsel), .o_haddr (ahbT_haddr), .o_hwrite (ahbT_hwrite)
  , .o_hsize (ahbT_hsize), .o_htrans (ahbT_htrans), .o_hwdata (ahbT_hwdata)
  , .i_hrdata (i_hrdata), .i_hready (i_hready), .i_hresp (i_hresp)
  , .i_routerToNi (niReq), .i_routerToNiValid (ahbReqValid), .o_routerToNiReady (ahbReady)
  , .o_niToRouter (ahb_niToRouter), .o_niToRouterValid (ahb_niToRouterValid)
  , .i_niToRouterReady (busy_q && (activeProto_q == pa_noc::PROTO_AHB) && i_niToRouterReady)
  );
  // }}} AHB-Lite target (native, no bridge)

  // {{{ APB target + APB->AHB bridge
  logic [NI_PACKET_WIDTH-1:0] apb_niToRouter;
  logic                       apb_niToRouterValid;

  logic [31:0] apb_paddr, apb_pwdata; logic apb_pwrite;
  logic [3:0]  apb_pstrb; logic apb_psel, apb_penable;
  logic        apb_pready, apb_pslverr; logic [31:0] apb_prdata;

  logic        apbBr_hsel;  logic [31:0] apbBr_haddr; logic apbBr_hwrite;
  logic [2:0]  apbBr_hsize; logic [1:0]  apbBr_htrans; logic [31:0] apbBr_hwdata;

  niApbTarget
  #(.GRID_WIDTH (GRID_WIDTH), .MY_ROW (MY_ROW), .MY_COL (MY_COL)
  , .PAYLOAD_WIDTH (PAYLOAD_WIDTH))
  u_apbTarget
  ( .i_clk (i_clk), .i_arst_n (i_arst_n)
  , .o_paddr (apb_paddr), .o_pwdata (apb_pwdata), .o_pwrite (apb_pwrite)
  , .o_pstrb (apb_pstrb), .o_psel (apb_psel), .o_penable (apb_penable)
  , .i_pready (apb_pready), .i_pslverr (apb_pslverr), .i_prdata (apb_prdata)
  , .i_routerToNi (niReq), .i_routerToNiValid (apbReqValid), .o_routerToNiReady (apbReady)
  , .o_niToRouter (apb_niToRouter), .o_niToRouterValid (apb_niToRouterValid)
  , .i_niToRouterReady (busy_q && (activeProto_q == pa_noc::PROTO_APB) && i_niToRouterReady)
  );

  apbToAhbBridge u_apbBridge
  ( .i_clk (i_clk), .i_arst_n (i_arst_n)
  , .i_paddr (apb_paddr), .i_pwdata (apb_pwdata), .i_pwrite (apb_pwrite)
  , .i_pstrb (apb_pstrb), .i_psel (apb_psel), .i_penable (apb_penable)
  , .o_pready (apb_pready), .o_pslverr (apb_pslverr), .o_prdata (apb_prdata)
  , .o_hsel (apbBr_hsel), .o_haddr (apbBr_haddr), .o_hwrite (apbBr_hwrite)
  , .o_hsize (apbBr_hsize), .o_htrans (apbBr_htrans), .o_hwdata (apbBr_hwdata)
  , .i_hrdata (i_hrdata), .i_hready (i_hready), .i_hresp (i_hresp)
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
