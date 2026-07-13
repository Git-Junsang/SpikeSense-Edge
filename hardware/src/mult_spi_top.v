// mult_spi_top.v — 다중 트랙 시분할 SNN 보드 최상위 (Phase 6-2)
//
// 신호 흐름:
//   RPi5 (USB mic xN)
//     → SPI 41B 패킷 [track_id][mel x40]  (dual과 동일 포맷, channel_id=track_id)
//     → clk_div2: 100MHz → 50MHz (시분할 SNN 동작 클럭)
//     → spi_slave (50MHz 도메인, 10MHz SCK 5x 오버샘플)
//     → mult_snn_top (단일 데이터패스 시분할, 트랙별 막전위·이상카운터)
//     → anomaly_flags[N_TRACKS] → 하위 16비트를 LED로 표시
//
// SPI 포맷·spi_slave는 dual과 동일(검증 완료). channel_id를 track_id로
// 해석만 한다 (channel_id 1바이트 = 0~255 → 최대 256트랙 수용).
//
// 참고: snn_top / dual_snn_top 은 동결(수정 금지). 본 모듈은 신규.

`timescale 1ns/1ps

module mult_spi_top #(
    parameter N_TRACKS = 64,
    parameter TRK_W    = 6,    // ceil(log2(N_TRACKS))
    parameter N_LED    = 16    // 표시할 트랙 수 (Nexys A7 LED 16개)
)(
    input  wire             clk,    // 입력 클럭 100 MHz (E3)
    input  wire             rst_n,  // CPU_RESETN (active-low)

    // SPI 물리 신호 (RPi5)
    input  wire             sck,
    input  wire             mosi,
    input  wire             cs_n,

    // 트랙별 이상 플래그 → LED[0..N_LED-1]
    output wire [N_LED-1:0] led
);

    // 클럭 2분주 (100 → 50 MHz)
    wire clk50;
    clk_div2 u_clkdiv (.clk_in(clk), .clk_out(clk50));

    // SPI 슬레이브 (50 MHz 도메인)
    wire [319:0] mel_bus;
    wire [7:0]   channel_id;
    wire         frame_rdy;

    spi_slave u_spi (
        .clk(clk50), .rst_n(rst_n),
        .sck(sck), .mosi(mosi), .cs_n(cs_n),
        .mel_out(mel_bus), .channel_id(channel_id), .frame_rdy(frame_rdy)
    );

    // channel_id → track_id (범위 밖 채널은 무시)
    wire [TRK_W-1:0] track_id    = channel_id[TRK_W-1:0];
    wire             frame_valid = frame_rdy && (channel_id < N_TRACKS);

    // 다중 트랙 시분할 SNN 엔진
    wire [N_TRACKS-1:0] anomaly_flags;
    wire                busy;

    mult_snn_top #(.N_TRACKS(N_TRACKS), .TRK_W(TRK_W)) u_mult (
        .clk(clk50), .rst_n(rst_n),
        .mel_in(mel_bus), .frame_valid(frame_valid), .track_id(track_id),
        .anomaly_flags(anomaly_flags), .busy(busy)
    );

    // 출력: 하위 N_LED개 트랙 플래그 → LED
    assign led = anomaly_flags[N_LED-1:0];

endmodule
