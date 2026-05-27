# ============================================================
# copy_hex_selftest.tcl — self-test 합성 PRE-hook
# ============================================================
# mt_selftest_top은 가중치(w/beta/vth)에 더해 골든(anomaly_mel/spk)도
# $readmemh basename으로 읽으므로, 합성 직전 7개 hex를 모두 run cwd(및
# synth_1 run 디렉토리)로 복사한다. (create_project_selftest.tcl에서 등록)
# ============================================================

set _here [file normalize [file dirname [info script]]]
set _repo [file normalize "$_here/../.."]
set _wt   "$_repo/hardware/src/weights"
set _gd   "$_wt/golden"

set _dsts [list [pwd]]
if { ![catch { set _rd [get_property DIRECTORY [get_runs synth_1]] }] && $_rd ne "" } {
    if { [lsearch -exact $_dsts $_rd] < 0 } { lappend _dsts $_rd }
}
puts "INFO(copy_hex_selftest): cwd=[pwd] ; dsts=$_dsts"

# {파일명 소스디렉토리} 목록
set _files [list \
    [list w1.hex   $_wt] [list w2.hex $_wt] [list w3.hex $_wt] \
    [list beta.hex $_wt] [list vth.hex $_wt] \
    [list anomaly_mel.hex $_gd] [list anomaly_spk.hex $_gd] ]

foreach _p $_files {
    set _h   [lindex $_p 0]
    set _src [file join [lindex $_p 1] $_h]
    if { ![file exists $_src] } { error "copy_hex_selftest: 원본 없음 → $_src" }
    foreach _d $_dsts {
        if { [catch { file copy -force $_src $_d } _e] } {
            puts "WARN(copy_hex_selftest): $_h → $_d 실패: $_e"
        } else {
            puts "INFO(copy_hex_selftest): $_h → $_d"
        }
    }
}
