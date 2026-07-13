// anomaly_judge_mult.v — 다중 트랙 Leaky Counter 이상 판정 (시분할용)
//
// 단일채널 anomaly_judge.v의 다중 트랙 확장판. 트랙별 (cnt_normal, cnt_anomaly) 유지.
//   감쇠: cnt = cnt - (cnt >> SHIFT_N) + spike   (곱셈 불필요)
//   update=1(ts_done_r) 시 track 카운터를 read-modify-write.
// 카운터는 전역 리셋에서만 0으로 초기화되고 버퍼 경계와 무관하게 연속
// 누적된다(원본과 동일한 leaky 적분 동작).
// anomaly_flags[t] = (cnt_anomaly[t] > cnt_normal[t])  (조합)

`timescale 1ns/1ps

module anomaly_judge_mult #(
    parameter CNT_WIDTH = 24,
    parameter SHIFT_N   = 14,
    parameter N_TRACKS  = 64,
    parameter TRK_W     = 6
)(
    input  wire                 clk,
    input  wire                 rst_n,

    input  wire [TRK_W-1:0]     track,        // 갱신 대상 트랙 (cur_track_r)
    input  wire                 spk_normal,   // Out0 스파이크 (정상)
    input  wire                 spk_anomaly,  // Out1 스파이크 (이상)
    input  wire                 update,       // ts_done_r 펄스

    output wire [N_TRACKS-1:0]  anomaly_flags // 트랙별 이상 플래그
);

    reg [CNT_WIDTH-1:0] cnt_n [0:N_TRACKS-1];
    reg [CNT_WIDTH-1:0] cnt_a [0:N_TRACKS-1];

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (k = 0; k < N_TRACKS; k = k + 1) begin
                cnt_n[k] <= {CNT_WIDTH{1'b0}};
                cnt_a[k] <= {CNT_WIDTH{1'b0}};
            end
        end else if (update) begin
            cnt_n[track] <= cnt_n[track] - (cnt_n[track] >> SHIFT_N)
                            + {{(CNT_WIDTH-1){1'b0}}, spk_normal};
            cnt_a[track] <= cnt_a[track] - (cnt_a[track] >> SHIFT_N)
                            + {{(CNT_WIDTH-1){1'b0}}, spk_anomaly};
        end
    end

    genvar g;
    generate
        for (g = 0; g < N_TRACKS; g = g + 1) begin : FLAG
            assign anomaly_flags[g] = (cnt_a[g] > cnt_n[g]) ? 1'b1 : 1'b0;
        end
    endgenerate

endmodule
