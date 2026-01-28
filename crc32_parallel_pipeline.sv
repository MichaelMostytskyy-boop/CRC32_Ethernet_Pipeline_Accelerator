/* Michael Mostytskyy
    Project: CRC32 Ethernet Accelerator
    Description:
    Hardware implementation of a parallel CRC32 engine (IEEE 802.3)
    Processes 32 bits per cycle using LSB-first logic (Poly 0xEDB88320)
    This standard approach avoids manual bit-reversal logic
*/

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
    assign crc_out   = ~LFSR_Q;
    assign valid_out = valid_out_reg; 


    // Immediate Assertions
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

endmodule