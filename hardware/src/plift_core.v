// plift_core.v — PLIF-T 뉴런 연산 코어 (전체 조합논리)
//
// lif_core.v 확장: β와 V_th를 런타임 입력으로 받아 뉴런별 학습 파라미터 지원.
//
// 연산 순서:
//   1) 누설    decayed = (beta × mem_in) >>> 8   (Q0.8 스케일 복원)
//   2) 적분    mem_new = decayed + current
//   3) 발화    spike = (mem_new >= vth_ext)
//   4) 소프트 리셋  mem_out = spike ? (mem_new - vth_ext) : mem_new
//
// beta: Q0.8 uint8 (0~255 → 0.0~0.996), vth: INT8 양수 (7~109, zero-extend), 막전위: 16-bit signed

module plift_core #(
    parameter MEM_WIDTH  = 16,
    parameter BETA_WIDTH = 8
)(
    input  wire signed [MEM_WIDTH-1:0]  current,  // MAC에서 온 입력 전류
    input  wire signed [MEM_WIDTH-1:0]  mem_in,   // 이전 막전위 (membrane_mem에서)
    input  wire        [BETA_WIDTH-1:0] beta,     // 감쇠 계수 Q0.8 uint8
    input  wire        [BETA_WIDTH-1:0] vth,      // 발화 임계값 INT8 (항상 양수)

    output wire                         spike,
    output wire signed [MEM_WIDTH-1:0]  mem_out
);

    // 누설: (beta × mem_in) >> 8
    // {1'b0, beta}로 9-bit 양수 만든 뒤 signed 곱. 최대 255×32767 < 2^23이라 24-bit면 충분.
    wire signed [MEM_WIDTH+BETA_WIDTH-1:0] product;
    wire signed [MEM_WIDTH-1:0]            decayed;

    assign product = $signed({1'b0, beta}) * mem_in;
    assign decayed = product[MEM_WIDTH+BETA_WIDTH-1 : BETA_WIDTH]; // >> 8

    // 적분
    wire signed [MEM_WIDTH-1:0] mem_new;
    assign mem_new = decayed + current;

    // 발화 판정 (vth를 16-bit로 zero-extend, 항상 양수)
    wire signed [MEM_WIDTH-1:0] vth_ext;
    assign vth_ext = {{(MEM_WIDTH-BETA_WIDTH){1'b0}}, vth};

    assign spike = (mem_new >= vth_ext) ? 1'b1 : 1'b0;

    // 소프트 리셋
    assign mem_out = spike ? (mem_new - vth_ext) : mem_new;

endmodule
