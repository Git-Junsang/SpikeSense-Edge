# ============================================================
# create_project_selftest.tcl — Phase 6-2 보드 자가진단 (RPi 불필요)
# ============================================================
# 대상 : Nexys A7-100T (xc7a100tcsg324-1), Top = mt_selftest_top (50 MHz)
# 실행 :
#   vivado -mode batch -source create_project_selftest.tcl -tclargs run
#   (GUI Tcl Console: set ::run_flow 1 ; source {.../create_project_selftest.tcl})
# ------------------------------------------------------------
# create_project_mt.tcl와 동일 구조. 차이: Top=mt_selftest_top,
# XDC=nexys_a7_selftest.xdc, PRE훅=copy_hex_selftest.tcl(가중치+골든 hex),
# bit=mt_selftest_top.bit.
# 보드를 굽고 리셋하면 ~6ms 후 LED15=PASS / LED14=FAIL / LED13=done.
# ============================================================

if { ![info exists ::run_flow] } { set ::run_flow 0 }
if { [lsearch -exact $argv "run"] >= 0 } { set ::run_flow 1 }

set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize "$script_dir/../.."]

set proj_name  "vivado_spikehw_selftest"
set proj_dir   "$repo_root/hardware/fpga/vivado_spikehw_selftest"
set part       "xc7a100tcsg324-1"

set src_dir    "$repo_root/hardware/src"
set wt_dir     "$src_dir/weights"
set gd_dir     "$wt_dir/golden"
set xdc_file   "$repo_root/hardware/constraints/nexys_a7_selftest.xdc"

puts "INFO: repo_root = $repo_root"
puts "INFO: proj_dir  = $proj_dir"

create_project $proj_name $proj_dir -part $part -force

# ---- RTL 소스 전체 + Top=mt_selftest_top ----
foreach f [glob "$src_dir/*.v"] {
    add_files -norecurse [list $f]
}
set_property top mt_selftest_top [get_filesets sources_1]

# ---- 가중치 + 골든 hex 등록 (basename 탐색용) ----
foreach f [glob "$wt_dir/*.hex"] { add_files -norecurse [list $f] }
add_files -norecurse [list [file join $gd_dir anomaly_mel.hex]]
add_files -norecurse [list [file join $gd_dir anomaly_spk.hex]]

# ---- 제약 (XDC) — 구현 전용 ----
add_files -fileset constrs_1 -norecurse [list $xdc_file]
set _xdc_obj [get_files -quiet *nexys_a7_selftest.xdc]
if { $_xdc_obj ne "" } { set_property used_in_synthesis false $_xdc_obj }

# ---- 합성 run 에만 SYNTHESIS 매크로 (hex basename + clk_div2 BUFG) ----
set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} \
             -value {-verilog_define SYNTHESIS} \
             -objects [get_runs synth_1]

# ---- 합성 직전 hex(가중치+골든) 복사 (PRE-synth 훅) ----
set_property STEPS.SYNTH_DESIGN.TCL.PRE [file join $script_dir copy_hex_selftest.tcl] [get_runs synth_1]

update_compile_order -fileset sources_1
puts "INFO: 프로젝트 생성 완료 → $proj_dir/$proj_name.xpr"

if { $::run_flow } {
    puts "INFO: ===== Synthesis 시작 ====="
    launch_runs synth_1 -jobs 4
    wait_on_run synth_1
    if { [get_property PROGRESS [get_runs synth_1]] != "100%" } {
        error "ERROR: Synthesis 실패 — synth_1 로그 확인"
    }
    open_run synth_1 -name synth_1
    report_utilization

    puts "INFO: ===== Implementation + Bitstream 시작 ====="
    launch_runs impl_1 -to_step write_bitstream -jobs 4
    wait_on_run impl_1
    if { [get_property PROGRESS [get_runs impl_1]] != "100%" } {
        error "ERROR: Implementation 실패 — impl_1 로그 확인"
    }
    open_run impl_1
    report_timing_summary -delay_type min_max -max_paths 1
    set bit "$proj_dir/$proj_name.runs/impl_1/mt_selftest_top.bit"
    puts "INFO: 비트스트림 → $bit"
}
