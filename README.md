# High-Performance Parallel Pipeline CRC32 Accelerator

## 1. Introduction
This project implements a high-speed, hardware-based **CRC32 (Cyclic Redundancy Check)** accelerator using SystemVerilog. Unlike traditional serial implementations that process one bit per cycle, this design utilizes a **Parallel Pipeline Architecture** to process **32-bit data chunks per clock cycle**.

The core is fully compliant with the **IEEE 802.3 (Ethernet)** standard polynomial (`0x04C11DB7`) and is optimized for high-throughput network applications and data integrity verification.

## 2. Key Features
* **Parallel Processing:** Computes CRC for full 32-bit words in a single clock cycle using a combinational XOR tree.
* **Pipelined Architecture:** Includes an input sampling stage to decouple timing paths and improve maximum frequency (Fmax).
* **Standard Compliance:** Verified against standard Ethernet CRC32 "Golden Vectors".
* **Zero-Wait State:** Supports back-to-back packet processing without requiring idle cycles between transactions.
* **Robust Control:** Features **asynchronous active-low reset** and dedicated `start_of_packet` signaling for frame synchronization.

## 3. Architecture Overview
The design follows a 2-stage pipeline approach to ensure signal stability and timing closure:

1.  **Input Sampling Stage:**
    All inputs (`data_in`, `enable`, `start_of_packet`) are registered. This isolates the complex XOR logic from external input delays and ensures clean signal timing.

2.  **CRC Calculation Engine:**
    The core logic implements a parallel Linear Feedback Shift Register (LFSR) emulation.
    * **LFSR Configuration:** Implements **Galois (Modular)** architecture to minimize critical path delay and maximize operating frequency.
    * **Logic:** A combinational `for` loop generates the next CRC state based on the current state and the incoming 32-bit data.
    * **Polynomial:** Uses the standard Ethernet generator `0x04C11DB7`.
    * **Initialization:** On `start_of_packet`, the CRC register is preset to `0xFFFFFFFF` as required by the standard.

## 4. Interface Description
The module interacts with the system through a synchronous interface. All operations are synchronized to the rising edge of the clock.

| Signal Name | Direction | Width | Description |
| :--- | :--- | :--- | :--- |
| **clk** | Input | 1-bit | System Clock. All internal logic triggers on the rising edge. |
| **reset_n** | Input | 1-bit | **Asynchronous Active-Low Reset**. Forces the pipeline and registers to a known state (0). |
| **enable** | Input | 1-bit | **Clock Enable**. Validates input data. High = Process, Low = Hold state. |
| **start_of_packet** | Input | 1-bit | **Sync Signal**. Asserts start of a new frame. Resets LFSR to seed (`0xFFFFFFFF`). |
| **data_in** | Input | 32-bit | **Data Payload**. The 32-bit word to be processed. |
| **crc_out** | Output | 32-bit | **CRC Result**. The calculated checksum (Valid after 1 cycle latency). |
| **valid_out** | Output | 1-bit | **Output Valid**. Indicates `crc_out` contains valid data (follows `enable` delay). |

## 5. Verification & Simulation
The project includes a comprehensive, self-checking SystemVerilog Testbench (`tb_crc32.sv`) covering:

* **Basic Data Flow:** Verifies pipeline latency (1 cycle delay) and valid signal generation.
* **Standard Compliance (Golden Vector):**
    * Input sequence: `0x12345678`
    * Expected Output: `0xDF8A8A2B`
    * Result: **PASSED** (Validated against standard models).
* **Error Detection:** Injects single-bit errors into the stream and verifies that the checksum changes, confirming error detection capability.
* **Back-to-Back Stress Test:** Simulates consecutive packets to ensure correct FSM resets.

### Simulation Waveform
The waveform below captures the simulation results for the "Golden Vector" test case.
* **Markers:**
  * `data_in`: Input payload (`0x12345678`).
  * `crc_out`: Calculated Result (`0xDF8A8A2B`).
* **Timing:** Observe the **1-cycle latency** between the valid input and the valid output.

![Simulation Waveform](images/sim_wave.png)

**Analysis of Results:**
The waveform above demonstrates two critical verification scenarios captured during the simulation:

1.  **Standard Compliance (Golden Vector) - Middle Marker:**
    * **Event:** At ~140ns, the standard input `0x12345678` is applied.
    * **Result:** The output `0xDF8A8A2B` matches the IEEE 802.3 standard exactly.

2.  **Error Detection Capability - Right Marker:**
    * **Event:** At ~200ns, a corrupted input `0x12345679` (single bit flip) is injected.
    * **Result:** The output changes to `0xDB4B979C`. This drastic change from the Golden Vector proves the "Avalanche Effect," confirming that the system effectively detects even single-bit data corruption.

## 6. File Description
* `crc32_parallel_pipeline.sv`: The synthesizable RTL design module.
* `tb_crc32.sv`: The self-checking testbench with automated PASS/FAIL reporting.

## 7. Tools Used
* **Language:** SystemVerilog (IEEE 1800-2012)
* **Simulation:** Icarus Verilog (iverilog)
* **Waveform Analysis:** GTKWave

## 8. How to Run Simulation
To compile and simulate the design using Icarus Verilog:

```bash
# 1. Compile the design and testbench
iverilog -g2012 -o crc_sim tb_crc32.sv crc32_parallel_pipeline.sv

# 2. Run the simulation
vvp crc_sim

# 3. View Waveforms (Optional)
gtkwave waves.vcd