# Testbench: niRouterPort unit test
# Directly exercises the shared-port multiplexer (ingress round-robin + egress
# NI-ID demux) at NUM_NI = 3.

TOP_MODULE = tb_niRouterPort_top
RTL_PATH = ../../rtl
TB_SV = tb_niRouterPort_top.sv
TB_CPP = tb_niRouterPort.cpp
STAMP = .stamp.verilate

GRID_WIDTH ?= 4
MAX_NI_PER_ROUTER ?= 3
MAX_SIM_TIME ?= 4000

RTL_SRCS = $(RTL_PATH)/pa_noc.sv $(RTL_PATH)/niRouterPort.sv

VERILATOR_CFLAGS := -CFLAGS -DMAX_SIM_TIME=$(MAX_SIM_TIME)

.PHONY: all
all: clean verilate build sim

.PHONY: designerTb
designerTb: verilate build sim

.PHONY: verilate
verilate: $(STAMP)

.PHONY: build
build: obj_dir/V$(TOP_MODULE)

.PHONY: sim
sim: ./obj_dir/V$(TOP_MODULE)
	@echo
	@echo "### SIMULATING ###"
	@./obj_dir/V$(TOP_MODULE)

./obj_dir/V$(TOP_MODULE): $(STAMP)
	@echo
	@echo "### BUILDING SIM ###"
	make -C obj_dir -f V$(TOP_MODULE).mk V$(TOP_MODULE)

$(STAMP): $(TB_SV) $(TB_CPP)
	@echo
	@echo "### VERILATING ###"
	verilator -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM --x-assign unique --x-initial unique -cc \
	$(RTL_SRCS) $(TB_SV) \
	--top-module $(TOP_MODULE) --exe $(TB_CPP) \
	$(VERILATOR_CFLAGS) \
	-GGRID_WIDTH=$(GRID_WIDTH) -GMAX_NI_PER_ROUTER=$(MAX_NI_PER_ROUTER)
	@touch $(STAMP)

.PHONY: clean
clean:
	rm -rf .stamp.*
	rm -rf ./obj_dir*
