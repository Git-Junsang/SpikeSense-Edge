// ============================================================
// param_rom.v — β(162개) + V_th(162개) 파라미터 ROM
// ============================================================
// 뉴런별 학습 파라미터를 저장하는 읽기 전용 메모리.
//
// 인덱스 구조 (neuron_idx 0~161):
//   [  0 ~ 127]: L1 (128뉴런, fc1→hidden1_lif)
//   [128 ~ 159]: L2 ( 32뉴런, fc2→hidden2_lif)
//   [160 ~ 161]: L3 (  2뉴런, fc3→output_lif)
//
// beta : Q0.8 uint8  → float_beta = beta_q / 256
//        HW 연산: decayed = (beta_q × mem) >> 8
// vth  : INT8 양의 정수 (범위 7~109)
//        HW 비교: mem_new >= {8'b0, vth}
//
// 읽기: 조합논리 (1사이클 지연 없음)
// ============================================================

module param_rom #(
    parameter N_NEURONS = 162
)(
    input  wire [7:0]           neuron_idx, // 0~161

    output wire [7:0]           beta,       // Q0.8 uint8
    output wire [7:0]           vth         // INT8 양의 정수 (unsigned 저장)
);

    reg [7:0] beta_mem [0:N_NEURONS-1];
    reg [7:0] vth_mem  [0:N_NEURONS-1];

    initial begin
        $readmemh("hardware/src/weights/beta.hex", beta_mem);
        $readmemh("hardware/src/weights/vth.hex",  vth_mem);
    end

    // 조합논리 읽기
    assign beta = beta_mem[neuron_idx];
    assign vth  = vth_mem[neuron_idx];

endmodule
