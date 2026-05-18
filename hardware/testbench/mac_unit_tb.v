// ============================================================
// mac_unit_tb.v — INT8×INT8 직렬 MAC 단독 검증 테스트벤치
// ============================================================
// 대상 모듈: mac_unit.v (직렬 누적, 24-bit acc)
//
// [Vivado 실행 방법]
//   1. Sources > Add Sources > Add or create simulation sources
//      → mac_unit_tb.v, hardware/src/mac_unit.v 추가
//   2. Simulation Settings > 상단 모듈: mac_unit_tb 선택
//   3. Flow Navigator > Run Simulation > Run Behavioral Simulation
//   4. Tcl Console: "run all" 입력 → $display 출력 확인
//   ※ 외부 파일 의존성 없음 (즉시 실행 가능)
//
// [VSCode 터미널 실행 방법]
//   /usr/bin/iverilog -g2001 -o hardware/sim/mac_unit_tb \
//       hardware/testbench/mac_unit_tb.v hardware/src/mac_unit.v
//   /usr/bin/vvp hardware/sim/mac_unit_tb
// ============================================================

`timescale 1ns/1ps

`define CHECK(val, exp, name) \
    if ((val) === (exp)) begin \
        pass_n = pass_n + 1; \
        $display("  PASS  %s", name); \
    end else begin \
        fail_n = fail_n + 1; \
        $display("  FAIL  %s  got=%0d  exp=%0d", name, $signed(val), $signed(exp)); \
    end

module mac_unit_tb;

    // ── 클럭 / 리셋 ───────────────────────────────────────────
    reg clk   = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;   // 100 MHz

    // ── DUT 포트 ──────────────────────────────────────────────
    reg        clear;
    reg        en;
    reg        shift_en;
    reg signed [ 7:0] a;
    reg signed [ 7:0] b;
    wire signed [15:0] current;

    mac_unit dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .clear    (clear),
        .en       (en),
        .a        (a),
        .b        (b),
        .shift_en (shift_en),
        .current  (current)
    );

    integer pass_n = 0;
    integer fail_n = 0;

    // ── 테스트 시퀀스 ─────────────────────────────────────────
    initial begin
        clear = 0; en = 0; shift_en = 0; a = 0; b = 0;
        #12 rst_n = 1;

        $display("");
        $display("============================================");
        $display("  mac_unit_tb — INT8×INT8 직렬 MAC 검증");
        $display("============================================");

        // ─── TC1: L1 모드 — mel × weight, >>7 시프트 ────────
        // a=[100, 127], b=[50, 127]
        // acc = 100×50 + 127×127 = 5000 + 16129 = 21129
        // current = 21129 >>> 7 = 165
        $display("  [TC1] L1 모드 (shift_en=1, >>>7)");
        clear = 1; en = 0; shift_en = 1;
        @(posedge clk); #1; clear = 0;

        en = 1; a = 8'sd100; b = 8'sd50;
        @(posedge clk); #1;                    // acc = 5000

        a = 8'sd127; b = 8'sd127;
        @(posedge clk); #1;                    // acc = 21129
        en = 0;
        `CHECK(current, 16'sd165, "TC1-1  acc=21129 >>7 = 165")

        // ─── TC2: L1 모드 — 음수 가중치 포함 ────────────────
        // a=[64, 64, 64], b=[32, -32, 32]
        // acc = 64×32 + 64×(−32) + 64×32 = 2048 − 2048 + 2048 = 2048
        // current = 2048 >>> 7 = 16
        $display("  [TC2] L1 모드 — 음수 가중치");
        clear = 1; shift_en = 1;
        @(posedge clk); #1; clear = 0;

        en = 1; a = 8'sd64; b = 8'sd32;
        @(posedge clk); #1;                    // acc = 2048
        b = -8'sd32;
        @(posedge clk); #1;                    // acc = 0
        b = 8'sd32;
        @(posedge clk); #1;                    // acc = 2048
        en = 0;
        `CHECK(current, 16'sd16, "TC2-1  음수 가중치 포함 >>7 = 16")

        // ─── TC3: L2 모드 — spike × weight, 시프트 없음 ─────
        // spk=[1, 0, 1, 1], w=[10, 20, −5, 30] → sum = 35
        $display("  [TC3] L2 모드 (shift_en=0, 스파이크 입력)");
        clear = 1; shift_en = 0;
        @(posedge clk); #1; clear = 0;

        en = 1;
        a = 8'sd1;  b = 8'sd10;  @(posedge clk); #1;  // acc = 10
        a = 8'sd0;  b = 8'sd20;  @(posedge clk); #1;  // acc = 10  (스파이크=0)
        a = 8'sd1;  b = -8'sd5;  @(posedge clk); #1;  // acc = 5
        a = 8'sd1;  b = 8'sd30;  @(posedge clk); #1;  // acc = 35
        en = 0;
        `CHECK(current, 16'sd35, "TC3-1  L2 sum = 35")

        // ─── TC4: L3 모드 — 음의 합산 ────────────────────────
        // spk=[1, 0, 1], w=[−20, 30, −10] → sum = −30
        $display("  [TC4] L3 모드 — 음수 결과");
        clear = 1; shift_en = 0;
        @(posedge clk); #1; clear = 0;

        en = 1;
        a = 8'sd1;  b = -8'sd20; @(posedge clk); #1;  // acc = −20
        a = 8'sd0;  b = 8'sd30;  @(posedge clk); #1;  // acc = −20 (스파이크=0)
        a = 8'sd1;  b = -8'sd10; @(posedge clk); #1;  // acc = −30
        en = 0;
        `CHECK(current, -16'sd30, "TC4-1  L3 음수 합 = −30")

        // ─── TC5: clear 동작 — 누적 중 초기화 ───────────────
        $display("  [TC5] clear 동작");
        // 먼저 누적 후 clear
        clear = 0; en = 1; a = 8'sd50; b = 8'sd50; shift_en = 0;
        @(posedge clk); #1;                    // acc = 2500
        // clear 인가
        clear = 1; en = 0;
        @(posedge clk); #1; clear = 0;
        `CHECK(current, 16'sd0, "TC5-1  clear 후 = 0")

        // clear 후 정상 누적 재개
        en = 1; a = 8'sd10; b = 8'sd3;
        @(posedge clk); #1;                    // acc = 30
        en = 0;
        `CHECK(current, 16'sd30, "TC5-2  clear 후 재누적 = 30")

        // ─── TC6: shift_en 전환 — 같은 acc에 shift 동적 전환
        $display("  [TC6] shift_en 동적 전환");
        clear = 1; shift_en = 0;
        @(posedge clk); #1; clear = 0;

        en = 1; a = 8'sd127; b = 8'sd127;
        @(posedge clk); #1;                    // acc = 16129
        en = 0;
        // shift_en=0: current = 16129
        `CHECK(current, 16'sd16129, "TC6-1  shift_en=0 → 16129")
        // shift_en=1: current = 16129>>>7 = 126
        shift_en = 1; #1;
        `CHECK(current, 16'sd126, "TC6-2  shift_en=1 → 16129>>7=126")

        // ─── 결과 ──────────────────────────────────────────────
        $display("--------------------------------------------");
        $display("  PASS=%0d  FAIL=%0d", pass_n, fail_n);
        if (fail_n == 0) $display("  OK  전체 통과");
        else             $display("  NG  %0d개 실패", fail_n);
        $display("============================================");
        $display("");
        $finish;
    end

endmodule
