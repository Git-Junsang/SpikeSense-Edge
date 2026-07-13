// dual_snn_top.v — 2채널 PLIF-T SNN 이상 감지 최상위 (Phase 5)
//
// 신호 흐름:
//   RPi5 (USB mic x2)
//     → SPI 41B 패킷 [channel_id][mel x40]
//     → spi_slave (mel_out, channel_id, frame_rdy)
//     → channel_id로 디먹스
//         ch0: snn_top #0 → ch0_anomaly (LED0)
//         ch1: snn_top #1 → ch1_anomaly (LED1)
//
// 두 snn_top은 독립 인스턴스(가중치 BRAM·막전위 각자 보유).
// mel_out은 spi_slave가 다음 프레임까지 유지하므로, 해당 채널만
// frame_valid를 1클럭 받아 mel을 래치한다.

`timescale 1ns/1ps

module dual_snn_top (
    input  wire clk,        // 시스템 클럭 (100 MHz)
    input  wire rst_n,

    // SPI 물리 신호 (RPi5)
    input  wire sck,
    input  wire mosi,
    input  wire cs_n,

    // 채널별 이상 플래그 (LED0/LED1)
    output wire ch0_anomaly,
    output wire ch1_anomaly,

    // 상태 (옵션 LED)
    output wire ch0_busy,
    output wire ch1_busy
);

    // SPI 슬레이브 — mel 디코딩
    wire [319:0] mel_bus;
    wire [7:0]   channel_id;
    wire         frame_rdy;

    spi_slave u_spi (
        .clk        (clk),
        .rst_n      (rst_n),
        .sck        (sck),
        .mosi       (mosi),
        .cs_n       (cs_n),
        .mel_out    (mel_bus),
        .channel_id (channel_id),
        .frame_rdy  (frame_rdy)
    );

    // 채널 디먹스 — frame_rdy를 channel_id에 따라 라우팅
    wire ch0_frame_valid = frame_rdy & (channel_id == 8'd0);
    wire ch1_frame_valid = frame_rdy & (channel_id == 8'd1);

    // 채널 0
    snn_top u_ch0 (
        .clk          (clk),
        .rst_n        (rst_n),
        .mel_in       (mel_bus),
        .frame_valid  (ch0_frame_valid),
        .anomaly_flag (ch0_anomaly),
        .busy         (ch0_busy)
    );

    // 채널 1
    snn_top u_ch1 (
        .clk          (clk),
        .rst_n        (rst_n),
        .mel_in       (mel_bus),
        .frame_valid  (ch1_frame_valid),
        .anomaly_flag (ch1_anomaly),
        .busy         (ch1_busy)
    );

endmodule
