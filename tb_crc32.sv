/* Michael Mostytskyy
   Project: CRC32 Ethernet Accelerator
   Description:
    Hardware implementation of a parallel CRC32 engine (IEEE 802.3).
    Processes 32 bits per cycle using LSB-first logic.
    Features:
    - Automatic bit-reversal of the official polynomial (0x04C11DB7 -> 0xEDB88320).
    - Two register stages: input capture and CRC state (timing isolation of the XOR network).

    Testbench: self-checking scoreboard, golden vectors, edge cases, randomized traffic,
    gaps between packets and true back-to-back packets (no idle cycle).
    With +define+CRC_ASSERT the DUT's SVA failures are added to the final status.
*/

`timescale 1ns / 1ps

module tb_crc32;

    // Signals
    logic        clk;
    logic        reset_n;
    logic        enable;
    logic        start_of_packet;
    logic        last_word;
    logic [31:0] data_in;
    logic [31:0] crc_out;
    logic        valid_out;

    // Scoreboard
    logic [31:0] expected_queue [$]; 
    int          error_count = 0;
    int          packets_received = 0;
    logic [31:0] last_crc;          // CRC seen at the most recent valid_out

    // Golden CRC Parameters (verified against zlib.crc32 on little-endian bytes)
    localparam logic [31:0] GOLDEN_CRC    = 32'hAF6D87D2;   // 0x12345678
    localparam logic [31:0] AVALANCHE_CRC = 32'h17D1E0B7;   // 0x12345679

    // Clock Generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // Waveform setup
    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_crc32);
    end

    // DUT Instantiation
    CRC32_parallel_pipeline u_dut (
        .clk            (clk),
        .reset_n        (reset_n),
        .enable         (enable),
        .start_of_packet(start_of_packet),
        .last_word      (last_word),
        .data_in        (data_in),
        .crc_out        (crc_out),
        .valid_out      (valid_out)
    );

    // Reference Model
    function automatic logic [31:0] calculate_reference_crc(input logic [31:0] packet_data[]);
        logic [31:0] crc_reg = 32'hFFFFFFFF;
        logic [31:0] polynom = 32'hEDB88320;
        logic [31:0] current_word;

        foreach (packet_data[i]) begin
            current_word = packet_data[i];
            for (int bit_idx = 0; bit_idx < 32; bit_idx++) begin
                if ((crc_reg[0] ^ current_word[bit_idx]))
                    crc_reg = (crc_reg >> 1) ^ polynom;
                else
                    crc_reg = (crc_reg >> 1);
            end
        end
        return ~crc_reg;
    endfunction

    // Drive Task (one packet, idle cycle afterwards)
    task automatic drive_packet(input logic [31:0] data[]);
        logic [31:0] calculated_crc;
        int pkt_len;
        pkt_len = data.size();

        calculated_crc = calculate_reference_crc(data);
        expected_queue.push_back(calculated_crc);

        @(posedge clk);
        enable <= 1;
        for (int i = 0; i < pkt_len; i++) begin
            start_of_packet <= (i == 0);
            last_word       <= (i == pkt_len - 1);
            data_in         <= data[i];
            @(posedge clk);
        end
        
        enable          <= 0;
        start_of_packet <= 0;
        last_word       <= 0;
        data_in         <= 0;
    endtask

    // Drive Task: two packets with NO idle cycle between them
    task automatic drive_b2b(input logic [31:0] a[], input logic [31:0] b[]);
        int na;
        int nb;
        na = a.size();
        nb = b.size();

        expected_queue.push_back(calculate_reference_crc(a));
        expected_queue.push_back(calculate_reference_crc(b));

        @(posedge clk);
        enable <= 1;
        for (int i = 0; i < na + nb; i++) begin
            start_of_packet <= (i == 0) || (i == na);
            last_word       <= (i == na - 1) || (i == na + nb - 1);
            data_in         <= (i < na) ? a[i] : b[i - na];
            @(posedge clk);
        end

        enable          <= 0;
        start_of_packet <= 0;
        last_word       <= 0;
        data_in         <= 0;
    endtask

    // Monitor Process
    initial begin
        forever begin
            @(posedge clk);
            if (valid_out) begin
                logic [31:0] expected;
                last_crc = crc_out;
                if (expected_queue.size() == 0) begin
                    $error("Time %0t: Unexpected valid_out! Queue is empty.", $time);
                    error_count++;
                end else begin
                    expected = expected_queue.pop_front();
                    packets_received++;
                    if (crc_out !== expected) begin
                        $error("Time %0t: CRC Mismatch! Exp: %h, Got: %h", $time, expected, crc_out);
                        error_count++;
                    end else begin
                        $display("Time %0t: Packet %0d Verified. CRC: %h", $time, packets_received, crc_out);
                    end
                end
            end
            if (!reset_n && valid_out) begin
                $fatal(1, "Protocol Error! valid_out active during Reset.");
            end
        end
    end

    // Main Test Stimulus
    initial begin
        // --- Variable Declarations (MUST BE AT TOP) ---
        logic [31:0] pkt1[];
        logic [31:0] pkt2[];
        logic [31:0] pkt3[];
        logic [31:0] zeros_pkt[];
        logic [31:0] ones_pkt[];
        logic [31:0] random_pkt[];
        logic [31:0] rb_a[];
        logic [31:0] rb_b[];
        int random_len;
        int len_a;
        int len_b;
        int total_errors;

        // Init
        reset_n = 0; enable = 0; start_of_packet = 0; last_word = 0; data_in = 0;
        
        fork
            // Thread A: Testing
            begin
                #50;
                @(posedge clk); reset_n = 1; #20;

                $display("--- Starting Verification ---");

                // 1. Golden Vector (0x12345678 -> 0xAF6D87D2)
                pkt1 = '{32'h12345678};
                drive_packet(pkt1);
                
                while (packets_received < 1) @(posedge clk);
                if (last_crc === GOLDEN_CRC) 
                    $display(">> GOLDEN CHECK PASSED (0x%h)", last_crc);
                else begin
                    $error(">> GOLDEN CHECK FAILED: got 0x%h", last_crc);
                    error_count++;
                end
                #50;

                // 1.5 One-bit change in the input must change the CRC (0x12345679 -> 0x17D1E0B7)
                pkt3 = '{32'h12345679};
                drive_packet(pkt3);
                while (expected_queue.size() > 0) @(posedge clk);
                if (last_crc === AVALANCHE_CRC && last_crc !== GOLDEN_CRC)
                    $display(">> ONE-BIT-CHANGE CHECK PASSED (0x%h)", last_crc);
                else begin
                    $error(">> ONE-BIT-CHANGE CHECK FAILED: got 0x%h", last_crc);
                    error_count++;
                end
                #50;

                // 2. Packets with an idle gap between them
                pkt2 = '{32'hDEADBEEF, 32'hCAFEBABE};
                drive_packet(pkt2); 
                drive_packet(pkt1);
                #50;

                // 2.1 True back-to-back packets (no idle cycle between them)
                $display("--- Testing True Back-to-Back ---");
                drive_b2b(pkt2, pkt1);
                drive_b2b(pkt1, pkt1);   // two single-word packets in consecutive cycles
                #50;

                // 2.5 Edge Cases: All Zeros and All Ones
                $display("--- Testing Edge Cases ---");
                
                // All Zeros
                zeros_pkt = new[5];
                foreach(zeros_pkt[i]) zeros_pkt[i] = 32'h00000000;
                drive_packet(zeros_pkt);
                
                // All Ones
                ones_pkt = new[5];
                foreach(ones_pkt[i]) ones_pkt[i] = 32'hFFFFFFFF;
                drive_packet(ones_pkt);
                #50;

                // 3. Random Loop
                $display("--- Starting Randomized Traffic ---");
                for (int i = 0; i < 20; i++) begin
                    random_len = $urandom_range(1, 10);
                    random_pkt = new[random_len];
                    foreach(random_pkt[j]) random_pkt[j] = $urandom();
                    drive_packet(random_pkt);
                    #20;
                end

                // 3.5 Random back-to-back pairs
                $display("--- Starting Randomized Back-to-Back Traffic ---");
                for (int i = 0; i < 10; i++) begin
                    len_a = $urandom_range(1, 6);
                    len_b = $urandom_range(1, 6);
                    rb_a = new[len_a];
                    rb_b = new[len_b];
                    foreach(rb_a[j]) rb_a[j] = $urandom();
                    foreach(rb_b[j]) rb_b[j] = $urandom();
                    drive_b2b(rb_a, rb_b);
                    #20;
                end

                // Wait for completion
                while (expected_queue.size() > 0) begin
                    @(posedge clk);
                end
                #500;
                
                total_errors = error_count;
`ifdef CRC_ASSERT
                total_errors = total_errors + u_dut.sva_fails;
`endif

                $display("\n--- TEST FINISHED ---");
                if (total_errors == 0) begin
                    $display("\n SUCCESS: All %0d packets passed.", packets_received);
`ifdef CRC_ASSERT
                    $display(" Scoreboard Empty. SVA failures: %0d.\n", u_dut.sva_fails);
`else
                    $display(" Scoreboard Empty. (SVA not enabled)\n");
`endif
                end else begin
                    $display("FAILURE: %0d errors found (scoreboard/golden: %0d).", total_errors, error_count);
`ifdef CRC_ASSERT
                    $display("         SVA failures: %0d", u_dut.sva_fails);
`endif
                end
            end

            // Thread B: Watchdog
            begin
                repeat(400000) @(posedge clk); 
                $fatal(1, "\nERROR: Simulation TIMEOUT! Something is stuck.\n");
            end
        join_any
        
        $finish;
    end
endmodule