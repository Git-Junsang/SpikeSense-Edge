// ============================================================
// mac_unit.v — 스파이크 게이트 누적기
// ============================================================
// 스파이크가 1-bit이므로 실제 곱셈 없이,
// spike=1이면 해당 가중치를 더하고, 0이면 무시합니다.
//
// 은닉층 처리 시: spike_in[9:0]  × weight 10개 → current
// 출력층 처리 시: spike_in[3:0]  × weight 4개  → current
// layer_sel로 구분합니다.
//
// 전부 조합논리(combinational)로 1클럭 안에 완료됩니다.
// ============================================================

module mac_unit #(
    parameter W_WIDTH = 8              // 가중치 비트폭 (INT8)
)(
    // --- 입력 ---
    input  wire [9:0]            spike_in,   // 스파이크 입력 (1-bit × 10채널)
    input  wire [10*W_WIDTH-1:0] weights,    // 가중치 10개 (flat bus)
    input  wire                  layer_sel,  // 0=은닉층(10입력), 1=출력층(4입력)

    // --- 출력 ---
    output reg signed [15:0]     current     // 합산된 입력 전류
);

    // -------------------------------------------------------
    // 내부 신호: 각 가중치를 개별적으로 꺼내기
    // -------------------------------------------------------
    wire signed [W_WIDTH-1:0] w [0:9];

    // flat bus를 개별 가중치로 분리
    genvar i;
    generate
        for (i = 0; i < 10; i = i + 1) begin : UNPACK
            assign w[i] = weights[i*W_WIDTH +: W_WIDTH];
        end
    endgenerate

    // -------------------------------------------------------
    // 스파이크 게이트 합산 (조합논리)
    // -------------------------------------------------------
    // spike=1이면 해당 가중치를 더하고, 0이면 0을 더합니다.
    // 곱셈기(DSP) 없이 MUX + 덧셈만으로 구현됩니다.

    wire signed [15:0] gated [0:9];

    generate
        for (i = 0; i < 10; i = i + 1) begin : GATE
            // spike가 1이면 가중치를 16-bit로 부호 확장, 0이면 0
            assign gated[i] = spike_in[i] ? {{(16-W_WIDTH){w[i][W_WIDTH-1]}}, w[i]}
                                          : 16'sd0;
        end
    endgenerate

    // -------------------------------------------------------
    // 합산
    // -------------------------------------------------------
    // 은닉층: 10개 전부 합산
    // 출력층: 4개만 합산 (나머지는 snn_top에서 spike_in[9:4]=0으로 보냄)

    always @(*) begin
        if (layer_sel == 1'b0) begin
            // 은닉층: 10개 합산
            current = gated[0] + gated[1] + gated[2] + gated[3] + gated[4]
                    + gated[5] + gated[6] + gated[7] + gated[8] + gated[9];
        end else begin
            // 출력층: 4개만 합산
            current = gated[0] + gated[1] + gated[2] + gated[3];
        end
    end

endmodule
