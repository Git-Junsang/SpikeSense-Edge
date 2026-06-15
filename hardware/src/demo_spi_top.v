// ============================================================
// demo_spi_top.v — 데모용 다중 트랙 SPI 보드 최상위 (신규)
// ============================================================
// mult_spi_top.v 와 구조 동일(clk_div2 → spi_slave → 시분할 엔진 → LED).
// 유일한 차이: 엔진을 mult_snn_top(Leaky Counter) 대신
//              demo_snn_top(세그먼트 단위 판정)으로 교체.
//   → LED[track] = 해당 트랙의 "가장 최근 완료 세그먼트" 정상/이상.
//     매 세그먼트마다 깔끔히 토글 (이상→정상→정상→이상 시연 가능).
//
// 인스턴스 이름(u_clkdiv / u_spi / u_mult)을 mult_spi_top과 동일하게 유지
// → 기존 nexys_a7_mult.xdc 의 계층 제약(생성클럭·ASYNC_REG)을 그대로 재사용.
// 합성 시 top module 을 demo_spi_top 으로 지정하고 같은 XDC를 사용하면 된다.
//
// ※ mult_spi_top.v / dual_snn_top.v / snn_top.v 는 동결. 본 모듈은 신규.
// ============================================================

`timescale 1ns/1ps

module demo_spi_top #(
    parameter N_TRACKS = 64,
    parameter TRK_W    = 6,    // ceil(log2(N_TRACKS))
    parameter N_LED    = 16    // Nexys A7 LED 16개
)(
    input  wire             clk,    // 입력 클럭 100 MHz (E3)
    input  wire             rst_n,  // CPU_RESETN (active-low)

    input  wire             sck,
    input  wire             mosi,
    input  wire             cs_n,

    output wire [N_LED-1:0] led
);

    // ── 클럭 2분주 (100 → 50 MHz) ────────────────────────────
    wire clk50;
    clk_div2 u_clkdiv (.clk_in(clk), .clk_out(clk50));

    // ── SPI 슬레이브 (50 MHz 도메인) ─────────────────────────
    wire [319:0] mel_bus;
    wire [7:0]   channel_id;
    wire         frame_rdy;

    spi_slave u_spi (
        .clk(clk50), .rst_n(rst_n),
        .sck(sck), .mosi(mosi), .cs_n(cs_n),
        .mel_out(mel_bus), .channel_id(channel_id), .frame_rdy(frame_rdy)
    );

    // ── channel_id → track_id ────────────────────────────────
    wire [TRK_W-1:0] track_id    = channel_id[TRK_W-1:0];
    wire             frame_valid = frame_rdy && (channel_id < N_TRACKS);

    // ── 다중 트랙 시분할 SNN 엔진 (세그먼트 단위 판정) ───────
    wire [N_TRACKS-1:0] anomaly_flags;
    wire                busy;

    demo_snn_top #(.N_TRACKS(N_TRACKS), .TRK_W(TRK_W)) u_mult (
        .clk(clk50), .rst_n(rst_n),
        .mel_in(mel_bus), .frame_valid(frame_valid), .track_id(track_id),
        .anomaly_flags(anomaly_flags), .busy(busy)
    );

    // ── 출력: 하위 N_LED개 트랙 플래그 → LED ─────────────────
    assign led = anomaly_flags[N_LED-1:0];

endmodule
