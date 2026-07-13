// tb_demo_spi_top.v — 데모 시퀀스 LED 토글 검증
// demo_spi_top(세그먼트 단위 판정)이 지정된 데모 시퀀스에서 LED를
// 매 세그먼트마다 정확히 토글하는지 검증한다.
//
//   시퀀스 (Enter 4회, 각 step 두 트랙에 한 세그먼트씩 전송):
//     track0:  이상  정상  정상  이상
//     track1:  정상  이상  정상  정상
//   기대 LED:
//     step1  led0=1 led1=0
//     step2  led0=0 led1=1
//     step3  led0=0 led1=0
//     step4  led0=1 led1=0
//
// 각 세그먼트 = hw_*_mel.hex의 31타임스텝(41B 프레임 31개)을 SPI로 전송.
//
// 실행:
//   /usr/bin/iverilog -g2001 -o hardware/sim/demo_spi_top \
//       hardware/testbench/tb_demo_spi_top.v hardware/src/*.v
//   /usr/bin/vvp hardware/sim/demo_spi_top

`timescale 1ns/1ps

module tb_demo_spi_top;

localparam N_TRACKS = 4;
localparam TRK_W    = 2;
localparam N_LED    = 4;
localparam SCK_H    = 100;   // SCK 반주기 100ns → 5MHz

reg clk = 0;
always #5 clk = ~clk;        // 100 MHz 입력

reg rst_n = 0;
reg sck = 0, mosi = 0, cs_n = 1;
wire [N_LED-1:0] led;

demo_spi_top #(.N_TRACKS(N_TRACKS), .TRK_W(TRK_W), .N_LED(N_LED)) dut (
    .clk(clk), .rst_n(rst_n),
    .sck(sck), .mosi(mosi), .cs_n(cs_n),
    .led(led)
);

integer pass_n = 0, fail_n = 0;

// 골든 hw_* 세그먼트 (31ts × 40mel = 1240바이트)
reg [7:0] hw_n_mel [0:1239];
reg [7:0] hw_a_mel [0:1239];

integer k, b, timeout, ts;
reg [327:0] fr;

// SPI 마스터: 한 타임스텝(41B) 전송 (mode 0, MSB-first)
task spi_send;
    input [7:0]   ch;
    input integer tstep;
    input         is_anom;
    begin
        fr[327:320] = ch;
        for (k = 0; k < 40; k = k + 1)
            fr[(39-k)*8 +: 8] = is_anom ? hw_a_mel[tstep*40+k] : hw_n_mel[tstep*40+k];
        cs_n = 0; #SCK_H;
        for (b = 327; b >= 0; b = b - 1) begin
            mosi = fr[b];
            #SCK_H; sck = 1;
            #SCK_H; sck = 0;
        end
        #SCK_H; cs_n = 1;
        #SCK_H;
    end
endtask

// 한 타임스텝 처리 완료 대기 (busy assert→deassert)
task wait_proc;
    begin
        timeout = 0;
        while (!dut.u_mult.busy && timeout < 4000) begin #20; timeout = timeout + 1; end
        timeout = 0;
        while (dut.u_mult.busy && timeout < 30000) begin #20; timeout = timeout + 1; end
        if (timeout >= 30000) begin $display("  TIMEOUT"); $finish; end
        #200;
    end
endtask

// 한 세그먼트(31 타임스텝) 전송
task send_segment;
    input [7:0] ch;
    input       is_anom;
    begin
        for (ts = 0; ts < 31; ts = ts + 1) begin
            spi_send(ch, ts, is_anom);
            wait_proc;
        end
    end
endtask

// LED 체크
task check_led;
    input integer step;
    input         exp0;
    input         exp1;
    begin
        if (led[0] === exp0) pass_n = pass_n + 1;
        else begin fail_n = fail_n + 1;
            $display("  FAIL step%0d led0 got=%b exp=%b", step, led[0], exp0); end
        if (led[1] === exp1) pass_n = pass_n + 1;
        else begin fail_n = fail_n + 1;
            $display("  FAIL step%0d led1 got=%b exp=%b", step, led[1], exp1); end
        $display("  step%0d: led0=%b led1=%b  (exp %b/%b)  %s",
                 step, led[0], led[1], exp0, exp1,
                 (led[0]===exp0 && led[1]===exp1) ? "OK" : "NG");
    end
endtask

initial begin
    $readmemh("hardware/src/weights/golden/hw_normal_mel.hex",  hw_n_mel);
    $readmemh("hardware/src/weights/golden/hw_anomaly_mel.hex", hw_a_mel);

    $display("");
    $display("============================================");
    $display("  tb_demo_spi_top — 데모 시퀀스 LED 토글 검증");
    $display("  track0: 이상 정상 정상 이상");
    $display("  track1: 정상 이상 정상 정상");
    $display("============================================");

    rst_n = 0;
    repeat (6) @(posedge clk); #1;
    rst_n = 1; #40;

    // step1: t0=이상, t1=정상  → led0=1 led1=0
    send_segment(8'd0, 1'b1);   // track0 anomaly
    send_segment(8'd1, 1'b0);   // track1 normal
    check_led(1, 1'b1, 1'b0);

    // step2: t0=정상, t1=이상  → led0=0 led1=1
    send_segment(8'd0, 1'b0);   // track0 normal
    send_segment(8'd1, 1'b1);   // track1 anomaly
    check_led(2, 1'b0, 1'b1);

    // step3: t0=정상, t1=정상  → led0=0 led1=0
    send_segment(8'd0, 1'b0);   // track0 normal
    send_segment(8'd1, 1'b0);   // track1 normal
    check_led(3, 1'b0, 1'b0);

    // step4: t0=이상, t1=정상  → led0=1 led1=0
    send_segment(8'd0, 1'b1);   // track0 anomaly
    send_segment(8'd1, 1'b0);   // track1 normal
    check_led(4, 1'b1, 1'b0);

    $display("");
    $display("============================================");
    $display("  PASS=%0d  FAIL=%0d", pass_n, fail_n);
    if (fail_n == 0) $display("  OK  세그먼트 단위 LED 토글 정상 (데모 시퀀스 재현)");
    else             $display("  NG  %0d개 실패", fail_n);
    $display("============================================");
    $display("");
    $finish;
end

endmodule
