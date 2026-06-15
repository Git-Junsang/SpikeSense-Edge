// ============================================================
// demo_snn_top.v — 데모용 시분할 PLIF-T SNN 엔진 (신규)
// ============================================================
// mult_snn_top.v 와 데이터패스(MAC·BRAM·ROM·막전위·spike_mem·FSM)는
// 100% 동일(bit-exact). 차이는 이상 판정 모듈뿐:
//   mult_snn_top  : anomaly_judge_mult (전역 Leaky Counter, 래치 성격)
//   demo_snn_top  : anomaly_judge_seg  (세그먼트 단위 다수결 → 매 세그먼트 토글)
//
// 이를 위해 FSM의 first_ts / buf_done 를 ts_done_r 정렬로 1단 레지스터링해
// 판정기에 first/last로 전달한다.
//
// ※ mult_snn_top.v / snn_top.v / dual_snn_top.v 는 동결. 본 모듈은 신규.
// ============================================================

`timescale 1ns/1ps

module demo_snn_top #(
    parameter N_TRACKS = 64,
    parameter TRK_W    = 6
)(
    input  wire                 clk,
    input  wire                 rst_n,

    input  wire [319:0]         mel_in,
    input  wire                 frame_valid,
    input  wire [TRK_W-1:0]     track_id,

    output wire [N_TRACKS-1:0]  anomaly_flags,
    output wire                 busy
);

    // ── mel 래치 ─────────────────────────────────────────────
    reg [319:0] mel_reg;
    always @(posedge clk)
        if (frame_valid) mel_reg <= mel_in;

    // ── FSM ──────────────────────────────────────────────────
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

    // ── 가중치 BRAM 주소 ─────────────────────────────────────
    wire [13:0] l1_base = {6'b0, neuron_cnt} * 14'd40;
    wire [13:0] l2_base = 14'd5120 + {6'b0, neuron_cnt} * 14'd128;
    wire [13:0] l3_base = 14'd9216 + {6'b0, neuron_cnt} * 14'd32;
    wire [13:0] bram_addr = ((layer == 2'd0) ? l1_base :
                             (layer == 2'd1) ? l2_base : l3_base)
                            + {6'b0, fan_cnt};

    wire [7:0] neuron_global = (layer == 2'd0) ? neuron_cnt :
                               (layer == 2'd1) ? 8'd128 + neuron_cnt :
                                                 8'd160 + neuron_cnt;

    // ── MAC 입력 a ───────────────────────────────────────────
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

    // ── 가중치 BRAM / param ROM ──────────────────────────────
    wire signed [7:0] bram_data;
    weight_bram u_bram (.clk(clk), .addr(bram_addr), .data(bram_data));

    wire [7:0] param_beta, param_vth;
    param_rom u_prom (.neuron_idx(neuron_global), .beta(param_beta), .vth(param_vth));

    // ── MAC Unit ─────────────────────────────────────────────
    wire signed [15:0] mac_current;
    mac_unit u_mac (
        .clk(clk), .rst_n(rst_n),
        .clear(mac_clear), .en(mac_en),
        .a(mac_a), .b(bram_data), .shift_en(mac_shift_en),
        .current(mac_current)
    );

    // ── 막전위 (트랙별 BRAM) ─────────────────────────────────
    wire signed [15:0] mem_rd;
    wire signed [15:0] mem_new_plif;

    membrane_mem_mult #(.N_TRACKS(N_TRACKS), .TRK_W(TRK_W)) u_mem (
        .clk(clk),
        .rd_track(cur_track), .rd_neuron(neuron_global), .rd_data(mem_rd),
        .wr_en(mem_wr_en), .wr_track(cur_track), .wr_neuron(neuron_global),
        .wr_data(mem_new_plif)
    );

    wire signed [15:0] mem_old = first_ts ? 16'sd0 : mem_rd;

    // ── PLIF-T Core ──────────────────────────────────────────
    wire plift_spike;
    plift_core u_plif (
        .current(mac_current), .mem_in(mem_old),
        .beta(param_beta), .vth(param_vth),
        .spike(plift_spike), .mem_out(mem_new_plif)
    );

    // ── Spike Memory ─────────────────────────────────────────
    spike_mem u_spk (
        .clk(clk), .rst_n(rst_n), .clear(spike_clear),
        .wr_en(spike_wr_en), .wr_layer(layer[0]),
        .wr_idx(neuron_cnt[6:0]), .spike_in(plift_spike),
        .l1_spikes(l1_spikes), .l2_spikes(l2_spikes)
    );

    // ── L3 스파이크 캡처 ─────────────────────────────────────
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

    // ── ts_done / track / first / last 를 1단 정렬 레지스터링 ──
    // (spk_*_r 가 유효해지는 ts_done_r 시점에 track/first/last 도 동일 정렬)
    reg ts_done_r, first_ts_r, buf_done_r;
    reg [TRK_W-1:0] cur_track_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ts_done_r   <= 1'b0;
            first_ts_r  <= 1'b0;
            buf_done_r  <= 1'b0;
            cur_track_r <= {TRK_W{1'b0}};
        end else begin
            ts_done_r   <= ts_done_comb;
            first_ts_r  <= first_ts;
            buf_done_r  <= buf_done;
            cur_track_r <= cur_track;
        end
    end

    // ── 세그먼트 단위 판정기 ─────────────────────────────────
    anomaly_judge_seg #(.ACC_WIDTH(8), .N_TRACKS(N_TRACKS), .TRK_W(TRK_W)) u_judge (
        .clk(clk), .rst_n(rst_n),
        .track(cur_track_r),
        .spk_normal(spk_normal_r), .spk_anomaly(spk_anomaly_r),
        .update(ts_done_r), .first(first_ts_r), .last(buf_done_r),
        .anomaly_flags(anomaly_flags)
    );

endmodule
