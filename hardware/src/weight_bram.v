// weight_bram.v — 9,280×8bit 가중치 BRAM
//
// W1/W2/W3를 단일 메모리에 연속 배치 (모두 row-major):
//   [   0 ~ 5119]: W1 (128뉴런 × 40입력)
//   [5120 ~ 9215]: W2 ( 32뉴런 × 128입력)
//   [9216 ~ 9279]: W3 (  2뉴런 × 32입력)
//
// 주소 계산은 FSM 담당:
//   L1: addr = n*40 + j          (n 0~127, j 0~39)
//   L2: addr = 5120 + n*128 + j  (n 0~31,  j 0~127)
//   L3: addr = 9216 + n*32  + j  (n 0~1,   j 0~31)
//
// 읽기: 클럭 상승 에지에 주소 래치, 다음 클럭에 data 출력 (1사이클 지연)

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

    // hex 경로: 시뮬레이션(iverilog/Vivado sim)은 저장소 루트 기준 상대경로,
    // Vivado 합성은 working dir이 다르므로 파일명만 사용 (hex를 프로젝트 소스로
    // 추가하면 Vivado가 소스 디렉토리에서 basename으로 탐색).
    // SYNTHESIS 매크로는 합성 run에서만 정의된다 (create_project.tcl 참조).
    initial begin
`ifdef SYNTHESIS
        $readmemh("w1.hex", mem,    0, 5119);
        $readmemh("w2.hex", mem, 5120, 9215);
        $readmemh("w3.hex", mem, 9216, 9279);
`else
        $readmemh("hardware/src/weights/w1.hex", mem,    0, 5119);
        $readmemh("hardware/src/weights/w2.hex", mem, 5120, 9215);
        $readmemh("hardware/src/weights/w3.hex", mem, 9216, 9279);
`endif
    end

    always @(posedge clk) begin
        data <= mem[addr];
    end

endmodule
