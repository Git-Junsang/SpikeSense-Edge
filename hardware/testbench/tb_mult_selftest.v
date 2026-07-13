// tb_mult_selftest.v — 보드 자가진단(mult_selftest_top) 시뮬 검증
// 보드에 굽기 전, 자가진단 로직이 골든 입력에 대해 PASS(LED15)를
// 내는지 iverilog로 확인한다. led[13]=done 대기 후 led[15]=PASS 검사.
//
// 실행:
//   /usr/bin/iverilog -g2001 -o hardware/sim/mult_selftest \
//       hardware/testbench/tb_mult_selftest.v hardware/src/*.v
//   /usr/bin/vvp hardware/sim/mult_selftest

`timescale 1ns/1ps

module tb_mult_selftest;

reg clk = 0;
always #5 clk = ~clk;          // 100 MHz 입력
reg rst_n = 0;
wire [15:0] led;

mult_selftest_top dut (.clk(clk), .rst_n(rst_n), .led(led));

integer cyc = 0;

initial begin
    rst_n = 0;
    repeat (6) @(posedge clk); #1;
    rst_n = 1;

    // done(led[13]) 대기 (31ts × ~9.6k clk50 ≈ 충분히 큰 한계)
    while (led[13] !== 1'b1 && cyc < 1500000) begin
        @(posedge clk);
        cyc = cyc + 1;
    end

    $display("");
    $display("============================================");
    $display("  tb_mult_selftest — 보드 자가진단 시뮬");
    $display("============================================");
    if (led[13] !== 1'b1) begin
        $display("  NG  done 미도달 (timeout, cyc=%0d)", cyc);
    end else begin
        $display("  done=1 @cyc=%0d", cyc);
        $display("  led = %b", led);
        $display("  불일치(led[6:0]) = %0d", led[6:0]);
        if (led[15] === 1'b1 && led[14] === 1'b0)
            $display("  OK  PASS (LED15=1) — 골든 스파이크 62개 전부 일치");
        else
            $display("  NG  FAIL (LED15=%0d LED14=%0d)", led[15], led[14]);
    end
    $display("============================================");
    $display("");
    $finish;
end

endmodule
