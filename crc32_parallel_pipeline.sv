/* Michael Mostytskyy
    Project: CRC32 Ethernet Accelerator
    Description:
    Hardware implementation of a parallel CRC32 engine (IEEE 802.3)
    Processes 32 bits per cycle using LSB-first logic (Poly 0xEDB88320)
    This standard approach avoids manual bit-reversal logic

    Two register stages: (1) input capture, (2) CRC state / valid.
    valid_out is seen 2 clock edges after last_word is sampled.

    Compile options:
      +define+CRC_ASSERT           enable SVA (needs a simulator with concurrent-assertion support)
      +define+INJECT_CRC_BUG       mutation: wrong final CRC bit (testbench sensitivity check)
      +define+INJECT_LATENCY_BUG   mutation: valid_out one cycle late (SVA sensitivity check)
*/

`timescale 1ns / 1ps

module CRC32_parallel_pipeline #(
    parameter logic [31:0] CRC_INIT = 32'hFFFFFFFF
)
(
    input  logic        clk,
    input  logic        reset_n,
    input  logic        enable,          // Tells us when data is valid
    input  logic        start_of_packet, // Resets the calculation for a new packet
    input  logic        last_word,
    input  logic [31:0] data_in,         // The input data
    
    output logic [31:0] crc_out,         // The result
    output logic        valid_out        // Tells the output interface the result is ready
);

    localparam logic [31:0] OFFICIAL_POLY = 32'h04C11DB7;
 // Function to reverse bits (MSB -> LSB conversion)
    function automatic logic [31:0] reverse_bits(input logic [31:0] in_data);
        logic [31:0] out_data;
        for (int i = 0; i < 32; i++) begin
            out_data[i] = in_data[31-i];
        end
        return out_data;
    endfunction

    localparam logic [31:0] POLYNOM = reverse_bits(OFFICIAL_POLY);

    // Internal signals used for the pipeline
    logic [31:0] data_in_pipe; 
    logic        enable_pipe;  
    logic        start_pipe;   
    logic        last_pipe;

    // Registers for the CRC state
    logic [31:0] LFSR_Q;       // The current value
    logic [31:0] LFSR_NEXT;    // The next value we are calculating
    logic        valid_out_reg;

    // Save the inputs into registers to improve timing
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            data_in_pipe <= 32'b0;
            enable_pipe  <= 1'b0;
            start_pipe   <= 1'b0;
            last_pipe    <= 1'b0;
        end else begin
            data_in_pipe <= enable ? data_in : 32'b0;
            enable_pipe  <= enable;
            start_pipe   <= enable && start_of_packet;
            last_pipe    <= enable && last_word;
        end
    end

    // Calculating the next CRC value (LSB First logic)
    always @(*) begin
        logic [31:0] current_state;
        logic [31:0] crc_temp;

        // Select initial value or current state
        if (start_pipe) begin
            current_state = CRC_INIT; 
        end else begin
            current_state = LFSR_Q;   
        end

        crc_temp = current_state;

        // Loop for calculating all 32 bits in parallel
        for (int i = 0; i < 32; i++) begin
            // Check LSB interaction
            if ((crc_temp[0] ^ data_in_pipe[i])) begin
                crc_temp = (crc_temp >> 1) ^ POLYNOM;
            end else begin
                crc_temp = (crc_temp >> 1);
            end
        end

        LFSR_NEXT = crc_temp;
    end

    // Update the final register with the new result
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            LFSR_Q <= CRC_INIT;
            valid_out_reg <= 1'b0;
        end else begin
            // Only update if we are enabled
            if (enable_pipe) begin
                LFSR_Q <= LFSR_NEXT;
            end
            
            if (enable_pipe && last_pipe) begin
                valid_out_reg <= 1'b1;
            end else begin
                valid_out_reg <= 1'b0;
            end
        end
    end

    // Connect the internal registers to the outputs
`ifdef INJECT_CRC_BUG
    assign crc_out   = ~LFSR_Q ^ 32'h0000_0001;   // intentional bug: flips bit 0 of the result
`else
    assign crc_out   = ~LFSR_Q;
`endif

`ifdef INJECT_LATENCY_BUG
    // intentional bug: valid_out is delayed by one extra cycle
    logic valid_out_dly;
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) valid_out_dly <= 1'b0;
        else          valid_out_dly <= valid_out_reg;
    end
    assign valid_out = valid_out_dly;
`else
    assign valid_out = valid_out_reg;
`endif


`ifdef CRC_ASSERT
    // ---------------- Protocol / latency assertions (SVA) ----------------
    int sva_fails = 0;   // read by the testbench so a failed assertion is never reported as PASSED

    default clocking cb @(posedge clk); endclocking
    default disable iff (!reset_n);

    // Control signals are only legal while enable is high
    a_sop_needs_enable: assert property (start_of_packet |-> enable)
        else begin sva_fails++; $error("[SVA] start_of_packet asserted without enable"); end

    a_last_needs_enable: assert property (last_word |-> enable)
        else begin sva_fails++; $error("[SVA] last_word asserted without enable"); end

    // Latency: valid_out is seen 2 clock edges after last_word is sampled
    a_latency: assert property ((enable && last_word) |-> ##2 valid_out)
        else begin sva_fails++; $error("[SVA] valid_out did not rise 2 cycles after last_word"); end

    // valid_out only ever follows a last_word (no spurious valid)
    a_no_spurious_valid: assert property (valid_out |-> $past(enable && last_word, 2))
        else begin sva_fails++; $error("[SVA] valid_out without a matching last_word"); end

    // Hold behavior: the result does not change while the pipeline has no valid data
    a_hold_state: assert property ((!enable_pipe) |=> $stable(crc_out))
        else begin sva_fails++; $error("[SVA] crc_out changed while the engine was idle"); end

    // Cover: true back-to-back frames (no idle cycle between them)
    c_back_to_back: cover property ((enable && last_word) ##1 (enable && start_of_packet));
    // Cover: a normal frame with a gap before the next one
    c_gap_between:  cover property ((enable && last_word) ##1 !enable);
`else
    // Fallback checks for simulators without concurrent-assertion support (e.g. Icarus)
    always @(posedge clk) begin
        if (reset_n) begin
            // Check 1: start_of_packet should only be high if enable is high
            if (start_of_packet && !enable) begin
                $error("Protocol Violation: 'start_of_packet' asserted without 'enable'!");
            end

            // Check 2: last_word should only be high if enable is high
            if (last_word && !enable) begin
                $error("Protocol Violation: 'last_word' asserted without 'enable'!");
            end
        end
    end
`endif

endmodule