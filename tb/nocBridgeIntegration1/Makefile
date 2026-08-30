# Testbench: NoC bridge integration
# AXI4-Lite CPU + AHB-Lite DMA accessing one APB peripheral through the NoC,
# with opcode-tagged packets converted at the target by protocol bridges.

TOP_MODULE = tb_nocBridgeIntegration1_top
RTL_PATH = ../../rtl
NOC_FILE_LIST = $(RTL_PATH)/noc.f
EXTRA_RTL = $(RTL_PATH)/bridge/ahbToApbBridge.sv \
            $(RTL_PATH)/bridge/axiLiteToApbBridge.sv \
            $(RTL_PATH)/bridge/apbTargetBridge.sv
TB_SV = tb_nocBridgeIntegration1_top.sv
TB_CPP = tb_nocBridgeIntegration1.cpp
WAVEFORM = waveform_nocBridgeIntegration1.vcd
STAMP = .stamp.verilate

GRID_WIDTH ?= 4
MAX_SIM_TIME ?= 20000
TIMEOUT_CYCLES ?= 1024

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

$(STAMP): $(TB_SV) $(TB_CPP)
	@echo
	@echo "### VERILATING ###"
	verilator -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM --trace --x-assign unique --x-initial unique -cc \
	-F $(NOC_FILE_LIST) $(EXTRA_RTL) $(TB_SV) \
	--top-module $(TOP_MODULE) --exe $(TB_CPP) \
	$(VERILATOR_CFLAGS) \
	-GGRID_WIDTH=$(GRID_WIDTH)
	@touch $(STAMP)

.PHONY: clean
clean:
	rm -rf .stamp.*
	rm -rf ./obj_dir*
	rm -rf *.vcd
