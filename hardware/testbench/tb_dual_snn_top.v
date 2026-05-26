// ============================================================
// tb_dual_snn_top.v — 듀얼채널 + SPI 인터페이스 검증 (Phase 5)
// ============================================================
// 검증 항목:
//   [1] 리셋 초기 상태
//   [2] SPI 프레임 전송 → channel_id 디먹스 → 채널별 독립 추론
//       ch0 = anomaly 골든, ch1 = normal 골든 (31 타임스텝 동시 진행)
//   [3] L3 막전위·스파이크·anomaly_flag 가 채널별 골든과 bit-exact 일치
//
// SPI 마스터 모사: mode 0 (CPOL=0, CPHA=0), MSB first, 41바이트 패킷
//
// 실행:
//   /usr/bin/iverilog -g2001 -o hardware/sim/dual_snn_top \
//       hardware/testbench/tb_dual_snn_top.v hardware/src/*.v
//   /usr/bin/vvp hardware/sim/dual_snn_top
// ============================================================

`timescale 1ns/1ps

module tb_dual_snn_top;

// ─── 클럭 / 리셋 ─────────────────────────────────────────────
reg clk   = 0;
reg rst_n = 0;
always #5 clk = ~clk;  // 100 MHz

localparam SCK_HALF = 40;  // SPI 반주기 80ns→12.5MHz (sysclk 100MHz ≫ SCK)

integer pass_n = 0;
integer fail_n = 0;
integer ts_i;
integer timeout_cnt;

// ─── SPI 마스터 신호 ─────────────────────────────────────────
reg sck  = 0;
reg mosi = 0;
reg cs_n = 1;

// ─── DUT ─────────────────────────────────────────────────────
wire ch0_anomaly, ch1_anomaly;
wire ch0_busy, ch1_busy;

dual_snn_top dut (
    .clk        (clk),
    .rst_n      (rst_n),
    .sck        (sck),
    .mosi       (mosi),
    .cs_n       (cs_n),
    .ch0_anomaly(ch0_anomaly),
    .ch1_anomaly(ch1_anomaly),
    .ch0_busy   (ch0_busy),
    .ch1_busy   (ch1_busy)
);

// ─── 골든 데이터 ─────────────────────────────────────────────
reg [7:0]  gv_n_mel [0:1239];  // normal mel:  31×40
reg [7:0]  gv_a_mel [0:1239];  // anomaly mel
reg [15:0] gv_n_mem [0:61];    // normal L3 막전위 [ts*2+n]
reg [15:0] gv_a_mem [0:61];
reg [0:0]  gv_n_spk [0:61];
reg [0:0]  gv_a_spk [0:61];

// 채널별 leaky counter 기대값 (ch0=anomaly, ch1=normal)
integer cnt_n0, cnt_a0;   // ch0
integer cnt_n1, cnt_a1;   // ch1

// ─── VCD ─────────────────────────────────────────────────────
initial begin
    $dumpfile("hardware/sim/dual_snn_top.vcd");
    $dumpvars(0, tb_dual_snn_top);
end

// ─── SPI 바이트 전송 (mode 0, MSB first) ─────────────────────
task spi_byte;
    input [7:0] b;
    integer k;
    begin
        for (k = 7; k >= 0; k = k - 1) begin
            mosi = b[k];      // SCK low 동안 데이터 셋업
            #(SCK_HALF);
            sck = 1;          // 상승엣지 = 샘플
            #(SCK_HALF);
            sck = 0;
        end
    end
endtask

// ─── SPI 41바이트 프레임 전송 ────────────────────────────────
task spi_send_frame;
    input integer channel;   // 0=anomaly 골든, 1=normal 골든
    input integer ts_idx;
    integer c;
    reg [7:0] mb;
    begin
        cs_n = 0;
        #(SCK_HALF);
        spi_byte(channel[7:0]);             // Byte0: channel_id
        for (c = 0; c < 40; c = c + 1) begin
            mb = (channel == 0) ? gv_a_mel[ts_idx*40+c]   // ch0=anomaly
                                : gv_n_mel[ts_idx*40+c];   // ch1=normal
            spi_byte(mb);                   // Byte1..40: mel[0..39]
        end
        #(SCK_HALF);
        cs_n = 1;                           // 프레임 종료 → frame_rdy
        #(SCK_HALF);
    end
endtask

// ─── 채널 busy 상승→하강 대기 + ts_done_r 반영 ───────────────
task wait_channel;
    input integer channel;
    begin
        // frame_rdy → frame_valid → busy 상승까지 대기
        timeout_cnt = 0;
        while (!(channel == 0 ? ch0_busy : ch1_busy)) begin
            @(posedge clk);
            timeout_cnt = timeout_cnt + 1;
            if (timeout_cnt > 1000) begin
                $display("  TIMEOUT: ch%0d busy 상승 안 함", channel);
                $finish;
            end
        end
        // 처리 완료(busy=0)까지 대기
        timeout_cnt = 0;
        while (channel == 0 ? ch0_busy : ch1_busy) begin
            @(posedge clk);
            timeout_cnt = timeout_cnt + 1;
            if (timeout_cnt > 12000) begin
                $display("  TIMEOUT: ch%0d busy 해제 안 함", channel);
                $finish;
            end
        end
        @(posedge clk); #1;  // ts_done_r → anomaly_judge 갱신 후 샘플링
    end
endtask

// ─── 채널 결과 검증 ──────────────────────────────────────────
task check_ch;
    input integer channel;
    input integer ts_val;
    reg [15:0] got_m0, got_m1, exp_m0, exp_m1;
    reg got_s0, got_s1, got_flag, exp_s0, exp_s1, exp_flag;
    begin
        if (channel == 0) begin  // ch0 = anomaly 골든
            got_m0   = dut.u_ch0.u_mem.mem_reg[160];
            got_m1   = dut.u_ch0.u_mem.mem_reg[161];
            got_s0   = dut.u_ch0.spk_normal_r;
            got_s1   = dut.u_ch0.spk_anomaly_r;
            got_flag = ch0_anomaly;
            exp_m0   = gv_a_mem[ts_val*2];
            exp_m1   = gv_a_mem[ts_val*2+1];
            exp_s0   = gv_a_spk[ts_val*2];
            exp_s1   = gv_a_spk[ts_val*2+1];
            cnt_n0   = cnt_n0 + exp_s0;
            cnt_a0   = cnt_a0 + exp_s1;
            exp_flag = (cnt_a0 > cnt_n0) ? 1'b1 : 1'b0;
        end else begin           // ch1 = normal 골든
            got_m0   = dut.u_ch1.u_mem.mem_reg[160];
            got_m1   = dut.u_ch1.u_mem.mem_reg[161];
            got_s0   = dut.u_ch1.spk_normal_r;
            got_s1   = dut.u_ch1.spk_anomaly_r;
            got_flag = ch1_anomaly;
            exp_m0   = gv_n_mem[ts_val*2];
            exp_m1   = gv_n_mem[ts_val*2+1];
            exp_s0   = gv_n_spk[ts_val*2];
            exp_s1   = gv_n_spk[ts_val*2+1];
            cnt_n1   = cnt_n1 + exp_s0;
            cnt_a1   = cnt_a1 + exp_s1;
            exp_flag = (cnt_a1 > cnt_n1) ? 1'b1 : 1'b0;
        end

        // 5개 항목 묶음 검증 (막전위 n0/n1, 스파이크 n0/n1, flag)
        check1(channel, ts_val, "n0_mem", got_m0 === exp_m0, got_m0, exp_m0);
        check1(channel, ts_val, "n1_mem", got_m1 === exp_m1, got_m1, exp_m1);
        check1(channel, ts_val, "spk_n0", got_s0 === exp_s0, got_s0, exp_s0);
        check1(channel, ts_val, "spk_n1", got_s1 === exp_s1, got_s1, exp_s1);
        check1(channel, ts_val, "flag",   got_flag === exp_flag, got_flag, exp_flag);
    end
endtask

// ─── 단일 비교 + 카운트 (FAIL만 상세 출력) ───────────────────
task check1;
    input integer channel;
    input integer ts_val;
    input [8*8-1:0] label;
    input          ok;
    input [15:0]   got_v;
    input [15:0]   exp_v;
    begin
        if (ok) begin
            pass_n = pass_n + 1;
        end else begin
            fail_n = fail_n + 1;
            $display("  FAIL ch%0d ts%0d %0s  got=0x%h exp=0x%h",
                     channel, ts_val, label, got_v, exp_v);
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

    $display("");
    $display("============================================");
    $display("  tb_dual_snn_top — 듀얼채널+SPI 검증 (Phase 5)");
    $display("    ch0 ← anomaly 골든 / ch1 ← normal 골든");
    $display("============================================");

    // ── 리셋 ─────────────────────────────────────────────────
    rst_n = 0;
    @(posedge clk); @(posedge clk); #1;
    rst_n = 1; #2;

    // [1] 초기 상태
    $display("\n[1] 리셋 후 초기 상태");
    check1(0, 0, "busy0",  ch0_busy    === 1'b0, ch0_busy,    0);
    check1(1, 0, "busy1",  ch1_busy    === 1'b0, ch1_busy,    0);
    check1(0, 0, "flag0",  ch0_anomaly === 1'b0, ch0_anomaly, 0);
    check1(1, 0, "flag1",  ch1_anomaly === 1'b0, ch1_anomaly, 0);

    // [2] 31 타임스텝 — 매 ts: ch0(anomaly), ch1(normal) SPI 전송·검증
    $display("\n[2] SPI 31 타임스텝 — 채널별 골든 대조");
    cnt_n0 = 0; cnt_a0 = 0;
    cnt_n1 = 0; cnt_a1 = 0;

    for (ts_i = 0; ts_i < 31; ts_i = ts_i + 1) begin
        // ── ch0 (anomaly) ──
        spi_send_frame(0, ts_i);
        wait_channel(0);
        check_ch(0, ts_i);
        // ── ch1 (normal) ──
        spi_send_frame(1, ts_i);
        wait_channel(1);
        check_ch(1, ts_i);
    end

    $display("    ch0 최종 anomaly_flag=%0d (cnt n=%0d a=%0d)", ch0_anomaly, cnt_n0, cnt_a0);
    $display("    ch1 최종 anomaly_flag=%0d (cnt n=%0d a=%0d)", ch1_anomaly, cnt_n1, cnt_a1);

    // ── 최종 결과 ─────────────────────────────────────────────
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
