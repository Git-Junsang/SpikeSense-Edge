// ============================================================
// tb_snn_top.v — snn_top Full System Testbench
// ============================================================
// Generates synthetic 16-bit PCM audio and feeds it into snn_top.
// Monitors anomaly_flag transitions.
//
// Test scenario:
//   1) Reset check
//   2) Normal signal (gentle sine wave) for ~1000 samples
//   3) Anomaly signal (large jumps crossing multiple levels) for ~1000 samples
//   4) Return to normal for ~500 samples
//   5) Observe anomaly_flag transitions
//
// Run: iverilog -o tb_top tb_snn_top.v snn_top.v level_crossing_enc.v
//        control_fsm.v weight_rom.v mac_unit.v lif_core.v
//        membrane_mem.v spike_buffer.v anomaly_judge.v
//      vvp tb_top
// ============================================================

`timescale 1ns / 1ps

module tb_snn_top;

    // -------------------------------------------------------
    // Clock & Reset
    // -------------------------------------------------------
    reg clk;
    reg rst_n;

    always #5 clk = ~clk;   // 100MHz

    // -------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------
    reg  signed [15:0] sample_in;
    reg                sample_valid;
    wire               anomaly_flag;
    wire               busy;

    // -------------------------------------------------------
    // DUT instance
    // -------------------------------------------------------
    snn_top u_dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .sample_in    (sample_in),
        .sample_valid (sample_valid),
        .anomaly_flag (anomaly_flag),
        .busy         (busy)
    );

    // -------------------------------------------------------
    // Sample injection task
    // -------------------------------------------------------
    // Mimics 16kHz sample rate:
    //   At 100MHz, 1 sample period = 6250 clocks
    //   We wait until FSM is done, then wait remaining clocks.
    //   For simulation speed, we use a shorter wait.

    task send_sample;
        input signed [15:0] sample;
    begin
        sample_in    = sample;
        sample_valid = 1'b1;
        @(posedge clk);
        #1;
        sample_valid = 1'b0;

        // Wait for FSM to finish (max 10 clocks)
        repeat (10) @(posedge clk);
        #1;
    end
    endtask

    // -------------------------------------------------------
    // Sine wave LUT (simple 16-step approximation)
    // -------------------------------------------------------
    // Generates smooth sine-like waveform
    // Amplitude controlled by scale parameter

    reg signed [15:0] sine_lut [0:15];

    initial begin
        // sin(0..2pi) * 32767, sampled at 16 points
        sine_lut[ 0] =  16'sd0;
        sine_lut[ 1] =  16'sd12539;
        sine_lut[ 2] =  16'sd23170;
        sine_lut[ 3] =  16'sd30273;
        sine_lut[ 4] =  16'sd32767;
        sine_lut[ 5] =  16'sd30273;
        sine_lut[ 6] =  16'sd23170;
        sine_lut[ 7] =  16'sd12539;
        sine_lut[ 8] =  16'sd0;
        sine_lut[ 9] = -16'sd12539;
        sine_lut[10] = -16'sd23170;
        sine_lut[11] = -16'sd30273;
        sine_lut[12] = -16'sd32767;
        sine_lut[13] = -16'sd30273;
        sine_lut[14] = -16'sd23170;
        sine_lut[15] = -16'sd12539;
    end

    // -------------------------------------------------------
    // Main test
    // -------------------------------------------------------
    integer i;
    integer sample_count;
    integer phase;
    reg signed [15:0] sample_val;
    reg prev_anomaly;

    // Monitoring internal signals for debug
    wire [23:0] cnt_n = u_dut.u_judge.cnt_normal;
    wire [23:0] cnt_a = u_dut.u_judge.cnt_anomaly;
    wire [3:0]  hspk  = u_dut.hid_spikes;
    wire        spk_o0 = u_dut.spk_normal_reg;
    wire        spk_o1 = u_dut.spk_anomaly_reg;

    initial begin
        $dumpfile("tb_snn_top.vcd");
        $dumpvars(0, tb_snn_top);

        clk          = 0;
        rst_n        = 0;
        sample_in    = 16'sd0;
        sample_valid = 1'b0;
        prev_anomaly = 1'b0;
        sample_count = 0;

        // ===========================================================
        // TEST 1: Reset check
        // ===========================================================
        $display("");
        $display("=========================================");
        $display(" TEST 1: Reset Check");
        $display("=========================================");

        #100;
        rst_n = 1;
        @(posedge clk); #1;

        if (anomaly_flag === 1'b0)
            $display("  PASS: anomaly_flag = 0 after reset");
        else
            $display("  FAIL: anomaly_flag = %b (expected 0)", anomaly_flag);

        if (busy === 1'b0)
            $display("  PASS: busy = 0 after reset");
        else
            $display("  FAIL: busy = %b (expected 0)", busy);

        // ===========================================================
        // TEST 2: Normal signal (~1000 samples)
        // ===========================================================
        $display("");
        $display("=========================================");
        $display(" TEST 2: Normal Signal (gentle sine)");
        $display("=========================================");

        phase = 0;
        for (i = 0; i < 1000; i = i + 1) begin
            // Gentle sine wave: small amplitude = few level crossings
            sample_val = sine_lut[phase] >>> 3;  // scale down (amplitude ~4096)
            send_sample(sample_val);
            phase = (phase + 1) & 4'hF;  // wrap at 16
            sample_count = sample_count + 1;

            // Print status every 200 samples
            if ((i+1) % 200 == 0) begin
                $display("  sample %4d: anomaly=%b, cnt_n=%6d, cnt_a=%6d, hid_spk=%b, o0=%b, o1=%b",
                         sample_count, anomaly_flag, cnt_n, cnt_a, hspk, spk_o0, spk_o1);
            end
        end

        $display("  >> After normal phase: anomaly_flag = %b", anomaly_flag);

        // ===========================================================
        // TEST 3: Anomaly signal (~1000 samples)
        // ===========================================================
        $display("");
        $display("=========================================");
        $display(" TEST 3: Anomaly Signal (large jumps)");
        $display("=========================================");

        for (i = 0; i < 1000; i = i + 1) begin
            // Large amplitude signal: crosses many levels
            sample_val = sine_lut[phase];  // full amplitude (~32767)
            // Add random-like impulses every 50 samples
            if (i % 50 < 5)
                sample_val = (i % 2 == 0) ? 16'sd30000 : -16'sd30000;

            send_sample(sample_val);
            phase = (phase + 3) & 4'hF;  // faster frequency
            sample_count = sample_count + 1;

            if ((i+1) % 200 == 0) begin
                $display("  sample %4d: anomaly=%b, cnt_n=%6d, cnt_a=%6d, hid_spk=%b, o0=%b, o1=%b",
                         sample_count, anomaly_flag, cnt_n, cnt_a, hspk, spk_o0, spk_o1);
            end

            // Detect anomaly_flag transition
            if (anomaly_flag && !prev_anomaly) begin
                $display("  *** anomaly_flag RISING at sample %0d ***", sample_count);
            end
            prev_anomaly = anomaly_flag;
        end

        $display("  >> After anomaly phase: anomaly_flag = %b", anomaly_flag);

        // ===========================================================
        // TEST 4: Return to normal (~500 samples)
        // ===========================================================
        $display("");
        $display("=========================================");
        $display(" TEST 4: Return to Normal");
        $display("=========================================");

        for (i = 0; i < 500; i = i + 1) begin
            sample_val = sine_lut[phase] >>> 3;  // gentle again
            send_sample(sample_val);
            phase = (phase + 1) & 4'hF;
            sample_count = sample_count + 1;

            if ((i+1) % 100 == 0) begin
                $display("  sample %4d: anomaly=%b, cnt_n=%6d, cnt_a=%6d",
                         sample_count, anomaly_flag, cnt_n, cnt_a);
            end

            // Detect anomaly_flag falling
            if (!anomaly_flag && prev_anomaly) begin
                $display("  *** anomaly_flag FALLING at sample %0d ***", sample_count);
            end
            prev_anomaly = anomaly_flag;
        end

        $display("  >> After recovery phase: anomaly_flag = %b", anomaly_flag);

        // ===========================================================
        // TEST 5: Timing verification
        // ===========================================================
        $display("");
        $display("=========================================");
        $display(" TEST 5: FSM Timing Check");
        $display("=========================================");

        // Send one sample and count clocks until done
        sample_val = 16'sd10000;
        sample_in    = sample_val;
        sample_valid = 1'b1;
        @(posedge clk); #1;
        sample_valid = 1'b0;

        // Wait for busy to rise
        @(posedge busy); #1;
        $display("  FSM started (busy=1)");

        // Count clocks until done
        begin : count_block
            integer clk_count;
            clk_count = 0;
            while (!u_dut.fsm_done) begin
                @(posedge clk);
                clk_count = clk_count + 1;
                if (clk_count > 20) begin
                    $display("  FAIL: FSM did not complete within 20 clocks");
                    disable count_block;
                end
            end
            $display("  FSM completed in %0d clocks (expected ~6)", clk_count);
            if (clk_count == 6)
                $display("  PASS: Correct timing");
            else
                $display("  INFO: Check FSM state transitions");
        end

        // ===========================================================
        // Summary
        // ===========================================================
        $display("");
        $display("=========================================");
        $display(" SIMULATION COMPLETE");
        $display("=========================================");
        $display("  Total samples processed: %0d", sample_count);
        $display("  Final anomaly_flag: %b", anomaly_flag);
        $display("  Final cnt_normal:  %0d", cnt_n);
        $display("  Final cnt_anomaly: %0d", cnt_a);
        $display("=========================================");

        #200;
        $finish;
    end

endmodule
