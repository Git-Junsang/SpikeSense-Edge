// ============================================================
// spi_slave.v — SPI 수신 전용 슬레이브 (RPi5 → FPGA)
// ============================================================
// 프로토콜 (RPi5 spidev, mode 0):
//   CPOL=0, CPHA=0  → SCK idle=0, MOSI를 SCK 상승엣지에서 샘플
//   MSB first, 41바이트 패킷
//     Byte 0      : channel_id (0x00=ch0, 0x01=ch1)
//     Byte 1..40  : mel_int8[0..39]
//   CS(active-low) 하강 → 41B 전송 → CS 상승 → frame_rdy 1클럭 펄스
//
// CDC: sck/mosi/cs_n을 시스템 클럭(clk, 100MHz)으로 2단 동기화 후
//      SCK 상승엣지를 검출해 비트 시프트 (SCK 10MHz ≪ clk이므로 안전).
//
// mel_out 패킹: mel_out[c*8 +: 8] = mel_int8[c]  (ch0 → [7:0], snn_top과 동일)
// ============================================================

`timescale 1ns/1ps

module spi_slave (
    input  wire        clk,      // 시스템 클럭 (100 MHz)
    input  wire        rst_n,

    // SPI 물리 신호 (비동기)
    input  wire        sck,      // SPI clock (mode 0)
    input  wire        mosi,     // master out, slave in
    input  wire        cs_n,     // chip select (active low)

    // 디코딩 결과
    output reg  [319:0] mel_out,     // mel_int8[0..39] (frame_rdy 시 유효)
    output reg  [7:0]   channel_id,  // 0=ch0, 1=ch1
    output reg          frame_rdy    // 41바이트 수신 완료 1클럭 펄스
);

    localparam [8:0] PKT_BITS = 9'd328; // 41바이트 × 8

    // -------------------------------------------------------
    // 입력 동기화 (2단 FF, 메타스테이빌리티 방지)
    // -------------------------------------------------------
    reg [1:0] sck_sync, cs_sync;
    reg [1:0] mosi_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sck_sync  <= 2'b00;
            cs_sync   <= 2'b11;   // CS는 idle=1
            mosi_sync <= 2'b00;
        end else begin
            sck_sync  <= {sck_sync[0],  sck};
            cs_sync   <= {cs_sync[0],   cs_n};
            mosi_sync <= {mosi_sync[0], mosi};
        end
    end

    wire sck_rise = (sck_sync == 2'b01);  // 0→1 (mode 0 샘플 시점)
    wire cs_fall  = (cs_sync  == 2'b10);  // 1→0 (프레임 시작)
    wire cs_rise  = (cs_sync  == 2'b01);  // 0→1 (프레임 종료)
    wire cs_active = ~cs_sync[1];          // CS=0 동안 수신
    wire mosi_bit  = mosi_sync[1];

    // -------------------------------------------------------
    // 시프트 수신 + 바이트 조립
    // -------------------------------------------------------
    reg  [8:0]   bit_cnt;       // 0..328 (수신한 총 비트 수)
    reg  [327:0] shreg;         // MSB-first 누적 시프트 레지스터

    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bit_cnt    <= 9'd0;
            shreg      <= 328'd0;
            mel_out    <= 320'd0;
            channel_id <= 8'd0;
            frame_rdy  <= 1'b0;
        end else begin
            frame_rdy <= 1'b0; // 기본 0, 완료 시에만 1클럭 펄스

            if (cs_fall) begin
                // 새 프레임 시작 → 비트 카운터 초기화
                bit_cnt <= 9'd0;
            end else if (cs_active && sck_rise) begin
                // MSB-first 시프트 인
                shreg   <= {shreg[326:0], mosi_bit};
                if (bit_cnt != PKT_BITS) bit_cnt <= bit_cnt + 9'd1;
            end

            if (cs_rise) begin
                // 프레임 종료: 정확히 41바이트 수신 시에만 유효 처리
                if (bit_cnt == PKT_BITS) begin
                    // shreg 최상위 바이트[327:320] = Byte0 = channel_id
                    channel_id <= shreg[327:320];
                    // Byte1..40 = mel[0..39] (먼저 온 바이트가 mel[0])
                    // mel_out[c*8 +: 8] = mel[c] 로 재배치
                    for (i = 0; i < 40; i = i + 1)
                        mel_out[i*8 +: 8] <= shreg[(39-i)*8 +: 8];
                    frame_rdy <= 1'b1;
                end
            end
        end
    end

endmodule
