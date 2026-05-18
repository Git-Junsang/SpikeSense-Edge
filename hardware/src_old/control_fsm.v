// ============================================================
// control_fsm.v — 6-상태 시퀀서
// ============================================================
// 새 스파이크가 도착하면 (start=1),
// H0 → H1 → H2 → H3 → Out0 → Out1 순서로
// 6클럭에 걸쳐 뉴런을 순차 처리합니다.
//
// 매 클럭마다 해당 뉴런의 주소, β, 제어 신호를 출력합니다.
// 6클럭이 끝나면 done=1을 출력하고 IDLE로 돌아갑니다.
// ============================================================

module control_fsm (
    input  wire        clk,
    input  wire        rst_n,

    // --- 시작 신호 ---
    input  wire        start,       // 새 타임스텝 시작 (level_crossing_enc의 spike_valid)

    // --- 뉴런 제어 출력 ---
    output reg  [2:0]  neuron_idx,  // 0~5: H0~H3, Out0, Out1
    output reg         layer_sel,   // 0=은닉층, 1=출력층
    output reg  [7:0]  beta,        // 해당 뉴런의 감쇠 계수 (Q0.8)

    // --- 쓰기 제어 출력 ---
    output reg         mem_wr_en,   // membrane_mem 쓰기 허가
    output reg         buf_wr_en,   // spike_buffer 쓰기 허가 (은닉층만)

    // --- 상태 출력 ---
    output reg         busy,        // 처리 중 (IDLE이 아닐 때)
    output reg         done         // 6클럭 처리 완료 (1클럭 펄스)
);

    // -------------------------------------------------------
    // β 상수 (Q0.8)
    // -------------------------------------------------------
    localparam [7:0] BETA_H0  = 8'd179;   // 0.70
    localparam [7:0] BETA_H1  = 8'd205;   // 0.80
    localparam [7:0] BETA_H2  = 8'd230;   // 0.90
    localparam [7:0] BETA_H3  = 8'd243;   // 0.95
    localparam [7:0] BETA_OUT = 8'd217;   // 0.85

    // -------------------------------------------------------
    // 상태 정의
    // -------------------------------------------------------
    localparam [2:0] S_IDLE = 3'd0;
    localparam [2:0] S_H0   = 3'd1;
    localparam [2:0] S_H1   = 3'd2;
    localparam [2:0] S_H2   = 3'd3;
    localparam [2:0] S_H3   = 3'd4;
    localparam [2:0] S_OUT0 = 3'd5;
    localparam [2:0] S_OUT1 = 3'd6;
    localparam [2:0] S_DONE = 3'd7;

    reg [2:0] state;

    // -------------------------------------------------------
    // 상태 천이
    // -------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
        end else begin
            case (state)
                S_IDLE: state <= start ? S_H0 : S_IDLE;
                S_H0:   state <= S_H1;
                S_H1:   state <= S_H2;
                S_H2:   state <= S_H3;
                S_H3:   state <= S_OUT0;
                S_OUT0: state <= S_OUT1;
                S_OUT1: state <= S_DONE;
                S_DONE: state <= S_IDLE;
                default: state <= S_IDLE;
            endcase
        end
    end

    // -------------------------------------------------------
    // 출력 로직
    // -------------------------------------------------------
    always @(*) begin
        // 기본값
        neuron_idx = 3'd0;
        layer_sel  = 1'b0;
        beta       = 8'd0;
        mem_wr_en  = 1'b0;
        buf_wr_en  = 1'b0;
        busy       = 1'b0;
        done       = 1'b0;

        case (state)
            S_H0: begin
                neuron_idx = 3'd0;
                layer_sel  = 1'b0;
                beta       = BETA_H0;
                mem_wr_en  = 1'b1;
                buf_wr_en  = 1'b1;
                busy       = 1'b1;
            end
            S_H1: begin
                neuron_idx = 3'd1;
                layer_sel  = 1'b0;
                beta       = BETA_H1;
                mem_wr_en  = 1'b1;
                buf_wr_en  = 1'b1;
                busy       = 1'b1;
            end
            S_H2: begin
                neuron_idx = 3'd2;
                layer_sel  = 1'b0;
                beta       = BETA_H2;
                mem_wr_en  = 1'b1;
                buf_wr_en  = 1'b1;
                busy       = 1'b1;
            end
            S_H3: begin
                neuron_idx = 3'd3;
                layer_sel  = 1'b0;
                beta       = BETA_H3;
                mem_wr_en  = 1'b1;
                buf_wr_en  = 1'b1;
                busy       = 1'b1;
            end
            S_OUT0: begin
                neuron_idx = 3'd4;
                layer_sel  = 1'b1;
                beta       = BETA_OUT;
                mem_wr_en  = 1'b1;
                buf_wr_en  = 1'b0;   // 출력층은 버퍼 안 씀
                busy       = 1'b1;
            end
            S_OUT1: begin
                neuron_idx = 3'd5;
                layer_sel  = 1'b1;
                beta       = BETA_OUT;
                mem_wr_en  = 1'b1;
                buf_wr_en  = 1'b0;
                busy       = 1'b1;
            end
            S_DONE: begin
                done = 1'b1;
            end
            default: ; // S_IDLE: 모든 출력 기본값
        endcase
    end

endmodule
