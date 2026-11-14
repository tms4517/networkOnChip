clear -all

# Root of the networkOnChip repo (exported by the top-level Makefile).
set ROOT $::env(NOC_ROOT)
set RTL  $ROOT/rtl
set FV   $ROOT/tb/formal/router

# Load and analyze the router RTL (and its submodules), the assertion module
# and the formal testbench.
analyze -sv12 \
  $RTL/pa_noc.sv \
  $RTL/fabric/synchronousFifo.sv \
  $RTL/fabric/roundRobinArbiter.sv \
  $RTL/fabric/arbiter.sv \
  $RTL/fabric/router.sv \
  $FV/routerAssertions.sv \
  $FV/routerTb.sv

# Enable formal coverage instrumentation before elaboration. Use COI as the
# checker mode: proof_core reports 0% for trivially-proven assertions.
check_cov -init -type {stimuli coi}

# Synthesize and read the netlist.
elaborate -top routerTb

# Single clock domain, active-low asynchronous reset.
clock i_clk
reset ~i_arst_n

# Bound total proof time so an inconclusive property cannot hang the run.
set_prove_time_limit 10m

# Prove all properties.
prove -all

# Summary of every property's status in the log.
report -summary -force -results -file router_fv_summary.rpt

# {{{ Formal coverage (COV app)
#   * stimuli (reachability) - <100% => over-constrained or dead code.
#   * checker (observability) - <100% => logic not in any assertion's cone.
check_cov -measure -type {stimuli coi}

check_cov -report -checker_mode coi -report_file router_cov.rpt -force

# List the unreachable cover items in the DUT (source locations) for triage.
check_cov -list -status unreachable -include_instance {.*u_dut.*} -regexp
# }}}

exit
