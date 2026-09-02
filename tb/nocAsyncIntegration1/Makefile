# Testbench: asynchronous NoC integration — 2 initiators / 2 targets
# Drives concurrent APB traffic with the initiators, fabric, and targets each on
# their own clock, crossing domains through per-NI cdcNiBridge instances.

TOP_MODULE = tb_nocAsyncIntegration1_top
RTL_PATH = ../../rtl
NOC_FILE_LIST = $(RTL_PATH)/noc.f
TB_SV = tb_nocAsyncIntegration1_top.sv
TB_CPP = tb_nocAsyncIntegration1.cpp
STAMP = .stamp.verilate

GRID_WIDTH ?= 4
MAX_SIM_TIME ?= 400000
TIMEOUT_CYCLES ?= 2048

VERILATOR_CFLAGS := -CFLAGS -DGRID_WIDTH=$(GRID_WIDTH) \
                    -CFLAGS -DMAX_SIM_TIME=$(MAX_SIM_TIME) \
                    -CFLAGS -DTIMEOUT_CYCLES=$(TIMEOUT_CYCLES)

.PHONY: all
all: clean verilate build sim

.PHONY: verilate
verilate: $(STAMP)

.PHONY: build
build: obj_dir/V$(TOP_MODULE)

.PHONY: sim
sim: ./obj_dir/V$(TOP_MODULE)
	@echo
	@echo "### SIMULATING ###"
	@./obj_dir/V$(TOP_MODULE) +verilator+rand+reset+2

./obj_dir/V$(TOP_MODULE): $(STAMP)
	@echo
	@echo "### BUILDING SIM ###"
	make -C obj_dir -f V$(TOP_MODULE).mk V$(TOP_MODULE) CFG_CXXFLAGS_PCH_I=-include LDLIBS=-pthread

$(STAMP): $(TB_SV) $(TB_CPP)
	@echo
	@echo "### VERILATING ###"
	verilator -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM --x-assign unique --x-initial unique -cc \
	-F $(NOC_FILE_LIST) $(TB_SV) \
	--top-module $(TOP_MODULE) --exe $(TB_CPP) \
	-LDFLAGS -pthread \
	$(VERILATOR_CFLAGS) \
	-GGRID_WIDTH=$(GRID_WIDTH)
	@touch $(STAMP)

.PHONY: clean
clean:
	rm -rf .stamp.*
	rm -rf ./obj_dir*
	rm -rf *.vcd
