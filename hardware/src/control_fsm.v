// ============================================================
// control_fsm.v — 3레이어 PLIF-T SNN 시퀀서 FSM
// ============================================================
// 동작:
//   frame_valid=1 → mel 래치 → (버퍼 첫 프레임이면 membrane reset)
//   → spike_mem clear → L1(128뉴런,40입력) → L2(32뉴런,128입력)
//   → L3(2뉴런,32입력) → 다음 frame_valid 대기
//   → 31 타임스텝 반복 후 done=1
//
// 타이밍 (뉴런당):
//   fan_cnt=0          : mac_clear=1, BRAM prefetch (addr=base+0)
//   fan_cnt=1..FAN_IN  : mac_en=1, BRAM data = W[base+fan_cnt-1]
//   fan_cnt=FAN_IN+1   : mem_wr_en=1 (write-back, plift_core 결과 저장)
//
// L1_SHIFT=7 (mac_shift_en=1), L2/L3 shift 없음
// ============================================================

`timescale 1ns/1ps

module control_fsm #(
    parameter TS_TOTAL = 31
)(
    input  wire       clk,
    input  wire       rst_n,

    input  wire       frame_valid,

    // 레이어/뉴런/fan 카운터 (snn_top에서 주소·데이터 생성에 사용)
    output reg  [1:0] layer,        // 0=L1, 1=L2, 2=L3
    output reg  [7:0] neuron_cnt,   // 레이어 내 뉴런 번호
    output reg  [7:0] fan_cnt,      // 0=clear/prefetch, 1..FAN=MAC, FAN+1=writeback

    // MAC 제어
    output wire       mac_clear,
    output wire       mac_en,
    output wire       mac_shift_en, // 1=L1(>>>7), 0=L2/L3

    // 메모리 쓰기 제어
    output wire       mem_wr_en,    // membrane_mem 쓰기 (매 뉴런 write-back)
    output wire       spike_wr_en,  // spike_mem 쓰기 (L1/L2만)
    output wire       spike_clear,  // spike_mem 동기 초기화 (타임스텝 시작)
    output wire       mem_rst_pulse,// membrane_mem 비동기 reset 트리거 (버퍼 경계)

    // 상태
    output wire       ts_done,      // 1타임스텝 완료 (1클럭 펄스, snn_top에서 1cy 지연 후 anomaly_judge.update)
    output wire       done,         // 31 타임스텝 완료 (1클럭 펄스)
    output wire       busy
);

    // -------------------------------------------------------
    // 레이어별 상수
    // -------------------------------------------------------
    localparam [7:0] FAN_L1 = 8'd40;
    localparam [7:0] FAN_L2 = 8'd128;
    localparam [7:0] FAN_L3 = 8'd32;
    localparam [7:0] N_L1   = 8'd128;  // L1 뉴런 수
    localparam [7:0] N_L2   = 8'd32;
    localparam [7:0] N_L3   = 8'd2;

    // -------------------------------------------------------
    // 상태 인코딩
    // -------------------------------------------------------
    localparam [2:0] S_IDLE     = 3'd0;
    localparam [2:0] S_MEM_RST  = 3'd1; // 1클럭: membrane_mem reset (버퍼 첫 프레임)
    localparam [2:0] S_SPK_CLR  = 3'd2; // 1클럭: spike_mem clear
    localparam [2:0] S_LAYER    = 3'd3; // L1/L2/L3 공용 (layer로 구분)
    localparam [2:0] S_BUF_DONE = 3'd4; // 1클럭: done=1

    reg [2:0] state;
    reg [4:0] ts_cnt; // 0..30

    // -------------------------------------------------------
    // 레이어별 파라미터 (조합논리)
    // -------------------------------------------------------
    wire [7:0] fan_max = (layer == 2'd0) ? FAN_L1 :
                         (layer == 2'd1) ? FAN_L2 : FAN_L3;
    wire [7:0] n_max   = (layer == 2'd0) ? N_L1 - 8'd1 :
                         (layer == 2'd1) ? N_L2 - 8'd1 : N_L3 - 8'd1;
    wire       wback   = (fan_cnt == fan_max + 8'd1);

    // -------------------------------------------------------
    // 출력 (조합논리)
    // -------------------------------------------------------
    assign mac_clear     = (state == S_LAYER) && (fan_cnt == 8'd0);
    assign mac_en        = (state == S_LAYER) && (fan_cnt >= 8'd1) && !wback;
    assign mac_shift_en  = (layer == 2'd0);
    assign mem_wr_en     = (state == S_LAYER) && wback;
    assign spike_wr_en   = mem_wr_en && (layer != 2'd2);
    assign spike_clear   = (state == S_SPK_CLR);
    assign mem_rst_pulse = (state == S_MEM_RST);
    assign ts_done       = mem_wr_en && (layer == 2'd2) && (neuron_cnt == n_max);
    assign done          = (state == S_BUF_DONE);
    assign busy          = (state != S_IDLE);

    // -------------------------------------------------------
    // 상태 천이 + 카운터
    // -------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            ts_cnt     <= 5'd0;
            layer      <= 2'd0;
            neuron_cnt <= 8'd0;
            fan_cnt    <= 8'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (frame_valid) begin
                        layer      <= 2'd0;
                        neuron_cnt <= 8'd0;
                        fan_cnt    <= 8'd0;
                        state <= (ts_cnt == 5'd0) ? S_MEM_RST : S_SPK_CLR;
                    end
                end

                S_MEM_RST: state <= S_SPK_CLR;

                S_SPK_CLR: begin
                    fan_cnt <= 8'd0;
                    state   <= S_LAYER;
                end

                S_LAYER: begin
                    if (wback) begin
                        if (neuron_cnt == n_max) begin
                            if (layer == 2'd2) begin
                                // L3 완료 → 타임스텝 완료
                                if (ts_cnt == TS_TOTAL - 1) begin
                                    ts_cnt <= 5'd0;
                                    state  <= S_BUF_DONE;
                                end else begin
                                    ts_cnt <= ts_cnt + 5'd1;
                                    state  <= S_IDLE;
                                end
                            end else begin
                                // 다음 레이어로 전환
                                layer      <= layer + 2'd1;
                                neuron_cnt <= 8'd0;
                                fan_cnt    <= 8'd0;
                                // state = S_LAYER 유지
                            end
                        end else begin
                            neuron_cnt <= neuron_cnt + 8'd1;
                            fan_cnt    <= 8'd0;
                        end
                    end else begin
                        fan_cnt <= fan_cnt + 8'd1;
                    end
                end

                S_BUF_DONE: state <= S_IDLE;

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
