LOG_DIR ?= $(shell pwd)/logs
TOP_MODULE = noc
NOC_ROOT = $(shell pwd)
RTL_PATH = $(NOC_ROOT)/rtl
TB_PATH = $(NOC_ROOT)/tb
FILE_LIST = $(RTL_PATH)/$(TOP_MODULE).f
TEST ?= 1
SYNTH_PATH = $(NOC_ROOT)/synthesis
YOSYS_SLANG_LIBSTDCPP = /tool/pandora64/.package/gcc-15.2.0/lib64/libstdc++.so.6

.PHONY: lint
lint:
	mkdir -p $(LOG_DIR)/lint && \
	cd $(LOG_DIR)/lint && \
	verilator --lint-only -sv \
	-F $(FILE_LIST) \
	--top-module $(TOP_MODULE) | tee verilator_lint.log && \
	cd $(RTL_PATH) && \
	svlint -f $(FILE_LIST) \
	-c $(NOC_ROOT)/.svlint.toml | tee $(LOG_DIR)/lint/svlint.log

.PHONY: nocStructureTb
nocStructureTb:
	mkdir -p $(LOG_DIR)/nocStructureTb && \
	$(MAKE) -C $(TB_PATH)/nocStructure TEST=$(TEST) | tee $(LOG_DIR)/nocStructureTb/sim.log

.PHONY: niApbInitiatorTb
niApbInitiatorTb:
	mkdir -p $(LOG_DIR)/niApbInitiatorTb && \
	$(MAKE) -C $(TB_PATH)/niApbInitiator | tee $(LOG_DIR)/niApbInitiatorTb/sim.log

.PHONY: synthesis
synthesis:
	mkdir -p $(LOG_DIR)/synthesis/yosys && \
	cd $(LOG_DIR)/synthesis/yosys && \
	sed 's|__NOC_ROOT__|$(NOC_ROOT)|g' $(SYNTH_PATH)/yosys.ys > yosys.ys && \
	env LD_PRELOAD=$(YOSYS_SLANG_LIBSTDCPP) \
		yosys -m slang -s yosys.ys | tee yosys.log

.PHONY: clean
clean:
	rm -rf $(LOG_DIR)
	$(MAKE) -C $(TB_PATH)/nocStructure clean
	$(MAKE) -C $(TB_PATH)/niApbInitiator clean
