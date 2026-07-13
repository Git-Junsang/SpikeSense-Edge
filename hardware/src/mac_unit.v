// mac_unit.v — INT8×INT8 직렬 누적 MAC
//
// FSM이 매 클럭 (a, b) 쌍을 주면 a×b를 누적한다.
//
// 레이어별 사용:
//   L1 (mel 입력): a=mel_int8, b=W1  / 40클럭 누적, shift_en=1 → current = acc>>>7
//   L2 (spike):    a=spike(0/1), b=W2 / 128클럭 누적, shift_en=0 → current = acc[15:0]
//   L3 (spike):    a=spike(0/1), b=W3 /  32클럭 누적, shift_en=0 → current = acc[15:0]
//
// 누적기 24-bit signed. 최대치: L1 40×127×127=645,160(<2^20), L2 128×127=16,256, L3 32×127=4,064
// → L2/L3는 하위 16-bit로 손실 없이 수용.

module mac_unit #(
    parameter DATA_WIDTH = 8,
    parameter ACC_WIDTH  = 24,
    parameter L1_SHIFT   = 7
)(
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          clear,    // 동기 초기화 (뉴런 전환 시)
    input  wire                          en,       // 1=이번 클럭에 a×b 누적
    input  wire signed [DATA_WIDTH-1:0]  a,        // mel_int8 또는 spike(8'sd0/1)
    input  wire signed [DATA_WIDTH-1:0]  b,        // 가중치 INT8
    input  wire                          shift_en, // 1=L1(>>>7), 0=L2/L3(그대로)

    output wire signed [15:0]            current   // 누적 결과 (plift_core로)
);

    // 8×8 → 16-bit signed 곱
    wire signed [DATA_WIDTH*2-1:0] product;
    assign product = a * b;

    // 24-bit signed 누적기
    reg signed [ACC_WIDTH-1:0] acc;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            acc <= {ACC_WIDTH{1'b0}};
        else if (clear)
            acc <= {ACC_WIDTH{1'b0}};
        else if (en)
            acc <= acc + {{(ACC_WIDTH-DATA_WIDTH*2){product[DATA_WIDTH*2-1]}}, product};
    end

    // 출력: L1은 산술 우측시프트 >>7, L2/L3는 하위 16-bit 직접
    wire signed [ACC_WIDTH-1:0] acc_shifted;
    assign acc_shifted = acc >>> L1_SHIFT; // 부호 보존

    assign current = shift_en ? acc_shifted[15:0] : acc[15:0];

endmodule
