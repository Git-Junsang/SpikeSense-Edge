// ============================================================
// level_crossing_enc.v — Level Crossing 인코더
// ============================================================
// 16-bit signed PCM 오디오 샘플을 받아서,
// 이전 샘플과 비교하여 5개 레벨의 상향/하향 교차를 감지합니다.
//
// 레벨: -0.6, -0.3, 0.0, +0.3, +0.6
// 16-bit signed 기준 (범위 -32768 ~ +32767):
//   -0.6 → -19661, -0.3 → -9830, 0.0 → 0, +0.3 → +9830, +0.6 → +19661
//
// 채널 매핑 (10채널):
//   ch0: 레벨0 상향, ch1: 레벨0 하향
//   ch2: 레벨1 상향, ch3: 레벨1 하향
//   ...
//   ch8: 레벨4 상향, ch9: 레벨4 하향
//
// 입력: 매 샘플마다 sample_valid=1과 함께 sample_in 제공
// 출력: spike_out[9:0], spike_valid
// ============================================================

module level_crossing_enc (
    input  wire        clk,
    input  wire        rst_n,

    // --- 입력 ---
    input  wire signed [15:0] sample_in,    // 16-bit PCM 오디오
    input  wire               sample_valid, // 새 샘플 도착 신호

    // --- 출력 ---
    output reg  [9:0]         spike_out,    // 10채널 스파이크
    output reg                spike_valid   // 스파이크 유효 신호
);

    // -------------------------------------------------------
    // 레벨 상수 (16-bit signed, 정규화 기준 -1.0~+1.0)
    // -------------------------------------------------------
    localparam signed [15:0] LEVEL0 = -16'sd19661;  // -0.6
    localparam signed [15:0] LEVEL1 = -16'sd9830;   // -0.3
    localparam signed [15:0] LEVEL2 =  16'sd0;      //  0.0
    localparam signed [15:0] LEVEL3 =  16'sd9830;   // +0.3
    localparam signed [15:0] LEVEL4 =  16'sd19661;  // +0.6

    // -------------------------------------------------------
    // 이전 샘플 저장
    // -------------------------------------------------------
    reg signed [15:0] prev_sample;
    reg               has_prev;   // 첫 샘플 여부 (첫 샘플엔 비교 불가)

    // -------------------------------------------------------
    // 교차 감지 (조합논리)
    // -------------------------------------------------------
    // 상향 교차: prev < level <= curr
    // 하향 교차: prev >= level > curr

    wire [9:0] crossing;

    // 레벨 0
    assign crossing[0] = (prev_sample < LEVEL0) && (sample_in >= LEVEL0);  // 상향
    assign crossing[1] = (prev_sample >= LEVEL0) && (sample_in < LEVEL0);  // 하향

    // 레벨 1
    assign crossing[2] = (prev_sample < LEVEL1) && (sample_in >= LEVEL1);
    assign crossing[3] = (prev_sample >= LEVEL1) && (sample_in < LEVEL1);

    // 레벨 2
    assign crossing[4] = (prev_sample < LEVEL2) && (sample_in >= LEVEL2);
    assign crossing[5] = (prev_sample >= LEVEL2) && (sample_in < LEVEL2);

    // 레벨 3
    assign crossing[6] = (prev_sample < LEVEL3) && (sample_in >= LEVEL3);
    assign crossing[7] = (prev_sample >= LEVEL3) && (sample_in < LEVEL3);

    // 레벨 4
    assign crossing[8] = (prev_sample < LEVEL4) && (sample_in >= LEVEL4);
    assign crossing[9] = (prev_sample >= LEVEL4) && (sample_in < LEVEL4);

    // -------------------------------------------------------
    // 순차 로직
    // -------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_sample <= 16'sd0;
            has_prev    <= 1'b0;
            spike_out   <= 10'b0;
            spike_valid <= 1'b0;
        end else if (sample_valid) begin
            prev_sample <= sample_in;
            has_prev    <= 1'b1;

            if (has_prev) begin
                spike_out   <= crossing;
                spike_valid <= 1'b1;
            end else begin
                // 첫 샘플: 비교할 이전값이 없으므로 스파이크 없음
                spike_out   <= 10'b0;
                spike_valid <= 1'b0;
            end
        end else begin
            spike_valid <= 1'b0;
        end
    end

endmodule
