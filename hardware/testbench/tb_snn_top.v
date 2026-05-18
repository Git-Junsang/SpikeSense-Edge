// ============================================================
// tb_snn_top.v — SNN 전체 시스템 골든 벡터 검증 (Phase 4)
// ============================================================
// 검증 항목:
//   [1] 리셋 초기 상태
//   [2] Normal 31 프레임 — L3 막전위·스파이크·anomaly_flag
//   [3] Anomaly 31 프레임 — 동일
//
// 실행:
//   mkdir -p hardware/sim
//   /usr/bin/iverilog -g2001 -o hardware/sim/snn_top \
//       hardware/testbench/tb_snn_top.v hardware/src/*.v
//   /usr/bin/vvp hardware/sim/snn_top
// ============================================================

`timescale 1ns/1ps

module tb_snn_top;

// ─── 클럭 / 리셋 ─────────────────────────────────────────────
reg clk   = 0;
reg rst_n = 0;
always #5 clk = ~clk;  // 100 MHz

integer pass_n = 0;
integer fail_n = 0;
integer ts_i;

// ─── DUT ─────────────────────────────────────────────────────
reg  [319:0] mel_in = 320'b0;
reg          frame_valid = 0;
wire         anomaly_flag;
wire         busy;

snn_top dut (
    .clk         (clk),
    .rst_n       (rst_n),
    .mel_in      (mel_in),
    .frame_valid (frame_valid),
    .anomaly_flag(anomaly_flag),
    .busy        (busy)
);

// ─── 골든 데이터 메모리 ──────────────────────────────────────
reg [7:0]  gv_n_mel [0:1239];    // normal mel:   31 frames × 40 ch
reg [7:0]  gv_a_mel [0:1239];    // anomaly mel
reg [15:0] gv_n_mem [0:61];      // normal L3 막전위 (uint16, [ts*2+n])
reg [15:0] gv_a_mem [0:61];      // anomaly L3 막전위
reg [0:0]  gv_n_spk [0:61];      // normal L3 스파이크 ([ts*2+0]=n0, [ts*2+1]=n1)
reg [0:0]  gv_a_spk [0:61];      // anomaly L3 스파이크

// ─── 기대 leaky counter (단순 누적, 31ts 내에서 decay≈0) ─────
integer exp_cnt_n;
integer exp_cnt_a;
integer timeout_cnt;
integer ch_i;
reg [7:0] mel_byte;

// ─── VCD ─────────────────────────────────────────────────────
initial begin
    $dumpfile("hardware/sim/snn_top.vcd");
    $dumpvars(0, tb_snn_top);
end

// ─── mel 패킹 태스크 ──────────────────────────────────────────
// mel_in[c*8 +: 8] = ch c 값 (little-endian, ch0 → [7:0])
task pack_mel;
    input integer ts_idx;
    input         is_anomaly;
    integer c;
    begin
        for (c = 0; c < 40; c = c + 1) begin
            mel_byte = is_anomaly ? gv_a_mel[ts_idx*40+c]
                                  : gv_n_mel[ts_idx*40+c];
            mel_in[c*8 +: 8] = mel_byte;
        end
    end
endtask

// ─── 프레임 전송 + 처리 완료 + ts_done_r 대기 태스크 ─────────
task send_and_wait;
    begin
        frame_valid = 1;
        @(posedge clk); #1;
        frame_valid = 0;

        // FSM이 busy=0이 될 때까지 대기 (타임아웃 12000 클럭)
        timeout_cnt = 0;
        while (busy) begin
            @(posedge clk);
            timeout_cnt = timeout_cnt + 1;
            if (timeout_cnt > 12000) begin
                $display("  TIMEOUT: busy가 해제되지 않음");
                $finish;
            end
        end

        // ts_done_r 발생 → anomaly_judge 갱신 후 샘플링
        @(posedge clk); #1;
    end
endtask

// ─── 타임스텝 결과 검증 태스크 ────────────────────────────────
// 호출 전 send_and_wait 완료 필요 (샘플링 타이밍 보장)
task check_ts;
    input integer ts_val;
    input         is_anomaly;
    reg [15:0] exp_m0, exp_m1;
    reg exp_s0, exp_s1, exp_flag;
    begin
        exp_m0 = is_anomaly ? gv_a_mem[ts_val*2]   : gv_n_mem[ts_val*2];
        exp_m1 = is_anomaly ? gv_a_mem[ts_val*2+1] : gv_n_mem[ts_val*2+1];
        exp_s0 = is_anomaly ? gv_a_spk[ts_val*2]   : gv_n_spk[ts_val*2];
        exp_s1 = is_anomaly ? gv_a_spk[ts_val*2+1] : gv_n_spk[ts_val*2+1];

        // leaky counter 갱신 (31ts 범위에서 decay=0이므로 단순 누적)
        exp_cnt_n = exp_cnt_n + exp_s0;
        exp_cnt_a = exp_cnt_a + exp_s1;
        exp_flag  = (exp_cnt_a > exp_cnt_n) ? 1'b1 : 1'b0;

        // L3 막전위 n0
        if (dut.u_mem.mem_reg[160] === exp_m0) begin
            pass_n = pass_n + 1;
            $display("  PASS  ts%0d %s  n0_mem=0x%h",
                     ts_val, is_anomaly ? "anom" : "norm", exp_m0);
        end else begin
            fail_n = fail_n + 1;
            $display("  FAIL  ts%0d %s  n0_mem  got=0x%h  exp=0x%h",
                     ts_val, is_anomaly ? "anom" : "norm",
                     dut.u_mem.mem_reg[160], exp_m0);
        end

        // L3 막전위 n1
        if (dut.u_mem.mem_reg[161] === exp_m1) begin
            pass_n = pass_n + 1;
            $display("  PASS  ts%0d %s  n1_mem=0x%h",
                     ts_val, is_anomaly ? "anom" : "norm", exp_m1);
        end else begin
            fail_n = fail_n + 1;
            $display("  FAIL  ts%0d %s  n1_mem  got=0x%h  exp=0x%h",
                     ts_val, is_anomaly ? "anom" : "norm",
                     dut.u_mem.mem_reg[161], exp_m1);
        end

        // L3 스파이크 n0 (normal class)
        if (dut.spk_normal_r === exp_s0) begin
            pass_n = pass_n + 1;
            $display("  PASS  ts%0d %s  spk_n0=%0d",
                     ts_val, is_anomaly ? "anom" : "norm", exp_s0);
        end else begin
            fail_n = fail_n + 1;
            $display("  FAIL  ts%0d %s  spk_n0  got=%0d  exp=%0d",
                     ts_val, is_anomaly ? "anom" : "norm",
                     dut.spk_normal_r, exp_s0);
        end

        // L3 스파이크 n1 (anomaly class)
        if (dut.spk_anomaly_r === exp_s1) begin
            pass_n = pass_n + 1;
            $display("  PASS  ts%0d %s  spk_n1=%0d",
                     ts_val, is_anomaly ? "anom" : "norm", exp_s1);
        end else begin
            fail_n = fail_n + 1;
            $display("  FAIL  ts%0d %s  spk_n1  got=%0d  exp=%0d",
                     ts_val, is_anomaly ? "anom" : "norm",
                     dut.spk_anomaly_r, exp_s1);
        end

        // anomaly_flag
        if (anomaly_flag === exp_flag) begin
            pass_n = pass_n + 1;
            $display("  PASS  ts%0d %s  flag=%0d  cnt(n=%0d,a=%0d)",
                     ts_val, is_anomaly ? "anom" : "norm",
                     exp_flag, exp_cnt_n, exp_cnt_a);
        end else begin
            fail_n = fail_n + 1;
            $display("  FAIL  ts%0d %s  flag  got=%0d  exp=%0d  cnt(n=%0d,a=%0d)",
                     ts_val, is_anomaly ? "anom" : "norm",
                     anomaly_flag, exp_flag, exp_cnt_n, exp_cnt_a);
        end
    end
endtask

// ─── 메인 테스트 ─────────────────────────────────────────────
initial begin
    // 골든 데이터 로드
    $readmemh("hardware/src/weights/golden/normal_mel.hex",      gv_n_mel);
    $readmemh("hardware/src/weights/golden/anomaly_mel.hex",     gv_a_mel);
    $readmemh("hardware/src/weights/golden/normal_mem_out.hex",  gv_n_mem);
    $readmemh("hardware/src/weights/golden/anomaly_mem_out.hex", gv_a_mem);
    $readmemh("hardware/src/weights/golden/normal_spk.hex",      gv_n_spk);
    $readmemh("hardware/src/weights/golden/anomaly_spk.hex",     gv_a_spk);

    $display("");
    $display("============================================");
    $display("  tb_snn_top — SNN 전체 시스템 검증 (Phase 4)");
    $display("============================================");

    // ── 리셋 ─────────────────────────────────────────────────
    rst_n = 0;
    @(posedge clk); @(posedge clk); #1;
    rst_n = 1; #2;

    // ===========================================================
    // [1] 리셋 후 초기 상태
    // ===========================================================
    $display("\n[1] 리셋 후 초기 상태");
    if (busy === 1'b0) begin
        pass_n = pass_n + 1;
        $display("  PASS  busy=0");
    end else begin
        fail_n = fail_n + 1;
        $display("  FAIL  busy=0  got=%0d", busy);
    end
    if (anomaly_flag === 1'b0) begin
        pass_n = pass_n + 1;
        $display("  PASS  anomaly_flag=0");
    end else begin
        fail_n = fail_n + 1;
        $display("  FAIL  anomaly_flag=0  got=%0d", anomaly_flag);
    end

    // ===========================================================
    // [2] Normal 입력 31 타임스텝
    // ===========================================================
    $display("\n[2] Normal 입력 — 31 타임스텝 (L3 막전위·스파이크·플래그)");
    exp_cnt_n = 0;
    exp_cnt_a = 0;

    for (ts_i = 0; ts_i < 31; ts_i = ts_i + 1) begin
        pack_mel(ts_i, 1'b0);
        send_and_wait;
        check_ts(ts_i, 1'b0);
    end

    // ===========================================================
    // [3] Anomaly 입력 31 타임스텝 (리셋 후)
    // ===========================================================
    $display("\n[3] Anomaly 입력 — 31 타임스텝 (리셋 후)");
    rst_n = 0;
    @(posedge clk); @(posedge clk); #1;
    rst_n = 1; #2;

    exp_cnt_n = 0;
    exp_cnt_a = 0;

    for (ts_i = 0; ts_i < 31; ts_i = ts_i + 1) begin
        pack_mel(ts_i, 1'b1);
        send_and_wait;
        check_ts(ts_i, 1'b1);
    end

    // ===========================================================
    // 최종 결과
    // ===========================================================
    $display("");
    $display("============================================");
    $display("  PASS=%0d  FAIL=%0d", pass_n, fail_n);
    if (fail_n == 0)
        $display("  OK  전체 통과");
    else
        $display("  NG  %0d개 실패", fail_n);
    $display("============================================");
    $display("");
    $finish;
end

endmodule
