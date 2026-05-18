// ============================================================
// spike_buffer.v — 은닉 스파이크 임시 저장
// ============================================================
// CLK 1~4에서 은닉 뉴런(H0~H3)의 스파이크를 한 비트씩 저장하고,
// CLK 5~6에서 출력층 MAC이 4비트를 한꺼번에 읽어갑니다.
//
// 시분할 구조이기 때문에 필요한 블록입니다.
// 만약 6뉴런을 병렬 처리했다면 이 버퍼는 불필요합니다.
// ============================================================

module spike_buffer (
    input  wire        clk,
    input  wire        rst_n,         // 비동기 리셋 (active low)

    // --- 쓰기: 은닉 뉴런 스파이크 저장 ---
    input  wire [1:0]  wr_idx,        // 저장할 위치 (0=H0, 1=H1, 2=H2, 3=H3)
    input  wire        wr_en,         // 쓰기 허가 (은닉층 처리 중에만 1)
    input  wire        spike_in,      // lif_core에서 온 스파이크 (1-bit)

    // --- 읽기: 4비트 한꺼번에 출력 ---
    output wire [3:0]  hid_spikes     // [0]=H0, [1]=H1, [2]=H2, [3]=H3
);

    // -------------------------------------------------------
    // 4-bit 레지스터
    // -------------------------------------------------------
    reg [3:0] buf_reg;

    assign hid_spikes = buf_reg;

    // -------------------------------------------------------
    // 쓰기 로직
    // -------------------------------------------------------
    // CLK 1: wr_idx=0, spike_in=H0 결과 → buf_reg[0]에 저장
    // CLK 2: wr_idx=1, spike_in=H1 결과 → buf_reg[1]에 저장
    // CLK 3: wr_idx=2, spike_in=H2 결과 → buf_reg[2]에 저장
    // CLK 4: wr_idx=3, spike_in=H3 결과 → buf_reg[3]에 저장
    // CLK 5~6: wr_en=0, 읽기만 (hid_spikes 유지)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            buf_reg <= 4'b0000;
        end else if (wr_en) begin
            buf_reg[wr_idx] <= spike_in;
        end
    end

endmodule
