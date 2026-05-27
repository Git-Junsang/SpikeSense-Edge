# ============================================================
# create_project.tcl — SpikeSense-Edge Phase 6 Vivado 프로젝트 생성
# ============================================================
# 대상 : Nexys A7-100T (xc7a100tcsg324-1), Top = dual_snn_top
# 실행 :
#   (A) Windows cmd.exe — 프로젝트 생성만:
#         cd /d "Z:\...\SpikeSense-Edge\hardware\fpga"
#         vivado -mode batch -source create_project.tcl
#   (B) Windows cmd.exe — 합성·구현·비트스트림까지 한 번에:
#         vivado -mode batch -source create_project.tcl -tclargs run
#   (C) Vivado GUI Tcl Console — cd 불필요(스크립트가 경로 자동 계산):
#         source {Z:/.../SpikeSense-Edge/hardware/fpga/create_project.tcl}
#         # 전체 흐름까지: 위 source 앞 줄에 → set ::run_flow 1
#         # ⚠ Tcl Console에서 'cd /d'는 cmd.exe 명령이라 에러("wrong # args") 발생
# ------------------------------------------------------------
# 경로는 스크립트 위치 기준으로 자동 계산하므로 Windows(Z:/) 어디에 있든 동작한다.
# weight_bram.v / param_rom.v 의 `ifdef SYNTHESIS 분기에 맞춰
# 합성 run에만 -verilog_define SYNTHESIS 를 주고, weights/*.hex 를
# 프로젝트 소스로 추가해 합성이 basename(w1.hex 등)으로 찾도록 한다.
# ============================================================

# ---- run_flow: 1이면 합성→구현→비트스트림까지 자동 실행 ----
if { ![info exists ::run_flow] } { set ::run_flow 0 }
if { [lsearch -exact $argv "run"] >= 0 } { set ::run_flow 1 }

# ---- 경로 계산 (스크립트 = <repo>/hardware/fpga/create_project.tcl) ----
set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize "$script_dir/../.."]

set proj_name  "vivado_spikehw_dual"
# 프로젝트는 저장소 안(hardware/fpga/vivado_spikehw_dual)에 생성된다.
# ⚠️ 단, 저장소 경로는 반드시 ASCII여야 한다. 경로에 한글(비-ASCII)이 있으면
#   합성 run(별도 프로세스 spawn)이 elaboration 직후 무에러로 크래시한다
#   (Vivado는 프로젝트/run 경로에 ASCII만 공식 지원). 공백은 아래 add_files/
#   read_xdc처럼 [list]로 감싸면 처리되지만, 한글은 폴더명 자체를 ASCII로 바꿔야 한다.
set proj_dir   "$repo_root/hardware/fpga/vivado_spikehw_dual"
set part       "xc7a100tcsg324-1"

set src_dir    "$repo_root/hardware/src"
set wt_dir      "$src_dir/weights"
set xdc_file   "$repo_root/hardware/constraints/nexys_a7_dual.xdc"
set tb_file    "$repo_root/hardware/testbench/tb_dual_snn_top.v"

puts "INFO: repo_root  = $repo_root"
puts "INFO: proj_dir   = $proj_dir"

# ---- 프로젝트 생성 (-force: 기존 동명 프로젝트 덮어쓰기) ----
create_project $proj_name $proj_dir -part $part -force

# ---- RTL 소스 (11개) + Top ----
#   ⚠ 저장소 경로에 공백/한글이 있으므로 각 파일을 [list $f]로 감싸야 한다.
#   add_files에 공백 포함 경로를 그냥 넘기면 공백 기준으로 쪼개져
#   "[Vivado 12-172] File or Directory 'Z:/2026' does not exist" 에러가 난다.
foreach f [glob "$src_dir/*.v"] {
    add_files -norecurse [list $f]
}
set_property top dual_snn_top [get_filesets sources_1]

# ---- 가중치 hex: 합성 시 basename 탐색용으로 프로젝트에 등록 ----
#   ifdef SYNTHESIS 분기에서 "w1.hex" 처럼 파일명만 쓰므로,
#   Vivado가 이 파일들의 디렉토리를 메모리 파일 탐색 경로에 포함한다.
foreach f [glob "$wt_dir/*.hex"] {
    add_files -norecurse [list $f]
}

# ---- 제약 (XDC) ----
add_files -fileset constrs_1 -norecurse [list $xdc_file]
# XDC는 구현(implementation) 전용으로 표시 — 합성에서 제외(표준 관행).
# 핀/IOSTANDARD/타이밍 제약은 합성엔 불필요하고 구현에서만 쓰면 된다.
# (타이밍 구동 합성을 원하면 아래 set_property 줄을 지워 XDC를 합성에도 쓰면 됨)
set _xdc_obj [get_files -quiet *nexys_a7_dual.xdc]
if { $_xdc_obj ne "" } {
    set_property used_in_synthesis false $_xdc_obj
}

# ---- 시뮬레이션 (선택): tb_dual_snn_top ----
#   합성에는 SYNTHESIS 매크로가 정의되지만 sim에는 정의되지 않으므로
#   RTL의 else 분기(저장소 루트 상대경로)가 적용된다.
#   → Vivado sim 실행 시 working dir 을 저장소 루트로 설정해야 hex 를 읽는다.
if { [file exists $tb_file] } {
    add_files -fileset sim_1 -norecurse [list $tb_file]
    set_property top tb_dual_snn_top [get_filesets sim_1]
}

# ---- 합성 run 에만 SYNTHESIS 매크로 정의 ----
#   (sim/구현에는 영향 없음 → RTL ifdef 분기가 정확히 갈린다)
set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} \
             -value {-verilog_define SYNTHESIS} \
             -objects [get_runs synth_1]

# ---- 합성 직전 hex를 run 디렉토리(cwd)로 복사 (PRE-synth 훅) ----
#   프로젝트에 hex를 add_files 해도 합성 sub-process는 $readmem 탐색 경로에
#   포함하지 않는다("could not open $readmem data file 'w1.hex'"). 그래서
#   합성 cwd로 hex를 복사해 basename("w1.hex" 등)이 풀리게 한다 (copy_hex.tcl).
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
    puts "INFO: ----- 타이밍 요약 (WNS >= 0 확인) -----"
    report_timing_summary -delay_type min_max -max_paths 1
    set bit "$proj_dir/$proj_name.runs/impl_1/dual_snn_top.bit"
    puts "INFO: 비트스트림 → $bit"
}
