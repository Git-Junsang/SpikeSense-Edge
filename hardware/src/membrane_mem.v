// ============================================================
// membrane_mem.v — 162뉴런 막전위 레지스터 파일 (16-bit)
// ============================================================
// src_old/membrane_mem.v 확장: 6뉴런 → 162뉴런
//
// 인덱스 구조 (neuron_idx 0~161):
//   [  0 ~ 127]: L1 128뉴런
//   [128 ~ 159]: L2  32뉴런
//   [160 ~ 161]: L3   2뉴런
//
// 막전위는 타임스텝 간 유지 (SNN 누설-적분 동작).
// 새 버퍼가 시작될 때 FSM이 rst_n 또는 별도 frame_rst로 초기화.
//
// 읽기: 조합논리 (주소 → 즉시 출력)
// 쓰기: clk 상승 에지, wr_en=1
// ============================================================

module membrane_mem #(
    parameter MEM_WIDTH = 16,
    parameter N_NEURONS = 162
)(
    input  wire                         clk,
    input  wire                         rst_n,      // 비동기 리셋 (active low)

    input  wire [7:0]                   neuron_idx, // 0~161
    input  wire                         wr_en,      // 쓰기 허가

    input  wire signed [MEM_WIDTH-1:0]  mem_in,     // plift_core에서 온 새 막전위
    output wire signed [MEM_WIDTH-1:0]  mem_out     // plift_core로 보낼 이전 막전위
);

    reg signed [MEM_WIDTH-1:0] mem_reg [0:N_NEURONS-1];

    // 조합논리 읽기
    assign mem_out = mem_reg[neuron_idx];

    // 클럭 동기 쓰기 + 비동기 리셋
    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (k = 0; k < N_NEURONS; k = k + 1)
                mem_reg[k] <= {MEM_WIDTH{1'b0}};
        end else if (wr_en) begin
            mem_reg[neuron_idx] <= mem_in;
        end
    end

endmodule
