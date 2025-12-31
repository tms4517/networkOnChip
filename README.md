# Network On Chip

This repository contains a rudimentary implementation of a Network On Chip
(NOC).

## Preliminary

Here is a compilation of resources that helped me gain a better understanding.

**Lectures:**
1. [Lec 93 - Network-on-chip basics ](https://youtu.be/7-KJ3BnFsr8?si=_OVRzOOJtf1CBOBV)
2. [Lec 94 - NoC - topologies and metrics](https://youtu.be/ocyE11htZTk?si=3FIPpv9kX1Cwj1gj)
3. [Lec 95 - NoC - routing](https://youtu.be/wmqrgNKJrro?si=NOxIGlCZCNCAop3I)
4. [Lec 96 - NoC - switching and flow control ](https://youtu.be/Qq6C0DkklgU?si=7plMJajoXen2zAl9)


**Papers:**

(See `papers/`)
1. W. J. Dally and B. Towles, "Route packets, not wires: on-chip interconnection networks," Proceedings of the 38th Design Automation Conference (IEEE Cat. No.01CH37232), Las Vegas, NV, USA, 2001, pp. 684-689.
2. Network-On-Chip Design by Haseeb Bokhari and Sri Parameswaran.

## Architecture

This implementation consists of a **2D mesh Network-on-Chip (NoC)** with the following key components:

### Topology: 2D Mesh

The NoC uses a 2D mesh topology where routers are arranged in a grid pattern. Each router connects to:
- **Four neighboring routers** (North, South, East, West) - except edge routers which have fewer connections
- **Two local Network Interface (NI)**: one converts packets from the router to
a communication protocol that an IP block can understand; the other converts
a communication protocol to packets that can be routed.

The mesh size is configurable via the `GRID_WIDTH` parameter (minimum 2x2 grid).

### Packet Format

Packets are 73 bits wide (`APB_PACKET_WIDTH`) with the following structure:
- **Bits [1:0]:** Destination column coordinate
- **Bits [3:2]:** Destination row coordinate
- **Bits [72:4]:** Payload (69 bits)

### Routing Algorithm: XY Routing

Each router implements deterministic **XY routing**:
1. **X-dimension first:** Packets move horizontally (East/West) until reaching the destination column
2. **Y-dimension second:** Once aligned column-wise, packets move vertically (North/South) to the destination row
3. **Local delivery:** When router coordinates match the destination, the packet is forwarded to the local NI

This guarantees deadlock-free routing in the mesh topology.

### Module Hierarchy

- **[noc.sv](rtl/noc.sv):** Top-level module that instantiates the mesh
- **[mesh.sv](rtl/mesh.sv):** Interconnects routers in a 2D grid, handling all router-to-router connections and edge router boundary conditions
- **[router.sv](rtl/router.sv):** Individual router implementing XY routing logic with 5 ports (4 neighbors + 1 local NI)
- **[pa_noc.sv](rtl/pa_noc.sv):** Package containing parameter definitions and packet format constants

### Key Design Choices

- **Registered outputs:** All router outputs are registered to improve timing.
- **Edge optimization:** Synthesis automatically optimizes away impossible routing comparisons at mesh boundaries.
- **Coordinate-based routing:** Simple address-based routing eliminates need for routing tables.
