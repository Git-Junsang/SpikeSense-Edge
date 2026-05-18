// ============================================================
// plift_core_tb.v — PLIF-T 뉴런 단독 검증 테스트벤치
// ============================================================
// 대상 모듈: plift_core.v (조합논리, 클럭 없음)
//
// [Vivado 실행 방법]
//   1. Sources > Add Sources > Add or create simulation sources
//      → plift_core_tb.v, hardware/src/plift_core.v 추가
//   2. Simulation Settings > 상단 모듈: plift_core_tb 선택
//   3. Flow Navigator > Run Simulation > Run Behavioral Simulation
//   4. Tcl Console에서 "run all" 입력 → $display 출력 확인
//   ※ 외부 파일 의존성 없음 (즉시 실행 가능)
//
// [VSCode 터미널 실행 방법]
//   /usr/bin/iverilog -g2001 -o hardware/sim/plift_core_tb \
//       hardware/testbench/plift_core_tb.v hardware/src/plift_core.v
//   /usr/bin/vvp hardware/sim/plift_core_tb
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

module plift_core_tb;

    // ── DUT 포트 ──────────────────────────────────────────────
    reg  signed [15:0] current;
    reg  signed [15:0] mem_in;
    reg         [ 7:0] beta;
    reg         [ 7:0] vth;
    wire               spike;
    wire signed [15:0] mem_out;

    plift_core dut (
        .current (current),
        .mem_in  (mem_in),
        .beta    (beta),
        .vth     (vth),
        .spike   (spike),
        .mem_out (mem_out)
    );

    integer pass_n = 0;
    integer fail_n = 0;

    // ── 테스트 시퀀스 ─────────────────────────────────────────
    initial begin
        $display("");
        $display("============================================");
        $display("  plift_core_tb — PLIF-T 뉴런 검증");
        $display("============================================");

        // ─── TC1: 발화 + Soft Reset ──────────────────────────
        // beta=200(≈0.78), mem_in=100, current=50, vth=50
        // decayed = (200 × 100) >> 8 = 20000 >> 8 = 78
        // mem_new = 78 + 50 = 128  ≥  50  → spike=1
        // mem_out = 128 − 50 = 78 (Soft Reset)
        beta = 8'd200; mem_in = 16'sd100; current = 16'sd50; vth = 8'd50;
        #10;
        `CHECK(spike,   1'b1,    "TC1  spike=1 (발화)")
        `CHECK(mem_out, 16'sd78, "TC1  mem_out=78 (soft reset)")

        // ─── TC2: 미발화 (임계값 미달) ───────────────────────
        // decayed=78, mem_new=78+10=88  <  100  → spike=0
        vth = 8'd100; current = 16'sd10;
        #10;
        `CHECK(spike,   1'b0,    "TC2  spike=0 (미발화)")
        `CHECK(mem_out, 16'sd88, "TC2  mem_out=88")

        // ─── TC3: 음수 막전위 누설 ───────────────────────────
        // beta=200, mem_in=-100, current=5, vth=20
        // product = 200 × (−100) = −20000  →  [23:8] = −79
        // mem_new = −79 + 5 = −74  <  20  → spike=0
        mem_in = -16'sd100; current = 16'sd5; vth = 8'd20;
        #10;
        `CHECK(spike,   1'b0,     "TC3  spike=0 (음수 누설)")
        `CHECK(mem_out, -16'sd74, "TC3  mem_out=−74")

        // ─── TC4: beta=0 (누설 없음, 순수 적분) ─────────────
        // decayed=0, mem_new=0+30=30  ≥  20  → spike=1
        // mem_out = 30 − 20 = 10
        beta = 8'd0; mem_in = 16'sd500; current = 16'sd30; vth = 8'd20;
        #10;
        `CHECK(spike,   1'b1,    "TC4  spike=1 (beta=0)")
        `CHECK(mem_out, 16'sd10, "TC4  mem_out=10")

        // ─── TC5: beta=255 (최대 누설) ───────────────────────
        // beta=255(≈0.996), mem_in=200, current=0, vth=30
        // product = 255 × 200 = 51000  →  [23:8] = 199
        // mem_new = 199 + 0 = 199  ≥  30  → spike=1
        // mem_out = 199 − 30 = 169
        beta = 8'd255; mem_in = 16'sd200; current = 16'sd0; vth = 8'd30;
        #10;
        `CHECK(spike,   1'b1,     "TC5  spike=1 (beta=255 최대누설)")
        `CHECK(mem_out, 16'sd169, "TC5  mem_out=169")

        // ─── TC6: 정확한 임계값 경계 (mem_new == vth) ────────
        // beta=0, current=50, vth=50 → mem_new=50 ≥ 50 → spike=1
        beta = 8'd0; mem_in = 16'sd0; current = 16'sd50; vth = 8'd50;
        #10;
        `CHECK(spike,   1'b1,   "TC6  spike=1 (경계: mem_new==vth)")
        `CHECK(mem_out, 16'sd0, "TC6  mem_out=0 (50−50)")

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
