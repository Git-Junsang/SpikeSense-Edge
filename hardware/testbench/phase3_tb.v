// ============================================================
// phase3_tb.v — Phase 3 제어·통합 모듈 검증 테스트벤치
// ============================================================
// 대상: control_fsm, snn_top (anomaly_judge는 src_old 복사본)
//
// 실행:
//   /usr/bin/iverilog -g2001 -o hardware/sim/phase3 \
//       hardware/testbench/phase3_tb.v hardware/src/*.v
//   /usr/bin/vvp hardware/sim/phase3
// ============================================================

`timescale 1ns/1ps

`define CHECK(val, exp, name) \
    if ((val) === (exp)) begin \
        pass_n = pass_n + 1; \
        $display("  PASS  %s", name); \
    end else begin \
        fail_n = fail_n + 1; \
        $display("  FAIL  %s  got=%0d  exp=%0d", name, val, exp); \
    end

`define CHECK_H(val, exp, name) \
    if ((val) === (exp)) begin \
        pass_n = pass_n + 1; \
        $display("  PASS  %s", name); \
    end else begin \
        fail_n = fail_n + 1; \
        $display("  FAIL  %s  got=0x%h  exp=0x%h", name, val, exp); \
    end

module tb_phase3;

// ─── 공통 클럭 / 리셋 ───────────────────────────────────────
reg clk   = 0;
reg rst_n = 0;
always #5 clk = ~clk;  // 100 MHz

integer pass_n = 0;
integer fail_n = 0;
integer i;

// ─── control_fsm 포트 ───────────────────────────────────────
reg  fsm_frame_valid = 0;
wire [1:0]  fsm_layer;
wire [7:0]  fsm_neuron_cnt;
wire [7:0]  fsm_fan_cnt;
wire        fsm_mac_clear;
wire        fsm_mac_en;
wire        fsm_mac_shift_en;
wire        fsm_mem_wr_en;
wire        fsm_spike_wr_en;
wire        fsm_spike_clear;
wire        fsm_mem_rst_pulse;
wire        fsm_ts_done;
wire        fsm_done;
wire        fsm_busy;

control_fsm #(.TS_TOTAL(2)) dut_fsm (  // 검증 속도용: 2 타임스텝
    .clk          (clk),
    .rst_n        (rst_n),
    .frame_valid  (fsm_frame_valid),
    .layer        (fsm_layer),
    .neuron_cnt   (fsm_neuron_cnt),
    .fan_cnt      (fsm_fan_cnt),
    .mac_clear    (fsm_mac_clear),
    .mac_en       (fsm_mac_en),
    .mac_shift_en (fsm_mac_shift_en),
    .mem_wr_en    (fsm_mem_wr_en),
    .spike_wr_en  (fsm_spike_wr_en),
    .spike_clear  (fsm_spike_clear),
    .mem_rst_pulse(fsm_mem_rst_pulse),
    .ts_done      (fsm_ts_done),
    .done         (fsm_done),
    .busy         (fsm_busy)
);

// ─── snn_top 포트 ───────────────────────────────────────────
reg  [319:0] top_mel_in  = 320'b0;
reg          top_fv      = 0;
wire         top_anomaly;
wire         top_busy;

snn_top dut_top (
    .clk          (clk),
    .rst_n        (rst_n),
    .mel_in       (top_mel_in),
    .frame_valid  (top_fv),
    .anomaly_flag (top_anomaly),
    .busy         (top_busy)
);

// ─── 보조: 클럭 대기 태스크 ─────────────────────────────────
task clk_n;
    input integer n;
    integer k;
    begin
        for (k = 0; k < n; k = k + 1)
            @(posedge clk);
        #1;
    end
endtask

// ─── VCD 덤프 ────────────────────────────────────────────────
initial begin
    $dumpfile("hardware/sim/phase3.vcd");
    $dumpvars(0, tb_phase3);
end

// ============================================================
// 메인 테스트
// ============================================================
initial begin
    #12 rst_n = 1;

    // ===========================================================
    // [1] control_fsm — IDLE 초기 상태
    // ===========================================================
    $display("\n[1] control_fsm — IDLE 초기 상태");
    #2;
    `CHECK(fsm_busy,          1'b0, "1-1  reset 후 busy=0")
    `CHECK(fsm_mac_clear,     1'b0, "1-2  IDLE: mac_clear=0")
    `CHECK(fsm_mac_en,        1'b0, "1-3  IDLE: mac_en=0")
    `CHECK(fsm_mem_wr_en,     1'b0, "1-4  IDLE: mem_wr_en=0")
    `CHECK(fsm_spike_clear,   1'b0, "1-5  IDLE: spike_clear=0")
    `CHECK(fsm_mem_rst_pulse, 1'b0, "1-6  IDLE: mem_rst_pulse=0")
    `CHECK(fsm_done,          1'b0, "1-7  IDLE: done=0")

    // ===========================================================
    // [2] control_fsm — 첫 frame_valid: MEM_RST → SPK_CLR → LAYER
    // ===========================================================
    $display("\n[2] control_fsm — 첫 frame_valid 후 MEM_RST/SPK_CLR 시퀀스");

    // ts_cnt=0이므로 첫 frame_valid → S_MEM_RST
    fsm_frame_valid = 1;
    @(posedge clk); #1;
    fsm_frame_valid = 0;

    // 이제 S_MEM_RST
    `CHECK(fsm_mem_rst_pulse, 1'b1, "2-1  MEM_RST: mem_rst_pulse=1")
    `CHECK(fsm_spike_clear,   1'b0, "2-2  MEM_RST: spike_clear=0")
    `CHECK(fsm_busy,          1'b1, "2-3  MEM_RST: busy=1")

    @(posedge clk); #1;
    // S_SPK_CLR
    `CHECK(fsm_spike_clear,   1'b1, "2-4  SPK_CLR: spike_clear=1")
    `CHECK(fsm_mem_rst_pulse, 1'b0, "2-5  SPK_CLR: mem_rst_pulse=0")

    @(posedge clk); #1;
    // S_LAYER: L1, neuron_cnt=0, fan_cnt=0
    `CHECK(fsm_layer,      2'd0,  "2-6  LAYER: layer=0(L1)")
    `CHECK(fsm_neuron_cnt, 8'd0,  "2-7  LAYER: neuron_cnt=0")
    `CHECK(fsm_fan_cnt,    8'd0,  "2-8  LAYER: fan_cnt=0")
    `CHECK(fsm_mac_clear,  1'b1,  "2-9  fan_cnt=0: mac_clear=1")
    `CHECK(fsm_mac_en,     1'b0,  "2-10 fan_cnt=0: mac_en=0")
    `CHECK(fsm_mac_shift_en,1'b1, "2-11 L1: mac_shift_en=1")
    `CHECK(fsm_spike_clear,1'b0,  "2-12 LAYER: spike_clear=0")

    // ===========================================================
    // [3] control_fsm — fan_cnt 증가 및 MAC en 확인
    // ===========================================================
    $display("\n[3] control_fsm — fan_cnt 진행 (L1, 40입력)");

    @(posedge clk); #1;
    // fan_cnt=1: MAC 시작
    `CHECK(fsm_fan_cnt,   8'd1,  "3-1  fan_cnt=1")
    `CHECK(fsm_mac_en,    1'b1,  "3-2  fan_cnt=1: mac_en=1")
    `CHECK(fsm_mac_clear, 1'b0,  "3-3  fan_cnt=1: mac_clear=0")
    `CHECK(fsm_mem_wr_en, 1'b0,  "3-4  fan_cnt=1: mem_wr_en=0")

    // fan_cnt=40: 마지막 MAC (FAN_L1=40)
    clk_n(39); // 현재 1 → 40
    `CHECK(fsm_fan_cnt,   8'd40, "3-5  fan_cnt=40 (마지막 MAC)")
    `CHECK(fsm_mac_en,    1'b1,  "3-6  fan_cnt=40: mac_en=1")
    `CHECK(fsm_mem_wr_en, 1'b0,  "3-7  fan_cnt=40: mem_wr_en=0")

    @(posedge clk); #1;
    // fan_cnt=41: write-back
    `CHECK(fsm_fan_cnt,   8'd41, "3-8  fan_cnt=41 (write-back)")
    `CHECK(fsm_mac_en,    1'b0,  "3-9  write-back: mac_en=0")
    `CHECK(fsm_mem_wr_en, 1'b1,  "3-10 write-back: mem_wr_en=1")
    `CHECK(fsm_spike_wr_en,1'b1, "3-11 write-back L1: spike_wr_en=1")

    @(posedge clk); #1;
    // 다음 뉴런 시작: neuron_cnt=1, fan_cnt=0
    `CHECK(fsm_neuron_cnt, 8'd1,  "3-12 다음 뉴런: neuron_cnt=1")
    `CHECK(fsm_fan_cnt,    8'd0,  "3-13 fan_cnt 리셋=0")
    `CHECK(fsm_mac_clear,  1'b1,  "3-14 fan_cnt=0: mac_clear=1")

    // ===========================================================
    // [4] control_fsm — 레이어 전환 (L1→L2→L3)
    // ===========================================================
    $display("\n[4] control_fsm — 레이어 전환");

    // L1 뉴런 1~127 통과 → L2 neuron_cnt=0, fan_cnt=0
    // 뉴런 1 fan_cnt=0에서 시작, 뉴런 1개당 42cy (0→41→next_neuron0)
    // 127뉴런 × 42cy = 5334cy → L2 시작
    clk_n(42 * 127); // 127뉴런 × 42cy = 5334
    // 이제 L1 뉴런 127 write-back 직후: layer→1(L2), neuron_cnt=0, fan_cnt=0
    `CHECK(fsm_layer,      2'd1, "4-1  L2 전환: layer=1")
    `CHECK(fsm_neuron_cnt, 8'd0, "4-2  L2: neuron_cnt=0")
    `CHECK(fsm_fan_cnt,    8'd0, "4-3  L2: fan_cnt=0")
    `CHECK(fsm_mac_shift_en,1'b0,"4-4  L2: mac_shift_en=0")
    `CHECK(fsm_spike_wr_en, 1'b0,"4-5  L2 fan_cnt=0: spike_wr_en=0")

    // L2 전체 통과: 32뉴런 × 130cy = 4160cy
    clk_n(4160);
    `CHECK(fsm_layer,      2'd2, "4-6  L3 전환: layer=2")
    `CHECK(fsm_neuron_cnt, 8'd0, "4-7  L3: neuron_cnt=0")
    `CHECK(fsm_mac_shift_en,1'b0,"4-8  L3: mac_shift_en=0")

    // L3 뉴런 0 통과 (34cy)
    clk_n(34);
    `CHECK(fsm_neuron_cnt, 8'd1, "4-9  L3 뉴런 1")

    // L3 뉴런 1 write-back (33cy 더)
    clk_n(33);
    // write-back: ts_done=1 이어야 함
    `CHECK(fsm_ts_done,    1'b1, "4-10 L3 마지막 write-back: ts_done=1")
    `CHECK(fsm_mem_wr_en,  1'b1, "4-11 write-back: mem_wr_en=1")
    `CHECK(fsm_spike_wr_en,1'b0, "4-12 L3: spike_wr_en=0")

    @(posedge clk); #1;
    // TS_TOTAL=2이므로 ts_cnt=0→1 → back to IDLE (ts_cnt<1)
    `CHECK(fsm_busy,   1'b0, "4-13 1st 타임스텝 완료: IDLE")
    `CHECK(fsm_done,   1'b0, "4-14 1st 타임스텝: done=0 (아직 2nd 남음)")
    `CHECK(fsm_ts_done,1'b0, "4-15 ts_done 1클럭만 유지")

    // ===========================================================
    // [5] control_fsm — 2nd 타임스텝: SPK_CLR(no MEM_RST), done=1
    // ===========================================================
    $display("\n[5] control_fsm — 2nd 타임스텝 (ts_cnt=1, MEM_RST 없음)");

    fsm_frame_valid = 1;
    @(posedge clk); #1;
    fsm_frame_valid = 0;

    // ts_cnt=1 → S_SPK_CLR (MEM_RST 건너뜀)
    `CHECK(fsm_spike_clear,   1'b1, "5-1  2nd 타임스텝: SPK_CLR=1")
    `CHECK(fsm_mem_rst_pulse, 1'b0, "5-2  2nd 타임스텝: MEM_RST=0")

    // L1+L2+L3 통과 (5248+4160+68=9476cy + overhead)
    // L1: 128*42=5376, L2: 32*130=4160, L3: 2*34=68
    clk_n(1 + 5376 + 4160 + 68); // SPK_CLR 후 1cy + 전체
    // L3 마지막 write-back 직후 → S_BUF_DONE → done=1
    `CHECK(fsm_done,  1'b1, "5-3  2 타임스텝 완료: done=1")
    `CHECK(fsm_busy,  1'b1, "5-4  BUF_DONE: busy=1")

    @(posedge clk); #1;
    `CHECK(fsm_done,  1'b0, "5-5  done은 1클럭만 유지")
    `CHECK(fsm_busy,  1'b0, "5-6  done 후 IDLE: busy=0")

    // ===========================================================
    // [6] snn_top — 구문·연결 검증
    // ===========================================================
    $display("\n[6] snn_top — reset 후 초기 상태");
    #2;
    `CHECK(top_busy,    1'b0, "6-1  reset 후 busy=0")
    `CHECK(top_anomaly, 1'b0, "6-2  reset 후 anomaly_flag=0")

    // 첫 frame_valid: mel_in 래치 + 처리 시작
    top_mel_in = 320'h01020304_05060708_090a0b0c_0d0e0f10_11121314_15161718_191a1b1c_1d1e1f20_21222324_25262728;
    top_fv = 1;
    @(posedge clk); #1;
    top_fv = 0;
    `CHECK(top_busy, 1'b1, "6-3  frame_valid 후 busy=1")

    // 결과 요약
    $display("");
    $display("============================================");
    $display("  Phase 3 검증  PASS=%0d  FAIL=%0d", pass_n, fail_n);
    $display("============================================");
    if (fail_n == 0)
        $display("  OK  전체 통과");
    else
        $display("  NG  %0d개 실패", fail_n);
    $display("");

    $finish;
end

endmodule
