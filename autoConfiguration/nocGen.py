#!/usr/bin/env python3
# Copyright (c) 2026 Tej Sanghavi.
"""Generate a ready-to-integrate noc<ProjectName> top from a JSON description.

The JSON lists initiators and targets (name, protocol, clock domain, router
and, for targets, an address map), the mesh grid width (gridWidth N gives an
NxN mesh; routers are numbered row-major 0..N*N-1) and the fabric clock.
The generated top exposes only the initiator/target protocol ports plus one
clock/reset pair per clock domain; NIs, CDC bridges, router-port muxes, target
protocol bridges and the mesh are instantiated and wired internally.

The output directory is a self-contained project: rtl/ (NoC library + top),
tb/ (self-checking testbench), synth/ (Yosys script) and a Makefile with
lint, sim and synth targets.

Usage: nocGen.py <config.json> -o <outDir>
"""

import argparse
import datetime
import json
import math
import os
import re
import shutil
import sys

NOC_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RTL_PATH = os.path.join(NOC_ROOT, "rtl")

PROTOCOLS = ("apb", "ahb", "axiLite")

PROTOCOL_TITLE = {"apb": "APB", "ahb": "AHB-Lite", "axiLite": "AXI4-Lite"}

PROTOCOL_CAMEL = {"apb": "Apb", "ahb": "Ahb", "axiLite": "AxiLite"}

OPCODE = {
    "apb": "pa_noc::PROTO_APB",
    "ahb": "pa_noc::PROTO_AHB",
    "axiLite": "pa_noc::PROTO_AXI_LITE",
}

NATIVE_PAYLOAD = {
    "apb": "pa_noc::APB_PAYLOAD_WIDTH",
    "ahb": "$bits(pa_noc::ty_AHB_PAYLOAD)",
    "axiLite": "$bits(pa_noc::ty_AXI_LITE_PAYLOAD)",
}

# Target wrappers instantiate AXI-Lite and AHB NIs, so mixed mode needs >= 71.
MIXED_PAYLOAD = "$bits(pa_noc::ty_AXI_LITE_PAYLOAD)"

TARGET_BRIDGE = {
    "apb": ("apbTargetBridge", ["axiLiteToApbBridge", "ahbToApbBridge"]),
    "ahb": ("ahbTargetBridge", ["axiLiteToAhbBridge", "apbToAhbBridge"]),
    "axiLite": ("axiTargetBridge", ["ahbToAxiLiteBridge",
                                    "apbToAxiLiteBridge"]),
}

# (direction at the NI, width, signal) for the user-facing protocol ports.
INITIATOR_PORTS = {
    "apb": [
        ("input", 32, "paddr"), ("input", 32, "pwdata"),
        ("input", 1, "pwrite"), ("input", 4, "pstrb"),
        ("input", 1, "psel"), ("input", 1, "penable"),
        ("output", 1, "pready"), ("output", 1, "pslverr"),
        ("output", 32, "prdata"),
    ],
    "ahb": [
        ("input", 1, "hsel"), ("input", 32, "haddr"),
        ("input", 1, "hwrite"), ("input", 3, "hsize"),
        ("input", 2, "htrans"), ("input", 32, "hwdata"),
        ("input", 1, "hready"), ("output", 1, "hreadyout"),
        ("output", 1, "hresp"), ("output", 32, "hrdata"),
    ],
    "axiLite": [
        ("input", 32, "awaddr"), ("input", 1, "awvalid"),
        ("output", 1, "awready"),
        ("input", 32, "wdata"), ("input", 4, "wstrb"),
        ("input", 1, "wvalid"), ("output", 1, "wready"),
        ("output", 2, "bresp"), ("output", 1, "bvalid"),
        ("input", 1, "bready"),
        ("input", 32, "araddr"), ("input", 1, "arvalid"),
        ("output", 1, "arready"),
        ("output", 32, "rdata"), ("output", 2, "rresp"),
        ("output", 1, "rvalid"), ("input", 1, "rready"),
    ],
}

TARGET_PORTS = {
    "apb": [
        ("output", 32, "paddr"), ("output", 32, "pwdata"),
        ("output", 1, "pwrite"), ("output", 4, "pstrb"),
        ("output", 1, "psel"), ("output", 1, "penable"),
        ("input", 1, "pready"), ("input", 1, "pslverr"),
        ("input", 32, "prdata"),
    ],
    "ahb": [
        ("output", 1, "hsel"), ("output", 32, "haddr"),
        ("output", 1, "hwrite"), ("output", 3, "hsize"),
        ("output", 2, "htrans"), ("output", 32, "hwdata"),
        ("input", 32, "hrdata"), ("input", 1, "hready"),
        ("input", 1, "hresp"),
    ],
    "axiLite": [
        ("output", 32, "awaddr"), ("output", 1, "awvalid"),
        ("input", 1, "awready"),
        ("output", 32, "wdata"), ("output", 4, "wstrb"),
        ("output", 1, "wvalid"), ("input", 1, "wready"),
        ("input", 2, "bresp"), ("input", 1, "bvalid"),
        ("output", 1, "bready"),
        ("output", 32, "araddr"), ("output", 1, "arvalid"),
        ("input", 1, "arready"),
        ("input", 32, "rdata"), ("input", 2, "rresp"),
        ("input", 1, "rvalid"), ("output", 1, "rready"),
    ],
}

IDENTIFIER = re.compile(r"^[a-z][A-Za-z0-9]*$")
PROJECT_NAME = re.compile(r"^[A-Za-z][A-Za-z0-9]*$")
RESERVED_NAME = re.compile(r"^(router\d+.*|niToRouter.*|routerToNi.*|noc)$")

ADDRESS_MAX = 0xFFFF_FFFF


class ConfigError(Exception):
    pass


class Node:
    """One initiator or target network interface."""

    def __init__(self, kind, name, protocol, clock, router):
        self.kind = kind
        self.name = name
        self.protocol = protocol
        self.clock = clock
        self.router = router
        self.row = 0
        self.col = 0
        self.niId = 0
        self.regions = []
        self.cdc = False


# {{{ Config parsing and validation

def parseAddress(value, where):
    if isinstance(value, int) and not isinstance(value, bool):
        address = value
    elif isinstance(value, str):
        try:
            address = int(value.replace("_", ""), 0)
        except ValueError:
            raise ConfigError("{}: '{}' is not an address".format(where, value))
    else:
        raise ConfigError("{}: '{}' is not an address".format(where, value))
    if not 0 <= address <= ADDRESS_MAX:
        raise ConfigError("{}: 0x{:X} is outside the 32-bit address space"
                          .format(where, address))
    return address


def require(entry, key, where):
    if key not in entry:
        raise ConfigError("{}: missing '{}'".format(where, key))
    return entry[key]


def isInteger(value):
    return isinstance(value, int) and not isinstance(value, bool)


def checkKeys(entry, allowed, where):
    unknown = sorted(set(entry) - set(allowed))
    if unknown:
        raise ConfigError("{}: unknown key(s) {}; allowed: {}".format(
            where, ", ".join(unknown), ", ".join(allowed)))


def parseNode(kind, entry, numRouters, index):
    """numRouters = gridWidth ** 2; router is a row-major index."""
    where = "{}[{}]".format(kind + "s", index)
    if not isinstance(entry, dict):
        raise ConfigError("{}: must be an object".format(where))
    name = require(entry, "name", where)
    where = "{} '{}'".format(kind, name)
    if not isinstance(name, str) or not IDENTIFIER.match(name):
        raise ConfigError("{}: name must be lowerCamelCase [a-z][A-Za-z0-9]*"
                          .format(where))
    if RESERVED_NAME.match(name):
        raise ConfigError("{}: name is reserved".format(where))
    protocol = require(entry, "protocol", where)
    if protocol not in PROTOCOLS:
        raise ConfigError("{}: protocol must be one of {}"
                          .format(where, ", ".join(PROTOCOLS)))
    clock = require(entry, "clock", where)
    if not isinstance(clock, str) or not IDENTIFIER.match(clock):
        raise ConfigError("{}: clock must be lowerCamelCase".format(where))
    allowed = ["name", "protocol", "clock", "router"]
    checkKeys(entry, allowed + (["addressMap"] if kind == "target" else []),
              where)
    router = require(entry, "router", where)
    if not isInteger(router) or not 0 <= router < numRouters:
        raise ConfigError("{}: router must be an integer in [0, {}] "
                          "(row-major: router = row * gridWidth + col)"
                          .format(where, numRouters - 1))
    node = Node(kind, name, protocol, clock, router)

    if kind == "target":
        regions = require(entry, "addressMap", where)
        if not isinstance(regions, list) or not regions:
            raise ConfigError("{}: addressMap must be a non-empty list"
                              .format(where))
        for i, region in enumerate(regions):
            regionWhere = "{} addressMap[{}]".format(where, i)
            if not isinstance(region, dict):
                raise ConfigError("{}: must be an object".format(regionWhere))
            checkKeys(region, ["base", "end", "size"], regionWhere)
            base = parseAddress(require(region, "base", regionWhere),
                                regionWhere)
            if ("end" in region) == ("size" in region):
                raise ConfigError("{}: give exactly one of 'end' or 'size'"
                                  .format(regionWhere))
            if "end" in region:
                end = parseAddress(region["end"], regionWhere)
            else:
                size = parseAddress(region["size"], regionWhere)
                if size == 0:
                    raise ConfigError("{}: size must be > 0"
                                      .format(regionWhere))
                end = parseAddress(base + size - 1, regionWhere)
            if end < base:
                raise ConfigError("{}: end is below base".format(regionWhere))
            node.regions.append((base, end))
    elif "addressMap" in entry:
        raise ConfigError("{}: initiators do not take an addressMap"
                          .format(where))
    return node


class Noc:
    """Validated NoC description plus derived placement."""

    def __init__(self, config):
        if not isinstance(config, dict):
            raise ConfigError("top level must be an object")
        checkKeys(config, ["projectName", "gridWidth", "fabricClock",
                           "initiators", "targets"], "config")

        project = require(config, "projectName", "config")
        if not isinstance(project, str) or not PROJECT_NAME.match(project):
            raise ConfigError("projectName must be [A-Za-z][A-Za-z0-9]*")
        self.topName = "noc" + project[0].upper() + project[1:]

        self.gridWidth = require(config, "gridWidth", "config")
        if not isInteger(self.gridWidth) or self.gridWidth < 2:
            raise ConfigError("gridWidth must be an integer >= 2 "
                              "(gridWidth N gives an NxN mesh)")
        self.numRouters = self.gridWidth ** 2

        self.fabricClock = require(config, "fabricClock", "config")
        if (not isinstance(self.fabricClock, str)
                or not IDENTIFIER.match(self.fabricClock)):
            raise ConfigError("fabricClock must be lowerCamelCase")

        initiators = require(config, "initiators", "config")
        targets = require(config, "targets", "config")
        if not isinstance(initiators, list) or not initiators:
            raise ConfigError("initiators must be a non-empty list")
        if not isinstance(targets, list) or not targets:
            raise ConfigError("targets must be a non-empty list")
        self.initiators = [parseNode("initiator", e, self.numRouters, i)
                           for i, e in enumerate(initiators)]
        self.targets = [parseNode("target", e, self.numRouters, i)
                        for i, e in enumerate(targets)]
        self.nodes = self.initiators + self.targets

        names = [n.name for n in self.nodes]
        duplicates = sorted({n for n in names if names.count(n) > 1})
        if duplicates:
            raise ConfigError("duplicate names: {}".format(
                ", ".join(duplicates)))

        self.clocks = [self.fabricClock]
        for node in self.nodes:
            if node.clock not in self.clocks:
                self.clocks.append(node.clock)
            node.cdc = node.clock != self.fabricClock

        self.protocols = sorted({n.protocol for n in self.nodes})
        self.mixed = len(self.protocols) > 1

        self.routerNodes = {}
        for node in self.nodes:
            self.routerNodes.setdefault(node.router, []).append(node)
        for router, nodes in self.routerNodes.items():
            for niId, node in enumerate(nodes):
                node.niId = niId
                node.row = router // self.gridWidth
                node.col = router % self.gridWidth
        self.maxNiPerRouter = max(len(n) for n in self.routerNodes.values())
        if self.maxNiPerRouter > 256:
            raise ConfigError("at most 256 NIs may share a router")
        self.niIdWidth = (math.ceil(math.log2(self.maxNiPerRouter))
                          if self.maxNiPerRouter > 1 else 0)

        self.addressMap = []
        for target in self.targets:
            for base, end in target.regions:
                self.addressMap.append((base, end, target))
        self.addressMap.sort(key=lambda entry: entry[0])
        for (b0, e0, t0), (b1, e1, t1) in zip(self.addressMap,
                                              self.addressMap[1:]):
            if b1 <= e0:
                raise ConfigError(
                    "address overlap: {} [0x{:08X}-0x{:08X}] and {} "
                    "[0x{:08X}-0x{:08X}]".format(t0.name, b0, e0,
                                                 t1.name, b1, e1))

    def rtlFiles(self):
        files = []
        if self.mixed:
            for protocol in self.protocols:
                if any(t.protocol == protocol for t in self.targets):
                    wrapper, bridges = TARGET_BRIDGE[protocol]
                    files += bridges + [wrapper]
        return [os.path.join(RTL_PATH, "bridge", f + ".sv") for f in files]

# }}} Config parsing and validation


# {{{ SystemVerilog emission helpers

def capitalise(text):
    return text[0].upper() + text[1:]


def topPort(node, signal):
    return node.name + capitalise(signal)


def hex32(value):
    return "32'h{:04X}_{:04X}".format(value >> 16, value & 0xFFFF)


def instance(module, params, name, ports):
    """Comma-leading instance with one parameter/port per line."""
    lines = ["  " + module]
    if params:
        width = max(len(p) for p, _ in params)
        for i, (param, value) in enumerate(params):
            lead = "#(" if i == 0 else ", "
            lines.append("  {}.{} ({})".format(lead, param.ljust(width),
                                               value))
        lines.append("  ) " + name)
    else:
        lines[0] += " " + name
    width = max(len(p) for p, _ in ports if p)
    first = True
    for port, value in ports:
        if port is None:
            lines.append(value)
            continue
        lead = "( " if first else ", "
        first = False
        lines.append("  {}.{} ({})".format(lead, port.ljust(width), value))
    lines.append("  );")
    return lines


def declarations(items):
    """Aligned `logic` declarations; items are (packed range, name)."""
    width = max(len(r) for r, _ in items)
    return ["  logic {}{};".format((r + " ").ljust(width + 1) if width else "",
                                   n) for r, n in items]


def lintOff(rule, lines):
    return (["/* verilator lint_off {} */".format(rule)] + lines
            + ["/* verilator lint_on {} */".format(rule)])


def comb(target, expression):
    return ["  always_comb", "    {} = {};".format(target, expression), ""]


# }}} SystemVerilog emission helpers


class Emitter:

    def __init__(self, noc, configPath):
        self.noc = noc
        self.configPath = configPath
        self.lines = []

    def emit(self, *lines):
        self.lines.extend(lines)

    def fold(self, title, description, body):
        self.emit("  // {{{{{{ {}".format(title))
        for line in description:
            self.emit("  // " + line if line else "  //")
        self.emit("")
        self.lines.extend(body)
        if self.lines[-1] != "":
            self.emit("")
        self.emit("  // }}}}}} {}".format(title), "")

    # {{{ Header and ports

    def header(self):
        noc = self.noc
        year = datetime.date.today().year
        self.emit("// Copyright (c) {} Tej Sanghavi.".format(year), "")
        self.emit(
            "// {}: auto-generated NoC top. DO NOT EDIT; regenerate with"
            .format(noc.topName),
            "//   autoConfiguration/nocGen.py {}".format(
                os.path.basename(self.configPath)),
            "//",
            "// Exposes only the initiator/target protocol ports and one"
            " clock/reset",
            "// pair per clock domain. Internally every initiator/target is"
            " attached",
            "// to a {0}x{0} mesh ({1} routers) through its protocol NI,"
            .format(noc.gridWidth, noc.numRouters),
            "// plus a cdcNiBridge when its clock differs from the fabric"
            " clock.",
        )
        if noc.maxNiPerRouter > 1:
            self.emit(
                "// Routers hosting several NIs share their NI port through"
                " niRouterPort.",
            )
        if noc.mixed:
            self.emit(
                "// Mixed protocols: every request is tagged with its"
                " initiator protocol",
                "// opcode and each target is a <protocol>TargetBridge that"
                " converts it.",
            )
        self.emit("//", "// Fabric clock domain: {}".format(noc.fabricClock),
                  "//", "// Placement (router: row, col):")
        for router in sorted(noc.routerNodes):
            nodes = noc.routerNodes[router]
            self.emit("//   router {} ({}, {}):".format(
                router, nodes[0].row, nodes[0].col))
            for n in nodes:
                self.emit("//     NI {}: {} ({} {}, clock {})".format(
                    n.niId, n.name, PROTOCOL_TITLE[n.protocol], n.kind,
                    n.clock))
        self.emit("//", "// Address map:")
        for base, end, target in noc.addressMap:
            self.emit("//   0x{:08X} - 0x{:08X} : {}".format(
                base, end, target.name))
        self.emit("", "`default_nettype none", "", "module " + noc.topName)

    def ports(self):
        noc = self.noc
        ports = []
        for clock in noc.clocks:
            role = " (fabric)" if clock == noc.fabricClock else ""
            ports.append("  // {} clock domain{}".format(clock, role))
            ports.append(("input", "", "i_{}Clk".format(clock)))
            ports.append(("input", "", "i_{}Arst_n".format(clock)))
        for node in noc.nodes:
            table = (INITIATOR_PORTS if node.kind == "initiator"
                     else TARGET_PORTS)[node.protocol]
            ports.append("")
            ports.append("  // {}: {} {}, router {}, clock {}".format(
                node.name, PROTOCOL_TITLE[node.protocol], node.kind,
                node.router, node.clock))
            for direction, width, signal in table:
                prefix = "i_" if direction == "input" else "o_"
                ports.append((direction,
                              "[{}:0]".format(width - 1) if width > 1 else "",
                              prefix + topPort(node, signal)))
        first = True
        for port in ports:
            if isinstance(port, str):
                self.emit(port)
                continue
            direction, packed, name = port
            lead = "( " if first else ", "
            first = False
            self.emit("{}{} var logic {}{}".format(
                lead, direction.ljust(6), packed.ljust(7), name))
        self.emit(");", "")

    # }}} Header and ports

    # {{{ Parameters and address map

    def parameters(self):
        noc = self.noc
        body = [
            "  localparam int unsigned GRID_WIDTH        = {};".format(
                noc.gridWidth),
            "  localparam int unsigned COORD_WIDTH       = $clog2(GRID_WIDTH);",
            "  localparam int unsigned MAX_NI_PER_ROUTER = {};".format(
                noc.maxNiPerRouter),
            "  localparam int unsigned NI_ID_WIDTH       = {};".format(
                noc.niIdWidth),
            "",
            "  localparam int unsigned NI_PAYLOAD_WIDTH =",
            "    {};".format(MIXED_PAYLOAD if noc.mixed
                             else NATIVE_PAYLOAD[noc.protocols[0]]),
            "",
        ]
        if noc.mixed:
            body += [
                "  localparam int unsigned NI_PACKET_WIDTH =",
                "    NI_PAYLOAD_WIDTH + (2 * NI_ID_WIDTH) + (4 * COORD_WIDTH);",
                "",
                "  localparam int unsigned NOC_PAYLOAD_WIDTH =",
                "    NI_PAYLOAD_WIDTH + pa_noc::PROTOCOL_WIDTH;",
            ]
        else:
            body += [
                "  localparam int unsigned NOC_PAYLOAD_WIDTH = "
                "NI_PAYLOAD_WIDTH;",
            ]
        body += [
            "",
            "  localparam int unsigned NOC_PACKET_WIDTH =",
            "    NOC_PAYLOAD_WIDTH + (2 * NI_ID_WIDTH) + (4 * COORD_WIDTH);",
        ]
        description = [
            "Mesh size and packet widths derived from the configuration.",
        ]
        if noc.mixed:
            description += [
                "NI packets are widened by the protocol opcode on the fabric.",
            ]
        self.fold("Parameters", description, body)

    def addressMapParameter(self):
        noc = self.noc
        count = len(noc.addressMap)
        body = [
            "  localparam int unsigned NUM_ADDR_MAP_ENTRIES = {};".format(
                count),
            "",
            "  localparam pa_noc::ty_ADDR_MAP_ENTRY [NUM_ADDR_MAP_ENTRIES-1:0]",
            "    ADDR_MAP =",
        ]
        # Packed assignment patterns list the MSB entry first.
        for i, (base, end, target) in enumerate(reversed(noc.addressMap)):
            lead = "    '{" if i == 0 else "    , "
            body += [
                "{}'{{baseAddr: {}".format(lead, hex32(base)),
                "      , endAddr:  {}".format(hex32(end)),
                "      , dstRow:   8'd{}".format(target.row),
                "      , dstCol:   8'd{}".format(target.col),
                "      , dstNiId:  8'd{}".format(target.niId),
                "      }} // [{}] {}".format(count - 1 - i, target.name),
            ]
        body.append("    };")
        self.fold("Address map", [
            "System address map shared by every initiator NI; each entry",
            "routes an address range to its target's router and NI ID.",
        ], body)

    # }}} Parameters and address map

    # {{{ Nodes

    def nodeSignals(self, node, suffix=""):
        return [
            ("[NOC_PACKET_WIDTH-1:0]", node.name + "NiToRouter" + suffix),
            ("", node.name + "NiToRouterValid" + suffix),
            ("", node.name + "NiToRouterReady" + suffix),
            ("[NOC_PACKET_WIDTH-1:0]", node.name + "RouterToNi" + suffix),
            ("", node.name + "RouterToNiValid" + suffix),
            ("", node.name + "RouterToNiReady" + suffix),
        ]

    def protocolPorts(self, node):
        table = (INITIATOR_PORTS if node.kind == "initiator"
                 else TARGET_PORTS)[node.protocol]
        ports = []
        for direction, _, signal in table:
            prefix = "i_" if direction == "input" else "o_"
            ports.append((prefix + signal, prefix + topPort(node, signal)))
        return ports

    def initiator(self, node):
        noc = self.noc
        name = node.name
        body = []
        signals = declarations(self.nodeSignals(node))
        if noc.mixed:
            # Opcode bits of the response are not used by the NI.
            body += signals[:3] + lintOff("UNUSEDSIGNAL", signals[3:4])
            body += signals[4:] + [""]
            body += declarations([("[NI_PACKET_WIDTH-1:0]",
                                   name + "NiRequest")]) + [""]
            body += comb(name + "NiToRouter", "{{{}, {}NiRequest}}".format(
                OPCODE[node.protocol], name))
            niToRouter = name + "NiRequest"
            routerToNi = name + "RouterToNi[NI_PACKET_WIDTH-1:0]"
        else:
            body += signals + [""]
            niToRouter = name + "NiToRouter"
            routerToNi = name + "RouterToNi"
        params = [
            ("GRID_WIDTH", "GRID_WIDTH"),
            ("NUM_ADDR_MAP_ENTRIES", "NUM_ADDR_MAP_ENTRIES"),
            ("ADDR_MAP", "ADDR_MAP"),
            ("SRC_ROW", str(node.row)),
            ("SRC_COL", str(node.col)),
            ("MAX_NI_PER_ROUTER", "MAX_NI_PER_ROUTER"),
            ("NI_ID", str(node.niId)),
            ("PAYLOAD_WIDTH", "NI_PAYLOAD_WIDTH"),
        ]
        ports = [
            ("i_clk", "i_{}Clk".format(node.clock)),
            ("i_arst_n", "i_{}Arst_n".format(node.clock)),
        ] + self.protocolPorts(node) + [
            ("o_niToRouter", niToRouter),
            ("o_niToRouterValid", name + "NiToRouterValid"),
            ("i_niToRouterReady", name + "NiToRouterReady"),
            ("i_routerToNi", routerToNi),
            ("i_routerToNiValid", name + "RouterToNiValid"),
            ("o_routerToNiReady", name + "RouterToNiReady"),
        ]
        body += instance("ni{}Initiator".format(PROTOCOL_CAMEL[node.protocol]),
                         params, "u_" + name, ports)
        self.nodeSection(node, body)

    def target(self, node):
        noc = self.noc
        name = node.name
        body = declarations(self.nodeSignals(node)) + [""]
        if noc.mixed:
            module = TARGET_BRIDGE[node.protocol][0]
        else:
            module = "ni{}Target".format(PROTOCOL_CAMEL[node.protocol])
        params = [
            ("GRID_WIDTH", "GRID_WIDTH"),
            ("MY_ROW", str(node.row)),
            ("MY_COL", str(node.col)),
            ("MAX_NI_PER_ROUTER", "MAX_NI_PER_ROUTER"),
            ("NI_ID", str(node.niId)),
            ("PAYLOAD_WIDTH", "NI_PAYLOAD_WIDTH"),
        ]
        ports = [
            ("i_clk", "i_{}Clk".format(node.clock)),
            ("i_arst_n", "i_{}Arst_n".format(node.clock)),
        ] + self.protocolPorts(node) + [
            ("i_routerToNi", name + "RouterToNi"),
            ("i_routerToNiValid", name + "RouterToNiValid"),
            ("o_routerToNiReady", name + "RouterToNiReady"),
            ("o_niToRouter", name + "NiToRouter"),
            ("o_niToRouterValid", name + "NiToRouterValid"),
            ("i_niToRouterReady", name + "NiToRouterReady"),
        ]
        body += instance(module, params, "u_" + name, ports)
        self.nodeSection(node, body)

    def nodeSection(self, node, body):
        noc = self.noc
        description = [
            "{} {} on router {} (row {}, col {}), NI ID {}, clock {}.".format(
                PROTOCOL_TITLE[node.protocol], node.kind, node.router,
                node.row, node.col, node.niId, node.clock),
        ]
        if node.cdc:
            description.append(
                "cdcNiBridge crosses its packets into the fabric clock"
                " domain ({}).".format(noc.fabricClock))
            body = body + [""] + self.cdc(node)
        self.fold(node.name, description, body)

    def cdc(self, node):
        noc = self.noc
        name = node.name
        body = declarations(self.nodeSignals(node, "Fab")) + [""]
        ports = [
            ("i_niClk", "i_{}Clk".format(node.clock)),
            ("i_niArst_n", "i_{}Arst_n".format(node.clock)),
            ("i_fabClk", "i_{}Clk".format(noc.fabricClock)),
            ("i_fabArst_n", "i_{}Arst_n".format(noc.fabricClock)),
            ("i_niToRouter", name + "NiToRouter"),
            ("i_niToRouterValid", name + "NiToRouterValid"),
            ("o_niToRouterReady", name + "NiToRouterReady"),
            ("o_routerToNi", name + "RouterToNi"),
            ("o_routerToNiValid", name + "RouterToNiValid"),
            ("i_routerToNiReady", name + "RouterToNiReady"),
            ("o_niToRouterFab", name + "NiToRouterFab"),
            ("o_niToRouterValidFab", name + "NiToRouterValidFab"),
            ("i_niToRouterReadyFab", name + "NiToRouterReadyFab"),
            ("i_routerToNiFab", name + "RouterToNiFab"),
            ("i_routerToNiValidFab", name + "RouterToNiValidFab"),
            ("o_routerToNiReadyFab", name + "RouterToNiReadyFab"),
        ]
        params = [
            ("PACKET_WIDTH", "NOC_PACKET_WIDTH"),
            ("FIFO_ADDR_WIDTH", "pa_noc::FIFO_ADDRESS_W"),
        ]
        return body + instance("cdcNiBridge", params, "u_{}Cdc".format(name),
                               ports)

    # }}} Nodes

    # {{{ Router ports and mesh

    def routerPort(self, router):
        noc = self.noc
        nodes = noc.routerNodes[router]
        row, col = router // noc.gridWidth, router % noc.gridWidth
        if noc.maxNiPerRouter == 1:
            self.directRouterPort(router, nodes[0], row, col)
            return
        prefix = "router{}".format(router)
        array = "[MAX_NI_PER_ROUTER-1:0]"
        toPort = declarations([
            (array + "[NOC_PACKET_WIDTH-1:0]", prefix + "NiToRouter"),
            (array, prefix + "NiToRouterValid"),
            (array, prefix + "RouterToNiReady"),
        ])
        fromPort = declarations([
            (array + "[NOC_PACKET_WIDTH-1:0]", prefix + "RouterToNi"),
            (array, prefix + "RouterToNiValid"),
            (array, prefix + "NiToRouterReady"),
        ])
        body = toPort
        if len(nodes) < noc.maxNiPerRouter:
            # Idle slots leave their router-port outputs unused.
            body += lintOff("UNUSEDSIGNAL", fromPort)
        else:
            body += fromPort
        body.append("")
        for slot in range(noc.maxNiPerRouter):
            if slot < len(nodes):
                node = nodes[slot]
                fab = "Fab" if node.cdc else ""
                index = "[{}]".format(slot)
                body += comb(prefix + "NiToRouter" + index,
                             node.name + "NiToRouter" + fab)
                body += comb(prefix + "NiToRouterValid" + index,
                             node.name + "NiToRouterValid" + fab)
                body += comb(prefix + "RouterToNiReady" + index,
                             node.name + "RouterToNiReady" + fab)
                body += comb(node.name + "NiToRouterReady" + fab,
                             prefix + "NiToRouterReady" + index)
                body += comb(node.name + "RouterToNi" + fab,
                             prefix + "RouterToNi" + index)
                body += comb(node.name + "RouterToNiValid" + fab,
                             prefix + "RouterToNiValid" + index)
            else:
                index = "[{}]".format(slot)
                body += comb(prefix + "NiToRouter" + index, "'0")
                body += comb(prefix + "NiToRouterValid" + index, "'0")
                body += comb(prefix + "RouterToNiReady" + index, "'1")
        slot = "[{}][{}]".format(row, col)
        params = [
            ("GRID_WIDTH", "GRID_WIDTH"),
            ("MAX_NI_PER_ROUTER", "MAX_NI_PER_ROUTER"),
            ("PAYLOAD_WIDTH", "NOC_PAYLOAD_WIDTH"),
        ]
        ports = [
            ("i_clk", "i_{}Clk".format(noc.fabricClock)),
            ("i_arst_n", "i_{}Arst_n".format(noc.fabricClock)),
            ("o_niToRouter", "niToRouter" + slot),
            ("o_niToRouterValid", "niToRouterValid" + slot),
            ("i_niToRouterReady", "niToRouterReady" + slot),
            ("i_routerToNi", "routerToNi" + slot),
            ("i_routerToNiValid", "routerToNiValid" + slot),
            ("o_routerToNiReady", "routerToNiReady" + slot),
            ("i_niToRouter", prefix + "NiToRouter"),
            ("i_niToRouterValid", prefix + "NiToRouterValid"),
            ("o_niToRouterReady", prefix + "NiToRouterReady"),
            ("o_routerToNi", prefix + "RouterToNi"),
            ("o_routerToNiValid", prefix + "RouterToNiValid"),
            ("i_routerToNiReady", prefix + "RouterToNiReady"),
        ]
        body += instance("niRouterPort", params, "u_{}Port".format(prefix),
                         ports)
        self.fold("Router {} port".format(router), [
            "Shares router {} (row {}, col {}) between its {} NI(s); slot ="
            .format(router, row, col, len(nodes)),
            "NI ID.",
        ], body)

    def directRouterPort(self, router, node, row, col):
        fab = "Fab" if node.cdc else ""
        slot = "[{}][{}]".format(row, col)
        body = []
        body += comb("niToRouter" + slot, node.name + "NiToRouter" + fab)
        body += comb("niToRouterValid" + slot,
                     node.name + "NiToRouterValid" + fab)
        body += comb("routerToNiReady" + slot,
                     node.name + "RouterToNiReady" + fab)
        body += comb(node.name + "NiToRouterReady" + fab,
                     "niToRouterReady" + slot)
        body += comb(node.name + "RouterToNi" + fab, "routerToNi" + slot)
        body += comb(node.name + "RouterToNiValid" + fab,
                     "routerToNiValid" + slot)
        self.fold("Router {} port".format(router), [
            "{} owns router {} (row {}, col {}) NI port.".format(
                node.name, router, row, col),
        ], body)

    def meshNets(self):
        noc = self.noc
        grid = "[GRID_WIDTH-1:0][GRID_WIDTH-1:0]"
        toMesh = declarations([
            (grid + "[NOC_PACKET_WIDTH-1:0]", "niToRouter"),
            (grid, "niToRouterValid"),
            (grid, "routerToNiReady"),
        ])
        fromMesh = declarations([
            (grid + "[NOC_PACKET_WIDTH-1:0]", "routerToNi"),
            (grid, "routerToNiValid"),
            (grid, "niToRouterReady"),
        ])
        body = toMesh
        if len(noc.routerNodes) < noc.gridWidth ** 2:
            # Routers without NIs leave their NI-port outputs unused.
            body += lintOff("UNUSEDSIGNAL", fromMesh)
        else:
            body += fromMesh
        body.append("")
        for router in range(noc.gridWidth ** 2):
            if router in noc.routerNodes:
                continue
            slot = "[{}][{}]".format(router // noc.gridWidth,
                                     router % noc.gridWidth)
            body += comb("niToRouter" + slot, "'0")
            body += comb("niToRouterValid" + slot, "'0")
            body += comb("routerToNiReady" + slot, "'1")
        self.fold("Mesh nets", [
            "Per-router NI ports of the mesh; routers without NIs are tied",
            "idle.",
        ], body)

    def mesh(self):
        noc = self.noc
        params = [
            ("GRID_WIDTH", "GRID_WIDTH"),
            ("PAYLOAD_WIDTH", "NOC_PAYLOAD_WIDTH"),
            ("FIFO_ADDRESS_WIDTH", "pa_noc::FIFO_ADDRESS_W"),
            ("MAX_NI_PER_ROUTER", "MAX_NI_PER_ROUTER"),
        ]
        ports = [
            ("i_clk", "i_{}Clk".format(noc.fabricClock)),
            ("i_arst_n", "i_{}Arst_n".format(noc.fabricClock)),
            ("i_niToRouter", "niToRouter"),
            ("i_niToRouterValid", "niToRouterValid"),
            ("o_niToRouterReady", "niToRouterReady"),
            ("o_routerToNi", "routerToNi"),
            ("o_routerToNiValid", "routerToNiValid"),
            ("i_routerToNiReady", "routerToNiReady"),
        ]
        body = instance("noc", params, "u_noc", ports)
        self.fold("Mesh", [
            "{0}x{0} mesh in the {1} clock domain.".format(
                noc.gridWidth, noc.fabricClock),
        ], body)

    # }}} Router ports and mesh

    def generate(self):
        noc = self.noc
        self.header()
        self.ports()
        self.parameters()
        self.addressMapParameter()
        for node in noc.initiators:
            self.initiator(node)
        for node in noc.targets:
            self.target(node)
        self.meshNets()
        for router in sorted(noc.routerNodes):
            self.routerPort(router)
        self.mesh()
        if self.lines[-1] == "":
            self.lines.pop()
        self.emit("endmodule", "", "`resetall")
        return "\n".join(self.lines) + "\n"


# {{{ Testbench emission

# Word-select bits of every target slave model in the generated testbench.
SLAVE_ADDR_BITS = 10

TIMEOUT_NS = 2000000

IDLE_DRIVES = {
    "apb": [("Paddr", "'0"), ("Pwdata", "'0"), ("Pwrite", "'0"),
            ("Pstrb", "'0"), ("Psel", "'0"), ("Penable", "'0")],
    "ahb": [("Hsel", "'0"), ("Haddr", "'0"), ("Hwrite", "'0"),
            ("Hsize", "'0"), ("Htrans", "'0"), ("Hwdata", "'0")],
    "axiLite": [("Awaddr", "'0"), ("Awvalid", "'0"), ("Wdata", "'0"),
                ("Wstrb", "'0"), ("Wvalid", "'0"), ("Bready", "'0"),
                ("Araddr", "'0"), ("Arvalid", "'0"), ("Rready", "'0")],
}

# Masters drive on the falling edge and sample 1ns later, so every handshake
# completes on the following rising edge.
ACCESS_TASK = {
    "apb": """\
    @(negedge @CLK@);
    @N@Paddr   = address;
    @N@Pwrite  = write;
    @N@Pwdata  = writeData;
    @N@Pstrb   = '1;
    @N@Psel    = '1;
    @N@Penable = '0;
    @(negedge @CLK@);
    @N@Penable = '1;
    #1;
    while (!@N@Pready) begin
      @(negedge @CLK@);
      #1;
    end
    readData = @N@Prdata;
    error    = @N@Pslverr;
    @(negedge @CLK@);
    @N@Psel    = '0;
    @N@Penable = '0;
""",
    "ahb": """\
    @(negedge @CLK@);
    @N@Hsel   = '1;
    @N@Haddr  = address;
    @N@Hwrite = write;
    @N@Hsize  = 3'd2;
    @N@Htrans = 2'b10;
    #1;
    while (!@N@Hreadyout) begin
      @(negedge @CLK@);
      #1;
    end
    @(negedge @CLK@);
    @N@Hsel   = '0;
    @N@Htrans = 2'b00;
    @N@Hwdata = writeData;
    #1;
    while (!@N@Hreadyout) begin
      @(negedge @CLK@);
      #1;
    end
    readData = @N@Hrdata;
    error    = @N@Hresp;
    @(negedge @CLK@);
""",
    "axiLite": """\
    logic addressDone;
    logic dataDone;
    @(negedge @CLK@);
    readData = '0;
    if (write) begin
      @N@Awaddr  = address;
      @N@Awvalid = '1;
      @N@Wdata   = writeData;
      @N@Wstrb   = '1;
      @N@Wvalid  = '1;
      addressDone = '0;
      dataDone    = '0;
      while (!(addressDone && dataDone)) begin
        #1;
        addressDone = addressDone || @N@Awready;
        dataDone    = dataDone || @N@Wready;
        @(negedge @CLK@);
        if (addressDone)
          @N@Awvalid = '0;
        if (dataDone)
          @N@Wvalid = '0;
      end
      @N@Bready = '1;
      #1;
      while (!@N@Bvalid) begin
        @(negedge @CLK@);
        #1;
      end
      error = (@N@Bresp != 2'b00);
      @(negedge @CLK@);
      @N@Bready = '0;
    end else begin
      @N@Araddr  = address;
      @N@Arvalid = '1;
      #1;
      while (!@N@Arready) begin
        @(negedge @CLK@);
        #1;
      end
      @(negedge @CLK@);
      @N@Arvalid = '0;
      @N@Rready  = '1;
      #1;
      while (!@N@Rvalid) begin
        @(negedge @CLK@);
        #1;
      end
      readData = @N@Rdata;
      error    = (@N@Rresp != 2'b00);
      @(negedge @CLK@);
      @N@Rready = '0;
    end
""",
}


def primes(count, start):
    found = []
    candidate = start
    while len(found) < count:
        if all(candidate % p for p in range(2, int(candidate ** 0.5) + 1)):
            found.append(candidate)
        candidate += 1
    return found


class TestPlan:
    """Per-initiator accesses that never race on a shared slave word.

    Every initiator reads each region base (reset value), then writes and
    reads back its own word base + 4 * (index + 1) in every region, then reads
    an unmapped address expecting a decode error.
    """

    def __init__(self, noc):
        mask = (1 << SLAVE_ADDR_BITS) - 1
        self.resetBase = {t.name: 0xA000_0000 + (i << 16)
                          for i, t in enumerate(noc.targets)}
        owners = {t.name: {} for t in noc.targets}
        for target in noc.targets:
            for base, _ in target.regions:
                owners[target.name][(base >> 2) & mask] = "reset"

        self.unmapped = None
        candidates = [0] + [end + 1 for _, end, _ in noc.addressMap
                            if end < ADDRESS_MAX - 3]
        for address in candidates:
            address &= ~3
            if not any(b <= address <= e for b, e, _ in noc.addressMap):
                self.unmapped = address
                break

        self.steps = {}
        for i, initiator in enumerate(noc.initiators):
            steps = []
            for target in noc.targets:
                for r, (base, _) in enumerate(target.regions):
                    expected = self.resetBase[target.name] + ((base >> 2)
                                                              & mask)
                    steps.append(("read", base, 0, expected, False,
                                  "{}[{}] reset".format(target.name, r)))
            for t, target in enumerate(noc.targets):
                for r, (base, end) in enumerate(target.regions):
                    address = base + 4 * (i + 1)
                    if address + 3 > end:
                        continue
                    word = (address >> 2) & mask
                    if owners[target.name].get(word, i) != i:
                        continue
                    owners[target.name][word] = i
                    data = ((i + 1) << 24) | ((t + 1) << 16) | (r + 1)
                    label = "{}[{}]".format(target.name, r)
                    steps.append(("write", address, data, 0, False, label))
                    steps.append(("read", address, 0, data, False, label))
            if self.unmapped is not None:
                steps.append(("read", self.unmapped, 0, 0, True, "unmapped"))
            self.steps[initiator.name] = steps


class TestbenchEmitter:

    def __init__(self, noc, configPath):
        self.noc = noc
        self.configPath = configPath
        self.plan = TestPlan(noc)
        self.lines = []
        halves = primes(len(noc.clocks), 5)
        self.halfPeriod = dict(zip(noc.clocks, halves))

    def emit(self, *lines):
        self.lines.extend(lines)

    def fold(self, title, body):
        self.emit("  // {{{{{{ {}".format(title), "")
        self.lines.extend(body)
        if self.lines[-1] != "":
            self.emit("")
        self.emit("  // }}}}}} {}".format(title), "")

    def header(self):
        noc = self.noc
        year = datetime.date.today().year
        self.emit(
            "// Copyright (c) {} Tej Sanghavi.".format(year), "",
            "// tb_{}: auto-generated self-checking testbench. DO NOT EDIT;"
            .format(noc.topName),
            "//   regenerate with autoConfiguration/nocGen.py {}".format(
                os.path.basename(self.configPath)),
            "//",
            "// Every target is a register-file model whose word i resets to",
            "// RESET_BASE + i. Each initiator, concurrently and in its own"
            " clock",
            "// domain, reads every region's reset value, writes and reads"
            " back a",
            "// word it alone owns in every region, and reads an unmapped"
            " address",
            "// expecting a decode error.",
            "", "`default_nettype none", "",
            "module tb_{};".format(noc.topName), "")

    def clocks(self):
        body = []
        for clock in self.noc.clocks:
            body += [
                "  logic {}Clk;".format(clock),
                "",
                "  initial {}Clk = '0;".format(clock),
                "",
                "  always #{} {}Clk = !{}Clk;".format(
                    self.halfPeriod[clock], clock, clock),
                "",
            ]
        body += [
            "  logic arst_n;",
            "",
            "  initial begin: reset",
            "    arst_n = '0;",
            "    #100 arst_n = '1;",
            "  end: reset",
        ]
        self.fold("Clocks and reset", body)

    def bookkeeping(self):
        self.fold("Checking", [
            "  int unsigned checks;",
            "  int unsigned errors;",
            "",
            "  initial begin: clearCounts",
            "    checks = 0;",
            "    errors = 0;",
            "  end: clearCounts",
            "",
            "  task automatic check",
            "    ( input string       what",
            "    , input logic [31:0] got",
            "    , input logic [31:0] expected",
            "    , input logic        error",
            "    , input logic        expectError",
            "    , input logic        compareData",
            "    );",
            "    checks++;",
            "    if ((error !== expectError)"
            " || (compareData && (got !== expected))) begin",
            "      errors++;",
            "      $display(\"  FAIL: %s got=0x%08h expected=0x%08h"
            " error=%0b\",",
            "               what, got, expected, error);",
            "    end",
            "    else",
            "      $display(\"  PASS: %s\", what);",
            "  endtask",
        ])

    def signals(self):
        noc = self.noc
        body = []
        for node in noc.nodes:
            table = (INITIATOR_PORTS if node.kind == "initiator"
                     else TARGET_PORTS)[node.protocol]
            body += declarations([
                ("[{}:0]".format(w - 1) if w > 1 else "",
                 topPort(node, signal)) for _, w, signal in table])
            body.append("")
            if node.kind == "initiator" and node.protocol == "ahb":
                # Single-subordinate AHB bus: HREADY is the NI's HREADYOUT.
                body += comb(topPort(node, "hready"),
                             topPort(node, "hreadyout"))
        self.fold("Protocol signals", body)

    def dut(self):
        noc = self.noc
        ports = []
        for clock in noc.clocks:
            ports.append(("i_{}Clk".format(clock), clock + "Clk"))
            ports.append(("i_{}Arst_n".format(clock), "arst_n"))
        for node in noc.nodes:
            table = (INITIATOR_PORTS if node.kind == "initiator"
                     else TARGET_PORTS)[node.protocol]
            for direction, _, signal in table:
                prefix = "i_" if direction == "input" else "o_"
                ports.append((prefix + topPort(node, signal),
                              topPort(node, signal)))
        self.fold("Device under test",
                  instance(noc.topName, [], "u_dut", ports))

    def slaves(self):
        body = []
        for target in self.noc.targets:
            ports = [("i_clk", target.clock + "Clk")]
            for direction, _, signal in TARGET_PORTS[target.protocol]:
                prefix = "i_" if direction == "output" else "o_"
                ports.append((prefix + signal, topPort(target, signal)))
            params = [
                ("ADDR_BITS", str(SLAVE_ADDR_BITS)),
                ("RESET_BASE", hex32(self.plan.resetBase[target.name])),
            ]
            body += instance("{}SlaveModel".format(target.protocol), params,
                             "u_{}Model".format(target.name), ports)
            body.append("")
        self.fold("Target models", body)

    def initiator(self, node):
        name, clock = node.name, node.clock + "Clk"
        body = [
            "  task automatic {}Access".format(name),
            "    ( input  logic [31:0] address",
            "    , input  logic        write",
            "    , input  logic [31:0] writeData",
            "    , output logic [31:0] readData",
            "    , output logic        error",
            "    );",
        ]
        task = ACCESS_TASK[node.protocol].replace("@N@", name)
        body += task.replace("@CLK@", clock).rstrip("\n").split("\n")
        body += ["  endtask", "", "  logic {}Done;".format(name), "",
                 "  initial begin: {}Test".format(name),
                 "    logic [31:0] readData;",
                 "    logic        error;",
                 "    {}Done = '0;".format(name)]
        for signal, value in IDLE_DRIVES[node.protocol]:
            body.append("    {}{} = {};".format(name, signal, value))
        body += ["    wait (arst_n);",
                 "    repeat (5) @(negedge {});".format(clock)]
        for kind, address, data, expected, expectError, label in \
                self.plan.steps[name]:
            write = kind == "write"
            body.append("    {}Access({}, 1'b{:d}, {}, readData, error);"
                        .format(name, hex32(address), write, hex32(data)))
            what = "{} {} {} @0x{:08X}".format(name, kind, label, address)
            body.append("    check(\"{}\", readData, {}, error, 1'b{:d},"
                        " 1'b{:d});".format(what, hex32(expected),
                                            expectError,
                                            not write and not expectError))
        body += ["    {}Done = '1;".format(name),
                 "  end: {}Test".format(name)]
        self.fold("{} ({} initiator)".format(
            name, PROTOCOL_TITLE[node.protocol]), body)

    def finish(self):
        done = ", ".join(n.name + "Done" for n in self.noc.initiators)
        self.fold("Completion", [
            "  initial begin: finish",
            "    wait (&{{{}}});".format(done),
            "    if (errors != 0)",
            "      $fatal(1, \"=== %0d/%0d checks FAILED ===\", errors,"
            " checks);",
            "    $display(\"=== %0d/%0d checks PASSED ===\", checks, checks);",
            "    $finish;",
            "  end: finish",
            "",
            "  initial begin: watchdog",
            "    #{};".format(TIMEOUT_NS),
            "    $fatal(1, \"=== TIMEOUT after %0d checks ===\", checks);",
            "  end: watchdog",
        ])

    def generate(self):
        self.header()
        self.clocks()
        self.bookkeeping()
        self.signals()
        self.dut()
        self.slaves()
        for node in self.noc.initiators:
            self.initiator(node)
        self.finish()
        if self.lines[-1] == "":
            self.lines.pop()
        self.emit("endmodule", "", "`resetall")
        return "\n".join(self.lines) + "\n"

# }}} Testbench emission


# {{{ Project packaging

TEMPLATE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             "templates")


def libraryFiles(noc):
    """NoC library sources (relative to rtl/) needed by the generated top."""
    with open(os.path.join(RTL_PATH, "noc.f")) as handle:
        files = [line.strip() for line in handle if line.strip()]
    return files + [os.path.relpath(f, RTL_PATH) for f in noc.rtlFiles()]


def writeFile(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        handle.write(text)


def fromTemplate(name, noc, configPath):
    with open(os.path.join(TEMPLATE_PATH, name)) as handle:
        text = handle.read()
    return (text.replace("@TOP@", noc.topName)
            .replace("@CONFIG@", os.path.basename(configPath)))


def writeProject(noc, configPath, outDir):
    """Self-contained project: rtl/, tb/, synth/, Makefile, .svlint.toml."""
    rtlDir = os.path.join(outDir, "rtl")
    tbDir = os.path.join(outDir, "tb")
    sources = libraryFiles(noc)
    for source in sources:
        os.makedirs(rtlDir, exist_ok=True)
        shutil.copyfile(os.path.join(RTL_PATH, source),
                        os.path.join(rtlDir, os.path.basename(source)))
    top = noc.topName + ".sv"
    writeFile(os.path.join(rtlDir, top), Emitter(noc, configPath).generate())
    writeFile(os.path.join(rtlDir, noc.topName + ".f"), "\n".join(
        [os.path.basename(s) for s in sources] + [top]) + "\n")

    models = ["{}SlaveModel.sv".format(p) for p in PROTOCOLS
              if any(t.protocol == p for t in noc.targets)]
    for model in models:
        os.makedirs(tbDir, exist_ok=True)
        shutil.copyfile(os.path.join(TEMPLATE_PATH, "tb", model),
                        os.path.join(tbDir, model))
    tbTop = "tb_{}.sv".format(noc.topName)
    writeFile(os.path.join(tbDir, tbTop),
              TestbenchEmitter(noc, configPath).generate())
    writeFile(os.path.join(tbDir, "tb_{}.f".format(noc.topName)),
              "\n".join(models + [tbTop]) + "\n")

    writeFile(os.path.join(outDir, "synth", "yosys.ys"),
              fromTemplate(os.path.join("synth", "yosys.ys"), noc,
                           configPath))
    writeFile(os.path.join(outDir, "Makefile"),
              fromTemplate("Makefile", noc, configPath))
    shutil.copyfile(os.path.join(NOC_ROOT, ".svlint.toml"),
                    os.path.join(outDir, ".svlint.toml"))
    shutil.copyfile(configPath, os.path.join(outDir,
                                             os.path.basename(configPath)))

# }}} Project packaging


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("config", help="NoC description (JSON)")
    parser.add_argument("-o", "--out-dir", required=True,
                        help="output project directory")
    args = parser.parse_args()

    try:
        with open(args.config) as handle:
            config = json.load(handle)
        noc = Noc(config)
    except (OSError, ValueError, ConfigError) as error:
        print("nocGen: error: {}".format(error), file=sys.stderr)
        return 1

    outDir = os.path.abspath(args.out_dir)
    writeProject(noc, args.config, outDir)
    print("nocGen: wrote {} to {} ({}x{} mesh, {} initiator(s), {} target(s),"
          " {}); run make lint|sim|synth there".format(
              noc.topName, outDir, noc.gridWidth, noc.gridWidth,
              len(noc.initiators), len(noc.targets),
              "mixed protocols" if noc.mixed else noc.protocols[0]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
