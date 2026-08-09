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

.PHONY: niApbTargetTb
niApbTargetTb:
	mkdir -p $(LOG_DIR)/niApbTargetTb && \
	$(MAKE) -C $(TB_PATH)/niApbTarget | tee $(LOG_DIR)/niApbTargetTb/sim.log

.PHONY: niAxiLiteInitiatorTb
niAxiLiteInitiatorTb:
	mkdir -p $(LOG_DIR)/niAxiLiteInitiatorTb && \
	$(MAKE) -C $(TB_PATH)/niAxiLiteInitiator | tee $(LOG_DIR)/niAxiLiteInitiatorTb/sim.log

.PHONY: niAxiLiteTargetTb
niAxiLiteTargetTb:
	mkdir -p $(LOG_DIR)/niAxiLiteTargetTb && \
	$(MAKE) -C $(TB_PATH)/niAxiLiteTarget | tee $(LOG_DIR)/niAxiLiteTargetTb/sim.log

.PHONY: niAhbInitiatorTb
niAhbInitiatorTb:
	mkdir -p $(LOG_DIR)/niAhbInitiatorTb && \
	$(MAKE) -C $(TB_PATH)/niAhbInitiator | tee $(LOG_DIR)/niAhbInitiatorTb/sim.log

.PHONY: niAhbTargetTb
niAhbTargetTb:
	mkdir -p $(LOG_DIR)/niAhbTargetTb && \
	$(MAKE) -C $(TB_PATH)/niAhbTarget | tee $(LOG_DIR)/niAhbTargetTb/sim.log

.PHONY: niRouterPortTb
niRouterPortTb:
	mkdir -p $(LOG_DIR)/niRouterPortTb && \
	$(MAKE) -C $(TB_PATH)/niRouterPort | tee $(LOG_DIR)/niRouterPortTb/sim.log

.PHONY: nocApbIntegration1Tb
nocApbIntegration1Tb:
	mkdir -p $(LOG_DIR)/nocApbIntegration1Tb && \
	$(MAKE) -C $(TB_PATH)/nocApbIntegration1 | tee $(LOG_DIR)/nocApbIntegration1Tb/sim.log

.PHONY: nocApbIntegration2Tb
nocApbIntegration2Tb:
	mkdir -p $(LOG_DIR)/nocApbIntegration2Tb && \
	$(MAKE) -C $(TB_PATH)/nocApbIntegration2 | tee $(LOG_DIR)/nocApbIntegration2Tb/sim.log

.PHONY: nocAxiIntegration1Tb
nocAxiIntegration1Tb:
	mkdir -p $(LOG_DIR)/nocAxiIntegration1Tb && \
	$(MAKE) -C $(TB_PATH)/nocAxiIntegration1 | tee $(LOG_DIR)/nocAxiIntegration1Tb/sim.log

.PHONY: nocAhbIntegration1Tb
nocAhbIntegration1Tb:
	mkdir -p $(LOG_DIR)/nocAhbIntegration1Tb && \
	$(MAKE) -C $(TB_PATH)/nocAhbIntegration1 | tee $(LOG_DIR)/nocAhbIntegration1Tb/sim.log

.PHONY: nocAxiIntegration2Tb
nocAxiIntegration2Tb:
	mkdir -p $(LOG_DIR)/nocAxiIntegration2Tb && \
	$(MAKE) -C $(TB_PATH)/nocAxiIntegration2 | tee $(LOG_DIR)/nocAxiIntegration2Tb/sim.log

.PHONY: nocAhbIntegration2Tb
nocAhbIntegration2Tb:
	mkdir -p $(LOG_DIR)/nocAhbIntegration2Tb && \
	$(MAKE) -C $(TB_PATH)/nocAhbIntegration2 | tee $(LOG_DIR)/nocAhbIntegration2Tb/sim.log

.PHONY: nocBridgeIntegration1Tb
nocBridgeIntegration1Tb:
	mkdir -p $(LOG_DIR)/nocBridgeIntegration1Tb && \
	$(MAKE) -C $(TB_PATH)/nocBridgeIntegration1 | tee $(LOG_DIR)/nocBridgeIntegration1Tb/sim.log

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
	$(MAKE) -C $(TB_PATH)/niApbTarget clean
	$(MAKE) -C $(TB_PATH)/niRouterPort clean
	$(MAKE) -C $(TB_PATH)/nocApbIntegration1 clean
	$(MAKE) -C $(TB_PATH)/nocApbIntegration2 clean
	$(MAKE) -C $(TB_PATH)/niAxiLiteInitiator clean
	$(MAKE) -C $(TB_PATH)/niAxiLiteTarget clean
	$(MAKE) -C $(TB_PATH)/niAhbInitiator clean
	$(MAKE) -C $(TB_PATH)/niAhbTarget clean
	$(MAKE) -C $(TB_PATH)/nocAxiIntegration1 clean
	$(MAKE) -C $(TB_PATH)/nocAhbIntegration1 clean
	$(MAKE) -C $(TB_PATH)/nocAxiIntegration2 clean
	$(MAKE) -C $(TB_PATH)/nocAhbIntegration2 clean
	$(MAKE) -C $(TB_PATH)/nocBridgeIntegration1 clean
