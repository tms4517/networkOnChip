`default_nettype none

module roundRobinArbiter
#(localparam int unsigned NUM_CLIENTS = 4)
( input  var logic i_clk
, input  var logic i_rst_n

, input  var logic [NUM_CLIENTS-1:0] i_request
, output var logic [NUM_CLIENTS-1:0] o_grant
);

  typedef enum logic [3:0]
  { CLIENT_0_MASK = 4'b1111
  , CLIENT_1_MASK = 4'b1110
  , CLIENT_2_MASK = 4'b1100
  , CLIENT_3_MASK = 4'b1000
  } ty_CLIENT_MASK;

  typedef enum logic [3:0]
  { CLIENT_0 = 4'b0001
  , CLIENT_1 = 4'b0010
  , CLIENT_2 = 4'b0100
  , CLIENT_3 = 4'b1000
  } ty_CLIENT_GRANTED;

  ty_CLIENT_MASK mask_q, mask_d;
  ty_CLIENT_GRANTED grant_q, grant_d;

  // Mask register: tracks which client should be prioritized next, The mask is
  // updated when a grant is issued, and determines the priority order for the
  // next arbitration cycle.
  always_ff @(posedge i_clk, negedge i_rst_n)
    if (!i_rst_n)
      mask_q <= CLIENT_0_MASK;
    else if ((grant_d != 0))
      mask_q <= mask_d;
    else
      mask_q <= mask_q;

  always_comb
    case (grant_q)
      CLIENT_0: mask_d = CLIENT_1_MASK;
      CLIENT_1: mask_d = CLIENT_2_MASK;
      CLIENT_2: mask_d = CLIENT_3_MASK;
      CLIENT_3: mask_d = CLIENT_0_MASK;
      default: mask_d = mask_q;
    endcase

  // Client granted access.
  always_ff @(posedge i_clk, negedge i_rst_n)
    if (!i_rst_n)
      grant_q <= ty_CLIENT_GRANTED'('0);
    else
      grant_q <= grant_d;

  // Determine if the current mask allows any of the requesting clients to be
  // granted. If there are no requests that match the mask, grant based on the
  // raw request (wrap-around).
  logic [NUM_CLIENTS-1:0] maskedReq;
  ty_CLIENT_GRANTED maskedGrant, rawRequestGrant;

  always_comb
    maskedReq = i_request & mask_q;

  always_comb
    if (maskedReq[0])
      maskedGrant = CLIENT_0;
    else if (maskedReq[1])
      maskedGrant = CLIENT_1;
    else if (maskedReq[2])
      maskedGrant = CLIENT_2;
    else if (maskedReq[3])
      maskedGrant = CLIENT_3;
    else
      maskedGrant = ty_CLIENT_GRANTED'('0);

  always_comb
    if (i_request[0])
      rawRequestGrant = CLIENT_0;
    else if (i_request[1])
      rawRequestGrant = CLIENT_1;
    else if (i_request[2])
      rawRequestGrant = CLIENT_2;
    else if (i_request[3])
      rawRequestGrant = CLIENT_3;
    else
      rawRequestGrant = ty_CLIENT_GRANTED'('0);

  always_comb
    grant_d = (maskedReq != 0) ? maskedGrant : rawRequestGrant;

  always_comb
    o_grant = grant_q;

endmodule

`resetall
