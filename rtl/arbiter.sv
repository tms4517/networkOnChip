// Arbiter that selects and forwards packets from multiple input FIFOs
// Uses round-robin scheduling to fairly distribute output bandwidth
`default_nettype none

module arbiter
#(parameter int unsigned NUM_INPUTS = 5
, parameter int unsigned WIDTH = 73
)
( input  var logic i_clk
, input  var logic i_arst_n

// Input ports (from FIFOs)
, input  var logic [NUM_INPUTS-1:0][WIDTH-1:0] i_data
, input  var logic [NUM_INPUTS-1:0] i_valid
, output var logic [NUM_INPUTS-1:0] o_ready

// Output port
, output var logic [WIDTH-1:0] o_data
, output var logic o_valid
, input  var logic i_ready
);

  logic [NUM_INPUTS-1:0] grant;
  logic [$clog2(NUM_INPUTS)-1:0] grant_idx;
  logic [$clog2(NUM_INPUTS)-1:0] priority;

  // Round-robin priority pointer
  always_ff @(posedge i_clk or negedge i_arst_n)
    if (!i_arst_n)
      priority <= '0;
    else if (o_valid && i_ready)
      priority <= priority + 1;

  // Round-robin arbiter: rotate priority each cycle when packet is accepted
  round_robin_arbiter #(.NUM_INPUTS(NUM_INPUTS))
  u_arbiter (
    .i_requests(i_valid),
    .i_priority(priority),
    .o_grant(grant),
    .o_grant_idx(grant_idx)
  );

  // Output multiplexer
  always_comb
    o_data = i_data[grant_idx];

  // Output handshaking
  assign o_valid = |grant;

  // Ready signal goes to selected FIFO
  always_comb begin
    o_ready = '0;
    if (o_valid)
      o_ready[grant_idx] = i_ready;
  end

endmodule

`resetall
