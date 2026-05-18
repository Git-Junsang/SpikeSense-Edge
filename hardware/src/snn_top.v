// ============================================================
// snn_top.v — PLIF-T SNN 이상 감지 최상위 모듈
// ============================================================
// 외부 인터페이스:
//   입력: mel_in[40×8bit, packed little-endian: mel_in[7:0]=ch0] + frame_valid
//   출력: anomaly_flag, busy
//
// 내부 흐름 (31 타임스텝 / 버퍼):
//   frame_valid → mel 래치 → (버퍼 시작이면 membrane reset)
//   → spike_mem clear
//   → L1: 128뉴런 × 40입력 (mel×W1, shift>>7)
//   → L2:  32뉴런 × 128입력 (L1_spike×W2)
//   → L3:   2뉴런 ×  32입력 (L2_spike×W3)
//   → 다음 frame_valid 대기 → 반복
//   → 31회 후 anomaly_judge 업데이트 → anomaly_flag
// ============================================================

`timescale 1ns/1ps

module snn_top (
    input  wire         clk,
    input  wire         rst_n,

    // RPi5 인터페이스
    input  wire [319:0] mel_in,       // mel[0..39], mel_in[7:0]=ch0
    input  wire         frame_valid,

    // 출력
    output wire         anomaly_flag,
    output wire         busy
);

    // =========================================================
    // mel 래치 (frame_valid 상승 시 등록)
    // =========================================================
    reg [319:0] mel_reg;
    always @(posedge clk) begin
        if (frame_valid) mel_reg <= mel_in;
    end

    // =========================================================
    // FSM
    // =========================================================
    wire [1:0] layer;
    wire [7:0] neuron_cnt;
    wire [7:0] fan_cnt;
    wire mac_clear, mac_en, mac_shift_en;
    wire mem_wr_en, spike_wr_en, spike_clear, mem_rst_pulse;
    wire ts_done_comb, fsm_done;

    control_fsm #(.TS_TOTAL(31)) u_fsm (
        .clk          (clk),
        .rst_n        (rst_n),
        .frame_valid  (frame_valid),
        .layer        (layer),
        .neuron_cnt   (neuron_cnt),
        .fan_cnt      (fan_cnt),
        .mac_clear    (mac_clear),
        .mac_en       (mac_en),
        .mac_shift_en (mac_shift_en),
        .mem_wr_en    (mem_wr_en),
        .spike_wr_en  (spike_wr_en),
        .spike_clear  (spike_clear),
        .mem_rst_pulse(mem_rst_pulse),
        .ts_done      (ts_done_comb),
        .done         (fsm_done),
        .busy         (busy)
    );

    // =========================================================
    // BRAM 주소 계산
    // =========================================================
    // L1: addr = neuron_cnt*40 + fan_cnt   (0..5119)
    // L2: addr = 5120 + neuron_cnt*128 + fan_cnt (5120..9215)
    // L3: addr = 9216 + neuron_cnt*32  + fan_cnt (9216..9279)
    wire [13:0] l1_base = {6'b0, neuron_cnt} * 14'd40;
    wire [13:0] l2_base = 14'd5120 + {6'b0, neuron_cnt} * 14'd128;
    wire [13:0] l3_base = 14'd9216 + {6'b0, neuron_cnt} * 14'd32;
    wire [13:0] bram_addr = ((layer == 2'd0) ? l1_base :
                             (layer == 2'd1) ? l2_base : l3_base)
                            + {6'b0, fan_cnt};

    // =========================================================
    // 전역 뉴런 인덱스 (param_rom, membrane_mem 공용)
    // =========================================================
    // L1: 0..127, L2: 128..159, L3: 160..161
    wire [7:0] neuron_global = (layer == 2'd0) ? neuron_cnt :
                               (layer == 2'd1) ? 8'd128 + neuron_cnt :
                                                 8'd160 + neuron_cnt;

    // =========================================================
    // MAC 입력 a 계산
    // =========================================================
    // fan_cnt=k (1..FAN_IN): a = input[k-1]
    // L1: mel_reg[(k-1)*8 +: 8]
    // L2: l1_spikes[k-1] ? 8'sd1 : 8'sd0
    // L3: l2_spikes[k-1] ? 8'sd1 : 8'sd0
    wire [127:0] l1_spikes;
    wire [31:0]  l2_spikes;

    wire [7:0]  fan_m1    = fan_cnt - 8'd1;             // fan_cnt-1 (valid when fan_cnt>=1)
    wire [8:0]  mel_bbase = {1'b0, fan_m1} * 9'd8;     // bit address into mel_reg
    wire [7:0]  mel_byte  = mel_reg[mel_bbase +: 8];    // signed INT8 mel value
    wire        l1_bit    = l1_spikes[fan_m1];           // L1 spike bit (0..127)
    wire        l2_bit    = l2_spikes[fan_m1[4:0]];     // L2 spike bit (0..31)

    wire signed [7:0] mac_a = (layer == 2'd0) ? mel_byte :
                               (layer == 2'd1) ? (l1_bit ? 8'sd1 : 8'sd0) :
                                                  (l2_bit ? 8'sd1 : 8'sd0);

    // =========================================================
    // Weight BRAM
    // =========================================================
    wire signed [7:0] bram_data;
    weight_bram u_bram (
        .clk  (clk),
        .addr (bram_addr),
        .data (bram_data)
    );

    // =========================================================
    // Param ROM (β, V_th)
    // =========================================================
    wire [7:0] param_beta, param_vth;
    param_rom u_prom (
        .neuron_idx (neuron_global),
        .beta       (param_beta),
        .vth        (param_vth)
    );

    // =========================================================
    // MAC Unit
    // =========================================================
    wire signed [15:0] mac_current;
    mac_unit u_mac (
        .clk      (clk),
        .rst_n    (rst_n),
        .clear    (mac_clear),
        .en       (mac_en),
        .a        (mac_a),
        .b        (bram_data),
        .shift_en (mac_shift_en),
        .current  (mac_current)
    );

    // =========================================================
    // Membrane Memory (membrane_mem)
    // membrane reset: rst_n & ~mem_rst_pulse (버퍼 경계 초기화)
    // =========================================================
    wire mem_rst_n_in = rst_n & ~mem_rst_pulse;
    wire signed [15:0] mem_old, mem_new_plif;

    membrane_mem u_mem (
        .clk        (clk),
        .rst_n      (mem_rst_n_in),
        .neuron_idx (neuron_global),
        .wr_en      (mem_wr_en),
        .mem_in     (mem_new_plif),
        .mem_out    (mem_old)
    );

    // =========================================================
    // PLIF-T Core (조합논리)
    // =========================================================
    wire plift_spike;
    plift_core u_plif (
        .current (mac_current),
        .mem_in  (mem_old),
        .beta    (param_beta),
        .vth     (param_vth),
        .spike   (plift_spike),
        .mem_out (mem_new_plif)
    );

    // =========================================================
    // Spike Memory
    // =========================================================
    spike_mem u_spk (
        .clk      (clk),
        .rst_n    (rst_n),
        .clear    (spike_clear),
        .wr_en    (spike_wr_en),
        .wr_layer (layer[0]),           // 0=L1, 1=L2
        .wr_idx   (neuron_cnt[6:0]),
        .spike_in (plift_spike),
        .l1_spikes(l1_spikes),
        .l2_spikes(l2_spikes)
    );

    // =========================================================
    // L3 스파이크 캡처 → anomaly_judge
    // =========================================================
    // write-back cycle에 plift_spike 캡처
    // ts_done은 L3 neuron_cnt=1의 write-back과 동시이므로
    // anomaly_judge.update는 1사이클 지연 (ts_done_r)
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
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) ts_done_r <= 1'b0;
        else        ts_done_r <= ts_done_comb;
    end

    // =========================================================
    // Anomaly Judge
    // =========================================================
    anomaly_judge #(.CNT_WIDTH(24), .SHIFT_N(14)) u_judge (
        .clk             (clk),
        .rst_n           (rst_n),
        .spk_normal      (spk_normal_r),
        .spk_anomaly     (spk_anomaly_r),
        .update          (ts_done_r),
        .anomaly_flag    (anomaly_flag),
        .cnt_normal_out  (),
        .cnt_anomaly_out ()
    );

endmodule
