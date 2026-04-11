// Round-robin arbiter for NUM_CLIENTS requesters.

// Maintains a rotating priority mask so that after a client is granted and
// acknowledged (i_ack), the next-highest-numbered client becomes highest
// priority, wrapping around from the last client back to client 0.
// If no masked request is active, the arbiter falls back to raw (unmasked)
// priority order to avoid deadlock. The grant is held stable until the
// downstream consumer asserts i_ack, preventing starvation of un-serviced
// clients.

`default_nettype none

module roundRobinArbiter
#(localparam int unsigned NUM_CLIENTS = 5)
( input  var logic i_clk
, input  var logic i_rst_n

, input  var logic [NUM_CLIENTS-1:0] i_request
// Acknowledgement from downstream that the granted packet has been consumed.
// The arbiter holds the current grant stable until i_ack is asserted, ensuring
// that a client is not starved if the router cannot forward its packet.
, input  var logic                   i_ack
, output var logic [NUM_CLIENTS-1:0] o_grant
);

  typedef enum logic [4:0]
  { CLIENT_0_MASK = 5'b11111
  , CLIENT_1_MASK = 5'b11110
  , CLIENT_2_MASK = 5'b11100
  , CLIENT_3_MASK = 5'b11000
  , CLIENT_4_MASK = 5'b10000
  } ty_CLIENT_MASK;

  typedef enum logic [4:0]
  { CLIENT_0 = 5'b00001
  , CLIENT_1 = 5'b00010
  , CLIENT_2 = 5'b00100
  , CLIENT_3 = 5'b01000
  , CLIENT_4 = 5'b10000
  } ty_CLIENT_GRANTED;

  ty_CLIENT_MASK mask_q, mask_d;
  ty_CLIENT_GRANTED grant_q, grant_d;
  logic currentGrantHasRequest;

  // Mask register: tracks which client should be prioritized next. The mask is
  // updated only when a grant is issued AND the downstream acknowledges
  // consumption (i_ack), ensuring the arbiter holds the current grant stable
  // until the packet is actually forwarded.
  always_ff @(posedge i_clk, negedge i_rst_n)
    if (!i_rst_n)
      mask_q <= CLIENT_0_MASK;
    else if ((grant_d != 0) && i_ack)
      mask_q <= mask_d;
    else
      mask_q <= mask_q;

  always_comb
    case (grant_q)
      CLIENT_0: mask_d = CLIENT_1_MASK;
      CLIENT_1: mask_d = CLIENT_2_MASK;
      CLIENT_2: mask_d = CLIENT_3_MASK;
      CLIENT_3: mask_d = CLIENT_4_MASK;
      CLIENT_4: mask_d = CLIENT_0_MASK;
      default: mask_d = mask_q;
    endcase

  // Client granted access. Only advance to the next grant when the current one
  // has been acknowledged.
  always_comb
    currentGrantHasRequest = |(grant_q & i_request);

  always_ff @(posedge i_clk, negedge i_rst_n)
    if (!i_rst_n)
      grant_q <= ty_CLIENT_GRANTED'('0);
    // Re-arbitrate if current transfer is acknowledged, if there is no active
    // grant yet, or if the granted requester no longer has a request.
    else if (i_ack || (grant_q == ty_CLIENT_GRANTED'('0))
                  || !currentGrantHasRequest)
      grant_q <= grant_d;
    else
      grant_q <= grant_q;

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
    else if (maskedReq[4])
      maskedGrant = CLIENT_4;
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
    else if (i_request[4])
      rawRequestGrant = CLIENT_4;
    else
      rawRequestGrant = ty_CLIENT_GRANTED'('0);

  always_comb
    grant_d = (maskedReq != 0) ? maskedGrant : rawRequestGrant;

  always_comb
    o_grant = grant_q;

endmodule

`resetall
