// Top level module.

`default_nettype none

module noc
#(parameter int unsigned GRID_WIDTH = 4
, localparam int unsigned PACKET_WIDTH = pa_noc::PACKET_WIDTH
)
( input  var logic i_clk
, input  var logic i_arst_n

, input  var logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0][PACKET_WIDTH-1:0] i_niToRouter
, output var logic [GRID_WIDTH-1:0][GRID_WIDTH-1:0][PACKET_WIDTH-1:0] o_routerToNi
);

  if (GRID_WIDTH < 2) begin: ParamCheck
    $error("Grid width parameter 'GRID_WIDTH' is invalid. Must be at least 2.");
  end: ParamCheck

  // NOTE: The mesh has been instanced without being connected to any network
  // interfaces. For now, this is to test whether the mesh itself and the
  // routing algorithms have been implemented correctly.

  mesh
  #(.GRID_WIDTH(GRID_WIDTH))
  u_mesh
  ( .i_clk    (i_clk)
  , .i_arst_n (i_arst_n)

  , .i_niToRouter (i_niToRouter)
  , .o_routerToNi (o_routerToNi)
  );

endmodule

`resetall
