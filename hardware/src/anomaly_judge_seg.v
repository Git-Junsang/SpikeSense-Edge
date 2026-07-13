// anomaly_judge_seg.v — 세그먼트 단위 이상 판정 (데모 전용, 신규)
//
// anomaly_judge_mult.v(전역 Leaky Counter)의 대안.
// 기존 Leaky Counter는 감쇠 1/16384라 한 번 올라간 카운터가 세그먼트가 바뀌어도
// 거의 안 내려와(래치 성격), "이상→정상→정상→이상" 같은 매 세그먼트 토글 데모에 부적합하다.
//
// 본 모듈은 트랙 버퍼(31타임스텝) 단위로 스파이크를 다수결한다:
//   - first(버퍼 첫 ts)에 누산기를 0에서 다시 시작
//   - 매 ts마다 spk_normal/spk_anomaly를 누적
//   - last(buf_done)에 anomaly_flag[track] = (acc_anomaly > acc_normal) 래치
//   → LED는 그 트랙의 가장 최근 완료 세그먼트 분류를 안정적으로 표시.
//
// 골든 hw_* 벡터에서 분리 마진이 커서(정상 29:2, 이상 0:31) 동점 없음.
// 참고: anomaly_judge_mult.v / mult_* 는 동결. 본 모듈은 신규.

`timescale 1ns/1ps

module anomaly_judge_seg #(
    parameter ACC_WIDTH = 8,    // 누산 폭 (최대 31스파이크 → 6비트면 충분, 여유 8)
    parameter N_TRACKS  = 64,
    parameter TRK_W     = 6
)(
    input  wire                 clk,
    input  wire                 rst_n,

    input  wire [TRK_W-1:0]     track,        // 갱신 대상 트랙 (cur_track_r)
    input  wire                 spk_normal,   // Out0 스파이크 (정상)
    input  wire                 spk_anomaly,  // Out1 스파이크 (이상)
    input  wire                 update,       // ts_done_r 펄스 (1타임스텝 완료)
    input  wire                 first,        // 이 ts가 버퍼의 첫 ts (first_ts_r) → 누산 리셋
    input  wire                 last,         // 이 ts가 버퍼의 마지막 ts (buf_done_r) → 플래그 래치

    output wire [N_TRACKS-1:0]  anomaly_flags // 트랙별 이상 플래그 (세그먼트 단위 래치)
);

    reg [ACC_WIDTH-1:0] acc_n [0:N_TRACKS-1];
    reg [ACC_WIDTH-1:0] acc_a [0:N_TRACKS-1];
    reg [N_TRACKS-1:0]  flags;

    // first면 0에서 시작, 아니면 기존 누적값에 더함
    wire [ACC_WIDTH-1:0] base_n = first ? {ACC_WIDTH{1'b0}} : acc_n[track];
    wire [ACC_WIDTH-1:0] base_a = first ? {ACC_WIDTH{1'b0}} : acc_a[track];
    wire [ACC_WIDTH-1:0] new_n  = base_n + {{(ACC_WIDTH-1){1'b0}}, spk_normal};
    wire [ACC_WIDTH-1:0] new_a  = base_a + {{(ACC_WIDTH-1){1'b0}}, spk_anomaly};

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (k = 0; k < N_TRACKS; k = k + 1) begin
                acc_n[k] <= {ACC_WIDTH{1'b0}};
                acc_a[k] <= {ACC_WIDTH{1'b0}};
            end
            flags <= {N_TRACKS{1'b0}};
        end else if (update) begin
            acc_n[track] <= new_n;
            acc_a[track] <= new_a;
            if (last)
                flags[track] <= (new_a > new_n) ? 1'b1 : 1'b0;
        end
    end

    assign anomaly_flags = flags;

endmodule
