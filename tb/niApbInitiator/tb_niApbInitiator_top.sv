// Testbench wrapper
// This module instantiates the NOC and connects a single Apb Initiator
// to a router (SRC_ROW, SRC_COL). APB and destination monitor ports are
// exposed to C++ via Verilator. A C++ APB driver can drive APB transactions
// into the initiator and observe the responses.

`default_nettype none

module tb_niApbInitiator_top
#(parameter int unsigned GRID_WIDTH        = 4
, parameter int unsigned SRC_ROW           = 0
, parameter int unsigned SRC_COL           = 0
, parameter int unsigned MAX_NI_PER_ROUTER = pa_noc::MAX_NI_PER_ROUTER
, parameter int unsigned NI_ID             = 0

, localparam int unsigned COORD_WIDTH    = $clog2(GRID_WIDTH)
, localparam int unsigned NI_ID_WIDTH    = (MAX_NI_PER_ROUTER > 1) ? $clog2(MAX_NI_PER_ROUTER) : 0
, localparam int unsigned PAYLOAD_WIDTH  = pa_noc::APB_PAYLOAD_WIDTH
, localparam int unsigned PACKET_WIDTH   = PAYLOAD_WIDTH + (2 * NI_ID_WIDTH) + (COORD_WIDTH * 4)
, localparam int unsigned NUM_ROUTERS    = GRID_WIDTH * GRID_WIDTH
)
( input  var logic i_clk
, input  var logic i_arst_n

  // APB initiator (master) interface — driven by C++
, input  var logic [31:0] i_paddr
, input  var logic [31:0] i_pwdata
, input  var logic        i_pwrite
, input  var logic [3:0]  i_pstrb
, input  var logic        i_psel
, input  var logic        i_penable
, output var logic        o_pready
, output var logic        o_pslverr
, output var logic [31:0] o_prdata

  // Destination monitor — flat output for C++ to observe all NI outputs
, output var logic [NUM_ROUTERS-1:0]                   o_routerToNiValid
, output var logic [NUM_ROUTERS*PACKET_WIDTH-1:0]      o_routerToNi_flat
);

  // {{{ Address map
  // 4 entries mapping address ranges to destinations
  // Entry 0: 0x0000_0000 – 0x0FFF_FFFF → router (0,1)
  // Entry 1: 0x1000_0000 – 0x1FFF_FFFF → router (1,0)
  // Entry 2: 0x2000_0000 – 0x2FFF_FFFF → router (1,1)
  // Entry 3: 0x3000_0000 – 0x3FFF_FFFF → router (GRID_WIDTH-1, GRID_WIDTH-1)
  localparam int unsigned NUM_ENTRIES = 4;

  localparam pa_noc::ty_ADDR_MAP_ENTRY [NUM_ENTRIES-1:0] ADDR_MAP =
    '{
      '{baseAddr: 32'h3000_0000
      , endAddr: 32'h3FFF_FFFF
      , dstRow: 8'(GRID_WIDTH-1)
      , dstCol: 8'(GRID_WIDTH-1)
      , dstNiId: 8'd0
      },
      '{baseAddr: 32'h2000_0000
      , endAddr: 32'h2FFF_FFFF
      , dstRow: 8'd1
      , dstCol: 8'd1
      , dstNiId: 8'd0
      },
      '{baseAddr: 32'h1000_0000
      , endAddr: 32'h1FFF_FFFF
      , dstRow: 8'd1
      , dstCol: 8'd0
      , dstNiId: 8'd0
      },
      '{baseAddr: 32'h0000_0000
      , endAddr: 32'h0FFF_FFFF
      , dstRow: 8'd0
      , dstCol: 8'd1
      , dstNiId: 8'd0
      }
    };
  // }}} Address map

  // {{{ Interconnects
  // NOC signals
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0][PACKET_WIDTH-1:0] niToRouter;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0]                   niToRouterValid;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0]                   niToRouterReady;

  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0][PACKET_WIDTH-1:0] routerToNi;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0]                   routerToNiValid;
  logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0]                   routerToNiReady;

  // niApbInitiator instance — connected at (SRC_ROW, SRC_COL)
  logic [PACKET_WIDTH-1:0] niToRouter_src;
  logic                    niToRouterValid_src;
  logic                    niToRouterReady_src;
  logic [PACKET_WIDTH-1:0] routerToNi_src;
  logic                    routerToNiValid_src;
  logic                    routerToNiReady_src;
  // }}} Interconnects

  niApbInitiator
  #(.GRID_WIDTH        (GRID_WIDTH)
  , .NUM_ADDR_MAP_ENTRIES (NUM_ENTRIES)
  , .ADDR_MAP          (ADDR_MAP)
  , .SRC_ROW           (SRC_ROW)
  , .SRC_COL           (SRC_COL)
  , .MAX_NI_PER_ROUTER (MAX_NI_PER_ROUTER)
  , .NI_ID             (NI_ID)
  ) u_niApbInitiator
  ( .i_clk     (i_clk)
  , .i_arst_n  (i_arst_n)

  , .i_paddr   (i_paddr)
  , .i_pwdata  (i_pwdata)
  , .i_pwrite  (i_pwrite)
  , .i_pstrb   (i_pstrb)
  , .i_psel    (i_psel)
  , .i_penable (i_penable)
  , .o_pready  (o_pready)
  , .o_pslverr (o_pslverr)
  , .o_prdata  (o_prdata)

  , .o_niToRouter      (niToRouter_src)
  , .o_niToRouterValid (niToRouterValid_src)
  , .i_niToRouterReady (niToRouterReady_src)

  , .i_routerToNi      (routerToNi_src)
  , .i_routerToNiValid (routerToNiValid_src)
  , .o_routerToNiReady (routerToNiReady_src)
  );

  // Wire niApbInitiator to NOC at (SRC_ROW, SRC_COL)
  // Tie off all other NI inputs (no other initiators active)
  for (genvar i = 0; i < GRID_WIDTH; i++) begin: gen_ni_row
    for (genvar j = 0; j < GRID_WIDTH; j++) begin: gen_ni_col
      always_comb begin
        if (i == SRC_ROW && j == SRC_COL) begin
          niToRouter[i][j]      = niToRouter_src;
          niToRouterValid[i][j] = niToRouterValid_src;
          routerToNiReady[i][j] = routerToNiReady_src;
        end else begin
          niToRouter[i][j]      = '0;
          niToRouterValid[i][j] = 1'b0;
          routerToNiReady[i][j] = 1'b1; // always accept (drain) at idle nodes
        end
      end
    end
  end

  always_comb
    niToRouterReady_src = niToRouterReady[SRC_ROW][SRC_COL];

  always_comb
    routerToNi_src = routerToNi[SRC_ROW][SRC_COL];

  always_comb
    routerToNiValid_src = routerToNiValid[SRC_ROW][SRC_COL];

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

  // {{{ Flatten outputs for C++ access
  for (genvar i = 0; i < GRID_WIDTH; i++) begin: gen_row
    for (genvar j = 0; j < GRID_WIDTH; j++) begin: gen_col

      localparam int unsigned IDX = i * GRID_WIDTH + j;

      always_comb
        o_routerToNiValid[IDX] = routerToNiValid[i][j];

      always_comb
        o_routerToNi_flat[IDX*PACKET_WIDTH +: PACKET_WIDTH] = routerToNi[i][j];
    end
  end
  // }}} Flatten outputs for C++ access

endmodule

`resetall
