// ============================================================
// phase2_tb.v — Phase 2 전체 모듈 통합 검증 (Vivado 호환)
// ============================================================
// 대상: plift_core · mac_unit · weight_bram · param_rom ·
//       membrane_mem · spike_mem (6개 모듈)
//
// [Vivado 실행 방법]
//   1. Sources > Add Sources > Add or create simulation sources
//      → phase2_tb.v, hardware/src/*.v 추가 (6개 파일 모두)
//   2. Simulation Settings > 상단 모듈: phase2_tb 선택
//   3. ★ $readmemh 경로 설정 (weight_bram · param_rom에서 사용):
//      Project Settings > Simulation > Simulation > "Simulation working directory"
//      → 프로젝트 루트 경로로 변경 (예: /data/.../SpikeSense-Edge)
//      또는 Tcl Console: cd {/data/.../SpikeSense-Edge}
//   4. Flow Navigator > Run Simulation > Run Behavioral Simulation
//   5. Tcl Console: "run all" 입력 → $display 출력 확인
//      파형 뷰어: 왼쪽 Objects 패널에서 신호 드래그 → waveform 창
//
// [VSCode 터미널 실행 방법]
//   mkdir -p hardware/sim
//   /usr/bin/iverilog -g2001 -o hardware/sim/phase2_tb \
//       hardware/testbench/phase2_tb.v hardware/src/*.v
//   /usr/bin/vvp hardware/sim/phase2_tb
// ============================================================

`timescale 1ns/1ps

`define CHECK(val, exp, name) \
    if ((val) === (exp)) begin \
        pass_n = pass_n + 1; \
        $display("  PASS  %s", name); \
    end else begin \
        fail_n = fail_n + 1; \
        $display("  FAIL  %s  got=0x%h  exp=0x%h", name, val, exp); \
    end

module phase2_tb;

// ─── 공통 클럭 / 리셋 ───────────────────────────────────────
reg clk   = 0;
reg rst_n = 0;
always #5 clk = ~clk;   // 100 MHz

integer pass_n = 0;
integer fail_n = 0;

// ─── 1. plift_core ──────────────────────────────────────────
reg  signed [15:0] pf_current, pf_mem_in;
reg         [ 7:0] pf_beta, pf_vth;
wire               pf_spike;
wire signed [15:0] pf_mem_out;

plift_core dut_plif (
    .current (pf_current), .mem_in (pf_mem_in),
    .beta    (pf_beta),    .vth    (pf_vth),
    .spike   (pf_spike),   .mem_out(pf_mem_out)
);

// ─── 2. mac_unit ────────────────────────────────────────────
reg        mac_clear, mac_en, mac_shift_en;
reg signed [ 7:0] mac_a, mac_b;
wire signed [15:0] mac_current;

mac_unit dut_mac (
    .clk(clk), .rst_n(rst_n),
    .clear(mac_clear), .en(mac_en),
    .a(mac_a), .b(mac_b),
    .shift_en(mac_shift_en), .current(mac_current)
);

// ─── 3. weight_bram ─────────────────────────────────────────
// ★ $readmemh("hardware/src/weights/w*.hex") 사용
// ★ Vivado: Simulation working directory = 프로젝트 루트로 설정 필요
reg  [13:0]        wb_addr;
wire signed [ 7:0] wb_data;

weight_bram dut_wb (.clk(clk), .addr(wb_addr), .data(wb_data));

// ─── 4. param_rom ───────────────────────────────────────────
// ★ $readmemh("hardware/src/weights/beta.hex" 등) 사용
reg  [7:0] pr_idx;
wire [7:0] pr_beta, pr_vth;

param_rom dut_pr (.neuron_idx(pr_idx), .beta(pr_beta), .vth(pr_vth));

// ─── 5. membrane_mem ────────────────────────────────────────
reg  [7:0]         mm_idx;
reg                mm_wr_en;
reg  signed [15:0] mm_in;
wire signed [15:0] mm_out;

membrane_mem dut_mm (
    .clk(clk), .rst_n(rst_n),
    .neuron_idx(mm_idx), .wr_en(mm_wr_en),
    .mem_in(mm_in), .mem_out(mm_out)
);

// ─── 6. spike_mem ───────────────────────────────────────────
reg        sm_wr_en, sm_wr_layer, sm_spike_in, sm_clear;
reg  [6:0] sm_wr_idx;
wire [127:0] sm_l1;
wire  [31:0] sm_l2;

spike_mem dut_sm (
    .clk(clk), .rst_n(rst_n), .clear(sm_clear),
    .wr_en(sm_wr_en), .wr_layer(sm_wr_layer),
    .wr_idx(sm_wr_idx), .spike_in(sm_spike_in),
    .l1_spikes(sm_l1), .l2_spikes(sm_l2)
);

// ─── 메인 테스트 시퀀스 ─────────────────────────────────────
initial begin
    // 초기값
    pf_current=0; pf_mem_in=0; pf_beta=8'd1; pf_vth=8'd1;
    mac_clear=0; mac_en=0; mac_shift_en=0; mac_a=0; mac_b=0;
    wb_addr=0; pr_idx=0;
    mm_idx=0; mm_wr_en=0; mm_in=0;
    sm_wr_en=0; sm_wr_layer=0; sm_wr_idx=0; sm_spike_in=0; sm_clear=0;

    #12 rst_n = 1;

    $display("");
    $display("============================================");
    $display("  phase2_tb — Phase 2 전체 모듈 검증");
    $display("============================================");

    // =========================================================
    // [1] plift_core (조합논리)
    // =========================================================
    $display("\n  [1] plift_core");

    // 발화 + Soft Reset: decayed=78, mem_new=128 >= 50
    pf_beta=8'd200; pf_mem_in=16'sd100; pf_current=16'sd50; pf_vth=8'd50;
    #10;
    `CHECK(pf_spike,   1'b1,     "1-1  spike=1 (발화)")
    `CHECK(pf_mem_out, 16'sd78,  "1-1  mem_out=78")

    // 미발화: mem_new=88 < 100
    pf_vth=8'd100; pf_current=16'sd10; #10;
    `CHECK(pf_spike,   1'b0,     "1-2  spike=0 (미발화)")
    `CHECK(pf_mem_out, 16'sd88,  "1-2  mem_out=88")

    // 음수 누설: decayed=-79, mem_new=-74 < 20
    pf_mem_in=-16'sd100; pf_current=16'sd5; pf_vth=8'd20; #10;
    `CHECK(pf_spike,   1'b0,     "1-3  spike=0 (음수)")
    `CHECK(pf_mem_out, -16'sd74, "1-3  mem_out=−74")

    // beta=0: decayed=0, mem_new=30 >= 20 → spike=1
    pf_beta=8'd0; pf_mem_in=16'sd500; pf_current=16'sd30; pf_vth=8'd20; #10;
    `CHECK(pf_spike,   1'b1,     "1-4  spike=1 (beta=0)")
    `CHECK(pf_mem_out, 16'sd10,  "1-4  mem_out=10")

    // =========================================================
    // [2] mac_unit
    // =========================================================
    $display("\n  [2] mac_unit");

    // L1: acc=21129, >>7 → 165
    mac_clear=1; mac_en=0; mac_shift_en=1;
    @(posedge clk); #1; mac_clear=0;
    mac_en=1; mac_a=8'sd100; mac_b=8'sd50;
    @(posedge clk); #1;
    mac_a=8'sd127; mac_b=8'sd127;
    @(posedge clk); #1; mac_en=0;
    `CHECK(mac_current, 16'sd165, "2-1  L1 >>7 = 165")

    // L2: spk=[1,0,1,1] w=[10,20,-5,30] → 35
    mac_clear=1; mac_shift_en=0;
    @(posedge clk); #1; mac_clear=0;
    mac_en=1;
    mac_a=8'sd1;  mac_b=8'sd10;  @(posedge clk); #1;
    mac_a=8'sd0;  mac_b=8'sd20;  @(posedge clk); #1;
    mac_a=8'sd1;  mac_b=-8'sd5;  @(posedge clk); #1;
    mac_a=8'sd1;  mac_b=8'sd30;  @(posedge clk); #1; mac_en=0;
    `CHECK(mac_current, 16'sd35, "2-2  L2 sum = 35")

    mac_clear=1; @(posedge clk); #1; mac_clear=0;
    `CHECK(mac_current, 16'sd0,  "2-3  clear → 0")

    // =========================================================
    // [3] weight_bram ($readmemh 초기화 확인)
    // =========================================================
    $display("\n  [3] weight_bram");
    $display("  ★ 실패 시: Vivado simulation working dir을 프로젝트 루트로 설정");

    wb_addr = 14'd0; @(posedge clk); #1;
    `CHECK(wb_data, 8'shb2, "3-1  addr=0 → 0xB2(−78)")

    wb_addr = 14'd1; @(posedge clk); #1;
    `CHECK(wb_data, 8'shfd, "3-2  addr=1 → 0xFD(−3)")

    wb_addr = 14'd5120; @(posedge clk); #1;
    if (wb_data !== 8'bx) begin
        pass_n = pass_n + 1;
        $display("  PASS  3-3  addr=5120(W2 시작) 유효값");
    end else begin
        fail_n = fail_n + 1;
        $display("  FAIL  3-3  addr=5120 Unknown — $readmemh 경로 확인");
    end

    // =========================================================
    // [4] param_rom ($readmemh 초기화 확인)
    // =========================================================
    $display("\n  [4] param_rom");

    pr_idx = 8'd0; #2;
    `CHECK(pr_beta, 8'hbb, "4-1  neuron=0 beta=0xBB(187)")
    `CHECK(pr_vth,  8'h3d, "4-2  neuron=0 vth=0x3D(61)")

    pr_idx = 8'd1; #2;
    `CHECK(pr_beta, 8'h53, "4-3  neuron=1 beta=0x53(83)")
    `CHECK(pr_vth,  8'h5b, "4-4  neuron=1 vth=0x5B(91)")

    pr_idx = 8'd128; #2;
    if (pr_beta !== 8'bx) begin
        pass_n = pass_n + 1;
        $display("  PASS  4-5  neuron=128(L2) 유효값");
    end else begin
        fail_n = fail_n + 1;
        $display("  FAIL  4-5  neuron=128 Unknown — $readmemh 경로 확인");
    end

    // =========================================================
    // [5] membrane_mem
    // =========================================================
    $display("\n  [5] membrane_mem");

    mm_idx=8'd5; #1;
    `CHECK(mm_out, 16'sd0,   "5-1  rst 후 mem[5]=0")

    mm_idx=8'd5; mm_in=16'sd300; mm_wr_en=1;
    @(posedge clk); #1; mm_wr_en=0;
    `CHECK(mm_out, 16'sd300, "5-2  mem[5]=300 write/read")

    mm_idx=8'd10; mm_in=-16'sd50; mm_wr_en=1;
    @(posedge clk); #1; mm_wr_en=0;
    `CHECK(mm_out, -16'sd50, "5-3  mem[10]=−50 write/read")

    mm_idx=8'd5; #1;
    `CHECK(mm_out, 16'sd300, "5-4  mem[5] 유지")

    rst_n=0; #3;
    `CHECK(mm_out, 16'sd0,   "5-5  비동기 rst → 0")
    @(posedge clk); rst_n=1; #1;

    // =========================================================
    // [6] spike_mem
    // =========================================================
    $display("\n  [6] spike_mem");

    sm_wr_en=1; sm_wr_layer=1'b0;
    sm_wr_idx=7'd0;  sm_spike_in=1'b1; @(posedge clk); #1;
    sm_wr_idx=7'd5;  sm_spike_in=1'b1; @(posedge clk); #1;
    sm_wr_idx=7'd1;  sm_spike_in=1'b0; @(posedge clk); #1;
    sm_wr_en=0;
    `CHECK(sm_l1[0], 1'b1, "6-1  L1[0]=1")
    `CHECK(sm_l1[1], 1'b0, "6-2  L1[1]=0")
    `CHECK(sm_l1[5], 1'b1, "6-3  L1[5]=1")

    sm_wr_en=1; sm_wr_layer=1'b1;
    sm_wr_idx=7'd3; sm_spike_in=1'b1; @(posedge clk); #1;
    sm_wr_en=0;
    `CHECK(sm_l2[3], 1'b1, "6-4  L2[3]=1")
    `CHECK(sm_l2[4], 1'b0, "6-5  L2[4]=0")

    sm_clear=1; @(posedge clk); #1; sm_clear=0;
    `CHECK(sm_l1[0], 1'b0, "6-6  clear→ L1[0]=0")
    `CHECK(sm_l2[3], 1'b0, "6-7  clear→ L2[3]=0")

    // ─── 결과 요약 ─────────────────────────────────────────────
    $display("");
    $display("============================================");
    $display("  Phase 2 검증  PASS=%0d  FAIL=%0d", pass_n, fail_n);
    if (fail_n == 0) $display("  OK  전체 통과");
    else             $display("  NG  %0d개 실패", fail_n);
    $display("============================================");
    $display("");
    $finish;
end

endmodule
