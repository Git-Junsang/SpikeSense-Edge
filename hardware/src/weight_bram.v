// ============================================================
// weight_bram.v — 9,280×8bit 가중치 BRAM
// ============================================================
// W1/W2/W3를 단일 메모리에 연속 배치:
//   주소 [    0 ~  5119]: W1 (128뉴런 × 40입력, row-major)
//   주소 [ 5120 ~  9215]: W2 ( 32뉴런 × 128입력, row-major)
//   주소 [ 9216 ~  9279]: W3 (  2뉴런 ×  32입력, row-major)
//
// 주소 계산 (FSM 담당):
//   L1: 뉴런 n(0~127), 입력 j(0~39)   → addr = n*40 + j
//   L2: 뉴런 n(0~31),  입력 j(0~127)  → addr = 5120 + n*128 + j
//   L3: 뉴런 n(0~1),   입력 j(0~31)   → addr = 9216 + n*32  + j
//
// 읽기: 클럭 상승 에지에서 주소 래치 → 다음 클럭에 data 출력 (1사이클 지연)
// ============================================================

module weight_bram #(
    parameter DEPTH     = 9280,
    parameter DATA_WIDTH = 8,
    parameter ADDR_WIDTH = 14  // ceil(log2(9280)) = 14
)(
    input  wire                     clk,
    input  wire [ADDR_WIDTH-1:0]    addr,
    output reg  signed [DATA_WIDTH-1:0] data  // INT8 가중치 (1사이클 지연)
);

    reg signed [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    initial begin
        $readmemh("hardware/src/weights/w1.hex", mem,    0, 5119);
        $readmemh("hardware/src/weights/w2.hex", mem, 5120, 9215);
        $readmemh("hardware/src/weights/w3.hex", mem, 9216, 9279);
    end

    always @(posedge clk) begin
        data <= mem[addr];
    end

endmodule
