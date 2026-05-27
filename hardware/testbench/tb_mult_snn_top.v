// ============================================================
// tb_mult_snn_top.v — 다중 트랙 시분할 SNN 검증 (Phase 6 확장)
// ============================================================
// 검증 전략 (시분할 격리성 + bit-exact 정확도):
//   4개 트랙에 골든 패턴을 배정: track0=normal, track1=anomaly,
//   track2=normal, track3=anomaly.
//   타임스텝마다 4트랙 프레임을 인터리빙 전송하고, 각 트랙의 L3 막전위·
//   스파이크가 해당 패턴의 단일채널 골든과 bit-exact 일치하는지 확인.
//   → 트랙 간 상태 격리 + 단일채널 등가성 동시 증명.
//
// 실행:
//   /usr/bin/iverilog -g2001 -o hardware/sim/mult_snn_top \
//       hardware/testbench/tb_mult_snn_top.v hardware/src/*.v
//   /usr/bin/vvp hardware/sim/mult_snn_top
// ============================================================

`timescale 1ns/1ps

module tb_mult_snn_top;

localparam N_TRACKS = 4;
localparam TRK_W    = 2;

// ─── 클럭 / 리셋 (50 MHz, 주기 20ns) ────────────────────────
reg clk = 0;
reg rst_n = 0;
always #10 clk = ~clk;

integer pass_n = 0;
integer fail_n = 0;
integer ts_i, t_i;

// ─── DUT ─────────────────────────────────────────────────────
reg  [319:0] mel_in = 320'b0;
reg          frame_valid = 0;
reg  [TRK_W-1:0] track_id = 0;
wire [N_TRACKS-1:0] anomaly_flags;
wire         busy;

mult_snn_top #(.N_TRACKS(N_TRACKS), .TRK_W(TRK_W)) dut (
    .clk(clk), .rst_n(rst_n),
    .mel_in(mel_in), .frame_valid(frame_valid), .track_id(track_id),
    .anomaly_flags(anomaly_flags), .busy(busy)
);

// ─── 골든 데이터 ─────────────────────────────────────────────
reg [7:0]  gv_n_mel [0:1239];
reg [7:0]  gv_a_mel [0:1239];
reg [15:0] gv_n_mem [0:61];
reg [15:0] gv_a_mem [0:61];
reg [0:0]  gv_n_spk [0:61];
reg [0:0]  gv_a_spk [0:61];

// 트랙별 패턴: 0=normal, 1=anomaly
reg pattern [0:N_TRACKS-1];

integer timeout_cnt;
integer c;
reg [7:0] mel_byte;

// ─── mel 패킹 ─────────────────────────────────────────────────
task pack_mel;
    input integer ts_idx;
    input         is_anomaly;
    begin
        for (c = 0; c < 40; c = c + 1) begin
            mel_byte = is_anomaly ? gv_a_mel[ts_idx*40+c] : gv_n_mel[ts_idx*40+c];
            mel_in[c*8 +: 8] = mel_byte;
        end
    end
endtask

// ─── 프레임 전송 + 처리완료 + ts_done_r 대기 ─────────────────
task send_and_wait;
    input integer trk;
    begin
        track_id    = trk[TRK_W-1:0];
        frame_valid = 1;
        @(posedge clk); #1;
        frame_valid = 0;

        timeout_cnt = 0;
        while (busy) begin
            @(posedge clk);
            timeout_cnt = timeout_cnt + 1;
            if (timeout_cnt > 12000) begin
                $display("  TIMEOUT: track %0d busy 미해제", trk);
                $finish;
            end
        end
        @(posedge clk); #1;   // ts_done_r 반영
    end
endtask

// ─── 트랙 결과 검증 (해당 트랙 L3 막전위·스파이크 vs 골든) ────
task check_track;
    input integer trk;
    input         is_anomaly;
    input integer ts_val;
    reg [15:0] exp_m0, exp_m1, got_m0, got_m1;
    reg exp_s0, exp_s1;
    integer base;
    begin
        exp_m0 = is_anomaly ? gv_a_mem[ts_val*2]   : gv_n_mem[ts_val*2];
        exp_m1 = is_anomaly ? gv_a_mem[ts_val*2+1] : gv_n_mem[ts_val*2+1];
        exp_s0 = is_anomaly ? gv_a_spk[ts_val*2]   : gv_n_spk[ts_val*2];
        exp_s1 = is_anomaly ? gv_a_spk[ts_val*2+1] : gv_n_spk[ts_val*2+1];

        base   = trk*256;
        got_m0 = dut.u_mem.mem[base+160];
        got_m1 = dut.u_mem.mem[base+161];

        // L3 막전위 n0
        if (got_m0 === exp_m0) pass_n = pass_n + 1;
        else begin
            fail_n = fail_n + 1;
            $display("  FAIL trk%0d ts%0d %s n0_mem got=0x%h exp=0x%h",
                     trk, ts_val, is_anomaly?"anom":"norm", got_m0, exp_m0);
        end
        // L3 막전위 n1
        if (got_m1 === exp_m1) pass_n = pass_n + 1;
        else begin
            fail_n = fail_n + 1;
            $display("  FAIL trk%0d ts%0d %s n1_mem got=0x%h exp=0x%h",
                     trk, ts_val, is_anomaly?"anom":"norm", got_m1, exp_m1);
        end
        // L3 스파이크 n0
        if (dut.spk_normal_r === exp_s0) pass_n = pass_n + 1;
        else begin
            fail_n = fail_n + 1;
            $display("  FAIL trk%0d ts%0d %s spk_n0 got=%0d exp=%0d",
                     trk, ts_val, is_anomaly?"anom":"norm", dut.spk_normal_r, exp_s0);
        end
        // L3 스파이크 n1
        if (dut.spk_anomaly_r === exp_s1) pass_n = pass_n + 1;
        else begin
            fail_n = fail_n + 1;
            $display("  FAIL trk%0d ts%0d %s spk_n1 got=%0d exp=%0d",
                     trk, ts_val, is_anomaly?"anom":"norm", dut.spk_anomaly_r, exp_s1);
        end
    end
endtask

// ─── 메인 ────────────────────────────────────────────────────
initial begin
    $readmemh("hardware/src/weights/golden/normal_mel.hex",      gv_n_mel);
    $readmemh("hardware/src/weights/golden/anomaly_mel.hex",     gv_a_mel);
    $readmemh("hardware/src/weights/golden/normal_mem_out.hex",  gv_n_mem);
    $readmemh("hardware/src/weights/golden/anomaly_mem_out.hex", gv_a_mem);
    $readmemh("hardware/src/weights/golden/normal_spk.hex",      gv_n_spk);
    $readmemh("hardware/src/weights/golden/anomaly_spk.hex",     gv_a_spk);

    // 트랙 패턴 배정 (교차)
    pattern[0] = 1'b0; // normal
    pattern[1] = 1'b1; // anomaly
    pattern[2] = 1'b0; // normal
    pattern[3] = 1'b1; // anomaly

    $display("");
    $display("============================================");
    $display("  tb_mult_snn_top — 다중 트랙 시분할 검증 (N=%0d)", N_TRACKS);
    $display("  트랙 패턴: t0=norm t1=anom t2=norm t3=anom");
    $display("============================================");

    rst_n = 0;
    @(posedge clk); @(posedge clk); #1;
    rst_n = 1; #2;

    // 31 타임스텝 × 4트랙 인터리빙
    for (ts_i = 0; ts_i < 31; ts_i = ts_i + 1) begin
        for (t_i = 0; t_i < N_TRACKS; t_i = t_i + 1) begin
            pack_mel(ts_i, pattern[t_i]);
            send_and_wait(t_i);
            check_track(t_i, pattern[t_i], ts_i);
        end
    end

    $display("");
    $display("--- anomaly_flags 최종 = %b (t3 t2 t1 t0) ---", anomaly_flags);
    $display("    (normal 트랙 t0/t2=0, anomaly 트랙 t1/t3=1 기대)");

    $display("");
    $display("============================================");
    $display("  PASS=%0d  FAIL=%0d", pass_n, fail_n);
    if (fail_n == 0) $display("  OK  전체 통과 — 시분할 격리 + bit-exact 확인");
    else             $display("  NG  %0d개 실패", fail_n);
    $display("============================================");
    $display("");
    $finish;
end

endmodule
