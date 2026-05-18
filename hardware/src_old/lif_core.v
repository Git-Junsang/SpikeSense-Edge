// ============================================================
// lif_core.v — 공유 LIF 뉴런 연산 코어
// ============================================================
// 6개 뉴런이 시분할로 이 모듈을 공유합니다.
// FSM이 매 클럭마다 beta, mem_in, current를 바꿔주면
// 이 모듈은 항상 같은 연산만 수행합니다:
//
//   1) 누설: decayed = (beta × mem_in) >>> 8
//   2) 적분: mem_new = decayed + current
//   3) 발화: mem_new >= threshold → spike = 1
//   4) 리셋: mem_out = mem_new - threshold (Soft Reset)
//
// beta는 Q0.8 (unsigned 8-bit, 0~255 → 0.0~0.996)
// 막전위는 16-bit signed
// ============================================================

module lif_core #(
    parameter MEM_WIDTH = 16,          // 막전위 비트폭
    parameter BETA_WIDTH = 8,          // 감쇠 계수 비트폭 (Q0.8)
    parameter signed [MEM_WIDTH-1:0] THRESHOLD = 16'sd256  // 임계값 (조정 가능)
)(
    // --- 입력 ---
    input  wire signed [MEM_WIDTH-1:0]  current,   // MAC에서 온 입력 전류
    input  wire signed [MEM_WIDTH-1:0]  mem_in,    // 이전 막전위 (membrane_mem에서)
    input  wire [BETA_WIDTH-1:0]        beta,      // 감쇠 계수 (Q0.8)

    // --- 출력 ---
    output wire                         spike,     // 발화 여부 (1-bit)
    output wire signed [MEM_WIDTH-1:0]  mem_out    // 새 막전위 (membrane_mem으로)
);

    // -------------------------------------------------------
    // ① 누설 (Leak): beta × mem_in
    // -------------------------------------------------------
    // beta(Q0.8, unsigned 8-bit) × mem_in(signed 16-bit)
    // 결과: signed 24-bit → 8비트 산술 우측 시프트 → 16-bit
    //
    // 예: beta=0.70 → 179
    //     mem_in = 300
    //     product = 179 × 300 = 53700
    //     decayed = 53700 >>> 8 = 209 (≈ 0.70 × 300)

    wire signed [MEM_WIDTH+BETA_WIDTH-1:0] product;
    wire signed [MEM_WIDTH-1:0] decayed;

    // beta를 signed로 변환 (MSB에 0 추가 → 항상 양수)
    assign product = $signed({1'b0, beta}) * mem_in;

    // 8비트 산술 우측 시프트로 Q0.8 스케일 복원
    // product[23:8] = product >> 8 (Q0.8 나눗셈)
    // ※ 수정 전 product[22:7]이었음 → >>7이라 β가 2배로 동작하는 버그
    assign decayed = product[MEM_WIDTH+BETA_WIDTH-1 : BETA_WIDTH];

    // -------------------------------------------------------
    // ② 적분 (Integrate): decayed + current
    // -------------------------------------------------------
    wire signed [MEM_WIDTH-1:0] mem_new;
    assign mem_new = decayed + current;

    // -------------------------------------------------------
    // ③ 발화 판정 (Fire): mem_new >= threshold
    // -------------------------------------------------------
    assign spike = (mem_new >= THRESHOLD) ? 1'b1 : 1'b0;

    // -------------------------------------------------------
    // ④ Soft Reset: spike 시 임계값만큼 차감, 초과분 보존
    // -------------------------------------------------------
    // spike=1: mem_out = mem_new - threshold
    // spike=0: mem_out = mem_new (변화 없음)
    assign mem_out = spike ? (mem_new - THRESHOLD) : mem_new;

endmodule
