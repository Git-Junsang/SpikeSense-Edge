// clk_div2.v — 100 MHz → 50 MHz 클럭 2분주
//
// 시분할 SNN은 50 MHz에서 타이밍이 닫힌다(임계경로 15.3ns < 20ns).
// Nexys A7 입력 오실레이터가 100 MHz(E3)라 2분주한다.
//   - 합성(SYNTHESIS): 분주 FF → BUFG로 전역 클럭망에 올림
//   - 시뮬레이션: BUFG 미지원 → 분주 FF를 그대로 사용
// XDC에서 create_generated_clock(-divide_by 2)로 50MHz를 선언한다.

`timescale 1ns/1ps

module clk_div2 (
    input  wire clk_in,    // 100 MHz
    output wire clk_out    // 50 MHz
);
    reg div = 1'b0;
    always @(posedge clk_in)
        div <= ~div;

`ifdef SYNTHESIS
    // 분주 클럭은 전역 버퍼(BUFG)로 라우팅
    BUFG u_clkbuf (.I(div), .O(clk_out));
`else
    assign clk_out = div;
`endif

endmodule
