// Integration testbench: opcode-tagged cross-protocol NoC with target bridges.
//
// A CPU (AXI4-Lite), a DMA (AHB-Lite) and an IO block (APB) all access a single
// AXI4-Lite peripheral.  Each initiator packs its NATIVE payload and its packet
// is tagged with the initiator protocol opcode.  The peripheral node
// (axiTargetBridge) decodes the opcode, steers the packet to the matching
// per-protocol target NI, and converts it to AXI via the AHB->AXI-Lite /
// APB->AXI-Lite bridges (AXI-Lite is native and needs no bridge).
//
//   CPU  (AXI4-Lite) : (0, 0)
//   DMA  (AHB-Lite)  : (GRID_WIDTH-1, GRID_WIDTH-1)
//   IO   (APB)       : (GRID_WIDTH-1, 0)
//   AXI peripheral   : (0, GRID_WIDTH-1)
//   Address map (all initiators): 0x0000_0000-0x0FFF_FFFF -> peripheral

`default_nettype none

module tb_nocBridgeIntegration3_top
#(parameter int unsigned GRID_WIDTH = 4
, parameter int unsigned CPU_ROW    = 0
, parameter int unsigned CPU_COL    = 0
, parameter int unsigned DMA_ROW    = GRID_WIDTH - 1
, parameter int unsigned DMA_COL    = GRID_WIDTH - 1
, parameter int unsigned PER_ROW    = 0
, parameter int unsigned PER_COL    = GRID_WIDTH - 1
, parameter int unsigned IO_ROW     = GRID_WIDTH - 1
, parameter int unsigned IO_COL     = 0

, localparam int unsigned COORD_WIDTH  = $clog2(GRID_WIDTH)
, localparam int unsigned FAB_PAYLOAD  = 96
, localparam int unsigned PROTO_W      = pa_noc::PROTOCOL_WIDTH
, localparam int unsigned NI_PACKET    = FAB_PAYLOAD + (COORD_WIDTH * 4)
, localparam int unsigned NOC_PAYLOAD  = FAB_PAYLOAD + PROTO_W
, localparam int unsigned FAB_PACKET   = NOC_PAYLOAD + (COORD_WIDTH * 4)
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

  // IO APB master interface — driven by C++
, input  var logic [31:0] i_apb_paddr
, input  var logic [31:0] i_apb_pwdata
, input  var logic        i_apb_pwrite
, input  var logic [3:0]  i_apb_pstrb
, input  var logic        i_apb_psel
, input  var logic        i_apb_penable
, output var logic        o_apb_pready
, output var logic        o_apb_pslverr
, output var logic [31:0] o_apb_prdata
);

  // {{{ Address map (all initiators reach the peripheral)
  localparam int unsigned NUM_ENTRIES = 1;

  localparam pa_noc::ty_ADDR_MAP_ENTRY [NUM_ENTRIES-1:0] ADDR_MAP =
    '{
      '{baseAddr: 32'h0000_0000
      , endAddr: 32'h0FFF_FFFF
      , dstRow: 8'(PER_ROW)
      , dstCol: 8'(PER_COL)
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

  // {{{ CPU — niAxiLiteInitiator (protocol PROTO_AXI_LITE)
  logic [NI_PACKET-1:0] cpu_niToRouter;
  logic                 cpu_niToRouterValid;
  logic                 cpu_niToRouterReady;
  logic [NI_PACKET-1:0] cpu_routerToNi;
  logic                 cpu_routerToNiValid;
  logic                 cpu_routerToNiReady;

  always_comb cpu_niToRouterReady = niToRouterReady[CPU_ROW][CPU_COL];
  always_comb cpu_routerToNi      = routerToNi[CPU_ROW][CPU_COL][NI_PACKET-1:0];
  always_comb cpu_routerToNiValid = routerToNiValid[CPU_ROW][CPU_COL];

  niAxiLiteInitiator
  #(.GRID_WIDTH (GRID_WIDTH), .NUM_ADDR_MAP_ENTRIES (NUM_ENTRIES)
  , .ADDR_MAP (ADDR_MAP), .SRC_ROW (CPU_ROW), .SRC_COL (CPU_COL)
  , .PAYLOAD_WIDTH (FAB_PAYLOAD))
  u_cpu
  ( .i_clk (i_clk), .i_arst_n (i_arst_n)
  , .i_awaddr (i_awaddr), .i_awvalid (i_awvalid), .o_awready (o_awready)
  , .i_wdata (i_wdata), .i_wstrb (i_wstrb), .i_wvalid (i_wvalid), .o_wready (o_wready)
  , .o_bresp (o_bresp), .o_bvalid (o_bvalid), .i_bready (i_bready)
  , .i_araddr (i_araddr), .i_arvalid (i_arvalid), .o_arready (o_arready)
  , .o_rdata (o_rdata), .o_rresp (o_rresp), .o_rvalid (o_rvalid), .i_rready (i_rready)
  , .o_niToRouter (cpu_niToRouter), .o_niToRouterValid (cpu_niToRouterValid)
  , .i_niToRouterReady (cpu_niToRouterReady)
  , .i_routerToNi (cpu_routerToNi), .i_routerToNiValid (cpu_routerToNiValid)
  , .o_routerToNiReady (cpu_routerToNiReady)
  );
  // }}} CPU

  // {{{ DMA — niAhbInitiator (protocol PROTO_AHB)
  logic [NI_PACKET-1:0] dma_niToRouter;
  logic                 dma_niToRouterValid;
  logic                 dma_niToRouterReady;
  logic [NI_PACKET-1:0] dma_routerToNi;
  logic                 dma_routerToNiValid;
  logic                 dma_routerToNiReady;
  logic                 dma_hreadyout;

  always_comb dma_niToRouterReady = niToRouterReady[DMA_ROW][DMA_COL];
  always_comb dma_routerToNi      = routerToNi[DMA_ROW][DMA_COL][NI_PACKET-1:0];
  always_comb dma_routerToNiValid = routerToNiValid[DMA_ROW][DMA_COL];

  niAhbInitiator
  #(.GRID_WIDTH (GRID_WIDTH), .NUM_ADDR_MAP_ENTRIES (NUM_ENTRIES)
  , .ADDR_MAP (ADDR_MAP), .SRC_ROW (DMA_ROW), .SRC_COL (DMA_COL)
  , .PAYLOAD_WIDTH (FAB_PAYLOAD))
  u_dma
  ( .i_clk (i_clk), .i_arst_n (i_arst_n)
  , .i_haddr (i_haddr), .i_hwrite (i_hwrite), .i_hsize (i_hsize)
  , .i_htrans (i_htrans), .i_hwdata (i_hwdata), .i_hsel (i_hsel)
  , .i_hready (dma_hreadyout), .o_hreadyout (dma_hreadyout)
  , .o_hresp (o_hresp), .o_hrdata (o_hrdata)
  , .o_niToRouter (dma_niToRouter), .o_niToRouterValid (dma_niToRouterValid)
  , .i_niToRouterReady (dma_niToRouterReady)
  , .i_routerToNi (dma_routerToNi), .i_routerToNiValid (dma_routerToNiValid)
  , .o_routerToNiReady (dma_routerToNiReady)
  );

  always_comb o_hreadyout = dma_hreadyout;
  // }}} DMA

  // {{{ IO — niApbInitiator (protocol PROTO_APB)
  logic [NI_PACKET-1:0] io_niToRouter;
  logic                 io_niToRouterValid;
  logic                 io_niToRouterReady;
  logic [NI_PACKET-1:0] io_routerToNi;
  logic                 io_routerToNiValid;
  logic                 io_routerToNiReady;

  always_comb io_niToRouterReady = niToRouterReady[IO_ROW][IO_COL];
  always_comb io_routerToNi      = routerToNi[IO_ROW][IO_COL][NI_PACKET-1:0];
  always_comb io_routerToNiValid = routerToNiValid[IO_ROW][IO_COL];

  niApbInitiator
  #(.GRID_WIDTH (GRID_WIDTH), .NUM_ADDR_MAP_ENTRIES (NUM_ENTRIES)
  , .ADDR_MAP (ADDR_MAP), .SRC_ROW (IO_ROW), .SRC_COL (IO_COL)
  , .PAYLOAD_WIDTH (FAB_PAYLOAD))
  u_io
  ( .i_clk (i_clk), .i_arst_n (i_arst_n)
  , .i_paddr (i_apb_paddr), .i_pwdata (i_apb_pwdata), .i_pwrite (i_apb_pwrite)
  , .i_pstrb (i_apb_pstrb), .i_psel (i_apb_psel), .i_penable (i_apb_penable)
  , .o_pready (o_apb_pready), .o_pslverr (o_apb_pslverr), .o_prdata (o_apb_prdata)
  , .o_niToRouter (io_niToRouter), .o_niToRouterValid (io_niToRouterValid)
  , .i_niToRouterReady (io_niToRouterReady)
  , .i_routerToNi (io_routerToNi), .i_routerToNiValid (io_routerToNiValid)
  , .o_routerToNiReady (io_routerToNiReady)
  );
  // }}} IO

  // {{{ Peripheral — axiTargetBridge + AXI slave
  logic [FAB_PACKET-1:0] per_niToRouter;
  logic                  per_niToRouterValid;
  logic                  per_niToRouterReady;
  logic [FAB_PACKET-1:0] per_routerToNi;
  logic                  per_routerToNiValid;
  logic                  per_routerToNiReady;

  logic [31:0] per_awaddr; logic per_awvalid, per_awready;
  logic [31:0] per_wdata;  logic [3:0] per_wstrb; logic per_wvalid, per_wready;
  logic [1:0]  per_bresp;  logic per_bvalid, per_bready;
  logic [31:0] per_araddr; logic per_arvalid, per_arready;
  logic [31:0] per_rdata;  logic [1:0] per_rresp; logic per_rvalid, per_rready;

  always_comb per_niToRouterReady = niToRouterReady[PER_ROW][PER_COL];
  always_comb per_routerToNi      = routerToNi[PER_ROW][PER_COL];
  always_comb per_routerToNiValid = routerToNiValid[PER_ROW][PER_COL];

  axiTargetBridge
  #(.GRID_WIDTH (GRID_WIDTH), .MY_ROW (PER_ROW), .MY_COL (PER_COL)
  , .PAYLOAD_WIDTH (FAB_PAYLOAD))
  u_peripheral
  ( .i_clk (i_clk), .i_arst_n (i_arst_n)
  , .i_routerToNi (per_routerToNi), .i_routerToNiValid (per_routerToNiValid)
  , .o_routerToNiReady (per_routerToNiReady)
  , .o_niToRouter (per_niToRouter), .o_niToRouterValid (per_niToRouterValid)
  , .i_niToRouterReady (per_niToRouterReady)
  , .o_awaddr (per_awaddr), .o_awvalid (per_awvalid), .i_awready (per_awready)
  , .o_wdata (per_wdata), .o_wstrb (per_wstrb), .o_wvalid (per_wvalid), .i_wready (per_wready)
  , .i_bresp (per_bresp), .i_bvalid (per_bvalid), .o_bready (per_bready)
  , .o_araddr (per_araddr), .o_arvalid (per_arvalid), .i_arready (per_arready)
  , .i_rdata (per_rdata), .i_rresp (per_rresp), .i_rvalid (per_rvalid), .o_rready (per_rready)
  );

  // Simple single-outstanding AXI4-Lite slave: 4 word registers.
  logic [31:0] slave_reg [0:3];
  logic [31:0] awaddr_q;
  logic        bpending_q;
  logic [31:0] rdata_q;
  logic        rpending_q;

  always_comb per_awready = 1'b1;
  always_comb per_wready  = 1'b1;
  always_comb per_arready = 1'b1;
  always_comb per_bvalid  = bpending_q;
  always_comb per_bresp   = 2'b00;
  always_comb per_rvalid  = rpending_q;
  always_comb per_rdata   = rdata_q;
  always_comb per_rresp   = 2'b00;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n) begin
      slave_reg[0] <= 32'hC000_0000;
      slave_reg[1] <= 32'hC111_1111;
      slave_reg[2] <= 32'hC222_2222;
      slave_reg[3] <= 32'hC333_3333;
      awaddr_q     <= '0;
      bpending_q   <= 1'b0;
      rdata_q      <= '0;
      rpending_q   <= 1'b0;
    end else begin
      if (per_awvalid)
        awaddr_q <= per_awaddr;
      if (per_wvalid)
        slave_reg[awaddr_q[3:2]] <= per_wdata;
      if (per_wvalid)
        bpending_q <= 1'b1;
      else if (per_bvalid && per_bready)
        bpending_q <= 1'b0;
      if (per_arvalid) begin
        rdata_q    <= slave_reg[per_araddr[3:2]];
        rpending_q <= 1'b1;
      end else if (per_rvalid && per_rready)
        rpending_q <= 1'b0;
    end
  // }}} Peripheral

  // {{{ Node <-> fabric wiring (opcode tag on request, strip on response)
  for (genvar i = 0; i < GRID_WIDTH; i++) begin: gen_row
    for (genvar j = 0; j < GRID_WIDTH; j++) begin: gen_col
      if (i == CPU_ROW && j == CPU_COL) begin: gen_cpu
        always_comb niToRouter[i][j]      = {pa_noc::PROTO_AXI_LITE, cpu_niToRouter};
        always_comb niToRouterValid[i][j] = cpu_niToRouterValid;
        always_comb routerToNiReady[i][j] = cpu_routerToNiReady;
      end: gen_cpu
      else if (i == DMA_ROW && j == DMA_COL) begin: gen_dma
        always_comb niToRouter[i][j]      = {pa_noc::PROTO_AHB, dma_niToRouter};
        always_comb niToRouterValid[i][j] = dma_niToRouterValid;
        always_comb routerToNiReady[i][j] = dma_routerToNiReady;
      end: gen_dma
      else if (i == PER_ROW && j == PER_COL) begin: gen_per
        always_comb niToRouter[i][j]      = per_niToRouter;
        always_comb niToRouterValid[i][j] = per_niToRouterValid;
        always_comb routerToNiReady[i][j] = per_routerToNiReady;
      end: gen_per
      else if (i == IO_ROW && j == IO_COL) begin: gen_io
        always_comb niToRouter[i][j]      = {pa_noc::PROTO_APB, io_niToRouter};
        always_comb niToRouterValid[i][j] = io_niToRouterValid;
        always_comb routerToNiReady[i][j] = io_routerToNiReady;
      end: gen_io
      else begin: gen_tie
        always_comb niToRouter[i][j]      = '0;
        always_comb niToRouterValid[i][j] = 1'b0;
        always_comb routerToNiReady[i][j] = 1'b1;
      end: gen_tie
    end
  end
  // }}} Node <-> fabric wiring

  // {{{ NOC (payload widened by PROTOCOL_WIDTH to carry the opcode)
  noc
  #(.GRID_WIDTH (GRID_WIDTH), .PAYLOAD_WIDTH (NOC_PAYLOAD))
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
