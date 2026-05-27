// ============================================================
// mt_selftest_top.v — RPi 없이 보드에서 도는 자가진단 (Phase 6-2)
// ============================================================
// 외부 자극원(RPi/SPI) 없이, 칩 안에 저장한 골든 anomaly mel을 시분할
// 엔진(mt_snn_top)에 31타임스텝 먹이고, 출력 스파이크가 골든 기대값과
// 일치하는지 칩 안에서 자체 비교한다.
//   - LED15 = PASS (62개 스파이크 전부 일치)
//   - LED14 = FAIL,  LED13 = done,  LED[6:0] = 불일치 개수
// 보드를 굽고 리셋만 하면(약 6ms 후) 결과가 LED에 표시된다.
//
// 클럭: 100MHz(E3) → clk_div2 → 50MHz. 골든 hex는 합성 시 basename,
// 시뮬 시 저장소 상대경로(weight_bram.v와 동일 규약).
// ============================================================

`timescale 1ns/1ps

module mt_selftest_top (
    input  wire        clk,    // 100 MHz 입력 (E3)
    input  wire        rst_n,  // CPU_RESETN (C12, active-low)
    output reg  [15:0] led
);

    // ---- 100 → 50 MHz ----
    wire clk50;
    clk_div2 u_clkdiv (.clk_in(clk), .clk_out(clk50));

    // ---- 골든 ROM: anomaly mel(31×40B) + 기대 스파이크(62b) ----
    reg [7:0] mel_rom [0:1239];
    reg [0:0] spk_rom [0:61];
    initial begin
`ifdef SYNTHESIS
        $readmemh("anomaly_mel.hex", mel_rom);
        $readmemh("anomaly_spk.hex", spk_rom);
`else
        $readmemh("hardware/src/weights/golden/anomaly_mel.hex", mel_rom);
        $readmemh("hardware/src/weights/golden/anomaly_spk.hex", spk_rom);
`endif
    end

    // ---- 시분할 엔진 (track 0만 사용, N_TRACKS=2) ----
    reg  [319:0] mel_in;
    reg          frame_valid;
    wire [1:0]   anomaly_flags;
    wire         busy, dbg_spk_normal, dbg_spk_anomaly, dbg_ts_done;

    mt_snn_top #(.N_TRACKS(2), .TRK_W(1)) u_eng (
        .clk(clk50), .rst_n(rst_n),
        .mel_in(mel_in), .frame_valid(frame_valid), .track_id(1'b0),
        .anomaly_flags(anomaly_flags), .busy(busy),
        .dbg_spk_normal(dbg_spk_normal), .dbg_spk_anomaly(dbg_spk_anomaly),
        .dbg_ts_done(dbg_ts_done)
    );

    // ---- 현재 ts의 mel 프레임 패킹 ----
    reg  [4:0]   ts;
    reg  [319:0] mel_frame;
    integer c;
    always @(*) begin
        mel_frame = 320'b0;
        for (c = 0; c < 40; c = c + 1)
            mel_frame[c*8 +: 8] = mel_rom[ts*40 + c];
    end

    // ---- 자가진단 FSM ----
    localparam S_FEED=3'd0, S_WHI=3'd1, S_WLO=3'd2, S_SAMP=3'd3, S_NEXT=3'd4, S_DONE=3'd5;
    reg [2:0] st;
    reg [6:0] fail;   // 불일치 누적 (최대 62)

    always @(posedge clk50 or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_FEED; ts <= 5'd0; fail <= 7'd0;
            frame_valid <= 1'b0; mel_in <= 320'b0; led <= 16'b0;
        end else begin
            frame_valid <= 1'b0;
            case (st)
                S_FEED: begin
                    mel_in      <= mel_frame;
                    frame_valid <= 1'b1;       // 1클럭 펄스
                    st          <= S_WHI;
                end
                S_WHI:  if (busy)  st <= S_WLO;   // busy 상승 대기
                S_WLO:  if (!busy) st <= S_SAMP;  // 처리 완료 대기
                S_SAMP: begin
                    // 두 스파이크 비교 (불일치 0/1/2를 한 번에 누적)
                    fail <= fail + (dbg_spk_normal  != spk_rom[{ts,1'b0}])
                                 + (dbg_spk_anomaly != spk_rom[{ts,1'b1}]);
                    st   <= S_NEXT;
                end
                S_NEXT: begin
                    if (ts == 5'd30) st <= S_DONE;
                    else begin ts <= ts + 5'd1; st <= S_FEED; end
                end
                S_DONE: begin
                    led[15]  <= (fail == 7'd0);  // PASS
                    led[14]  <= (fail != 7'd0);  // FAIL
                    led[13]  <= 1'b1;            // done
                    led[6:0] <= fail;            // 불일치 개수 (PASS면 0)
                end
                default: st <= S_DONE;
            endcase
        end
    end

endmodule
