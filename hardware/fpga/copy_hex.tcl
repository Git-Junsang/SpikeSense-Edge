# ============================================================
# copy_hex.tcl — 합성 PRE-hook: 가중치/파라미터 hex를 합성 run 디렉토리로 복사
# ============================================================
# Vivado 합성은 run 디렉토리(<proj>.runs/synth_1)를 작업 디렉토리(cwd)로
# 쓰며, $readmemh의 상대/basename 경로를 그 cwd 기준으로 찾는다.
# 프로젝트에 hex를 add_files 해도 합성 sub-process의 $readmem 탐색 경로엔
# 들어가지 않으므로("could not open $readmem data file 'w1.hex'"),
# 합성 직전 이 훅이 hex를 cwd로 복사해 weight_bram.v / param_rom.v 의
# `ifdef SYNTHESIS 분기("w1.hex" 등 basename)가 확실히 파일을 찾게 한다.
#
# 등록: create_project.tcl 에서
#   set_property STEPS.SYNTH_DESIGN.TCL.PRE <이 파일> [get_runs synth_1]
# 실행 컨텍스트: 이 스크립트는 synth_1 run 디렉토리(cwd)에서 source 된다.
# ============================================================

set _here [file normalize [file dirname [info script]]]   ;# .../hardware/fpga
set _repo [file normalize "$_here/../.."]
set _wt   "$_repo/hardware/src/weights"

# 복사 대상 디렉토리: cwd + 합성 run 디렉토리(명시적 조회).
# 프로젝트 플로우에서 PRE-훅의 cwd가 run 디렉토리가 아닐 수 있어,
# $readmem이 실제로 탐색하는 synth_1 run 디렉토리에도 확실히 복사한다.
set _dsts [list [pwd]]
if { ![catch { set _rd [get_property DIRECTORY [get_runs synth_1]] }] && $_rd ne "" } {
    if { [lsearch -exact $_dsts $_rd] < 0 } { lappend _dsts $_rd }
}
puts "INFO(copy_hex): cwd=[pwd]"
puts "INFO(copy_hex): 대상 디렉토리 = $_dsts"

foreach _h {w1.hex w2.hex w3.hex beta.hex vth.hex} {
    set _src [file join $_wt $_h]
    if { ![file exists $_src] } {
        error "copy_hex: 원본 hex 없음 → $_src"
    }
    foreach _d $_dsts {
        if { [catch { file copy -force $_src $_d } _e] } {
            puts "WARN(copy_hex): $_h → $_d 복사 실패: $_e"
        } else {
            puts "INFO(copy_hex): $_h → $_d"
        }
    }
}
