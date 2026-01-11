/* Michael Mostytskyy 
 Project: CRC32 Ethernet Accelerator
 Description: 
    Self-checking testbench for the CRC32 module
    Verifies the design against Golden Vectors and performs Error Detection tests
*/

`timescale 1ns / 1ps

module tb_crc32;

    // Signals to connect to the module we are testing
    logic        clk;
    logic        reset_n;
    logic        enable;
    logic        start_of_packet;
    logic [31:0] data_in;
    logic [31:0] crc_out;
    logic        valid_out;

    // The correct CRC result we expect to see (Standard Ethernet value)
    localparam logic [31:0] GOLDEN_CRC = 32'hDF8A8A2B;

    // Generate the clock signal (flips every 5ns)
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // Create the waveform file to view in GTKWave
    initial begin
        $dumpfile("waves.vcd");
        $dumpvars(0, tb_crc32);
    end

    // Connect the testbench to the design
    CRC32_parallel_pipeline u_dut (
        .clk            (clk),
        .reset_n        (reset_n),
        .enable         (enable),
        .start_of_packet(start_of_packet),
        .data_in        (data_in),
        .crc_out        (crc_out),
        .valid_out      (valid_out)
    );

    // Main simulation block
    initial begin
        // Initialize all signals to zero
        reset_n = 0;
        enable  = 0;
        start_of_packet = 0;
        data_in = 0;
        
        #50;
        
        // Release the reset so the chip can start working
        @(posedge clk); 
        reset_n = 1;
        #20;

        // Send a dummy packet just to see if data flows correctly
        @(posedge clk);
        enable = 1;
        start_of_packet = 1;
        data_in = 32'h12345678;
        
        @(posedge clk);
        start_of_packet = 0;
        data_in = 32'h9ABCDEF0;
        
        @(posedge clk);
        enable = 0;
        data_in = 0;
        
        wait(valid_out == 1); // Wait for the result
        #40;
        
        // Test 1 -> Golden Vector Check
        // We send known data and check if the result matches the standard
        $display("\nTime: %0t |Test: golden vector check", $time);
        
        @(posedge clk);
        enable = 1;
        start_of_packet = 1;
        data_in = 32'h12345678;
        
        @(posedge clk);
        enable = 0;
        start_of_packet = 0;
        data_in = 0;
        
        wait(valid_out == 1);
        @(negedge clk);

        // Check if the output matches the expected Golden Value
        if (crc_out == GOLDEN_CRC) begin
            $display("\tPASS -> standard CRC32 verified!");
            $display("\tInput: 12345678 -> output: %h", crc_out);
        end else begin
            $display("\tFAIL -> expected: %h, got: %h", GOLDEN_CRC, crc_out);
        end

        #50;

        // Test 2 -> Error Detection Check
        // We send bad data (bit flip) and make sure the CRC changes
        $display("\nTime: %0t |Test: error detection check", $time);

        @(posedge clk);
        enable = 1;
        start_of_packet = 1;
        data_in = 32'h12345679; // Notice the 9 at the end  is error injected
        
        @(posedge clk);
        enable = 0;
        start_of_packet = 0;
        data_in = 0;
        
        wait(valid_out == 1);
        @(negedge clk);

        // The CRC should be different from the Golden one
        if (crc_out != GOLDEN_CRC) begin
            $display("\tPASS -> error detected successfully!");
            $display("\tCorrupted Input -> new CRC: %h (different from golden)", crc_out);
        end else begin
            $display("\tFAIL -> collision corrupted data produced same CRC.");
        end

        #50;
        $display("\nTime: %0t |all tests finished", $time);
        $finish; // Stop the simulation
    end

endmodule