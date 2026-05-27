# ============================================================
# create_project_mult.tcl — SpikeSense-Edge Phase 6-2 (다중 트랙 시분할)
# ============================================================
# 대상 : Nexys A7-100T (xc7a100tcsg324-1), Top = mult_spi_top (50 MHz)
# 실행 :
#   (A) Windows cmd.exe — 프로젝트 생성만:
#         vivado -mode batch -source create_project_mult.tcl
#   (B) Windows cmd.exe — 합성·구현·비트스트림까지:
#         vivado -mode batch -source create_project_mult.tcl -tclargs run
#   (C) Vivado GUI Tcl Console:
#         source {Z:/.../SpikeSense-Edge/hardware/fpga/create_project_mult.tcl}
#         # 전체 흐름까지: source 앞 줄에 → set ::run_flow 1
# ------------------------------------------------------------
# dual용 create_project.tcl과 동일 구조. 차이: top=mult_spi_top,
# XDC=nexys_a7_mult.xdc(50MHz 생성클럭), bit=mult_spi_top.bit.
# weight_bram/param_rom의 `ifdef SYNTHESIS 분기 + clk_div2의 BUFG `ifdef
# SYNTHESIS 분기 모두 -verilog_define SYNTHESIS로 활성화된다.
# ============================================================

if { ![info exists ::run_flow] } { set ::run_flow 0 }
if { [lsearch -exact $argv "run"] >= 0 } { set ::run_flow 1 }

set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize "$script_dir/../.."]

set proj_name  "vivado_spikehw_mult"
# ⚠️ 저장소 경로는 반드시 ASCII (한글 폴더면 합성 run이 무에러 크래시).
set proj_dir   "$repo_root/hardware/fpga/vivado_spikehw_mult"
set part       "xc7a100tcsg324-1"

set src_dir    "$repo_root/hardware/src"
set wt_dir     "$src_dir/weights"
set xdc_file   "$repo_root/hardware/constraints/nexys_a7_mult.xdc"
set tb_file    "$repo_root/hardware/testbench/tb_mult_snn_top.v"

puts "INFO: repo_root = $repo_root"
puts "INFO: proj_dir  = $proj_dir"

create_project $proj_name $proj_dir -part $part -force

# ---- RTL 소스 (hardware/src/*.v 전체) + Top=mult_spi_top ----
#   ⚠ 공백 포함 경로 → 각 파일을 [list $f]로 감싼다.
foreach f [glob "$src_dir/*.v"] {
    add_files -norecurse [list $f]
}
set_property top mult_spi_top [get_filesets sources_1]

# ---- 가중치 hex (합성 시 basename 탐색용 등록) ----
foreach f [glob "$wt_dir/*.hex"] {
    add_files -norecurse [list $f]
}

# ---- 제약 (XDC) — 구현 전용 ----
add_files -fileset constrs_1 -norecurse [list $xdc_file]
set _xdc_obj [get_files -quiet *nexys_a7_mult.xdc]
if { $_xdc_obj ne "" } {
    set_property used_in_synthesis false $_xdc_obj
}

# ---- 시뮬레이션 (선택): tb_mult_snn_top ----
if { [file exists $tb_file] } {
    add_files -fileset sim_1 -norecurse [list $tb_file]
    set_property top tb_mult_snn_top [get_filesets sim_1]
}

# ---- 합성 run 에만 SYNTHESIS 매크로 정의 (hex 경로 + clk_div2 BUFG) ----
set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} \
             -value {-verilog_define SYNTHESIS} \
             -objects [get_runs synth_1]

# ---- 합성 직전 hex를 run 디렉토리로 복사 (PRE-synth 훅) ----
set_property STEPS.SYNTH_DESIGN.TCL.PRE [file join $script_dir copy_hex.tcl] [get_runs synth_1]

update_compile_order -fileset sources_1
puts "INFO: 프로젝트 생성 완료 → $proj_dir/$proj_name.xpr"

# ============================================================
# run_flow == 1 : 합성 → 구현 → 비트스트림 → 리포트
# ============================================================
if { $::run_flow } {
    puts "INFO: ===== Synthesis 시작 ====="
    launch_runs synth_1 -jobs 4
    wait_on_run synth_1
    if { [get_property PROGRESS [get_runs synth_1]] != "100%" } {
        error "ERROR: Synthesis 실패 — synth_1 로그 확인"
    }
    open_run synth_1 -name synth_1
    puts "INFO: ----- 합성 후 자원 사용량 -----"
    report_utilization

    puts "INFO: ===== Implementation + Bitstream 시작 ====="
    launch_runs impl_1 -to_step write_bitstream -jobs 4
    wait_on_run impl_1
    if { [get_property PROGRESS [get_runs impl_1]] != "100%" } {
        error "ERROR: Implementation 실패 — impl_1 로그 확인"
    }
    open_run impl_1
    puts "INFO: ----- 타이밍 요약 (WNS >= 0 = 50MHz 닫힘 확인) -----"
    report_timing_summary -delay_type min_max -max_paths 1
    set bit "$proj_dir/$proj_name.runs/impl_1/mult_spi_top.bit"
    puts "INFO: 비트스트림 → $bit"
}
