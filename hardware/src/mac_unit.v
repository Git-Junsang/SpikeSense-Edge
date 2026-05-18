// ============================================================
// mac_unit.v — INT8×INT8 직렬 누적 MAC
// ============================================================
// FSM이 매 클럭마다 (a, b) 쌍을 제공하면 a×b를 누적합니다.
//
// 레이어별 사용 방식:
//   L1 (mel 입력): a=mel_int8(signed), b=W1_int8(signed)
//                  40클럭 누적 후 shift_en=1 → current = acc>>>7
//   L2 (spike):    a=spike?8'sd1:8'sd0, b=W2_int8(signed)
//                  128클럭 누적, shift_en=0 → current = acc[15:0]
//   L3 (spike):    a=spike?8'sd1:8'sd0, b=W3_int8(signed)
//                  32클럭 누적, shift_en=0 → current = acc[15:0]
//
// 누적기: 24-bit signed
//   L1 최대: 40 × 127 × 127 = 645,160 < 2^20  → 24-bit 충분
//   L2 최대: 128 × 127     = 16,256  < 2^15  → 16-bit에 수용
//   L3 최대: 32 × 127      = 4,064   < 2^12  → 16-bit에 수용
// ============================================================

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

    // -------------------------------------------------------
    // 8×8 → 16-bit 곱셈 (signed)
    // -------------------------------------------------------
    wire signed [DATA_WIDTH*2-1:0] product;
    assign product = a * b;

    // -------------------------------------------------------
    // 24-bit 부호 있는 누적기
    // -------------------------------------------------------
    reg signed [ACC_WIDTH-1:0] acc;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            acc <= {ACC_WIDTH{1'b0}};
        else if (clear)
            acc <= {ACC_WIDTH{1'b0}};
        else if (en)
            acc <= acc + {{(ACC_WIDTH-DATA_WIDTH*2){product[DATA_WIDTH*2-1]}}, product};
    end

    // -------------------------------------------------------
    // 출력: L1은 산술 우측시프트 >>7, L2/L3는 하위 16-bit 직접
    // -------------------------------------------------------
    wire signed [ACC_WIDTH-1:0] acc_shifted;
    assign acc_shifted = acc >>> L1_SHIFT; // 부호 보존 산술 시프트

    assign current = shift_en ? acc_shifted[15:0] : acc[15:0];

endmodule
