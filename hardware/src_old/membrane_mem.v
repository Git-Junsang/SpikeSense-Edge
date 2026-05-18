// ============================================================
// membrane_mem.v — 막전위 레지스터 파일 (6뉴런)
// ============================================================
// H0, H1, H2, H3, Out0, Out1 총 6개 뉴런의 막전위를 저장합니다.
// FSM이 neuron_idx로 주소를 지정하면,
// 해당 뉴런의 막전위를 읽거나 새 값을 씁니다.
//
// 읽기: 조합논리 (주소 넣으면 바로 출력)
// 쓰기: 클럭 상승 에지에서 wr_en=1일 때
// ============================================================

module membrane_mem #(
    parameter MEM_WIDTH  = 16,         // 막전위 비트폭
    parameter N_NEURONS  = 6           // 뉴런 수 (H0~H3 + Out0~Out1)
)(
    input  wire                         clk,
    input  wire                         rst_n,       // 비동기 리셋 (active low)

    // --- FSM 제어 ---
    input  wire [2:0]                   neuron_idx,  // 뉴런 주소 (0~5)
    input  wire                         wr_en,       // 쓰기 허가

    // --- 데이터 ---
    input  wire signed [MEM_WIDTH-1:0]  mem_in,      // lif_core에서 온 새 막전위
    output wire signed [MEM_WIDTH-1:0]  mem_out      // lif_core로 보낼 이전 막전위
);

    // -------------------------------------------------------
    // 레지스터 배열: 6개 뉴런의 막전위
    // -------------------------------------------------------
    // idx 0: H0 (β=0.70)
    // idx 1: H1 (β=0.80)
    // idx 2: H2 (β=0.90)
    // idx 3: H3 (β=0.95)
    // idx 4: Out0 (정상)
    // idx 5: Out1 (이상)
    reg signed [MEM_WIDTH-1:0] mem_reg [0:N_NEURONS-1];

    // -------------------------------------------------------
    // 읽기: 조합논리 (주소 → 즉시 출력)
    // -------------------------------------------------------
    assign mem_out = mem_reg[neuron_idx];

    // -------------------------------------------------------
    // 쓰기: 클럭 에지, wr_en=1일 때
    // -------------------------------------------------------
    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // 리셋: 모든 막전위를 0으로 초기화
            for (k = 0; k < N_NEURONS; k = k + 1) begin
                mem_reg[k] <= {MEM_WIDTH{1'b0}};
            end
        end else if (wr_en) begin
            mem_reg[neuron_idx] <= mem_in;
        end
    end

endmodule
