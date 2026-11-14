LOG_DIR ?= $(shell pwd)/logs
TOP_MODULE = noc
NOC_ROOT = $(shell pwd)
RTL_PATH = $(NOC_ROOT)/rtl
TB_PATH = $(NOC_ROOT)/tb/directedTb
FORMAL_PATH = $(NOC_ROOT)/tb/formal
# Optional job-submission prefix (e.g. an LSF bsub command); empty runs locally.
GRID ?=
FILE_LIST = $(RTL_PATH)/$(TOP_MODULE).f
TEST ?= 1
SYNTH_PATH = $(NOC_ROOT)/synthesis
# Optional libstdc++ to LD_PRELOAD for the yosys-slang plugin (set in env if needed).
YOSYS_SLANG_LIBSTDCPP ?=

export NOC_ROOT

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

# Directed testbenches: `make <name>Tb` builds and runs tb/directedTb/<name>
DIRECTED_TBS = nocStructure \
               niApbInitiator \
               niApbTarget \
               niAxiLiteInitiator \
               niAxiLiteTarget \
               niAhbInitiator \
               niAhbTarget \
               niRouterPort \
               nocApbIntegration1 \
               nocApbIntegration2 \
               nocAxiIntegration1 \
               nocAhbIntegration1 \
               nocAxiIntegration2 \
               nocAhbIntegration2 \
               nocBridgeIntegration1 \
               nocBridgeIntegration2 \
               nocBridgeIntegration3 \
               nocBridgeIntegration4 \
               asyncFifo \
               cdcNiBridge \
               nocAsyncIntegration1

.PHONY: $(addsuffix Tb,$(DIRECTED_TBS))
$(addsuffix Tb,$(DIRECTED_TBS)): %Tb:
	mkdir -p $(LOG_DIR)/$@ && \
	cd $(LOG_DIR)/$@ && \
	$(MAKE) -f $(TB_PATH)/$*/Makefile TB_DIR=$(TB_PATH)/$*/ TEST=$(TEST) | tee sim.log

.PHONY: formalRouterTb
formalRouterTb:
	mkdir -p $(LOG_DIR)/formalRouterTb && \
	cd $(LOG_DIR)/formalRouterTb && \
	rm -rf jgproject && \
	$(GRID) jg $(FORMAL_PATH)/router/jg/jg.tcl | tee jg.log

.PHONY: synthesis
synthesis:
	mkdir -p $(LOG_DIR)/synthesis/yosys && \
	cd $(LOG_DIR)/synthesis/yosys && \
	sed 's|__NOC_ROOT__|$(NOC_ROOT)|g' $(SYNTH_PATH)/yosys.ys > yosys.ys && \
	env $(if $(YOSYS_SLANG_LIBSTDCPP),LD_PRELOAD=$(YOSYS_SLANG_LIBSTDCPP)) \
		yosys -m slang -s yosys.ys | tee yosys.log

.PHONY: clean
clean:
	rm -rf $(LOG_DIR)
