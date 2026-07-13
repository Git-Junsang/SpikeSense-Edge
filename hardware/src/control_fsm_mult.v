// control_fsm_mult.v — 다중 트랙 시분할 PLIF-T SNN 시퀀서 FSM
//
// control_fsm.v의 다중 트랙 확장판.
//   - frame_valid + track_id로 한 프레임(=한 타임스텝)을 처리
//   - 트랙별 ts 카운터(ts_arr) 유지 → 각 트랙이 독립적으로 0..TS_TOTAL-1 순환
//   - 막전위 비동기 리셋(S_MEM_RST) 대신 first_ts(=ts_arr[track]==0)를 출력해
//     상위에서 mem_old=0 마스킹으로 버퍼 시작을 초기화
//
// 뉴런당 타이밍 (단일채널과 동일):
//   fan_cnt=0      : mac_clear (BRAM/막전위 주소 안정)
//   fan_cnt=1..FAN : mac_en
//   fan_cnt=FAN+1  : mem_wr_en (write-back)

`timescale 1ns/1ps

module control_fsm_mult #(
    parameter TS_TOTAL = 31,
    parameter N_TRACKS = 64,
    parameter TRK_W    = 6
)(
    input  wire             clk,
    input  wire             rst_n,

    input  wire             frame_valid,
    input  wire [TRK_W-1:0] track_id,

    // 카운터 (주소·데이터 생성용)
    output reg  [1:0]       layer,
    output reg  [7:0]       neuron_cnt,
    output reg  [7:0]       fan_cnt,

    // MAC 제어
    output wire             mac_clear,
    output wire             mac_en,
    output wire             mac_shift_en,

    // 메모리 쓰기 제어
    output wire             mem_wr_en,
    output wire             spike_wr_en,
    output wire             spike_clear,

    // 시분할 상태
    output reg              first_ts,    // 현 타임스텝이 트랙 버퍼의 첫 프레임 → mem_old=0
    output reg  [TRK_W-1:0] cur_track,   // 현재 처리 중인 트랙

    output wire             ts_done,     // 1타임스텝 완료 펄스
    output wire             buf_done,    // 트랙 버퍼(TS_TOTAL) 완료 펄스
    output wire             busy
);

    localparam [7:0] FAN_L1 = 8'd40,  FAN_L2 = 8'd128, FAN_L3 = 8'd32;
    localparam [7:0] N_L1   = 8'd128, N_L2   = 8'd32,  N_L3   = 8'd2;

    localparam [1:0] S_IDLE    = 2'd0;
    localparam [1:0] S_SPK_CLR = 2'd1;
    localparam [1:0] S_LAYER   = 2'd2;

    reg [1:0] state;
    reg [4:0] ts_arr [0:N_TRACKS-1];

    wire [7:0] fan_max = (layer == 2'd0) ? FAN_L1 :
                         (layer == 2'd1) ? FAN_L2 : FAN_L3;
    wire [7:0] n_max   = (layer == 2'd0) ? N_L1 - 8'd1 :
                         (layer == 2'd1) ? N_L2 - 8'd1 : N_L3 - 8'd1;
    wire       wback   = (fan_cnt == fan_max + 8'd1);

    assign mac_clear    = (state == S_LAYER) && (fan_cnt == 8'd0);
    assign mac_en       = (state == S_LAYER) && (fan_cnt >= 8'd1) && !wback;
    assign mac_shift_en = (layer == 2'd0);
    assign mem_wr_en    = (state == S_LAYER) && wback;
    assign spike_wr_en  = mem_wr_en && (layer != 2'd2);
    assign spike_clear  = (state == S_SPK_CLR);
    assign ts_done      = mem_wr_en && (layer == 2'd2) && (neuron_cnt == n_max);
    assign buf_done     = ts_done && (ts_arr[cur_track] == TS_TOTAL - 1);
    assign busy         = (state != S_IDLE);

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            layer      <= 2'd0;
            neuron_cnt <= 8'd0;
            fan_cnt    <= 8'd0;
            first_ts   <= 1'b0;
            cur_track  <= {TRK_W{1'b0}};
            for (k = 0; k < N_TRACKS; k = k + 1)
                ts_arr[k] <= 5'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (frame_valid) begin
                        cur_track  <= track_id;
                        first_ts   <= (ts_arr[track_id] == 5'd0);
                        layer      <= 2'd0;
                        neuron_cnt <= 8'd0;
                        fan_cnt    <= 8'd0;
                        state      <= S_SPK_CLR;
                    end
                end

                S_SPK_CLR: begin
                    fan_cnt <= 8'd0;
                    state   <= S_LAYER;
                end

                S_LAYER: begin
                    if (wback) begin
                        if (neuron_cnt == n_max) begin
                            if (layer == 2'd2) begin
                                // 타임스텝 완료 → 이 트랙의 ts 전진 (순환)
                                ts_arr[cur_track] <= (ts_arr[cur_track] == TS_TOTAL - 1)
                                                     ? 5'd0 : ts_arr[cur_track] + 5'd1;
                                state <= S_IDLE;
                            end else begin
                                layer      <= layer + 2'd1;
                                neuron_cnt <= 8'd0;
                                fan_cnt    <= 8'd0;
                            end
                        end else begin
                            neuron_cnt <= neuron_cnt + 8'd1;
                            fan_cnt    <= 8'd0;
                        end
                    end else begin
                        fan_cnt <= fan_cnt + 8'd1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
