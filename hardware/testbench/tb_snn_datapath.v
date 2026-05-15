// ============================================================
// tb_snn_datapath.v — Integrated Testbench for 4 Sub-blocks
// ============================================================
// mac_unit, lif_core, membrane_mem, spike_buffer
// Wired as snn_top, FSM behavior driven manually.
//
// Test scenarios:
//   1) Reset check
//   2) MAC output verification
//   3) LIF accumulation & firing
//   4) Full 6-clock timestep sequence
//   5) spike_buffer bit-pattern verification
//
// Run: iverilog -o tb_snn tb_snn_datapath.v mac_unit.v lif_core.v membrane_mem.v spike_buffer.v
//      vvp tb_snn
// ============================================================

`timescale 1ns / 1ps

module tb_snn_datapath;

    // -------------------------------------------------------
    // Clock & Reset
    // -------------------------------------------------------
    reg clk;
    reg rst_n;

    always #5 clk = ~clk;   // 100MHz (period 10ns)

    // -------------------------------------------------------
    // Control signals (manual FSM drive)
    // -------------------------------------------------------
    reg [2:0]  neuron_idx;
    reg        layer_sel;    // 0=hidden, 1=output
    reg        mem_wr_en;
    reg        buf_wr_en;

    // -------------------------------------------------------
    // Data signals
    // -------------------------------------------------------
    reg  [9:0]           spike_in;
    reg  [10*8-1:0]      weights;
    reg  [7:0]           beta;

    wire [9:0]           mac_spike_in;
    wire signed [15:0]   current;
    wire signed [15:0]   mem_old;
    wire signed [15:0]   mem_new;
    wire                 spike_out;
    wire [3:0]           hid_spikes;

    // -------------------------------------------------------
    // MAC input MUX
    // -------------------------------------------------------
    assign mac_spike_in = (layer_sel == 1'b0)
                        ? spike_in
                        : {6'b000000, hid_spikes};

    // -------------------------------------------------------
    // DUT instances
    // -------------------------------------------------------

    mac_unit #(.W_WIDTH(8)) u_mac (
        .spike_in   (mac_spike_in),
        .weights    (weights),
        .layer_sel  (layer_sel),
        .current    (current)
    );

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

    spike_buffer u_buf (
        .clk        (clk),
        .rst_n      (rst_n),
        .wr_idx     (neuron_idx[1:0]),
        .wr_en      (buf_wr_en),
        .spike_in   (spike_out),
        .hid_spikes (hid_spikes)
    );

    // -------------------------------------------------------
    // Weight packing task
    // -------------------------------------------------------
    task set_weights;
        input signed [7:0] w0, w1, w2, w3, w4, w5, w6, w7, w8, w9;
    begin
        weights = {w9, w8, w7, w6, w5, w4, w3, w2, w1, w0};
    end
    endtask

    // -------------------------------------------------------
    // Process one neuron (1 clock cycle)
    // -------------------------------------------------------
    task process_neuron;
        input [2:0]  idx;
        input        is_output;
        input [7:0]  b;
    begin
        neuron_idx = idx;
        layer_sel  = is_output;
        beta       = b;
        mem_wr_en  = 1'b0;
        buf_wr_en  = 1'b0;

        #1;

        $display("    [N%0d] current=%4d, mem_old=%4d, mem_new=%4d, spike=%b",
                 idx, current, mem_old, mem_new, spike_out);

        mem_wr_en = 1'b1;
        if (!is_output) buf_wr_en = 1'b1;

        @(posedge clk);
        #1;
        mem_wr_en = 1'b0;
        buf_wr_en = 1'b0;
    end
    endtask

    // -------------------------------------------------------
    // Run one timestep (6 clocks)
    // -------------------------------------------------------
    reg signed [7:0] w1_h0 [0:9];
    reg signed [7:0] w1_h1 [0:9];
    reg signed [7:0] w1_h2 [0:9];
    reg signed [7:0] w1_h3 [0:9];
    reg signed [7:0] w2_o0 [0:3];
    reg signed [7:0] w2_o1 [0:3];

    task run_one_timestep;
        input integer ts;
    begin
        $display("  --- timestep %0d (spike_in=%b) ---", ts, spike_in);

        // CLK 1: H0 (beta=0.70=179)
        set_weights(w1_h0[0],w1_h0[1],w1_h0[2],w1_h0[3],w1_h0[4],
                    w1_h0[5],w1_h0[6],w1_h0[7],w1_h0[8],w1_h0[9]);
        process_neuron(3'd0, 1'b0, 8'd179);

        // CLK 2: H1 (beta=0.80=205)
        set_weights(w1_h1[0],w1_h1[1],w1_h1[2],w1_h1[3],w1_h1[4],
                    w1_h1[5],w1_h1[6],w1_h1[7],w1_h1[8],w1_h1[9]);
        process_neuron(3'd1, 1'b0, 8'd205);

        // CLK 3: H2 (beta=0.90=230)
        set_weights(w1_h2[0],w1_h2[1],w1_h2[2],w1_h2[3],w1_h2[4],
                    w1_h2[5],w1_h2[6],w1_h2[7],w1_h2[8],w1_h2[9]);
        process_neuron(3'd2, 1'b0, 8'd230);

        // CLK 4: H3 (beta=0.95=243)
        set_weights(w1_h3[0],w1_h3[1],w1_h3[2],w1_h3[3],w1_h3[4],
                    w1_h3[5],w1_h3[6],w1_h3[7],w1_h3[8],w1_h3[9]);
        process_neuron(3'd3, 1'b0, 8'd243);

        $display("    spike_buffer = %b", hid_spikes);

        // CLK 5: Out0 (beta=0.85=217)
        set_weights(w2_o0[0], w2_o0[1], w2_o0[2], w2_o0[3],
                    8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0);
        process_neuron(3'd4, 1'b1, 8'd217);

        // CLK 6: Out1 (beta=0.85=217)
        set_weights(w2_o1[0], w2_o1[1], w2_o1[2], w2_o1[3],
                    8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0);
        process_neuron(3'd5, 1'b1, 8'd217);
    end
    endtask

    // -------------------------------------------------------
    // Main test
    // -------------------------------------------------------
    integer t;
    integer pass_count;
    integer fail_count;

    initial begin
        $dumpfile("tb_snn_datapath.vcd");
        $dumpvars(0, tb_snn_datapath);

        clk       = 0;
        rst_n     = 0;
        spike_in  = 10'b0;
        weights   = 80'b0;
        beta      = 8'd0;
        neuron_idx = 3'd0;
        layer_sel = 1'b0;
        mem_wr_en = 1'b0;
        buf_wr_en = 1'b0;
        pass_count = 0;
        fail_count = 0;

        // ===========================================================
        // Weight initialization
        // ===========================================================
        // H0: large weights on ch0,1
        w1_h0[0]= 8'sd100; w1_h0[1]= 8'sd80; w1_h0[2]= 8'sd10;
        w1_h0[3]= 8'sd5;   w1_h0[4]= 8'sd5;  w1_h0[5]= 8'sd5;
        w1_h0[6]= 8'sd5;   w1_h0[7]= 8'sd5;  w1_h0[8]= 8'sd5;
        w1_h0[9]= 8'sd5;

        // H1: evenly distributed
        w1_h1[0]= 8'sd30; w1_h1[1]= 8'sd30; w1_h1[2]= 8'sd30;
        w1_h1[3]= 8'sd30; w1_h1[4]= 8'sd30; w1_h1[5]= 8'sd30;
        w1_h1[6]= 8'sd30; w1_h1[7]= 8'sd30; w1_h1[8]= 8'sd30;
        w1_h1[9]= 8'sd30;

        // H2: small weights
        w1_h2[0]= 8'sd15; w1_h2[1]= 8'sd15; w1_h2[2]= 8'sd15;
        w1_h2[3]= 8'sd15; w1_h2[4]= 8'sd15; w1_h2[5]= 8'sd15;
        w1_h2[6]= 8'sd15; w1_h2[7]= 8'sd15; w1_h2[8]= 8'sd15;
        w1_h2[9]= 8'sd15;

        // H3: small weights + high beta for slow accumulation
        w1_h3[0]= 8'sd10; w1_h3[1]= 8'sd10; w1_h3[2]= 8'sd10;
        w1_h3[3]= 8'sd10; w1_h3[4]= 8'sd10; w1_h3[5]= 8'sd10;
        w1_h3[6]= 8'sd10; w1_h3[7]= 8'sd10; w1_h3[8]= 8'sd10;
        w1_h3[9]= 8'sd10;

        // Out0 (normal): positive weights on H0,H1
        w2_o0[0]= 8'sd120; w2_o0[1]= 8'sd100;
        w2_o0[2]= 8'sd30;  w2_o0[3]= 8'sd20;

        // Out1 (anomaly): positive weights on H2,H3
        w2_o1[0]= 8'sd20;  w2_o1[1]= 8'sd30;
        w2_o1[2]= 8'sd100; w2_o1[3]= 8'sd120;

        // ===========================================================
        // TEST 1: Reset check
        // ===========================================================
        $display("");
        $display("=========================================");
        $display(" TEST 1: Reset Check");
        $display("=========================================");

        #20;
        rst_n = 1;
        @(posedge clk);
        #1;

        neuron_idx = 3'd0; #1;
        if (mem_old === 16'sd0) begin
            $display("  PASS: H0 membrane = 0");
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: H0 membrane = %0d (expected 0)", mem_old);
            fail_count = fail_count + 1;
        end

        if (hid_spikes === 4'b0000) begin
            $display("  PASS: spike_buffer = 0000");
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: spike_buffer = %b (expected 0000)", hid_spikes);
            fail_count = fail_count + 1;
        end

        // ===========================================================
        // TEST 2: MAC output verification
        // ===========================================================
        $display("");
        $display("=========================================");
        $display(" TEST 2: MAC Output Verification");
        $display("=========================================");

        spike_in  = 10'b0000000001;
        layer_sel = 1'b0;
        set_weights(8'sd100, 8'sd50, 8'sd0, 8'sd0, 8'sd0,
                    8'sd0,   8'sd0,  8'sd0, 8'sd0, 8'sd0);
        #1;

        if (current === 16'sd100) begin
            $display("  PASS: ch0 only -> current = %0d", current);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: current = %0d (expected 100)", current);
            fail_count = fail_count + 1;
        end

        spike_in = 10'b0000000011;
        #1;

        if (current === 16'sd150) begin
            $display("  PASS: ch0+ch1 -> current = %0d", current);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: current = %0d (expected 150)", current);
            fail_count = fail_count + 1;
        end

        spike_in  = 10'b0000000000;
        layer_sel = 1'b1;
        set_weights(8'sd40, 8'sd30, 8'sd20, 8'sd10,
                    8'sd99, 8'sd99, 8'sd99, 8'sd99, 8'sd99, 8'sd99);
        #1;

        if (current === 16'sd0) begin
            $display("  PASS: output layer, hid_spk=0 -> current = %0d", current);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: current = %0d (expected 0)", current);
            fail_count = fail_count + 1;
        end

        // ===========================================================
        // TEST 3: LIF accumulation & firing
        // ===========================================================
        $display("");
        $display("=========================================");
        $display(" TEST 3: LIF Accumulation & Firing");
        $display("=========================================");

        spike_in = 10'b0000000001;

        $display("  H0 repeated stimulus (current=100, beta=179/256~0.70):");
        for (t = 0; t < 8; t = t + 1) begin
            set_weights(w1_h0[0],w1_h0[1],w1_h0[2],w1_h0[3],w1_h0[4],
                        w1_h0[5],w1_h0[6],w1_h0[7],w1_h0[8],w1_h0[9]);
            neuron_idx = 3'd0;
            layer_sel  = 1'b0;
            beta       = 8'd179;
            #1;
            $display("    t%0d: current=%4d, mem_old=%4d -> mem_new=%4d, spike=%b",
                     t, current, mem_old, mem_new, spike_out);
            mem_wr_en = 1'b1;
            @(posedge clk);
            #1;
            mem_wr_en = 1'b0;
        end

        // ===========================================================
        // TEST 4: Full timestep sequence (6 clocks)
        // ===========================================================
        $display("");
        $display("=========================================");
        $display(" TEST 4: Full Timestep Sequence");
        $display("=========================================");

        rst_n = 0;
        #20;
        rst_n = 1;
        @(posedge clk);
        #1;

        for (t = 0; t < 5; t = t + 1) begin
            spike_in = 10'b0000000011;
            run_one_timestep(t);
        end

        $display("");
        $display("  --- No-spike period (leak check) ---");
        for (t = 5; t < 8; t = t + 1) begin
            spike_in = 10'b0000000000;
            run_one_timestep(t);
        end

        // ===========================================================
        // TEST 5: spike_buffer bit-pattern verification
        // ===========================================================
        $display("");
        $display("=========================================");
        $display(" TEST 5: spike_buffer Bit Pattern");
        $display("=========================================");

        rst_n = 0; #20; rst_n = 1; @(posedge clk); #1;

        // H0=1, H1=0, H2=1, H3=0 -> expected: 4'b0101
        buf_wr_en = 1'b1;
        neuron_idx = 3'd0;
        spike_in = 10'b1111111111;
        set_weights(8'sd30, 8'sd30, 8'sd30, 8'sd30, 8'sd30,
                    8'sd30, 8'sd30, 8'sd30, 8'sd30, 8'sd30);
        layer_sel = 1'b0;
        beta = 8'd179;
        #1;
        $display("  H0: current=%0d, spike=%b", current, spike_out);
        @(posedge clk); #1;

        neuron_idx = 3'd1;
        spike_in = 10'b0000000001;
        set_weights(8'sd10, 8'sd0, 8'sd0, 8'sd0, 8'sd0,
                    8'sd0,  8'sd0, 8'sd0, 8'sd0, 8'sd0);
        #1;
        $display("  H1: current=%0d, spike=%b", current, spike_out);
        @(posedge clk); #1;

        neuron_idx = 3'd2;
        spike_in = 10'b1111111111;
        set_weights(8'sd30, 8'sd30, 8'sd30, 8'sd30, 8'sd30,
                    8'sd30, 8'sd30, 8'sd30, 8'sd30, 8'sd30);
        #1;
        $display("  H2: current=%0d, spike=%b", current, spike_out);
        @(posedge clk); #1;

        neuron_idx = 3'd3;
        spike_in = 10'b0000000001;
        set_weights(8'sd10, 8'sd0, 8'sd0, 8'sd0, 8'sd0,
                    8'sd0,  8'sd0, 8'sd0, 8'sd0, 8'sd0);
        #1;
        $display("  H3: current=%0d, spike=%b", current, spike_out);
        @(posedge clk); #1;

        buf_wr_en = 1'b0;

        if (hid_spikes[0] === 1'b1 && hid_spikes[1] === 1'b0 &&
            hid_spikes[2] === 1'b1 && hid_spikes[3] === 1'b0) begin
            $display("  PASS: spike_buffer = %b (expected 0101)", hid_spikes);
            pass_count = pass_count + 1;
        end else begin
            $display("  FAIL: spike_buffer = %b (expected 0101)", hid_spikes);
            fail_count = fail_count + 1;
        end

        // ===========================================================
        // Result summary
        // ===========================================================
        $display("");
        $display("=========================================");
        $display(" RESULT SUMMARY");
        $display("=========================================");
        $display("  PASS: %0d", pass_count);
        $display("  FAIL: %0d", fail_count);
        if (fail_count == 0)
            $display("  ALL TESTS PASSED");
        else
            $display("  SOME TESTS FAILED");
        $display("=========================================");

        #100;
        $finish;
    end

endmodule
