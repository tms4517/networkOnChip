# Testbench: niAxiLiteInitiator
# Drives AXI4-Lite transactions through niAxiLiteInitiator and checks the emitted
# request packets plus the returned B/R responses.

TOP_MODULE = tb_niAxiLiteInitiator_top
RTL_PATH = ../../rtl
ASSERT_PATH = ../assertions
NOC_FILE_LIST = $(RTL_PATH)/noc.f
ASSERT_SV = $(ASSERT_PATH)/axil_checker.sv
TB_SV = tb_niAxiLiteInitiator_top.sv
TB_CPP = tb_niAxiLiteInitiator.cpp
WAVEFORM = waveform_niAxiLiteInitiator.vcd
STAMP = .stamp.verilate

# vaxivip axil_master variant (prototype)
VIP_PATH = $(CURDIR)/../vip
TB_CPP_VIP = tb_niAxiLiteInitiator_vaxivip.cpp
VIP_MDIR = obj_dir_vaxivip

GRID_WIDTH ?= 4
MAX_SIM_TIME ?= 20000
TIMEOUT_CYCLES ?= 512

VERILATOR_CFLAGS := -CFLAGS -DGRID_WIDTH=$(GRID_WIDTH) \
                    -CFLAGS -DMAX_SIM_TIME=$(MAX_SIM_TIME) \
                    -CFLAGS -DTIMEOUT_CYCLES=$(TIMEOUT_CYCLES)

.PHONY: all
all: clean verilate build sim

.PHONY: designerTb
designerTb: verilate build sim

.PHONY: verilate
verilate: $(STAMP)

.PHONY: build
build: obj_dir/V$(TOP_MODULE)

.PHONY: sim
sim: $(WAVEFORM)

.PHONY: waves
waves: $(WAVEFORM)
	@echo
	@echo "### WAVES ###"
	gtkwave $(WAVEFORM)

$(WAVEFORM): ./obj_dir/V$(TOP_MODULE)
	@echo
	@echo "### SIMULATING ###"
	@./obj_dir/V$(TOP_MODULE) +verilator+rand+reset+2

./obj_dir/V$(TOP_MODULE): $(STAMP)
	@echo
	@echo "### BUILDING SIM ###"
	make -C obj_dir -f V$(TOP_MODULE).mk V$(TOP_MODULE)

$(STAMP): $(TB_SV) $(TB_CPP) $(ASSERT_SV)
	@echo
	@echo "### VERILATING ###"
	verilator -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-TIMESCALEMOD -Wno-SYNCASYNCNET --assert --trace --x-assign unique --x-initial unique -cc \
	-F $(NOC_FILE_LIST) $(ASSERT_SV) $(TB_SV) \
	--top-module $(TOP_MODULE) --exe $(TB_CPP) \
	$(VERILATOR_CFLAGS) \
	-GGRID_WIDTH=$(GRID_WIDTH)
	@touch $(STAMP)

# Build + run the vaxivip axil_master variant in its own output dir so it does
# not clash with the default flow. The verilaxi axil_checker is still compiled
# in (same harness + --assert). -CFLAGS -I$(VIP_PATH) lets the C++ TB find the
# vendored VIP headers under tb/vip.
# ASSERT_FLAG defaults to --assert (checker $stops on violation). Override with
# `make vaxivip ASSERT_FLAG=` to observe the data path without stopping.
ASSERT_FLAG ?= --assert
.PHONY: vaxivip
vaxivip:
	@echo
	@echo "### VERILATING (vaxivip) ###"
	verilator -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-TIMESCALEMOD -Wno-SYNCASYNCNET $(ASSERT_FLAG) --trace --x-assign unique --x-initial unique -cc \
	--Mdir $(VIP_MDIR) \
	-F $(NOC_FILE_LIST) $(ASSERT_SV) $(TB_SV) \
	--top-module $(TOP_MODULE) --exe $(TB_CPP_VIP) \
	-CFLAGS -I$(VIP_PATH) \
	$(VERILATOR_CFLAGS) \
	-GGRID_WIDTH=$(GRID_WIDTH)
	@echo
	@echo "### BUILDING SIM (vaxivip) ###"
	make -C $(VIP_MDIR) -f V$(TOP_MODULE).mk V$(TOP_MODULE)
	@echo
	@echo "### SIMULATING (vaxivip) ###"
	@./$(VIP_MDIR)/V$(TOP_MODULE) +verilator+rand+reset+2

.PHONY: clean
clean:
	rm -rf .stamp.*
	rm -rf ./obj_dir*
	rm -rf *.vcd
