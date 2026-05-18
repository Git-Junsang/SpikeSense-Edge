// ============================================================
// tb_phase2.v — Phase 2 핵심 모듈 검증 테스트벤치
// ============================================================
// 대상: plift_core, mac_unit, weight_bram, param_rom,
//       membrane_mem, spike_mem (6개 모두)
//
// 실행:
//   mkdir -p hardware/sim
//   /usr/bin/iverilog -g2001 -o hardware/sim/phase2 \
//       hardware/testbench/tb_phase2.v hardware/src/*.v
//   /usr/bin/vvp hardware/sim/phase2
//   gtkwave hardware/testbench/phase2.vcd   (GUI 환경)
//
// 전제: hardware/src/weights/ 에 hex 파일 존재 (Phase 1 완료)
// ============================================================

`timescale 1ns/1ps

// ─── 체크 매크로 (pass/fail 카운터 + 출력) ──────────────────
`define CHECK(val, exp, name) \
    if ((val) === (exp)) begin \
        pass_n = pass_n + 1; \
        $display("  PASS  %s", name); \
    end else begin \
        fail_n = fail_n + 1; \
        $display("  FAIL  %s  got=0x%h  exp=0x%h", name, val, exp); \
    end

module tb_phase2;

// ─── 공통 클럭 / 리셋 ───────────────────────────────────────
reg clk   = 0;
reg rst_n = 0;
always #5 clk = ~clk;   // 100 MHz (10ns 주기)

integer pass_n = 0;
integer fail_n = 0;

// ─── 1. plift_core 포트 ─────────────────────────────────────
reg  signed [15:0] pf_current, pf_mem_in;
reg         [ 7:0] pf_beta, pf_vth;
wire               pf_spike;
wire signed [15:0] pf_mem_out;

plift_core dut_plif (
    .current (pf_current),
    .mem_in  (pf_mem_in),
    .beta    (pf_beta),
    .vth     (pf_vth),
    .spike   (pf_spike),
    .mem_out (pf_mem_out)
);

// ─── 2. mac_unit 포트 ───────────────────────────────────────
reg        mac_clear, mac_en, mac_shift_en;
reg signed [ 7:0] mac_a, mac_b;
wire signed [15:0] mac_current;

mac_unit dut_mac (
    .clk      (clk),
    .rst_n    (rst_n),
    .clear    (mac_clear),
    .en       (mac_en),
    .a        (mac_a),
    .b        (mac_b),
    .shift_en (mac_shift_en),
    .current  (mac_current)
);

// ─── 3. weight_bram 포트 ────────────────────────────────────
reg  [13:0]       wb_addr;
wire signed [7:0] wb_data;

weight_bram dut_wb (
    .clk  (clk),
    .addr (wb_addr),
    .data (wb_data)
);

// ─── 4. param_rom 포트 ──────────────────────────────────────
reg  [7:0] pr_idx;
wire [7:0] pr_beta, pr_vth;

param_rom dut_pr (
    .neuron_idx (pr_idx),
    .beta       (pr_beta),
    .vth        (pr_vth)
);

// ─── 5. membrane_mem 포트 ───────────────────────────────────
reg  [7:0]        mm_idx;
reg               mm_wr_en;
reg  signed [15:0] mm_in;
wire signed [15:0] mm_out;

membrane_mem dut_mm (
    .clk        (clk),
    .rst_n      (rst_n),
    .neuron_idx (mm_idx),
    .wr_en      (mm_wr_en),
    .mem_in     (mm_in),
    .mem_out    (mm_out)
);

// ─── 6. spike_mem 포트 ──────────────────────────────────────
reg        sm_wr_en, sm_wr_layer, sm_spike_in, sm_clear;
reg  [6:0] sm_wr_idx;
wire [127:0] sm_l1;
wire  [31:0] sm_l2;

spike_mem dut_sm (
    .clk      (clk),
    .rst_n    (rst_n),
    .clear    (sm_clear),
    .wr_en    (sm_wr_en),
    .wr_layer (sm_wr_layer),
    .wr_idx   (sm_wr_idx),
    .spike_in (sm_spike_in),
    .l1_spikes(sm_l1),
    .l2_spikes(sm_l2)
);

// ─── VCD 덤프 (gtkwave용) ────────────────────────────────────
initial begin
    $dumpfile("hardware/sim/phase2.vcd");
    $dumpvars(0, tb_phase2);
end

// ─── 메인 테스트 시퀀스 ─────────────────────────────────────
initial begin
    // 초기값
    pf_current=0; pf_mem_in=0; pf_beta=8'd1; pf_vth=8'd1;
    mac_clear=0; mac_en=0; mac_shift_en=0; mac_a=0; mac_b=0;
    wb_addr=0; pr_idx=0;
    mm_idx=0; mm_wr_en=0; mm_in=0;
    sm_wr_en=0; sm_wr_layer=0; sm_wr_idx=0; sm_spike_in=0; sm_clear=0;

    #12 rst_n = 1;  // 리셋 해제

    // ===========================================================
    // [1] plift_core — 조합논리, 클럭 불필요
    // ===========================================================
    $display("\n[1] plift_core (PLIF-T 뉴런)");

    // 1-1: 발화 + Soft Reset
    // beta=200, mem_in=100, current=50, vth=50
    // decayed = (200*100)>>8 = 20000>>8 = 78
    // mem_new = 78+50 = 128 >= 50 → spike=1, mem_out=78
    pf_beta=8'd200; pf_mem_in=16'sd100; pf_current=16'sd50; pf_vth=8'd50;
    #2;
    `CHECK(pf_spike,   1'b1,     "1-1  spike=1 (발화)")
    `CHECK(pf_mem_out, 16'sd78,  "1-1  mem_out=78 (soft reset)")

    // 1-2: 미발화 (vth 미달)
    // mem_new = 78+10 = 88 < 100 → spike=0, mem_out=88
    pf_vth=8'd100; pf_current=16'sd10;
    #2;
    `CHECK(pf_spike,   1'b0,     "1-2  spike=0 (미발화)")
    `CHECK(pf_mem_out, 16'sd88,  "1-2  mem_out=88")

    // 1-3: 음수 막전위 누설
    // beta=200, mem_in=-100, current=5, vth=20
    // decayed = (200*-100)>>8 = -20000>>8 = -79
    // mem_new = -79+5 = -74 < 20 → spike=0
    pf_mem_in=-16'sd100; pf_current=16'sd5; pf_vth=8'd20;
    #2;
    `CHECK(pf_spike,   1'b0,     "1-3  spike=0 (음수 누설)")
    `CHECK(pf_mem_out, -16'sd74, "1-3  mem_out=-74")

    // 1-4: beta=0 (누설 없음, 전류만 적분)
    // decayed=0, mem_new=0+30=30 >= 20 → spike=1, mem_out=10
    pf_beta=8'd0; pf_mem_in=16'sd500; pf_current=16'sd30; pf_vth=8'd20;
    #2;
    `CHECK(pf_spike,   1'b1,     "1-4  spike=1 (beta=0)")
    `CHECK(pf_mem_out, 16'sd10,  "1-4  mem_out=10")

    // ===========================================================
    // [2] mac_unit — 직렬 누적 MAC
    // ===========================================================
    $display("\n[2] mac_unit (INT8×INT8 직렬 MAC)");

    // 2-1: L1 모드 (shift_en=1, >>>7)
    // a=[100,127], b=[50,127]
    // acc = 100*50 + 127*127 = 5000 + 16129 = 21129
    // current = 21129 >>> 7 = 165
    mac_clear=1; mac_en=0; mac_shift_en=1;
    @(posedge clk); #1; mac_clear=0;
    mac_en=1; mac_a=8'sd100; mac_b=8'sd50;
    @(posedge clk); #1;                    // acc=5000
    mac_a=8'sd127; mac_b=8'sd127;
    @(posedge clk); #1;                    // acc=21129
    `CHECK(mac_current, 16'sd165, "2-1  L1 shift >>7 = 165")
    mac_en=0;

    // 2-2: L2 모드 (shift_en=0, spike×weight)
    // spk=[1,0,1,1], w=[10,20,-5,30] → sum=10+0-5+30=35
    mac_clear=1; mac_shift_en=0;
    @(posedge clk); #1; mac_clear=0;
    mac_en=1;
    mac_a=8'sd1;  mac_b=8'sd10;  @(posedge clk); #1;  // acc=10
    mac_a=8'sd0;  mac_b=8'sd20;  @(posedge clk); #1;  // acc=10
    mac_a=8'sd1;  mac_b=-8'sd5;  @(posedge clk); #1;  // acc=5
    mac_a=8'sd1;  mac_b=8'sd30;  @(posedge clk); #1;  // acc=35
    `CHECK(mac_current, 16'sd35, "2-2  L2 spike MAC = 35")
    mac_en=0;

    // 2-3: clear 동작 확인
    mac_clear=1; @(posedge clk); #1; mac_clear=0;
    `CHECK(mac_current, 16'sd0, "2-3  clear 후 = 0")

    // ===========================================================
    // [3] weight_bram — $readmemh 초기화 확인
    // ===========================================================
    $display("\n[3] weight_bram ($readmemh 초기화)");

    // w1.hex 첫 번째 값: 0xb2 = -78 (INT8)
    wb_addr = 14'd0;
    @(posedge clk); #1;
    `CHECK(wb_data, 8'shb2, "3-1  addr=0 → 0xB2")

    // w1.hex 두 번째 값: 0xfd = -3 (INT8)
    wb_addr = 14'd1;
    @(posedge clk); #1;
    `CHECK(wb_data, 8'shfd, "3-2  addr=1 → 0xFD")

    // W2 시작 주소(5120): w2.hex 첫 번째 값 (Unknown 아님을 확인)
    wb_addr = 14'd5120;
    @(posedge clk); #1;
    if (wb_data !== 8'bx) begin
        pass_n = pass_n + 1;
        $display("  PASS  3-3  addr=5120(W2 시작) 유효");
    end else begin
        fail_n = fail_n + 1;
        $display("  FAIL  3-3  addr=5120(W2 시작) Unknown값");
    end

    // ===========================================================
    // [4] param_rom — $readmemh 초기화 확인
    // ===========================================================
    $display("\n[4] param_rom (β+Vth ROM)");

    // neuron=0: beta.hex[0]=0xBB=187, vth.hex[0]=0x3D=61
    pr_idx = 8'd0; #2;
    `CHECK(pr_beta, 8'hbb, "4-1  neuron=0 beta=0xBB(187)")
    `CHECK(pr_vth,  8'h3d, "4-2  neuron=0 vth=0x3D(61)")

    // neuron=1: beta.hex[1]=0x53=83, vth.hex[1]=0x5B=91
    pr_idx = 8'd1; #2;
    `CHECK(pr_beta, 8'h53, "4-3  neuron=1 beta=0x53(83)")
    `CHECK(pr_vth,  8'h5b, "4-4  neuron=1 vth=0x5B(91)")

    // neuron=128 (L2 시작): Unknown 아님 확인
    pr_idx = 8'd128; #2;
    if (pr_beta !== 8'bx) begin
        pass_n = pass_n + 1;
        $display("  PASS  4-5  neuron=128(L2) beta 유효");
    end else begin
        fail_n = fail_n + 1;
        $display("  FAIL  4-5  neuron=128(L2) beta Unknown");
    end

    // ===========================================================
    // [5] membrane_mem — 쓰기/읽기/리셋
    // ===========================================================
    $display("\n[5] membrane_mem (162뉴런 막전위)");

    // 5-1: rst 직후 → 0
    mm_idx=8'd5; #1;
    `CHECK(mm_out, 16'sd0, "5-1  rst 후 mem[5]=0")

    // 5-2: 뉴런 5 쓰기/읽기
    mm_idx=8'd5; mm_in=16'sd300; mm_wr_en=1;
    @(posedge clk); #1; mm_wr_en=0;
    `CHECK(mm_out, 16'sd300, "5-2  mem[5]=300 쓰기/읽기")

    // 5-3: 음수 막전위 (뉴런 10)
    mm_idx=8'd10; mm_in=-16'sd50; mm_wr_en=1;
    @(posedge clk); #1; mm_wr_en=0;
    `CHECK(mm_out, -16'sd50, "5-3  mem[10]=-50 쓰기/읽기")

    // 5-4: 다른 주소 → 이전 값 유지
    mm_idx=8'd5; #1;
    `CHECK(mm_out, 16'sd300, "5-4  mem[5] 유지 (다른 주소 쓴 후)")

    // 5-5: 비동기 리셋 → 0
    rst_n=0; #3;
    `CHECK(mm_out, 16'sd0, "5-5  비동기 rst → mem[5]=0")
    @(posedge clk); rst_n=1; #1;

    // ===========================================================
    // [6] spike_mem — 레이어별 스파이크 저장
    // ===========================================================
    $display("\n[6] spike_mem (L1 128-bit / L2 32-bit)");

    // 6-1: L1 스파이크 쓰기
    sm_wr_en=1; sm_wr_layer=1'b0;
    sm_wr_idx=7'd0;  sm_spike_in=1'b1; @(posedge clk); #1;
    sm_wr_idx=7'd5;  sm_spike_in=1'b1; @(posedge clk); #1;
    sm_wr_idx=7'd1;  sm_spike_in=1'b0; @(posedge clk); #1;
    sm_wr_en=0;
    `CHECK(sm_l1[0], 1'b1, "6-1  L1[0]=1")
    `CHECK(sm_l1[1], 1'b0, "6-2  L1[1]=0")
    `CHECK(sm_l1[5], 1'b1, "6-3  L1[5]=1")

    // 6-2: L2 스파이크 쓰기
    sm_wr_en=1; sm_wr_layer=1'b1;
    sm_wr_idx=7'd3; sm_spike_in=1'b1; @(posedge clk); #1;
    sm_wr_en=0;
    `CHECK(sm_l2[3], 1'b1, "6-4  L2[3]=1")
    `CHECK(sm_l2[4], 1'b0, "6-5  L2[4]=0")

    // 6-3: L1 쓰는 동안 L2 유지
    `CHECK(sm_l1[0], 1'b1, "6-6  L1[0] L2 쓰기 후에도 유지")

    // 6-4: clear 동기 초기화
    sm_clear=1; @(posedge clk); #1; sm_clear=0;
    `CHECK(sm_l1[0], 1'b0, "6-7  clear 후 L1[0]=0")
    `CHECK(sm_l2[3], 1'b0, "6-8  clear 후 L2[3]=0")

    // ===========================================================
    // 결과 요약
    // ===========================================================
    $display("");
    $display("============================================");
    $display("  Phase 2 검증  PASS=%0d  FAIL=%0d", pass_n, fail_n);
    $display("============================================");
    if (fail_n == 0)
        $display("  OK  전체 통과");
    else
        $display("  NG  %0d개 실패 — 상세 내용 위를 참조", fail_n);
    $display("");

    $finish;
end

endmodule
