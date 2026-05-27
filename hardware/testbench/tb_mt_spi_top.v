// ============================================================
// tb_mt_spi_top.v — SPI 통합 다중 트랙 시분할 검증 (Phase 6-2)
// ============================================================
// 전 경로 검증: clk_div2(100→50MHz) → spi_slave → channel_id=track_id
//   디먹스 → mt_snn_top.
// SPI 마스터(mode 0, SCK 5MHz)로 41B 프레임을 보내고, 각 트랙의 L3
// 막전위가 해당 패턴의 단일채널 골든과 일치하는지 확인.
//   track0=normal, track1=anomaly, ts0·ts1 전송 → 트랙별 영역 격리·지속 검증.
//
// 실행:
//   /usr/bin/iverilog -g2001 -o hardware/sim/mt_spi_top \
//       hardware/testbench/tb_mt_spi_top.v hardware/src/*.v
//   /usr/bin/vvp hardware/sim/mt_spi_top
// ============================================================

`timescale 1ns/1ps

module tb_mt_spi_top;

localparam N_TRACKS = 4;
localparam TRK_W    = 2;
localparam SCK_H    = 100;   // SCK 반주기 100ns → 5MHz (50MHz가 10× 오버샘플)

reg clk = 0;
always #5 clk = ~clk;        // 100 MHz 입력

reg rst_n = 0;
reg sck = 0, mosi = 0, cs_n = 1;
wire [15:0] led;

mt_spi_top #(.N_TRACKS(N_TRACKS), .TRK_W(TRK_W), .N_LED(16)) dut (
    .clk(clk), .rst_n(rst_n),
    .sck(sck), .mosi(mosi), .cs_n(cs_n),
    .led(led)
);

integer pass_n = 0, fail_n = 0;

reg [7:0]  gv_n_mel [0:1239];
reg [7:0]  gv_a_mel [0:1239];
reg [15:0] gv_n_mem [0:61];
reg [15:0] gv_a_mem [0:61];

integer k, b, timeout;
reg [327:0] fr;

// ─── SPI 마스터: 41B 프레임 전송 (mode 0, MSB-first) ─────────
task spi_send;
    input [7:0] ch;
    input integer ts;
    input         is_anom;
    begin
        fr[327:320] = ch;
        for (k = 0; k < 40; k = k + 1)
            fr[(39-k)*8 +: 8] = is_anom ? gv_a_mel[ts*40+k] : gv_n_mel[ts*40+k];

        cs_n = 0; #SCK_H;
        for (b = 327; b >= 0; b = b - 1) begin
            mosi = fr[b];
            #SCK_H; sck = 1;   // 상승엣지 샘플
            #SCK_H; sck = 0;
        end
        #SCK_H; cs_n = 1;      // 프레임 종료 → frame_rdy
        #SCK_H;
    end
endtask

// ─── 처리 완료 대기 (busy assert→deassert) ───────────────────
task wait_proc;
    begin
        timeout = 0;
        while (!dut.u_mt.busy && timeout < 4000) begin #20; timeout = timeout + 1; end
        timeout = 0;
        while (dut.u_mt.busy && timeout < 30000) begin #20; timeout = timeout + 1; end
        if (timeout >= 30000) begin $display("  TIMEOUT"); $finish; end
        #100;
    end
endtask

task check_track;
    input integer trk;
    input         is_anom;
    input integer ts;
    reg [15:0] exp_m0, exp_m1, got_m0, got_m1;
    integer base;
    begin
        exp_m0 = is_anom ? gv_a_mem[ts*2]   : gv_n_mem[ts*2];
        exp_m1 = is_anom ? gv_a_mem[ts*2+1] : gv_n_mem[ts*2+1];
        base   = trk*256;
        got_m0 = dut.u_mt.u_mem.mem[base+160];
        got_m1 = dut.u_mt.u_mem.mem[base+161];
        if (got_m0 === exp_m0) pass_n = pass_n + 1;
        else begin fail_n = fail_n + 1;
            $display("  FAIL trk%0d ts%0d %s n0 got=0x%h exp=0x%h", trk, ts, is_anom?"anom":"norm", got_m0, exp_m0); end
        if (got_m1 === exp_m1) pass_n = pass_n + 1;
        else begin fail_n = fail_n + 1;
            $display("  FAIL trk%0d ts%0d %s n1 got=0x%h exp=0x%h", trk, ts, is_anom?"anom":"norm", got_m1, exp_m1); end
    end
endtask

initial begin
    $readmemh("hardware/src/weights/golden/normal_mel.hex",      gv_n_mel);
    $readmemh("hardware/src/weights/golden/anomaly_mel.hex",     gv_a_mel);
    $readmemh("hardware/src/weights/golden/normal_mem_out.hex",  gv_n_mem);
    $readmemh("hardware/src/weights/golden/anomaly_mem_out.hex", gv_a_mem);

    $display("");
    $display("============================================");
    $display("  tb_mt_spi_top — SPI 통합 시분할 검증");
    $display("  ch0→track0(normal), ch1→track1(anomaly)");
    $display("============================================");

    rst_n = 0;
    repeat (6) @(posedge clk); #1;
    rst_n = 1; #20;

    // ts0
    spi_send(8'd0, 0, 1'b0); wait_proc; check_track(0, 1'b0, 0);
    spi_send(8'd1, 0, 1'b1); wait_proc; check_track(1, 1'b1, 0);
    // ts1 (트랙별 막전위 지속 + 전진 검증)
    spi_send(8'd0, 1, 1'b0); wait_proc; check_track(0, 1'b0, 1);
    spi_send(8'd1, 1, 1'b1); wait_proc; check_track(1, 1'b1, 1);

    $display("");
    $display("============================================");
    $display("  PASS=%0d  FAIL=%0d", pass_n, fail_n);
    if (fail_n == 0) $display("  OK  SPI→track 디먹스 + 시분할 처리 정상");
    else             $display("  NG  %0d개 실패", fail_n);
    $display("============================================");
    $display("");
    $finish;
end

endmodule
