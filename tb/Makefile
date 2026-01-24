# `make all` OR `make verilate` -> `make build` -> `make sim` -> `make waves`
# TODO: Modify RTL to take into account parameterization of GRID_WIDTH which
# results to different row and column bit widths.

TOP_MODULE=noc
RTL_PATH=../rtl
GRID_WIDTH ?= 4
MAX_SIM_TIME ?= 1000

.PHONY: all
all: clean verilate build sim waves

.PHONY: verilate
verilate: .stamp.verilate

.PHONY: build
build: obj_dir/Vnoc

.PHONY: sim
sim: waveform.vcd

.PHONY: waves
waves: waveform.vcd
	@echo
	@echo "### WAVES ###"
	gtkwave waveform.vcd &

waveform.vcd: ./obj_dir/V$(TOP_MODULE)
	@echo
	@echo "### SIMULATING ###"
	@./obj_dir/V$(TOP_MODULE) +verilator+rand+reset+2

./obj_dir/V$(TOP_MODULE): .stamp.verilate
	@echo
	@echo "### BUILDING SIM ###"
	make -C obj_dir -f V$(TOP_MODULE).mk V$(TOP_MODULE)

.stamp.verilate: $(RTL_PATH)/$(TOP_MODULE).sv tb_$(TOP_MODULE).cpp
	@echo
	@echo "### VERILATING ###"
	verilator -Wall --trace --x-assign unique --x-initial unique -cc \
	-f $(TOP_MODULE).f --top-module $(TOP_MODULE) --exe tb_$(TOP_MODULE).cpp \
	-CFLAGS -DGRID_WIDTH=$(GRID_WIDTH) -CFLAGS -DMAX_SIM_TIME=$(MAX_SIM_TIME) \
	-GGRID_WIDTH=$(GRID_WIDTH)
	@touch .stamp.verilate

.PHONY:
lint:
	verilator --lint-only -sv -f $(TOP_MODULE).f --top-module $(TOP_MODULE)
	svlint -f $(TOP_MODULE).f -c ../.svlint.toml

.PHONY: clean
clean:
	rm -rf .stamp.*;
	rm -rf ./obj_dir
	rm -rf waveform.vcd
