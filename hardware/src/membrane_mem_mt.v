// ============================================================
// membrane_mem_mt.v — 다중 트랙 막전위 메모리 (시분할용)
// ============================================================
// 단일채널 membrane_mem.v의 다중 트랙 확장판.
//   - 트랙당 256엔트리 스트라이드(뉴런 0~161 사용, 나머지 미사용)
//     → 주소 = {track, neuron}  곱셈 없는 연결로 타이밍 유리
//   - BRAM 추론을 위해 **동기 읽기**(1클럭 지연) + 동기 쓰기
//   - 비동기 리셋 없음: 버퍼 시작 막전위 초기화는 상위(mt_snn_top)에서
//     first_ts일 때 mem_old를 0으로 마스킹해 대체 (BRAM 클리어 불필요)
//
// 읽기 주소(rd_*)는 뉴런 처리 내내 안정적이므로 1클럭 읽기지연이
// write-back 시점 전에 자연히 해소된다 (별도 prefetch 제어 불필요).
// ============================================================

`timescale 1ns/1ps

module membrane_mem_mt #(
    parameter MEM_WIDTH = 16,
    parameter N_TRACKS  = 64,
    parameter TRK_W     = 6     // ceil(log2(N_TRACKS))
)(
    input  wire                         clk,

    // 읽기 포트 (동기, 1클럭 지연)
    input  wire [TRK_W-1:0]             rd_track,
    input  wire [7:0]                   rd_neuron,   // 0~161
    output reg  signed [MEM_WIDTH-1:0]  rd_data,

    // 쓰기 포트 (동기)
    input  wire                         wr_en,
    input  wire [TRK_W-1:0]             wr_track,
    input  wire [7:0]                   wr_neuron,
    input  wire signed [MEM_WIDTH-1:0]  wr_data
);

    localparam DEPTH = N_TRACKS * 256;

    reg signed [MEM_WIDTH-1:0] mem [0:DEPTH-1];

    wire [TRK_W+8-1:0] rd_addr = {rd_track, rd_neuron};
    wire [TRK_W+8-1:0] wr_addr = {wr_track, wr_neuron};

    // 동기 읽기 (read-first: 같은 사이클 쓰기 이전 값 출력)
    always @(posedge clk)
        rd_data <= mem[rd_addr];

    // 동기 쓰기
    always @(posedge clk)
        if (wr_en)
            mem[wr_addr] <= wr_data;

endmodule
