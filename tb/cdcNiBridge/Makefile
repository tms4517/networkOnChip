# Testbench: cdcNiBridge
# NI->fabric->NI loopback across two clock domains at different frequencies.

TOP_MODULE = tb_cdcNiBridge_top
RTL_PATH = ../../rtl
NOC_FILE_LIST = $(RTL_PATH)/noc.f
TB_SV = tb_cdcNiBridge_top.sv
TB_CPP = tb_cdcNiBridge.cpp
STAMP = .stamp.verilate

MAX_SIM_TIME ?= 200000

VERILATOR_CFLAGS := -CFLAGS -DMAX_SIM_TIME=$(MAX_SIM_TIME)

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
	make -C obj_dir -f V$(TOP_MODULE).mk V$(TOP_MODULE)

$(STAMP): $(TB_SV) $(TB_CPP)
	@echo
	@echo "### VERILATING ###"
	verilator -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM --x-assign unique --x-initial unique -cc \
	-F $(NOC_FILE_LIST) $(TB_SV) \
	--top-module $(TOP_MODULE) --exe $(TB_CPP) \
	-LDFLAGS -pthread \
	$(VERILATOR_CFLAGS)
	@touch $(STAMP)

.PHONY: clean
clean:
	rm -rf .stamp.*
	rm -rf ./obj_dir*
	rm -rf *.vcd
