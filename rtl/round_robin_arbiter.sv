// Round-robin arbiter: grants access based on rotating priority
// Ensures fair scheduling by advancing priority pointer after each grant
`default_nettype none

module round_robin_arbiter
#(parameter int unsigned NUM_INPUTS = 5)
( input  var logic [NUM_INPUTS-1:0] i_requests
, input  var logic [$clog2(NUM_INPUTS)-1:0] i_priority
, output var logic [NUM_INPUTS-1:0] o_grant
, output var logic [$clog2(NUM_INPUTS)-1:0] o_grant_idx
);

  logic [NUM_INPUTS-1:0] rotated_requests;
  logic [$clog2(NUM_INPUTS)-1:0] priority_offset;

  // Rotate requests based on priority pointer
  always_comb begin
    rotated_requests = '0;
    for (int i = 0; i < NUM_INPUTS; i++) begin
      rotated_requests[(i - i_priority) % NUM_INPUTS] = i_requests[i];
    end
  end

  // Priority encoder: find lowest set bit in rotated requests
  always_comb begin
    priority_offset = '0;
    for (int i = NUM_INPUTS - 1; i >= 0; i--) begin
      if (rotated_requests[i])
        priority_offset = i;
    end
  end

  // Convert back to original index
  assign o_grant_idx = (priority_offset + i_priority) % NUM_INPUTS;

  // Generate grant signal (one-hot)
  always_comb begin
    o_grant = '0;
    if (|i_requests)
      o_grant[o_grant_idx] = 1'b1;
  end

endmodule

`resetall
