/* Michael Mostytskyy
 Project: CRC32 Ethernet Accelerator
 Description: 
    Hardware implementation of a parallel CRC32 engine (IEEE 802.3)
    It processes 32 bits per cycle using a pipeline stage for high speed
*/

module CRC32_parallel_pipeline (
    input  logic        clk,
    input  logic        reset_n,
    input  logic        enable,          // Tells us when data is valid
    input  logic        start_of_packet, // Resets the calculation for a new packet
    input  logic [31:0] data_in,         // The input data
    
    output logic [31:0] crc_out,         // The result
    output logic        valid_out        // Tells the output interface the result is ready
);

    // The standard polynomial used for Ethernet
    localparam logic [31:0] POLYNOM  = 32'h04C11DB7;
    // CRC always starts with this value
    localparam logic [31:0] CRC_INIT = 32'hFFFFFFFF;

    // Internal signals used for the pipeline
    logic [31:0] data_in_pipe; 
    logic        enable_pipe;  
    logic        start_pipe;   
    
    // Registers for the CRC state
    logic [31:0] LFSR_Q;       // The current value
    logic [31:0] LFSR_NEXT;    // The next value we are calculating

    // Connect the internal registers to the outputs
    assign crc_out   = LFSR_Q;
    assign valid_out = enable_pipe; 

    // Save the inputs into registers to improve timing
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            data_in_pipe <= 32'b0;
            enable_pipe  <= 1'b0;
            start_pipe   <= 1'b0;
        end else begin
            data_in_pipe <= data_in;
            enable_pipe  <= enable;
            start_pipe   <= start_of_packet;
        end
    end

    // Calculating the next CRC value
    always @(*) begin
        logic [31:0] current_state;

        // Select initial value or current state
        if (start_pipe) begin
            current_state = CRC_INIT; 
        end else begin
            current_state = LFSR_Q;   
        end

        LFSR_NEXT = current_state;

        // Loop for calculating all 32 bits in parallel
        for (int i = 0; i < 32; i++) begin
            // Check if the top bit matches
            if (LFSR_NEXT[31] ^ data_in_pipe[31-i]) begin
                 // Shift left and apply the polynomial
                 LFSR_NEXT = (LFSR_NEXT << 1) ^ POLYNOM;
            end else begin
                 // Shift left
                 LFSR_NEXT = (LFSR_NEXT << 1);
            end
        end
    end

    // Update the final register with the new result
    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            LFSR_Q <= CRC_INIT;
        end else if (enable_pipe) begin
            // Only update if we are enabled
            LFSR_Q <= LFSR_NEXT;
        end
    end

endmodule