// ============================================================
// snn_top.v — SNN 이상 감지 최상위 모듈
// ============================================================
// 8개 하위 블록을 인스턴스화하고 배선합니다.
//
// 외부 인터페이스:
//   입력: 16-bit PCM 오디오 + sample_valid
//   출력: anomaly_flag
//
// 내부 흐름:
//   PCM → level_crossing_enc → 10-bit spike
//       → control_fsm 시작
//       → 6클럭 시분할 처리 (weight_rom → mac → lif → mem/buf)
//       → anomaly_judge → anomaly_flag
// ============================================================

module snn_top (
    input  wire        clk,
    input  wire        rst_n,

    // --- 외부 입력 ---
    input  wire signed [15:0] sample_in,      // 16-bit PCM 오디오
    input  wire               sample_valid,   // 새 샘플 도착

    // --- 외부 출력 ---
    output wire               anomaly_flag,   // 1=이상 의심
    output wire               busy            // 처리 중
);

    // -------------------------------------------------------
    // 내부 신호
    // -------------------------------------------------------

    // ⓪ level_crossing_enc 출력
    wire [9:0]  spike_enc;
    wire        spike_valid;

    // ① control_fsm 출력
    wire [2:0]  neuron_idx;
    wire        layer_sel;
    wire [7:0]  beta;
    wire        mem_wr_en;
    wire        buf_wr_en;
    wire        fsm_busy;
    wire        fsm_done;

    // ② weight_rom 출력
    wire [79:0] weights;

    // MAC 입력 MUX
    wire [9:0]  mac_spike_in;

    // ③ mac_unit 출력
    wire signed [15:0] current;

    // ④ lif_core 입출력
    wire signed [15:0] mem_old;
    wire signed [15:0] mem_new;
    wire               spike_out;

    // ⑥ spike_buffer 출력
    wire [3:0]  hid_spikes;

    // 스파이크 입력 래치 (FSM 처리 중 유지)
    reg [9:0] spike_latched;

    // Out0, Out1 스파이크 캡처
    reg spk_normal_reg;
    reg spk_anomaly_reg;

    // -------------------------------------------------------
    // 스파이크 입력 래치
    // -------------------------------------------------------
    // level_crossing_enc 출력은 1클럭 펄스이므로,
    // FSM이 6클럭 동안 쓸 수 있도록 래치합니다.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            spike_latched <= 10'b0;
        else if (spike_valid)
            spike_latched <= spike_enc;
    end

    // -------------------------------------------------------
    // MAC 입력 MUX
    // -------------------------------------------------------
    // 은닉층: 래치된 외부 스파이크 10채널
    // 출력층: spike_buffer 4비트 + 상위 6비트 0
    assign mac_spike_in = (layer_sel == 1'b0)
                        ? spike_latched
                        : {6'b000000, hid_spikes};

    // -------------------------------------------------------
    // Out0/Out1 스파이크 캡처
    // -------------------------------------------------------
    // FSM이 Out0(idx=4), Out1(idx=5) 처리 시 스파이크를 캡처하여
    // anomaly_judge에 전달합니다.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spk_normal_reg  <= 1'b0;
            spk_anomaly_reg <= 1'b0;
        end else begin
            if (mem_wr_en && neuron_idx == 3'd4)
                spk_normal_reg <= spike_out;
            if (mem_wr_en && neuron_idx == 3'd5)
                spk_anomaly_reg <= spike_out;
        end
    end

    // -------------------------------------------------------
    // ⓪ Level Crossing 인코더
    // -------------------------------------------------------
    level_crossing_enc u_enc (
        .clk          (clk),
        .rst_n        (rst_n),
        .sample_in    (sample_in),
        .sample_valid (sample_valid),
        .spike_out    (spike_enc),
        .spike_valid  (spike_valid)
    );

    // -------------------------------------------------------
    // ① Control FSM
    // -------------------------------------------------------
    control_fsm u_fsm (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (spike_valid),
        .neuron_idx (neuron_idx),
        .layer_sel  (layer_sel),
        .beta       (beta),
        .mem_wr_en  (mem_wr_en),
        .buf_wr_en  (buf_wr_en),
        .busy       (fsm_busy),
        .done       (fsm_done)
    );

    assign busy = fsm_busy;

    // -------------------------------------------------------
    // ② Weight ROM
    // -------------------------------------------------------
    weight_rom #(.W_WIDTH(8)) u_wrom (
        .neuron_idx (neuron_idx),
        .weights    (weights)
    );

    // -------------------------------------------------------
    // ③ MAC Unit
    // -------------------------------------------------------
    mac_unit #(.W_WIDTH(8)) u_mac (
        .spike_in   (mac_spike_in),
        .weights    (weights),
        .layer_sel  (layer_sel),
        .current    (current)
    );

    // -------------------------------------------------------
    // ④ LIF Core
    // -------------------------------------------------------
    lif_core #(
        .MEM_WIDTH  (16),
        .BETA_WIDTH (8),
        .THRESHOLD  (16'sd256)
    ) u_lif (
        .current    (current),
        .mem_in     (mem_old),
        .beta       (beta),
        .spike      (spike_out),
        .mem_out    (mem_new)
    );

    // -------------------------------------------------------
    // ⑤ Membrane Memory
    // -------------------------------------------------------
    membrane_mem #(
        .MEM_WIDTH  (16),
        .N_NEURONS  (6)
    ) u_mem (
        .clk        (clk),
        .rst_n      (rst_n),
        .neuron_idx (neuron_idx),
        .wr_en      (mem_wr_en),
        .mem_in     (mem_new),
        .mem_out    (mem_old)
    );

    // -------------------------------------------------------
    // ⑥ Spike Buffer
    // -------------------------------------------------------
    spike_buffer u_buf (
        .clk        (clk),
        .rst_n      (rst_n),
        .wr_idx     (neuron_idx[1:0]),
        .wr_en      (buf_wr_en),
        .spike_in   (spike_out),
        .hid_spikes (hid_spikes)
    );

    // -------------------------------------------------------
    // ⑦ Anomaly Judge
    // -------------------------------------------------------
    anomaly_judge #(
        .CNT_WIDTH  (24),
        .SHIFT_N    (14)
    ) u_judge (
        .clk           (clk),
        .rst_n         (rst_n),
        .spk_normal    (spk_normal_reg),
        .spk_anomaly   (spk_anomaly_reg),
        .update        (fsm_done),
        .anomaly_flag  (anomaly_flag),
        .cnt_normal_out  (),   // 디버그 시 연결
        .cnt_anomaly_out ()    // 디버그 시 연결
    );

endmodule
