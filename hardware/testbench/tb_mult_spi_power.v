// ============================================================
// tb_mult_spi_power.v — 전력 측정(SAIF)용 자극 전용 테스트벤치
// ============================================================
// 목적: Post-Implementation Timing Simulation으로 스위칭 액티비티(SAIF)를
//   뽑아 report_power의 신뢰도를 올린다.
//
// tb_mult_spi_top과 달리 **내부 신호(busy, u_mem.mem 등)를 일절 참조하지 않는다**.
//   → 플랫된 타이밍 네트리스트에서도 elaborate 성공.
//   → 골든 hex $readmemh도 없음 (mel은 의사난수 생성) → 시뮬 working-dir 무관.
//
// SPI 마스터(mode 0, SCK 5MHz)로 여러 트랙·타임스텝에 41B 프레임을 인가하여
// 시분할 데이터패스를 충분히 토글시킨 뒤 $finish.
//
// 사용 (Vivado):
//   1) 이 파일을 Simulation Sources(sim_1)에 추가, sim top = tb_mult_spi_power
//   2) Run Post-Implementation Timing Simulation
//   3) Tcl: open_saif power.saif; log_saif [get_objects -r /tb_mult_spi_power/dut/*];
//           run all; close_saif
//   4) open_run impl_1; read_saif -strip_path tb_mult_spi_power/dut power.saif;
//      report_power -file power_saif.rpt
//
// iverilog 동작 확인(behavioral, 저장소 루트에서):
//   /usr/bin/iverilog -g2001 -o hardware/sim/mult_spi_power \
//       hardware/testbench/tb_mult_spi_power.v hardware/src/*.v
//   /usr/bin/vvp hardware/sim/mult_spi_power
// ============================================================

`timescale 1ns/1ps

module tb_mult_spi_power;

    localparam N_TRACKS = 4;
    localparam TRK_W    = 2;
    localparam SCK_H    = 100;   // SCK 반주기 100ns → 5MHz (50MHz 도메인 10× 오버샘플)
    localparam N_TS     = 2;     // 트랙당 인가할 타임스텝 수 (늘리면 활동 표본↑, 시뮬 시간↑)
                                 // 2×4트랙=8프레임 ≈ sim 2.5ms (timing 시뮬 30분 내 목표)

    reg clk = 0;
    always #5 clk = ~clk;        // 100 MHz 입력

    reg rst_n = 0;
    reg sck = 0, mosi = 0, cs_n = 1;
    wire [15:0] led;

    mult_spi_top #(.N_TRACKS(N_TRACKS), .TRK_W(TRK_W), .N_LED(16)) dut (
        .clk(clk), .rst_n(rst_n),
        .sck(sck), .mosi(mosi), .cs_n(cs_n),
        .led(led)
    );

    integer b, k;
    reg [327:0] fr;

    // 의사난수 mel(0~127) — track/ts/idx 기반 결정적 생성 (hex 불필요)
    function [7:0] gen_mel;
        input [7:0]  tr;
        input integer ts;
        input integer idx;
        begin
            gen_mel = (tr * 8'd37 + idx * 8'd13 + ts * 8'd7) & 8'h7F;
        end
    endfunction

    // SPI 41B 프레임 전송 (mode 0, MSB-first): [track_id][mel×40]
    task spi_send;
        input [7:0]  ch;
        input integer ts;
        begin
            fr[327:320] = ch;
            for (k = 0; k < 40; k = k + 1)
                fr[(39-k)*8 +: 8] = gen_mel(ch, ts, k);

            cs_n = 0; #SCK_H;
            for (b = 327; b >= 0; b = b - 1) begin
                mosi = fr[b];
                #SCK_H; sck = 1;   // 상승엣지 샘플
                #SCK_H; sck = 0;
            end
            #SCK_H; cs_n = 1;      // 프레임 종료 → frame_rdy
            #SCK_H;
        end
    endtask

    integer ts, tr;
    initial begin
        rst_n = 0;
        repeat (6) @(posedge clk); #1;
        rst_n = 1; #20;

        // 여러 타임스텝 × 여러 트랙으로 데이터패스를 반복 가동
        for (ts = 0; ts < N_TS; ts = ts + 1)
            for (tr = 0; tr < N_TRACKS; tr = tr + 1) begin
                spi_send(tr[7:0], ts);
                #250000;   // 한 타임스텝 처리(~192µs@50MHz) 이상 대기 → 데이터패스 1회 실행
            end

        #100000;
        $display("tb_mult_spi_power: 자극 완료 (frames=%0d)", N_TS * N_TRACKS);
        $finish;
    end

endmodule
