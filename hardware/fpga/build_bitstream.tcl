# ============================================================
# build_bitstream.tcl — non-project 플로우로 합성→구현→비트스트림
# ============================================================
# 왜 이 스크립트? (선택 — 비프로젝트 대안)
#   정상 빌드 경로는 create_project.tcl(프로젝트 모드)이다. 이 스크립트는
#   프로젝트 없이 메인 프로세스에서 합성→구현→비트스트림을 돌리는 대안이다.
#   배경: 과거 저장소 경로에 한글이 있던 시절, 프로젝트 모드 launch_runs 합성이
#   별도 프로세스 spawn 중 크래시했다(한글 경로 mojibake). 그때 우회로 만든 것이며,
#   ASCII 경로로 바꿔 프로젝트 모드가 정상화된 지금은 GUI 없는 배치 빌드용 백업이다.
#   (메인 프로세스 in-process 합성 검증: 경고 0, LUT~3.5K/BRAM36 4/DSP 2.)
#
# 실행 (Vivado Tcl Console 또는 cmd.exe 배치):
#   source {Z:/.../SpikeSense-Edge/hardware/fpga/build_bitstream.tcl}
#   또는  vivado -mode batch -source build_bitstream.tcl
#
# 산출물: hardware/fpga/build/ 아래 dual_snn_top.bit, 타이밍/자원 리포트.
# ============================================================

set script_dir [file normalize [file dirname [info script]]]
set repo  [file normalize "$script_dir/../.."]
set src   "$repo/hardware/src"
set wt    "$src/weights"
set xdc   "$repo/hardware/constraints/nexys_a7_dual.xdc"
set build "$script_dir/build"
set part  "xc7a100tcsg324-1"

# ---- 재실행 안전: 이미 열린 설계/프로젝트 정리 ----
#   (앞선 합성으로 in-memory 설계가 열려 있으면 read_verilog가 충돌하므로)
catch { close_design }
catch { close_project }

# ---- 작업 디렉토리 준비 + hex 복사 (synth cwd 기준 basename 해결) ----
file mkdir $build
foreach h {w1.hex w2.hex w3.hex beta.hex vth.hex} {
    file copy -force [file join $wt $h] $build
}
cd $build
puts "INFO: build dir = $build"

# ---- RTL 읽기 (공백 경로 → 파일마다 [list]로 보호) ----
foreach f [glob "$src/*.v"] {
    read_verilog -library xil_defaultlib [list $f]
}

# ---- 합성 (메인 프로세스, SYNTHESIS 매크로 → ifdef로 basename hex) ----
synth_design -top dual_snn_top -part $part -verilog_define SYNTHESIS
write_checkpoint -force post_synth.dcp
report_utilization -file util_synth.rpt

# ---- 구현용 제약은 합성 후 적용 (공백 경로 → [list]로 보호) ----
read_xdc [list $xdc]

# ---- 구현: opt → place → route ----
opt_design
place_design
route_design
write_checkpoint -force post_route.dcp   ;# 배치·라우팅 완료 설계 (GUI 재오픈용)

# ---- 리포트 ----
report_utilization      -file util_impl.rpt
report_timing_summary   -file timing_summary.rpt -max_paths 10
set wns [get_property SLACK [get_timing_paths -setup -max_paths 1 -nworst 1]]
puts "============================================================"
puts "INFO: WNS (setup worst slack) = $wns  (>=0 이면 타이밍 통과)"
puts "============================================================"

# ---- 비트스트림 ----
write_bitstream -force dual_snn_top.bit
puts "INFO: 비트스트림 → $build/dual_snn_top.bit"
puts "INFO: 리포트 → util_impl.rpt / timing_summary.rpt"
