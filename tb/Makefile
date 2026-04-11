# make designerTb TEST=1   # random traffic TB (tb_noc.cpp)
# make designerTb TEST=2   # single packet TB (tb_noc_single_packet.cpp)
# make designerTb TEST=3   # multi-source to one destination (tb_noc_multi_to_one.cpp)

TOP_MODULE=noc
RTL_PATH=../rtl
FILE_LIST=$(RTL_PATH)/$(TOP_MODULE).f
GRID_WIDTH ?= 4
MAX_SIM_TIME ?= 1000
TEST ?= 1
VERILATOR_CFLAGS := -CFLAGS -DGRID_WIDTH=$(GRID_WIDTH) -CFLAGS -DMAX_SIM_TIME=$(MAX_SIM_TIME)

ifeq ($(TEST),1)
TB_CPP := tb_noc.cpp
WAVEFORM := waveform.vcd
STAMP := .stamp.verilate.test1
else ifeq ($(TEST),2)
TB_CPP := tb_noc_single_packet.cpp
WAVEFORM := waveform_single.vcd
STAMP := .stamp.verilate.test2
SRC_ROW ?= 0
SRC_COL ?= 0
DST_ROW ?= 3
DST_COL ?= 2
TEST_PAYLOAD ?= 0x123456789ABCDEF0ULL
TIMEOUT_CYCLES ?= 256
VERILATOR_CFLAGS += -CFLAGS -DSRC_ROW=$(SRC_ROW) -CFLAGS -DSRC_COL=$(SRC_COL)
VERILATOR_CFLAGS += -CFLAGS -DDST_ROW=$(DST_ROW) -CFLAGS -DDST_COL=$(DST_COL)
VERILATOR_CFLAGS += -CFLAGS -DTEST_PAYLOAD=$(TEST_PAYLOAD) -CFLAGS -DTIMEOUT_CYCLES=$(TIMEOUT_CYCLES)
else ifeq ($(TEST),3)
TB_CPP := tb_noc_multi_to_one.cpp
WAVEFORM := waveform_multi_to_one.vcd
STAMP := .stamp.verilate.test3
DST_ROW ?= 1
DST_COL ?= 1
TIMEOUT_CYCLES ?= 512
VERILATOR_CFLAGS += -CFLAGS -DDST_ROW=$(DST_ROW) -CFLAGS -DDST_COL=$(DST_COL)
VERILATOR_CFLAGS += -CFLAGS -DTIMEOUT_CYCLES=$(TIMEOUT_CYCLES)
else
$(error Unsupported TEST='$(TEST)'. Use TEST=1, TEST=2, or TEST=3)
endif

.PHONY: all
all: clean verilate build sim waves

.PHONY: designerTb
designerTb: verilate build sim

.PHONY: verilate
verilate: $(STAMP)

.PHONY: build
build: obj_dir/Vnoc

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

$(STAMP): $(RTL_PATH)/$(TOP_MODULE).sv $(TB_CPP)
	@echo
	@echo "### VERILATING (TEST=$(TEST)) ###"
	verilator -Wall --trace --x-assign unique --x-initial unique -cc \
	-F $(FILE_LIST) --top-module $(TOP_MODULE) --exe $(TB_CPP) \
	$(VERILATOR_CFLAGS) \
	-GGRID_WIDTH=$(GRID_WIDTH)
	@touch $(STAMP)

.PHONY: clean
clean:
	rm -rf .stamp.*;
	rm -rf ./obj_dir*
	rm -rf *.vcd
