// ============================================================
// mult_snn_top.v — 다중 트랙 시분할 PLIF-T SNN 최상위 (Phase 6 확장)
// ============================================================
// 단일 데이터패스(MAC·가중치 BRAM·param ROM·spike_mem)를 N_TRACKS개
// 트랙이 시분할 공유. 트랙별 상태(막전위·이상 카운터)만 복제.
//
// 인터페이스:
//   입력: mel_in[40×8b] + frame_valid + track_id
//   출력: anomaly_flags[N_TRACKS] (트랙별 이상 플래그), busy
//
// 한 frame_valid = 한 트랙의 한 타임스텝.
// 각 트랙은 독립적으로 31 타임스텝 버퍼를 순환하며, ts0에서 막전위가
// 0으로 초기화된다(first_ts 마스킹). 결과는 단일채널 snn_top과 bit-exact.
//
// ※ snn_top.v / dual_snn_top.v는 동결(수정 금지). 본 모듈은 신규.
// ============================================================

`timescale 1ns/1ps

module mult_snn_top #(
    parameter N_TRACKS = 64,
    parameter TRK_W    = 6     // ceil(log2(N_TRACKS))
)(
    input  wire                 clk,
    input  wire                 rst_n,

    input  wire [319:0]         mel_in,      // mel[0..39], mel_in[7:0]=ch0
    input  wire                 frame_valid,
    input  wire [TRK_W-1:0]     track_id,

    output wire [N_TRACKS-1:0]  anomaly_flags,
    output wire                 busy,

    // 관찰용 디버그 출력 (보드 self-test / ILA). mult_spi_top에선 미연결.
    output wire                 dbg_spk_normal,   // 현재 트랙 L3 n0(정상) 스파이크
    output wire                 dbg_spk_anomaly,  // 현재 트랙 L3 n1(이상) 스파이크
    output wire                 dbg_ts_done       // 타임스텝 완료(ts_done_r)
);

    // =========================================================
    // mel 래치 (공유 스크래치, frame_valid 시 등록)
    // =========================================================
    reg [319:0] mel_reg;
    always @(posedge clk)
        if (frame_valid) mel_reg <= mel_in;

    // =========================================================
    // FSM
    // =========================================================
    wire [1:0] layer;
    wire [7:0] neuron_cnt, fan_cnt;
    wire mac_clear, mac_en, mac_shift_en;
    wire mem_wr_en, spike_wr_en, spike_clear;
    wire first_ts;
    wire [TRK_W-1:0] cur_track;
    wire ts_done_comb, buf_done;

    control_fsm_mult #(.TS_TOTAL(31), .N_TRACKS(N_TRACKS), .TRK_W(TRK_W)) u_fsm (
        .clk(clk), .rst_n(rst_n),
        .frame_valid(frame_valid), .track_id(track_id),
        .layer(layer), .neuron_cnt(neuron_cnt), .fan_cnt(fan_cnt),
        .mac_clear(mac_clear), .mac_en(mac_en), .mac_shift_en(mac_shift_en),
        .mem_wr_en(mem_wr_en), .spike_wr_en(spike_wr_en), .spike_clear(spike_clear),
        .first_ts(first_ts), .cur_track(cur_track),
        .ts_done(ts_done_comb), .buf_done(buf_done), .busy(busy)
    );

    // =========================================================
    // 가중치 BRAM 주소 (공유, 단일채널과 동일)
    // =========================================================
    wire [13:0] l1_base = {6'b0, neuron_cnt} * 14'd40;
    wire [13:0] l2_base = 14'd5120 + {6'b0, neuron_cnt} * 14'd128;
    wire [13:0] l3_base = 14'd9216 + {6'b0, neuron_cnt} * 14'd32;
    wire [13:0] bram_addr = ((layer == 2'd0) ? l1_base :
                             (layer == 2'd1) ? l2_base : l3_base)
                            + {6'b0, fan_cnt};

    // 전역 뉴런 인덱스 (param_rom, 막전위 공용)
    wire [7:0] neuron_global = (layer == 2'd0) ? neuron_cnt :
                               (layer == 2'd1) ? 8'd128 + neuron_cnt :
                                                 8'd160 + neuron_cnt;

    // =========================================================
    // MAC 입력 a (공유, 단일채널과 동일)
    // =========================================================
    wire [127:0] l1_spikes;
    wire [31:0]  l2_spikes;
    wire [7:0]  fan_m1    = fan_cnt - 8'd1;
    wire [8:0]  mel_bbase = {1'b0, fan_m1} * 9'd8;
    wire [7:0]  mel_byte  = mel_reg[mel_bbase +: 8];
    wire        l1_bit    = l1_spikes[fan_m1];
    wire        l2_bit    = l2_spikes[fan_m1[4:0]];

    wire signed [7:0] mac_a = (layer == 2'd0) ? mel_byte :
                               (layer == 2'd1) ? (l1_bit ? 8'sd1 : 8'sd0) :
                                                 (l2_bit ? 8'sd1 : 8'sd0);

    // =========================================================
    // 가중치 BRAM / param ROM (공유)
    // =========================================================
    wire signed [7:0] bram_data;
    weight_bram u_bram (.clk(clk), .addr(bram_addr), .data(bram_data));

    wire [7:0] param_beta, param_vth;
    param_rom u_prom (.neuron_idx(neuron_global), .beta(param_beta), .vth(param_vth));

    // =========================================================
    // MAC Unit (공유)
    // =========================================================
    wire signed [15:0] mac_current;
    mac_unit u_mac (
        .clk(clk), .rst_n(rst_n),
        .clear(mac_clear), .en(mac_en),
        .a(mac_a), .b(bram_data), .shift_en(mac_shift_en),
        .current(mac_current)
    );

    // =========================================================
    // 막전위 (트랙별 BRAM, 동기 읽기)
    // 읽기 주소는 뉴런 처리 내내 안정 → 1클럭 지연이 write-back 전 해소.
    // first_ts 시 mem_old=0 (버퍼 시작 초기화 대체).
    // =========================================================
    wire signed [15:0] mem_rd;
    wire signed [15:0] mem_new_plif;

    membrane_mem_mult #(.N_TRACKS(N_TRACKS), .TRK_W(TRK_W)) u_mem (
        .clk(clk),
        .rd_track(cur_track), .rd_neuron(neuron_global), .rd_data(mem_rd),
        .wr_en(mem_wr_en), .wr_track(cur_track), .wr_neuron(neuron_global),
        .wr_data(mem_new_plif)
    );

    wire signed [15:0] mem_old = first_ts ? 16'sd0 : mem_rd;

    // =========================================================
    // PLIF-T Core (조합, 공유)
    // =========================================================
    wire plift_spike;
    plift_core u_plif (
        .current(mac_current), .mem_in(mem_old),
        .beta(param_beta), .vth(param_vth),
        .spike(plift_spike), .mem_out(mem_new_plif)
    );

    // =========================================================
    // Spike Memory (공유 스크래치 — 프레임 내에서만 유효)
    // =========================================================
    spike_mem u_spk (
        .clk(clk), .rst_n(rst_n), .clear(spike_clear),
        .wr_en(spike_wr_en), .wr_layer(layer[0]),
        .wr_idx(neuron_cnt[6:0]), .spike_in(plift_spike),
        .l1_spikes(l1_spikes), .l2_spikes(l2_spikes)
    );

    // =========================================================
    // L3 스파이크 캡처 → anomaly_judge_mult
    // =========================================================
    reg spk_normal_r, spk_anomaly_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spk_normal_r  <= 1'b0;
            spk_anomaly_r <= 1'b0;
        end else if (mem_wr_en && layer == 2'd2) begin
            if (neuron_cnt == 8'd0) spk_normal_r  <= plift_spike;
            else                    spk_anomaly_r <= plift_spike;
        end
    end

    reg ts_done_r;
    reg [TRK_W-1:0] cur_track_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ts_done_r   <= 1'b0;
            cur_track_r <= {TRK_W{1'b0}};
        end else begin
            ts_done_r   <= ts_done_comb;
            cur_track_r <= cur_track;
        end
    end

    anomaly_judge_mult #(.CNT_WIDTH(24), .SHIFT_N(14), .N_TRACKS(N_TRACKS), .TRK_W(TRK_W)) u_judge (
        .clk(clk), .rst_n(rst_n),
        .track(cur_track_r),
        .spk_normal(spk_normal_r), .spk_anomaly(spk_anomaly_r),
        .update(ts_done_r),
        .anomaly_flags(anomaly_flags)
    );

    // 디버그 탭 (내부 레지스터 노출)
    assign dbg_spk_normal  = spk_normal_r;
    assign dbg_spk_anomaly = spk_anomaly_r;
    assign dbg_ts_done     = ts_done_r;

endmodule
