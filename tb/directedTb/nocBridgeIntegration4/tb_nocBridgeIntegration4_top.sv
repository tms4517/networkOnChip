// Integration testbench: mixed protocols with two NIs per router.
//
// Two initiators of different protocols share one router, and two bridged
// targets of different peripheral protocols share another router.  Each shared
// router port uses niRouterPort (round-robin ingress, NI-ID egress demux).
// Requests are tagged with the initiator protocol opcode above the payload.
//
//   Router (INIT_ROW,INIT_COL): CPU (AXI4-Lite) NI_ID 0, DMA (AHB-Lite) NI_ID 1
//   Router (TGT_ROW ,TGT_COL ): apbTargetBridge NI_ID 0, ahbTargetBridge NI_ID 1
//
// Address map (both initiators):
//   0x0000_0000 - 0x0FFF_FFFF -> APB peripheral (NI_ID 0)
//   0x1000_0000 - 0x1FFF_FFFF -> AHB peripheral (NI_ID 1)

`default_nettype none

module tb_nocBridgeIntegration4_top
#(parameter int unsigned GRID_WIDTH        = 4
, parameter int unsigned MAX_NI_PER_ROUTER = 2
, parameter int unsigned INIT_ROW          = 0
, parameter int unsigned INIT_COL          = 0
, parameter int unsigned TGT_ROW           = GRID_WIDTH - 1
, parameter int unsigned TGT_COL           = GRID_WIDTH - 1

, localparam int unsigned COORD_WIDTH = $clog2(GRID_WIDTH)
, localparam int unsigned NI_ID_WIDTH = (MAX_NI_PER_ROUTER > 1)
                                        ? $clog2(MAX_NI_PER_ROUTER) : 0
, localparam int unsigned FAB_PAYLOAD = $bits(pa_noc::ty_AXI_LITE_PAYLOAD)
, localparam int unsigned PROTO_W     = pa_noc::PROTOCOL_WIDTH
, localparam int unsigned NOC_PAYLOAD = FAB_PAYLOAD + PROTO_W
, localparam int unsigned NI_PACKET   = FAB_PAYLOAD + (2 * NI_ID_WIDTH)
                                        + (COORD_WIDTH * 4)
, localparam int unsigned FAB_PACKET  = NOC_PAYLOAD + (2 * NI_ID_WIDTH)
                                        + (COORD_WIDTH * 4)
)
( input  var logic i_clk
, input  var logic i_arst_n

  // CPU AXI4-Lite master interface — driven by C++
, input  var logic [31:0] i_awaddr
, input  var logic        i_awvalid
, output var logic        o_awready
, input  var logic [31:0] i_wdata
, input  var logic [3:0]  i_wstrb
, input  var logic        i_wvalid
, output var logic        o_wready
, output var logic [1:0]  o_bresp
, output var logic        o_bvalid
, input  var logic        i_bready
, input  var logic [31:0] i_araddr
, input  var logic        i_arvalid
, output var logic        o_arready
, output var logic [31:0] o_rdata
, output var logic [1:0]  o_rresp
, output var logic        o_rvalid
, input  var logic        i_rready

  // DMA AHB-Lite master interface — driven by C++
, input  var logic [31:0] i_haddr
, input  var logic [31:0] i_hwdata
, input  var logic        i_hwrite
, input  var logic [2:0]  i_hsize
, input  var logic [1:0]  i_htrans
, input  var logic        i_hsel
, output var logic        o_hreadyout
, output var logic        o_hresp
, output var logic [31:0] o_hrdata
);

  // {{{ Address map (both targets on the same router)
  localparam int unsigned NUM_ENTRIES = 2;

  localparam pa_noc::ty_ADDR_MAP_ENTRY [NUM_ENTRIES-1:0] ADDR_MAP =
    '{
      '{baseAddr: 32'h1000_0000
      , endAddr: 32'h1FFF_FFFF
      , dstRow: 8'(TGT_ROW)
      , dstCol: 8'(TGT_COL)
      , dstNiId: 8'd1
      },
      '{baseAddr: 32'h0000_0000
      , endAddr: 32'h0FFF_FFFF
      , dstRow: 8'(TGT_ROW)
      , dstCol: 8'(TGT_COL)
      , dstNiId: 8'd0
      }
    };
  // }}} Address map

  // {{{ Fabric interconnect (fabric packet width includes the opcode)
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0][FAB_PACKET-1:0] niToRouter;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0]                 niToRouterValid;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0]                 niToRouterReady;

  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0][FAB_PACKET-1:0] routerToNi;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0]                 routerToNiValid;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0]                 routerToNiReady;
  // }}} Fabric interconnect

  // {{{ Initiator router port (CPU NI_ID 0, DMA NI_ID 1)
  logic [MAX_NI_PER_ROUTER-1:0][FAB_PACKET-1:0] init_niToRouter;
  logic [MAX_NI_PER_ROUTER-1:0]                 init_niToRouterValid;
  logic [MAX_NI_PER_ROUTER-1:0]                 init_niToRouterReady;
/* verilator lint_off UNUSEDSIGNAL */
  logic [MAX_NI_PER_ROUTER-1:0][FAB_PACKET-1:0] init_routerToNi;
/* verilator lint_on UNUSEDSIGNAL */
  logic [MAX_NI_PER_ROUTER-1:0]                 init_routerToNiValid;
  logic [MAX_NI_PER_ROUTER-1:0]                 init_routerToNiReady;

  logic [FAB_PACKET-1:0] initPort_niToRouter;
  logic                  initPort_niToRouterValid;
  logic                  initPort_routerToNiReady;

  niRouterPort
  #(.GRID_WIDTH (GRID_WIDTH), .MAX_NI_PER_ROUTER (MAX_NI_PER_ROUTER)
  , .PAYLOAD_WIDTH (NOC_PAYLOAD))
  u_initPort
  ( .i_clk (i_clk), .i_arst_n (i_arst_n)
  , .o_niToRouter (initPort_niToRouter)
  , .o_niToRouterValid (initPort_niToRouterValid)
  , .i_niToRouterReady (niToRouterReady[INIT_ROW][INIT_COL])
  , .i_routerToNi (routerToNi[INIT_ROW][INIT_COL])
  , .i_routerToNiValid (routerToNiValid[INIT_ROW][INIT_COL])
  , .o_routerToNiReady (initPort_routerToNiReady)
  , .i_niToRouter (init_niToRouter), .i_niToRouterValid (init_niToRouterValid)
  , .o_niToRouterReady (init_niToRouterReady)
  , .o_routerToNi (init_routerToNi), .o_routerToNiValid (init_routerToNiValid)
  , .i_routerToNiReady (init_routerToNiReady)
  );
  // }}} Initiator router port

  // {{{ CPU — niAxiLiteInitiator NI_ID 0 (protocol PROTO_AXI_LITE)
  logic [NI_PACKET-1:0] cpu_niToRouter;

  always_comb
    init_niToRouter[0] = {pa_noc::PROTO_AXI_LITE, cpu_niToRouter};

  niAxiLiteInitiator
  #(.GRID_WIDTH (GRID_WIDTH), .NUM_ADDR_MAP_ENTRIES (NUM_ENTRIES)
  , .ADDR_MAP (ADDR_MAP), .SRC_ROW (INIT_ROW), .SRC_COL (INIT_COL)
  , .MAX_NI_PER_ROUTER (MAX_NI_PER_ROUTER), .NI_ID (0)
  , .PAYLOAD_WIDTH (FAB_PAYLOAD))
  u_cpu
  ( .i_clk (i_clk), .i_arst_n (i_arst_n)
  , .i_awaddr (i_awaddr), .i_awvalid (i_awvalid), .o_awready (o_awready)
  , .i_wdata (i_wdata), .i_wstrb (i_wstrb), .i_wvalid (i_wvalid), .o_wready (o_wready)
  , .o_bresp (o_bresp), .o_bvalid (o_bvalid), .i_bready (i_bready)
  , .i_araddr (i_araddr), .i_arvalid (i_arvalid), .o_arready (o_arready)
  , .o_rdata (o_rdata), .o_rresp (o_rresp), .o_rvalid (o_rvalid), .i_rready (i_rready)
  , .o_niToRouter (cpu_niToRouter), .o_niToRouterValid (init_niToRouterValid[0])
  , .i_niToRouterReady (init_niToRouterReady[0])
  , .i_routerToNi (init_routerToNi[0][NI_PACKET-1:0])
  , .i_routerToNiValid (init_routerToNiValid[0])
  , .o_routerToNiReady (init_routerToNiReady[0])
  );
  // }}} CPU

  // {{{ DMA — niAhbInitiator NI_ID 1 (protocol PROTO_AHB)
  logic [NI_PACKET-1:0] dma_niToRouter;
  logic                 dma_hreadyout;

  always_comb
    init_niToRouter[1] = {pa_noc::PROTO_AHB, dma_niToRouter};

  niAhbInitiator
  #(.GRID_WIDTH (GRID_WIDTH), .NUM_ADDR_MAP_ENTRIES (NUM_ENTRIES)
  , .ADDR_MAP (ADDR_MAP), .SRC_ROW (INIT_ROW), .SRC_COL (INIT_COL)
  , .MAX_NI_PER_ROUTER (MAX_NI_PER_ROUTER), .NI_ID (1)
  , .PAYLOAD_WIDTH (FAB_PAYLOAD))
  u_dma
  ( .i_clk (i_clk), .i_arst_n (i_arst_n)
  , .i_haddr (i_haddr), .i_hwrite (i_hwrite), .i_hsize (i_hsize)
  , .i_htrans (i_htrans), .i_hwdata (i_hwdata), .i_hsel (i_hsel)
  , .i_hready (dma_hreadyout), .o_hreadyout (dma_hreadyout)
  , .o_hresp (o_hresp), .o_hrdata (o_hrdata)
  , .o_niToRouter (dma_niToRouter), .o_niToRouterValid (init_niToRouterValid[1])
  , .i_niToRouterReady (init_niToRouterReady[1])
  , .i_routerToNi (init_routerToNi[1][NI_PACKET-1:0])
  , .i_routerToNiValid (init_routerToNiValid[1])
  , .o_routerToNiReady (init_routerToNiReady[1])
  );

  always_comb o_hreadyout = dma_hreadyout;
  // }}} DMA

  // {{{ Target router port (APB peripheral NI_ID 0, AHB peripheral NI_ID 1)
  logic [MAX_NI_PER_ROUTER-1:0][FAB_PACKET-1:0] tgt_niToRouter;
  logic [MAX_NI_PER_ROUTER-1:0]                 tgt_niToRouterValid;
  logic [MAX_NI_PER_ROUTER-1:0]                 tgt_niToRouterReady;
  logic [MAX_NI_PER_ROUTER-1:0][FAB_PACKET-1:0] tgt_routerToNi;
  logic [MAX_NI_PER_ROUTER-1:0]                 tgt_routerToNiValid;
  logic [MAX_NI_PER_ROUTER-1:0]                 tgt_routerToNiReady;

  logic [FAB_PACKET-1:0] tgtPort_niToRouter;
  logic                  tgtPort_niToRouterValid;
  logic                  tgtPort_routerToNiReady;

  niRouterPort
  #(.GRID_WIDTH (GRID_WIDTH), .MAX_NI_PER_ROUTER (MAX_NI_PER_ROUTER)
  , .PAYLOAD_WIDTH (NOC_PAYLOAD))
  u_tgtPort
  ( .i_clk (i_clk), .i_arst_n (i_arst_n)
  , .o_niToRouter (tgtPort_niToRouter)
  , .o_niToRouterValid (tgtPort_niToRouterValid)
  , .i_niToRouterReady (niToRouterReady[TGT_ROW][TGT_COL])
  , .i_routerToNi (routerToNi[TGT_ROW][TGT_COL])
  , .i_routerToNiValid (routerToNiValid[TGT_ROW][TGT_COL])
  , .o_routerToNiReady (tgtPort_routerToNiReady)
  , .i_niToRouter (tgt_niToRouter), .i_niToRouterValid (tgt_niToRouterValid)
  , .o_niToRouterReady (tgt_niToRouterReady)
  , .o_routerToNi (tgt_routerToNi), .o_routerToNiValid (tgt_routerToNiValid)
  , .i_routerToNiReady (tgt_routerToNiReady)
  );
  // }}} Target router port

  // {{{ APB peripheral — apbTargetBridge NI_ID 0 + APB slave
/* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] apb_paddr;
/* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] apb_pwdata; logic apb_pwrite;
  logic        apb_psel, apb_penable;
  logic        apb_pready, apb_pslverr; logic [31:0] apb_prdata;

  apbTargetBridge
  #(.GRID_WIDTH (GRID_WIDTH), .MY_ROW (TGT_ROW), .MY_COL (TGT_COL)
  , .PAYLOAD_WIDTH (FAB_PAYLOAD)
  , .MAX_NI_PER_ROUTER (MAX_NI_PER_ROUTER), .NI_ID (0))
  u_apbPeripheral
  ( .i_clk (i_clk), .i_arst_n (i_arst_n)
  , .i_routerToNi (tgt_routerToNi[0]), .i_routerToNiValid (tgt_routerToNiValid[0])
  , .o_routerToNiReady (tgt_routerToNiReady[0])
  , .o_niToRouter (tgt_niToRouter[0]), .o_niToRouterValid (tgt_niToRouterValid[0])
  , .i_niToRouterReady (tgt_niToRouterReady[0])
  , .o_paddr (apb_paddr), .o_pwdata (apb_pwdata), .o_pwrite (apb_pwrite)
/* verilator lint_off PINCONNECTEMPTY */
  , .o_pstrb ()
/* verilator lint_on PINCONNECTEMPTY */
  , .o_psel (apb_psel), .o_penable (apb_penable)
  , .i_pready (apb_pready), .i_pslverr (apb_pslverr), .i_prdata (apb_prdata)
  );

  // Simple zero-wait APB slave: 4 word registers.
  logic [31:0] apbSlave_reg [0:3];

  always_comb apb_pslverr = 1'b0;

  always_comb apb_pready = apb_psel && apb_penable;

  always_comb apb_prdata = apbSlave_reg[apb_paddr[3:2]];

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n) begin
      apbSlave_reg[0] <= 32'hA000_0000;
      apbSlave_reg[1] <= 32'hA111_1111;
      apbSlave_reg[2] <= 32'hA222_2222;
      apbSlave_reg[3] <= 32'hA333_3333;
    end else if (apb_psel && apb_penable && apb_pwrite) begin
      apbSlave_reg[apb_paddr[3:2]] <= apb_pwdata;
    end
  // }}} APB peripheral

  // {{{ AHB peripheral — ahbTargetBridge NI_ID 1 + AHB slave
  logic        ahb_hsel;  logic ahb_hwrite;
/* verilator lint_off UNUSEDSIGNAL */
  logic [31:0] ahb_haddr;
  logic [1:0]  ahb_htrans;
/* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] ahb_hwdata;
  logic [31:0] ahb_hrdata; logic ahb_hready, ahb_hresp;

  ahbTargetBridge
  #(.GRID_WIDTH (GRID_WIDTH), .MY_ROW (TGT_ROW), .MY_COL (TGT_COL)
  , .PAYLOAD_WIDTH (FAB_PAYLOAD)
  , .MAX_NI_PER_ROUTER (MAX_NI_PER_ROUTER), .NI_ID (1))
  u_ahbPeripheral
  ( .i_clk (i_clk), .i_arst_n (i_arst_n)
  , .i_routerToNi (tgt_routerToNi[1]), .i_routerToNiValid (tgt_routerToNiValid[1])
  , .o_routerToNiReady (tgt_routerToNiReady[1])
  , .o_niToRouter (tgt_niToRouter[1]), .o_niToRouterValid (tgt_niToRouterValid[1])
  , .i_niToRouterReady (tgt_niToRouterReady[1])
  , .o_hsel (ahb_hsel), .o_haddr (ahb_haddr), .o_hwrite (ahb_hwrite)
/* verilator lint_off PINCONNECTEMPTY */
  , .o_hsize ()
/* verilator lint_on PINCONNECTEMPTY */
  , .o_htrans (ahb_htrans), .o_hwdata (ahb_hwdata)
  , .i_hrdata (ahb_hrdata), .i_hready (ahb_hready), .i_hresp (ahb_hresp)
  );

  // Simple zero-wait AHB-Lite slave: 4 word registers.
  logic [31:0] ahbSlave_reg [0:3];
  logic        dphase_wr;
  logic [1:0]  dphase_addr;

  always_comb ahb_hready = 1'b1;
  always_comb ahb_hresp  = 1'b0;
  always_comb ahb_hrdata = ahbSlave_reg[dphase_addr];

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n) begin
      ahbSlave_reg[0] <= 32'hB000_0000;
      ahbSlave_reg[1] <= 32'hB111_1111;
      ahbSlave_reg[2] <= 32'hB222_2222;
      ahbSlave_reg[3] <= 32'hB333_3333;
      dphase_wr       <= 1'b0;
      dphase_addr     <= '0;
    end else begin
      if (dphase_wr)
        ahbSlave_reg[dphase_addr] <= ahb_hwdata;
      if (ahb_hsel && ahb_htrans[1]) begin
        dphase_addr <= ahb_haddr[3:2];
        dphase_wr   <= ahb_hwrite;
      end else begin
        dphase_wr   <= 1'b0;
      end
    end
  // }}} AHB peripheral

  // {{{ Router port <-> fabric wiring
  for (genvar i = 0; i < GRID_WIDTH; i++) begin: gen_row
    for (genvar j = 0; j < GRID_WIDTH; j++) begin: gen_col
      if (i == INIT_ROW && j == INIT_COL) begin: gen_init
        always_comb niToRouter[i][j]      = initPort_niToRouter;
        always_comb niToRouterValid[i][j] = initPort_niToRouterValid;
        always_comb routerToNiReady[i][j] = initPort_routerToNiReady;
      end: gen_init
      else if (i == TGT_ROW && j == TGT_COL) begin: gen_tgt
        always_comb niToRouter[i][j]      = tgtPort_niToRouter;
        always_comb niToRouterValid[i][j] = tgtPort_niToRouterValid;
        always_comb routerToNiReady[i][j] = tgtPort_routerToNiReady;
      end: gen_tgt
      else begin: gen_tie
        always_comb niToRouter[i][j]      = '0;
        always_comb niToRouterValid[i][j] = 1'b0;
        always_comb routerToNiReady[i][j] = 1'b1;
      end: gen_tie
    end
  end
  // }}} Router port <-> fabric wiring

  // {{{ NOC (payload widened by PROTOCOL_WIDTH, NI-ID fields enabled)
  noc
  #(.GRID_WIDTH (GRID_WIDTH), .PAYLOAD_WIDTH (NOC_PAYLOAD)
  , .MAX_NI_PER_ROUTER (MAX_NI_PER_ROUTER))
  u_noc
  ( .i_clk (i_clk), .i_arst_n (i_arst_n)
  , .i_niToRouter (niToRouter), .i_niToRouterValid (niToRouterValid)
  , .o_niToRouterReady (niToRouterReady)
  , .o_routerToNi (routerToNi), .o_routerToNiValid (routerToNiValid)
  , .i_routerToNiReady (routerToNiReady)
  );
  // }}} NOC

endmodule

`resetall
