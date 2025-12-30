TOP_MODULE=noc
RTL_PATH=../rtl

.PHONY: lint
lint: $(RTL_PATH)/$(TOP_MODULE).sv
	verilator --lint-only -I../rtl/ pa_$(TOP_MODULE).sv $(TOP_MODULE).sv

.PHONY: clean
clean:
	rm -rf .stamp.*;
	rm -rf ./obj_dir
	rm -rf waveform.vcd
