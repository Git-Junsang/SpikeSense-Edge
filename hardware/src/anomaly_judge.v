// ============================================================
// anomaly_judge.v — Leaky Counter 기반 이상 판정
// ============================================================
// 출력 뉴런(Out0, Out1)의 스파이크를 Leaky Counter로 누적하고,
// cnt_anomaly > cnt_normal이면 anomaly_flag를 올립니다.
//
// 감쇠 방식: cnt = cnt - (cnt >> 14) + spike
//   decay = 1 - 1/16384 = 0.99994
//   실효 윈도우 ≈ 16384 타임스텝 ≈ 1.02초 (@16kHz)
//   곱셈기 불필요 (시프트 + 뺄셈만)
//
// update=1 펄스가 올 때마다 (FSM의 done 신호)
// 두 카운터를 갱신하고 비교합니다.
// ============================================================

module anomaly_judge #(
    parameter CNT_WIDTH = 24,          // 카운터 비트폭
    parameter SHIFT_N   = 14           // 감쇠 시프트량 (실효 윈도우 조절)
)(
    input  wire        clk,
    input  wire        rst_n,

    // --- 입력 ---
    input  wire        spk_normal,     // Out0 스파이크 (정상)
    input  wire        spk_anomaly,    // Out1 스파이크 (이상)
    input  wire        update,         // 카운터 갱신 신호 (FSM done)

    // --- 출력 ---
    output wire        anomaly_flag,   // 1=이상 의심
    output wire [CNT_WIDTH-1:0] cnt_normal_out,   // 디버그용
    output wire [CNT_WIDTH-1:0] cnt_anomaly_out   // 디버그용
);

    // -------------------------------------------------------
    // Leaky Counter 레지스터
    // -------------------------------------------------------
    reg [CNT_WIDTH-1:0] cnt_normal;
    reg [CNT_WIDTH-1:0] cnt_anomaly;

    assign cnt_normal_out  = cnt_normal;
    assign cnt_anomaly_out = cnt_anomaly;

    // -------------------------------------------------------
    // 감쇠량 계산 (조합논리)
    // -------------------------------------------------------
    // leak = cnt >> SHIFT_N
    // 새 값 = cnt - leak + spike

    wire [CNT_WIDTH-1:0] leak_normal;
    wire [CNT_WIDTH-1:0] leak_anomaly;

    assign leak_normal  = cnt_normal  >> SHIFT_N;
    assign leak_anomaly = cnt_anomaly >> SHIFT_N;

    // -------------------------------------------------------
    // 카운터 갱신 (클럭 동기)
    // -------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt_normal  <= {CNT_WIDTH{1'b0}};
            cnt_anomaly <= {CNT_WIDTH{1'b0}};
        end else if (update) begin
            // 정상 카운터: 감쇠 + 새 스파이크
            cnt_normal  <= cnt_normal  - leak_normal  + {{(CNT_WIDTH-1){1'b0}}, spk_normal};
            // 이상 카운터: 감쇠 + 새 스파이크
            cnt_anomaly <= cnt_anomaly - leak_anomaly + {{(CNT_WIDTH-1){1'b0}}, spk_anomaly};
        end
    end

    // -------------------------------------------------------
    // 판정 (조합논리)
    // -------------------------------------------------------
    assign anomaly_flag = (cnt_anomaly > cnt_normal) ? 1'b1 : 1'b0;

endmodule
