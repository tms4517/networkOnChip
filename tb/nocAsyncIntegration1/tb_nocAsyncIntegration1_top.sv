// Integration testbench: asynchronous (multi-clock) NoC.
//
// Same topology as nocApbIntegration1 (two niApbInitiator masters and two
// niApbTarget slaves on a 4x4 grid) but each network interface runs in its own
// clock domain, decoupled from the fabric by a per-NI cdcNiBridge:
//
//   initiators + their APB masters : i_initClk  / i_initArst_n
//   fabric (noc mesh)              : i_clk      / i_arst_n
//   targets + their APB slaves     : i_tgtClk   / i_tgtArst_n
//
// This demonstrates initiators and targets operating at frequencies unrelated
// to each other and to the fabric.
//
// Node placement (default 4x4 grid):
//   Initiator 0 : (0,0)              Target A : (0, GRID_WIDTH-1)
//   Initiator 1 : (GW-1,GW-1)        Target B : (GRID_WIDTH-1, 0)
//
// Address map (shared by both initiators):
//   0x0000_0000 - 0x0FFF_FFFF -> Target A
//   0x1000_0000 - 0x1FFF_FFFF -> Target B

`default_nettype none

module tb_nocAsyncIntegration1_top
#(parameter int unsigned GRID_WIDTH = 4
, parameter int unsigned INIT0_ROW  = 0
, parameter int unsigned INIT0_COL  = 0
, parameter int unsigned INIT1_ROW  = GRID_WIDTH - 1
, parameter int unsigned INIT1_COL  = GRID_WIDTH - 1
, parameter int unsigned TGTA_ROW   = 0
, parameter int unsigned TGTA_COL   = GRID_WIDTH - 1
, parameter int unsigned TGTB_ROW   = GRID_WIDTH - 1
, parameter int unsigned TGTB_COL   = 0

, localparam int unsigned COORD_WIDTH   = $clog2(GRID_WIDTH)
, localparam int unsigned PAYLOAD_WIDTH = pa_noc::APB_PAYLOAD_WIDTH
, localparam int unsigned PACKET_WIDTH  = PAYLOAD_WIDTH + (COORD_WIDTH * 4)
)
( input  var logic i_clk         // fabric clock
, input  var logic i_arst_n
, input  var logic i_initClk      // initiator clock domain
, input  var logic i_initArst_n
, input  var logic i_tgtClk       // target clock domain
, input  var logic i_tgtArst_n

  // Initiator 0 APB master interface — driven by C++ (initiator clock domain)
, input  var logic [31:0] i_paddr0
, input  var logic [31:0] i_pwdata0
, input  var logic        i_pwrite0
, input  var logic [3:0]  i_pstrb0
, input  var logic        i_psel0
, input  var logic        i_penable0
, output var logic        o_pready0
, output var logic        o_pslverr0
, output var logic [31:0] o_prdata0

  // Initiator 1 APB master interface — driven by C++ (initiator clock domain)
, input  var logic [31:0] i_paddr1
, input  var logic [31:0] i_pwdata1
, input  var logic        i_pwrite1
, input  var logic [3:0]  i_pstrb1
, input  var logic        i_psel1
, input  var logic        i_penable1
, output var logic        o_pready1
, output var logic        o_pslverr1
, output var logic [31:0] o_prdata1
);

  // {{{ Address map (shared by both initiators)
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

  // {{{ NOC interconnect arrays (fabric clock domain)
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0][PACKET_WIDTH-1:0] niToRouter;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0]                   niToRouterValid;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0]                   niToRouterReady;

  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0][PACKET_WIDTH-1:0] routerToNi;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0]                   routerToNiValid;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0]                   routerToNiReady;
  // }}} NOC interconnect arrays

  // ------------------------------------------------------------------------
  // A single NI leg: NI-side handshake, bridge, and fabric-side handshake.
  // ------------------------------------------------------------------------
  `define NI_LEG(NAME) \
    logic [PACKET_WIDTH-1:0] niToRouter_``NAME; \
    logic                    niToRouterValid_``NAME; \
    logic                    niToRouterReady_``NAME; \
    logic [PACKET_WIDTH-1:0] routerToNi_``NAME; \
    logic                    routerToNiValid_``NAME; \
    logic                    routerToNiReady_``NAME; \
    logic [PACKET_WIDTH-1:0] fabNiToRouter_``NAME; \
    logic                    fabNiToRouterValid_``NAME; \
    logic                    fabNiToRouterReady_``NAME; \
    logic [PACKET_WIDTH-1:0] fabRouterToNi_``NAME; \
    logic                    fabRouterToNiValid_``NAME; \
    logic                    fabRouterToNiReady_``NAME;

  `NI_LEG(i0)
  `NI_LEG(i1)
  `NI_LEG(tA)
  `NI_LEG(tB)

  // {{{ Initiator 0 NI + CDC bridge
  niApbInitiator
  #(.GRID_WIDTH            (GRID_WIDTH)
  , .NUM_ADDR_MAP_ENTRIES  (NUM_ENTRIES)
  , .ADDR_MAP              (ADDR_MAP)
  , .SRC_ROW               (INIT0_ROW)
  , .SRC_COL               (INIT0_COL)
  ) u_init0
  ( .i_clk     (i_initClk)
  , .i_arst_n  (i_initArst_n)

  , .i_paddr   (i_paddr0)
  , .i_pwdata  (i_pwdata0)
  , .i_pwrite  (i_pwrite0)
  , .i_pstrb   (i_pstrb0)
  , .i_psel    (i_psel0)
  , .i_penable (i_penable0)
  , .o_pready  (o_pready0)
  , .o_pslverr (o_pslverr0)
  , .o_prdata  (o_prdata0)

  , .o_niToRouter      (niToRouter_i0)
  , .o_niToRouterValid (niToRouterValid_i0)
  , .i_niToRouterReady (niToRouterReady_i0)
  , .i_routerToNi      (routerToNi_i0)
  , .i_routerToNiValid (routerToNiValid_i0)
  , .o_routerToNiReady (routerToNiReady_i0)
  );

  cdcNiBridge
  #(.PACKET_WIDTH (PACKET_WIDTH)
  ) u_cdc_i0
  ( .i_niClk    (i_initClk)
  , .i_niArst_n (i_initArst_n)
  , .i_fabClk   (i_clk)
  , .i_fabArst_n (i_arst_n)

  , .i_niToRouter      (niToRouter_i0)
  , .i_niToRouterValid (niToRouterValid_i0)
  , .o_niToRouterReady (niToRouterReady_i0)
  , .o_routerToNi      (routerToNi_i0)
  , .o_routerToNiValid (routerToNiValid_i0)
  , .i_routerToNiReady (routerToNiReady_i0)

  , .o_niToRouterFab      (fabNiToRouter_i0)
  , .o_niToRouterValidFab (fabNiToRouterValid_i0)
  , .i_niToRouterReadyFab (fabNiToRouterReady_i0)
  , .i_routerToNiFab      (fabRouterToNi_i0)
  , .i_routerToNiValidFab (fabRouterToNiValid_i0)
  , .o_routerToNiReadyFab (fabRouterToNiReady_i0)
  );
  // }}} Initiator 0

  // {{{ Initiator 1 NI + CDC bridge
  niApbInitiator
  #(.GRID_WIDTH            (GRID_WIDTH)
  , .NUM_ADDR_MAP_ENTRIES  (NUM_ENTRIES)
  , .ADDR_MAP              (ADDR_MAP)
  , .SRC_ROW               (INIT1_ROW)
  , .SRC_COL               (INIT1_COL)
  ) u_init1
  ( .i_clk     (i_initClk)
  , .i_arst_n  (i_initArst_n)

  , .i_paddr   (i_paddr1)
  , .i_pwdata  (i_pwdata1)
  , .i_pwrite  (i_pwrite1)
  , .i_pstrb   (i_pstrb1)
  , .i_psel    (i_psel1)
  , .i_penable (i_penable1)
  , .o_pready  (o_pready1)
  , .o_pslverr (o_pslverr1)
  , .o_prdata  (o_prdata1)

  , .o_niToRouter      (niToRouter_i1)
  , .o_niToRouterValid (niToRouterValid_i1)
  , .i_niToRouterReady (niToRouterReady_i1)
  , .i_routerToNi      (routerToNi_i1)
  , .i_routerToNiValid (routerToNiValid_i1)
  , .o_routerToNiReady (routerToNiReady_i1)
  );

  cdcNiBridge
  #(.PACKET_WIDTH (PACKET_WIDTH)
  ) u_cdc_i1
  ( .i_niClk    (i_initClk)
  , .i_niArst_n (i_initArst_n)
  , .i_fabClk   (i_clk)
  , .i_fabArst_n (i_arst_n)

  , .i_niToRouter      (niToRouter_i1)
  , .i_niToRouterValid (niToRouterValid_i1)
  , .o_niToRouterReady (niToRouterReady_i1)
  , .o_routerToNi      (routerToNi_i1)
  , .o_routerToNiValid (routerToNiValid_i1)
  , .i_routerToNiReady (routerToNiReady_i1)

  , .o_niToRouterFab      (fabNiToRouter_i1)
  , .o_niToRouterValidFab (fabNiToRouterValid_i1)
  , .i_niToRouterReadyFab (fabNiToRouterReady_i1)
  , .i_routerToNiFab      (fabRouterToNi_i1)
  , .i_routerToNiValidFab (fabRouterToNiValid_i1)
  , .o_routerToNiReadyFab (fabRouterToNiReady_i1)
  );
  // }}} Initiator 1

  // {{{ Target A NI + CDC bridge + APB slave
  logic [31:0] apbA_paddr;
  logic [31:0] apbA_pwdata;
  logic        apbA_pwrite;
  logic [3:0]  apbA_pstrb;
  logic        apbA_psel;
  logic        apbA_penable;
  logic        apbA_pready;
  logic        apbA_pslverr;
  logic [31:0] apbA_prdata;

  niApbTarget
  #(.GRID_WIDTH (GRID_WIDTH)
  , .MY_ROW     (TGTA_ROW)
  , .MY_COL     (TGTA_COL)
  ) u_tgtA
  ( .i_clk     (i_tgtClk)
  , .i_arst_n  (i_tgtArst_n)

  , .o_paddr   (apbA_paddr)
  , .o_pwdata  (apbA_pwdata)
  , .o_pwrite  (apbA_pwrite)
  , .o_pstrb   (apbA_pstrb)
  , .o_psel    (apbA_psel)
  , .o_penable (apbA_penable)
  , .i_pready  (apbA_pready)
  , .i_pslverr (apbA_pslverr)
  , .i_prdata  (apbA_prdata)

  , .i_routerToNi      (routerToNi_tA)
  , .i_routerToNiValid (routerToNiValid_tA)
  , .o_routerToNiReady (routerToNiReady_tA)
  , .o_niToRouter      (niToRouter_tA)
  , .o_niToRouterValid (niToRouterValid_tA)
  , .i_niToRouterReady (niToRouterReady_tA)
  );

  cdcNiBridge
  #(.PACKET_WIDTH (PACKET_WIDTH)
  ) u_cdc_tA
  ( .i_niClk    (i_tgtClk)
  , .i_niArst_n (i_tgtArst_n)
  , .i_fabClk   (i_clk)
  , .i_fabArst_n (i_arst_n)

  , .i_niToRouter      (niToRouter_tA)
  , .i_niToRouterValid (niToRouterValid_tA)
  , .o_niToRouterReady (niToRouterReady_tA)
  , .o_routerToNi      (routerToNi_tA)
  , .o_routerToNiValid (routerToNiValid_tA)
  , .i_routerToNiReady (routerToNiReady_tA)

  , .o_niToRouterFab      (fabNiToRouter_tA)
  , .o_niToRouterValidFab (fabNiToRouterValid_tA)
  , .i_niToRouterReadyFab (fabNiToRouterReady_tA)
  , .i_routerToNiFab      (fabRouterToNi_tA)
  , .i_routerToNiValidFab (fabRouterToNiValid_tA)
  , .o_routerToNiReadyFab (fabRouterToNiReady_tA)
  );

  // Simple APB slave for Target A: 4 word registers, immediate PREADY.
  logic [31:0] slaveA_reg [0:3];

  always_comb
    apbA_pslverr = 1'b0;

  always_comb
    apbA_pready = apbA_psel && apbA_penable;

  always_comb
    apbA_prdata = slaveA_reg[apbA_paddr[3:2]];

  always_ff @(posedge i_tgtClk or negedge i_tgtArst_n)
    if (!i_tgtArst_n) begin
      slaveA_reg[0] <= 32'hA000_0000;
      slaveA_reg[1] <= 32'hA111_1111;
      slaveA_reg[2] <= 32'hA222_2222;
      slaveA_reg[3] <= 32'hA333_3333;
    end else if (apbA_psel && apbA_penable && apbA_pwrite) begin
      slaveA_reg[apbA_paddr[3:2]] <= apbA_pwdata;
    end
  // }}} Target A

  // {{{ Target B NI + CDC bridge + APB slave
  logic [31:0] apbB_paddr;
  logic [31:0] apbB_pwdata;
  logic        apbB_pwrite;
  logic [3:0]  apbB_pstrb;
  logic        apbB_psel;
  logic        apbB_penable;
  logic        apbB_pready;
  logic        apbB_pslverr;
  logic [31:0] apbB_prdata;

  niApbTarget
  #(.GRID_WIDTH (GRID_WIDTH)
  , .MY_ROW     (TGTB_ROW)
  , .MY_COL     (TGTB_COL)
  ) u_tgtB
  ( .i_clk     (i_tgtClk)
  , .i_arst_n  (i_tgtArst_n)

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

  cdcNiBridge
  #(.PACKET_WIDTH (PACKET_WIDTH)
  ) u_cdc_tB
  ( .i_niClk    (i_tgtClk)
  , .i_niArst_n (i_tgtArst_n)
  , .i_fabClk   (i_clk)
  , .i_fabArst_n (i_arst_n)

  , .i_niToRouter      (niToRouter_tB)
  , .i_niToRouterValid (niToRouterValid_tB)
  , .o_niToRouterReady (niToRouterReady_tB)
  , .o_routerToNi      (routerToNi_tB)
  , .o_routerToNiValid (routerToNiValid_tB)
  , .i_routerToNiReady (routerToNiReady_tB)

  , .o_niToRouterFab      (fabNiToRouter_tB)
  , .o_niToRouterValidFab (fabNiToRouterValid_tB)
  , .i_niToRouterReadyFab (fabNiToRouterReady_tB)
  , .i_routerToNiFab      (fabRouterToNi_tB)
  , .i_routerToNiValidFab (fabRouterToNiValid_tB)
  , .o_routerToNiReadyFab (fabRouterToNiReady_tB)
  );

  // Simple APB slave for Target B: 4 word registers, immediate PREADY.
  logic [31:0] slaveB_reg [0:3];

  always_comb
    apbB_pslverr = 1'b0;

  always_comb
    apbB_pready = apbB_psel && apbB_penable;

  always_comb
    apbB_prdata = slaveB_reg[apbB_paddr[3:2]];

  always_ff @(posedge i_tgtClk or negedge i_tgtArst_n)
    if (!i_tgtArst_n) begin
      slaveB_reg[0] <= 32'hB000_0000;
      slaveB_reg[1] <= 32'hB111_1111;
      slaveB_reg[2] <= 32'hB222_2222;
      slaveB_reg[3] <= 32'hB333_3333;
    end else if (apbB_psel && apbB_penable && apbB_pwrite) begin
      slaveB_reg[apbB_paddr[3:2]] <= apbB_pwdata;
    end
  // }}} Target B

  // {{{ NI port connections — fabric side of each bridge drives the noc arrays
  for (genvar i = 0; i < GRID_WIDTH; i++) begin: gen_ni_row
    for (genvar j = 0; j < GRID_WIDTH; j++) begin: gen_ni_col
      if (i == INIT0_ROW && j == INIT0_COL) begin: gen_i0
        always_comb niToRouter[i][j]         = fabNiToRouter_i0;
        always_comb niToRouterValid[i][j]    = fabNiToRouterValid_i0;
        always_comb fabNiToRouterReady_i0    = niToRouterReady[i][j];
        always_comb fabRouterToNi_i0         = routerToNi[i][j];
        always_comb fabRouterToNiValid_i0    = routerToNiValid[i][j];
        always_comb routerToNiReady[i][j]    = fabRouterToNiReady_i0;
      end: gen_i0
      else if (i == INIT1_ROW && j == INIT1_COL) begin: gen_i1
        always_comb niToRouter[i][j]         = fabNiToRouter_i1;
        always_comb niToRouterValid[i][j]    = fabNiToRouterValid_i1;
        always_comb fabNiToRouterReady_i1    = niToRouterReady[i][j];
        always_comb fabRouterToNi_i1         = routerToNi[i][j];
        always_comb fabRouterToNiValid_i1    = routerToNiValid[i][j];
        always_comb routerToNiReady[i][j]    = fabRouterToNiReady_i1;
      end: gen_i1
      else if (i == TGTA_ROW && j == TGTA_COL) begin: gen_tA
        always_comb niToRouter[i][j]         = fabNiToRouter_tA;
        always_comb niToRouterValid[i][j]    = fabNiToRouterValid_tA;
        always_comb fabNiToRouterReady_tA    = niToRouterReady[i][j];
        always_comb fabRouterToNi_tA         = routerToNi[i][j];
        always_comb fabRouterToNiValid_tA    = routerToNiValid[i][j];
        always_comb routerToNiReady[i][j]    = fabRouterToNiReady_tA;
      end: gen_tA
      else if (i == TGTB_ROW && j == TGTB_COL) begin: gen_tB
        always_comb niToRouter[i][j]         = fabNiToRouter_tB;
        always_comb niToRouterValid[i][j]    = fabNiToRouterValid_tB;
        always_comb fabNiToRouterReady_tB    = niToRouterReady[i][j];
        always_comb fabRouterToNi_tB         = routerToNi[i][j];
        always_comb fabRouterToNiValid_tB    = routerToNiValid[i][j];
        always_comb routerToNiReady[i][j]    = fabRouterToNiReady_tB;
      end: gen_tB
      else begin: gen_tieoff
        always_comb niToRouter[i][j]      = '0;
        always_comb niToRouterValid[i][j] = 1'b0;
        always_comb routerToNiReady[i][j] = 1'b1;
      end: gen_tieoff
    end
  end
  // }}} NI port connections

  // {{{ NOC (fabric clock domain)
  noc
  #(.GRID_WIDTH (GRID_WIDTH)
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
