TOP_MODULE=noc
RTL_PATH=../rtl

.PHONY: lint
lint:
	verilator --lint-only -sv -f noc.f
	svlint -f noc.f -c ../.svlint.toml

.PHONY: clean
clean:
	rm -rf .stamp.*;
	rm -rf ./obj_dir
	rm -rf waveform.vcd
