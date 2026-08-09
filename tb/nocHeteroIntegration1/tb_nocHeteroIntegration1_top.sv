// Heterogeneous-protocol integration testbench wrapper
// Demonstrates cross-protocol traffic over the NoC using the canonical payload:
// a single AHB-Lite initiator transparently accesses an AXI4-Lite target AND an
// APB target.  Each NI translates its native AMBA protocol to/from the common
// canonical transaction payload, so masters and slaves of different protocols
// interoperate without any external bridge.
//
// Node placement (default 4x4 grid):
//   AHB initiator : (0, 0)
//   AXI target A  : (0, GRID_WIDTH-1)   regs preset to 0xA000_0000 + n
//   APB target B  : (GRID_WIDTH-1, 0)   regs preset to 0xB000_0000 + n
//
// Address map (in the AHB initiator):
//   0x0000_0000 - 0x0FFF_FFFF -> AXI target A
//   0x1000_0000 - 0x1FFF_FFFF -> APB target B

`default_nettype none

module tb_nocHeteroIntegration1_top
#(parameter int unsigned GRID_WIDTH = 4
, parameter int unsigned INIT_ROW   = 0
, parameter int unsigned INIT_COL   = 0
, parameter int unsigned TGTA_ROW   = 0
, parameter int unsigned TGTA_COL   = GRID_WIDTH - 1
, parameter int unsigned TGTB_ROW   = GRID_WIDTH - 1
, parameter int unsigned TGTB_COL   = 0

, localparam int unsigned COORD_WIDTH   = $clog2(GRID_WIDTH)
, localparam int unsigned PAYLOAD_WIDTH = pa_noc::CANON_PAYLOAD_WIDTH
, localparam int unsigned PACKET_WIDTH  = PAYLOAD_WIDTH + (COORD_WIDTH * 4)
)
( input  var logic i_clk
, input  var logic i_arst_n

  // AHB-Lite master interface — driven by C++
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

  // {{{ Address map — routes each range to a different-protocol target
  localparam int unsigned NUM_ENTRIES = 2;

  localparam pa_noc::ty_ADDR_MAP_ENTRY [NUM_ENTRIES-1:0] ADDR_MAP =
    '{
      '{baseAddr: 32'h1000_0000
      , endAddr: 32'h1FFF_FFFF
      , dstRow: 8'(TGTB_ROW)
      , dstCol: 8'(TGTB_COL)
      , dstNiId: 8'd0
      },
      '{baseAddr: 32'h0000_0000
      , endAddr: 32'h0FFF_FFFF
      , dstRow: 8'(TGTA_ROW)
      , dstCol: 8'(TGTA_COL)
      , dstNiId: 8'd0
      }
    };
  // }}} Address map

  // {{{ NOC interconnect arrays
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0][PACKET_WIDTH-1:0] niToRouter;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0]                   niToRouterValid;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0]                   niToRouterReady;

  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0][PACKET_WIDTH-1:0] routerToNi;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0]                   routerToNiValid;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0]                   routerToNiReady;
  // }}} NOC interconnect arrays

  // {{{ AHB initiator NI
  logic [PACKET_WIDTH-1:0] niToRouter_init;
  logic                    niToRouterValid_init;
  logic                    niToRouterReady_init;
  logic [PACKET_WIDTH-1:0] routerToNi_init;
  logic                    routerToNiValid_init;
  logic                    routerToNiReady_init;

  // HREADY of the single-slave AHB port is the NI's own HREADYOUT.
  logic                    ahb_hreadyout;

  always_comb
    niToRouterReady_init = niToRouterReady[INIT_ROW][INIT_COL];

  always_comb
    routerToNi_init = routerToNi[INIT_ROW][INIT_COL];

  always_comb
    routerToNiValid_init = routerToNiValid[INIT_ROW][INIT_COL];

  niAhbInitiator
  #(.GRID_WIDTH            (GRID_WIDTH)
  , .NUM_ADDR_MAP_ENTRIES  (NUM_ENTRIES)
  , .ADDR_MAP              (ADDR_MAP)
  , .SRC_ROW               (INIT_ROW)
  , .SRC_COL               (INIT_COL)
  ) u_init
  ( .i_clk       (i_clk)
  , .i_arst_n    (i_arst_n)

  , .i_haddr     (i_haddr)
  , .i_hwrite    (i_hwrite)
  , .i_hsize     (i_hsize)
  , .i_htrans    (i_htrans)
  , .i_hwdata    (i_hwdata)
  , .i_hsel      (i_hsel)
  , .i_hready    (ahb_hreadyout)
  , .o_hreadyout (ahb_hreadyout)
  , .o_hresp     (o_hresp)
  , .o_hrdata    (o_hrdata)

  , .o_niToRouter      (niToRouter_init)
  , .o_niToRouterValid (niToRouterValid_init)
  , .i_niToRouterReady (niToRouterReady_init)

  , .i_routerToNi      (routerToNi_init)
  , .i_routerToNiValid (routerToNiValid_init)
  , .o_routerToNiReady (routerToNiReady_init)
  );

  always_comb
    o_hreadyout = ahb_hreadyout;
  // }}} AHB initiator NI

  // {{{ Target A — AXI4-Lite target NI + AXI subordinate
  logic [PACKET_WIDTH-1:0] niToRouter_tA;
  logic                    niToRouterValid_tA;
  logic                    niToRouterReady_tA;
  logic [PACKET_WIDTH-1:0] routerToNi_tA;
  logic                    routerToNiValid_tA;
  logic                    routerToNiReady_tA;

  logic [31:0] axiA_awaddr;
  logic        axiA_awvalid;
  logic [31:0] axiA_wdata;
  logic [3:0]  axiA_wstrb;
  logic        axiA_wvalid;
  logic        axiA_bready;
  logic [31:0] axiA_araddr;
  logic        axiA_arvalid;
  logic        axiA_rready;
  logic [1:0]  axiA_bresp;
  logic        axiA_bvalid;
  logic [31:0] axiA_rdata;
  logic [1:0]  axiA_rresp;
  logic        axiA_rvalid;

  always_comb
    routerToNi_tA = routerToNi[TGTA_ROW][TGTA_COL];

  always_comb
    routerToNiValid_tA = routerToNiValid[TGTA_ROW][TGTA_COL];

  always_comb
    niToRouterReady_tA = niToRouterReady[TGTA_ROW][TGTA_COL];

  niAxiLiteTarget
  #(.GRID_WIDTH (GRID_WIDTH)
  , .MY_ROW     (TGTA_ROW)
  , .MY_COL     (TGTA_COL)
  ) u_tgtA
  ( .i_clk     (i_clk)
  , .i_arst_n  (i_arst_n)

  , .o_awaddr  (axiA_awaddr)
  , .o_awvalid (axiA_awvalid)
  , .i_awready (1'b1)
  , .o_wdata   (axiA_wdata)
  , .o_wstrb   (axiA_wstrb)
  , .o_wvalid  (axiA_wvalid)
  , .i_wready  (1'b1)
  , .i_bresp   (axiA_bresp)
  , .i_bvalid  (axiA_bvalid)
  , .o_bready  (axiA_bready)
  , .o_araddr  (axiA_araddr)
  , .o_arvalid (axiA_arvalid)
  , .i_arready (1'b1)
  , .i_rdata   (axiA_rdata)
  , .i_rresp   (axiA_rresp)
  , .i_rvalid  (axiA_rvalid)
  , .o_rready  (axiA_rready)

  , .i_routerToNi      (routerToNi_tA)
  , .i_routerToNiValid (routerToNiValid_tA)
  , .o_routerToNiReady (routerToNiReady_tA)

  , .o_niToRouter      (niToRouter_tA)
  , .o_niToRouterValid (niToRouterValid_tA)
  , .i_niToRouterReady (niToRouterReady_tA)
  );

  // Simple single-outstanding AXI4-Lite subordinate: 4 word registers.
  logic [31:0] slaveA_reg [0:3];
  logic [31:0] awaddrA_q;
  logic        bpendingA_q;
  logic [31:0] rdataA_q;
  logic        rpendingA_q;

  always_comb
    axiA_bvalid = bpendingA_q;

  always_comb
    axiA_bresp = 2'b00;

  always_comb
    axiA_rvalid = rpendingA_q;

  always_comb
    axiA_rdata = rdataA_q;

  always_comb
    axiA_rresp = 2'b00;

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n) begin
      slaveA_reg[0] <= 32'hA000_0000;
      slaveA_reg[1] <= 32'hA111_1111;
      slaveA_reg[2] <= 32'hA222_2222;
      slaveA_reg[3] <= 32'hA333_3333;
      awaddrA_q     <= '0;
      bpendingA_q   <= 1'b0;
      rdataA_q      <= '0;
      rpendingA_q   <= 1'b0;
    end else begin
      if (axiA_awvalid)
        awaddrA_q <= axiA_awaddr;
      if (axiA_wvalid)
        slaveA_reg[awaddrA_q[3:2]] <= axiA_wdata;
      if (axiA_wvalid)
        bpendingA_q <= 1'b1;
      else if (axiA_bvalid && axiA_bready)
        bpendingA_q <= 1'b0;
      if (axiA_arvalid) begin
        rdataA_q    <= slaveA_reg[axiA_araddr[3:2]];
        rpendingA_q <= 1'b1;
      end else if (axiA_rvalid && axiA_rready)
        rpendingA_q <= 1'b0;
    end
  // }}} Target A

  // {{{ Target B — APB target NI + APB subordinate
  logic [PACKET_WIDTH-1:0] niToRouter_tB;
  logic                    niToRouterValid_tB;
  logic                    niToRouterReady_tB;
  logic [PACKET_WIDTH-1:0] routerToNi_tB;
  logic                    routerToNiValid_tB;
  logic                    routerToNiReady_tB;

  logic [31:0] apbB_paddr;
  logic [31:0] apbB_pwdata;
  logic        apbB_pwrite;
  logic [3:0]  apbB_pstrb;
  logic        apbB_psel;
  logic        apbB_penable;
  logic        apbB_pready;
  logic        apbB_pslverr;
  logic [31:0] apbB_prdata;

  always_comb
    routerToNi_tB = routerToNi[TGTB_ROW][TGTB_COL];

  always_comb
    routerToNiValid_tB = routerToNiValid[TGTB_ROW][TGTB_COL];

  always_comb
    niToRouterReady_tB = niToRouterReady[TGTB_ROW][TGTB_COL];

  niApbTarget
  #(.GRID_WIDTH (GRID_WIDTH)
  , .MY_ROW     (TGTB_ROW)
  , .MY_COL     (TGTB_COL)
  ) u_tgtB
  ( .i_clk     (i_clk)
  , .i_arst_n  (i_arst_n)

  , .o_paddr   (apbB_paddr)
  , .o_pwdata  (apbB_pwdata)
  , .o_pwrite  (apbB_pwrite)
  , .o_pstrb   (apbB_pstrb)
  , .o_psel    (apbB_psel)
  , .o_penable (apbB_penable)
  , .i_pready  (apbB_pready)
  , .i_pslverr (apbB_pslverr)
  , .i_prdata  (apbB_prdata)

  , .i_routerToNi      (routerToNi_tB)
  , .i_routerToNiValid (routerToNiValid_tB)
  , .o_routerToNiReady (routerToNiReady_tB)

  , .o_niToRouter      (niToRouter_tB)
  , .o_niToRouterValid (niToRouterValid_tB)
  , .i_niToRouterReady (niToRouterReady_tB)
  );

  // Simple APB subordinate: 4 word registers, immediate PREADY.
  logic [31:0] slaveB_reg [0:3];

  always_comb
    apbB_pslverr = 1'b0;

  always_comb
    apbB_pready = apbB_psel && apbB_penable;

  always_comb
    apbB_prdata = slaveB_reg[apbB_paddr[3:2]];

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n) begin
      slaveB_reg[0] <= 32'hB000_0000;
      slaveB_reg[1] <= 32'hB111_1111;
      slaveB_reg[2] <= 32'hB222_2222;
      slaveB_reg[3] <= 32'hB333_3333;
    end else if (apbB_psel && apbB_penable && apbB_pwrite) begin
      slaveB_reg[apbB_paddr[3:2]] <= apbB_pwdata;
    end
  // }}} Target B

  // {{{ NI port connections (single driver per element)
  for (genvar i = 0; i < GRID_WIDTH; i++) begin: gen_ni_row
    for (genvar j = 0; j < GRID_WIDTH; j++) begin: gen_ni_col
      if (i == INIT_ROW && j == INIT_COL) begin: gen_init
        always_comb niToRouter[i][j]      = niToRouter_init;
        always_comb niToRouterValid[i][j] = niToRouterValid_init;
        always_comb routerToNiReady[i][j] = routerToNiReady_init;
      end: gen_init
      else if (i == TGTA_ROW && j == TGTA_COL) begin: gen_tA
        always_comb niToRouter[i][j]      = niToRouter_tA;
        always_comb niToRouterValid[i][j] = niToRouterValid_tA;
        always_comb routerToNiReady[i][j] = routerToNiReady_tA;
      end: gen_tA
      else if (i == TGTB_ROW && j == TGTB_COL) begin: gen_tB
        always_comb niToRouter[i][j]      = niToRouter_tB;
        always_comb niToRouterValid[i][j] = niToRouterValid_tB;
        always_comb routerToNiReady[i][j] = routerToNiReady_tB;
      end: gen_tB
      else begin: gen_tieoff
        always_comb niToRouter[i][j]      = '0;
        always_comb niToRouterValid[i][j] = 1'b0;
        always_comb routerToNiReady[i][j] = 1'b1;
      end: gen_tieoff
    end
  end
  // }}} NI port connections

  // {{{ NOC
  noc
  #(.GRID_WIDTH (GRID_WIDTH)
  , .PAYLOAD_WIDTH (PAYLOAD_WIDTH)
  ) u_noc
  ( .i_clk     (i_clk)
  , .i_arst_n  (i_arst_n)

  , .i_niToRouter      (niToRouter)
  , .i_niToRouterValid (niToRouterValid)
  , .o_niToRouterReady (niToRouterReady)

  , .o_routerToNi      (routerToNi)
  , .o_routerToNiValid (routerToNiValid)
  , .i_routerToNiReady (routerToNiReady)
  );
  // }}} NOC

endmodule

`resetall
