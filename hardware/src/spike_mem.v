// spike_mem.v — 레이어별 스파이크 임시 저장
//
// 저장 구조:
//   l1_spikes[127:0]: L1 128뉴런 스파이크 (L2 MAC 입력)
//   l2_spikes[ 31:0]: L2  32뉴런 스파이크 (L3 MAC 입력)
//   L3 스파이크(2-bit)는 anomaly_judge로 직결하므로 저장 안 함.
//
// 쓰기: FSM이 각 뉴런 처리 후 wr_en=1로 해당 비트 갱신
// 읽기: 조합논리 (전체 버스)
// clear: 타임스텝 시작 시 FSM이 동기 초기화

module spike_mem (
    input  wire        clk,
    input  wire        rst_n,     // 비동기 리셋 (active low)
    input  wire        clear,     // 동기 초기화 (타임스텝 경계)

    // --- 쓰기 인터페이스 ---
    input  wire        wr_en,
    input  wire        wr_layer,  // 0=L1(128bit), 1=L2(32bit)
    input  wire [6:0]  wr_idx,    // L1: 0~127, L2: 0~31
    input  wire        spike_in,

    // --- 읽기: 전체 버스 출력 (조합논리) ---
    output wire [127:0] l1_spikes,
    output wire [31:0]  l2_spikes
);

    reg [127:0] l1_reg;
    reg [31:0]  l2_reg;

    assign l1_spikes = l1_reg;
    assign l2_spikes = l2_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            l1_reg <= 128'b0;
            l2_reg <=  32'b0;
        end else if (clear) begin
            l1_reg <= 128'b0;
            l2_reg <=  32'b0;
        end else if (wr_en) begin
            if (wr_layer == 1'b0)
                l1_reg[wr_idx]       <= spike_in;  // wr_idx: 0~127
            else
                l2_reg[wr_idx[4:0]]  <= spike_in;  // wr_idx[4:0]: 0~31
        end
    end

endmodule
