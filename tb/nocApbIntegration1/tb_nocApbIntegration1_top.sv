// Integration testbench wrapper
// Instantiates the NOC with TWO niApbInitiator masters (on different routers)
// and TWO niApbTarget slaves (on different routers).  Both initiators share an
// address map that can reach either target, so this exercises concurrent
// multi-initiator / multi-target traffic and the dynamic source-based response
// routing of niApbTarget.
//
// Node placement (default 4x4 grid):
//   Initiator 0 : (0,0)              Target A : (0, GRID_WIDTH-1)
//   Initiator 1 : (GW-1,GW-1)        Target B : (GRID_WIDTH-1, 0)
//
// Address map (shared by both initiators):
//   0x0000_0000 - 0x0FFF_FFFF -> Target A
//   0x1000_0000 - 0x1FFF_FFFF -> Target B

`default_nettype none

module tb_nocApbIntegration1_top
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
( input  var logic i_clk
, input  var logic i_arst_n

  // Initiator 0 APB master interface — driven by C++
, input  var logic [31:0] i_paddr0
, input  var logic [31:0] i_pwdata0
, input  var logic        i_pwrite0
, input  var logic [3:0]  i_pstrb0
, input  var logic        i_psel0
, input  var logic        i_penable0
, output var logic        o_pready0
, output var logic        o_pslverr0
, output var logic [31:0] o_prdata0

  // Initiator 1 APB master interface — driven by C++
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

  // {{{ NOC interconnect arrays
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0][PACKET_WIDTH-1:0] niToRouter;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0]                   niToRouterValid;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0]                   niToRouterReady;

  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0][PACKET_WIDTH-1:0] routerToNi;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0]                   routerToNiValid;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0]                   routerToNiReady;
  // }}} NOC interconnect arrays

  // {{{ Initiator 0 NI — router-side signals
  logic [PACKET_WIDTH-1:0] niToRouter_i0;
  logic                    niToRouterValid_i0;
  logic                    niToRouterReady_i0;
  logic [PACKET_WIDTH-1:0] routerToNi_i0;
  logic                    routerToNiValid_i0;
  logic                    routerToNiReady_i0;

  always_comb
    niToRouterReady_i0 = niToRouterReady[INIT0_ROW][INIT0_COL];

  always_comb
    routerToNi_i0 = routerToNi[INIT0_ROW][INIT0_COL];

  always_comb
    routerToNiValid_i0 = routerToNiValid[INIT0_ROW][INIT0_COL];

  niApbInitiator
  #(.GRID_WIDTH            (GRID_WIDTH)
  , .NUM_ADDR_MAP_ENTRIES  (NUM_ENTRIES)
  , .ADDR_MAP              (ADDR_MAP)
  , .SRC_ROW               (INIT0_ROW)
  , .SRC_COL               (INIT0_COL)
  ) u_init0
  ( .i_clk     (i_clk)
  , .i_arst_n  (i_arst_n)

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
  // }}} Initiator 0

  // {{{ Initiator 1 NI — router-side signals
  logic [PACKET_WIDTH-1:0] niToRouter_i1;
  logic                    niToRouterValid_i1;
  logic                    niToRouterReady_i1;
  logic [PACKET_WIDTH-1:0] routerToNi_i1;
  logic                    routerToNiValid_i1;
  logic                    routerToNiReady_i1;

  always_comb
    niToRouterReady_i1 = niToRouterReady[INIT1_ROW][INIT1_COL];

  always_comb
    routerToNi_i1 = routerToNi[INIT1_ROW][INIT1_COL];

  always_comb
    routerToNiValid_i1 = routerToNiValid[INIT1_ROW][INIT1_COL];

  niApbInitiator
  #(.GRID_WIDTH            (GRID_WIDTH)
  , .NUM_ADDR_MAP_ENTRIES  (NUM_ENTRIES)
  , .ADDR_MAP              (ADDR_MAP)
  , .SRC_ROW               (INIT1_ROW)
  , .SRC_COL               (INIT1_COL)
  ) u_init1
  ( .i_clk     (i_clk)
  , .i_arst_n  (i_arst_n)

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
  // }}} Initiator 1

  // {{{ Target A NI + APB slave
  logic [PACKET_WIDTH-1:0] niToRouter_tA;
  logic                    niToRouterValid_tA;
  logic                    niToRouterReady_tA;
  logic [PACKET_WIDTH-1:0] routerToNi_tA;
  logic                    routerToNiValid_tA;
  logic                    routerToNiReady_tA;

  logic [31:0] apbA_paddr;
  logic [31:0] apbA_pwdata;
  logic        apbA_pwrite;
  logic [3:0]  apbA_pstrb;
  logic        apbA_psel;
  logic        apbA_penable;
  logic        apbA_pready;
  logic        apbA_pslverr;
  logic [31:0] apbA_prdata;

  always_comb
    routerToNi_tA = routerToNi[TGTA_ROW][TGTA_COL];

  always_comb
    routerToNiValid_tA = routerToNiValid[TGTA_ROW][TGTA_COL];

  always_comb
    niToRouterReady_tA = niToRouterReady[TGTA_ROW][TGTA_COL];

  niApbTarget
  #(.GRID_WIDTH (GRID_WIDTH)
  , .MY_ROW     (TGTA_ROW)
  , .MY_COL     (TGTA_COL)
  ) u_tgtA
  ( .i_clk     (i_clk)
  , .i_arst_n  (i_arst_n)

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

  // Simple APB slave for Target A: 4 word registers, immediate PREADY.
  logic [31:0] slaveA_reg [0:3];

  always_comb
    apbA_pslverr = 1'b0;

  always_comb
    apbA_pready = apbA_psel && apbA_penable;

  always_comb
    apbA_prdata = slaveA_reg[apbA_paddr[3:2]];

  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n) begin
      slaveA_reg[0] <= 32'hA000_0000;
      slaveA_reg[1] <= 32'hA111_1111;
      slaveA_reg[2] <= 32'hA222_2222;
      slaveA_reg[3] <= 32'hA333_3333;
    end else if (apbA_psel && apbA_penable && apbA_pwrite) begin
      slaveA_reg[apbA_paddr[3:2]] <= apbA_pwdata;
    end
  // }}} Target A

  // {{{ Target B NI + APB slave
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

  // Simple APB slave for Target B: 4 word registers, immediate PREADY.
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
      if (i == INIT0_ROW && j == INIT0_COL) begin: gen_i0
        always_comb niToRouter[i][j]      = niToRouter_i0;
        always_comb niToRouterValid[i][j] = niToRouterValid_i0;
        always_comb routerToNiReady[i][j] = routerToNiReady_i0;
      end: gen_i0
      else if (i == INIT1_ROW && j == INIT1_COL) begin: gen_i1
        always_comb niToRouter[i][j]      = niToRouter_i1;
        always_comb niToRouterValid[i][j] = niToRouterValid_i1;
        always_comb routerToNiReady[i][j] = routerToNiReady_i1;
      end: gen_i1
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
