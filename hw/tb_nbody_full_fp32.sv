// ============================================================================
// tb_nbody_full_fp32.sv — full-system testbench for nbody_accelerator_fp32.sv
//
// Run:
//   iverilog -g2012 -o sim_nbody_full32 tb_nbody_full_fp32.sv nbody_accelerator_fp32.sv
//   vvp sim_nbody_full32
// ============================================================================
`timescale 1ns/1ps

module tb_nbody_full_fp32;
    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    logic        mmio_we, mmio_re;
    logic [7:0]  mmio_addr;
    logic [31:0] mmio_wdata;
    logic [31:0] mmio_rdata;
    logic        irq;

    nbody_accelerator dut (
        .clk(clk), .rst_n(rst_n),
        .mmio_we(mmio_we), .mmio_re(mmio_re),
        .mmio_addr(mmio_addr), .mmio_wdata(mmio_wdata), .mmio_rdata(mmio_rdata),
        .irq(irq)
    );

    logic [31:0] body_words [0:34];
    initial $readmemh("/tmp/nbody_words32.hex", body_words);

    // NOTE: nbody_accelerator registers rf_host_we/rf_host_wdata one cycle
    // behind mmio_we/mmio_wdata (they're set inside an always_ff), while
    // rf_host_addr is combinational from mmio_addr. A write only lands
    // correctly if mmio_addr is still holding the same value on the cycle
    // AFTER the we pulse, i.e. back-to-back writes need >=1 idle cycle of
    // gap or the next write's address arrives before the previous write's
    // registered rf_host_we/wdata are consumed. The extra idle cycles below
    // give that margin (confirmed necessary/sufficient via tb_debug_probe.sv).
    task automatic mmio_write(input [7:0] addr, input [31:0] data);
        begin
            @(negedge clk);
            mmio_we = 1'b1; mmio_addr = addr; mmio_wdata = data;
            @(negedge clk);
            mmio_we = 1'b0;
            repeat (2) @(negedge clk);
        end
    endtask

    task automatic mmio_read(input [7:0] addr, output [31:0] data);
        begin
            @(negedge clk);
            mmio_re = 1'b1; mmio_addr = addr;
            @(negedge clk);
            data = mmio_rdata;
            mmio_re = 1'b0;
            repeat (2) @(negedge clk);
        end
    endtask

    integer i;
    longint unsigned cycle_count;
    logic irq_seen;
    logic [31:0] rdata;

    task automatic run_case(input int n_iter);
        begin
            rst_n = 1'b0; mmio_we = 0; mmio_re = 0; mmio_addr = 0; mmio_wdata = 0;
            repeat (3) @(negedge clk);
            rst_n = 1'b1;
            @(negedge clk);

            for (i = 0; i < 35; i = i + 1)
                mmio_write(8'h40 + i*8'd4, body_words[i]);

            mmio_write(8'h08, 32'h3C23D70A); // DT = 0.01 (float32)
            mmio_write(8'h0C, n_iter[31:0]); // N_ITER

            mmio_write(8'h00, 32'h1); // START

            cycle_count = 0;
            irq_seen = 1'b0;
            while (!irq_seen) begin
                @(negedge clk);
                cycle_count = cycle_count + 1;
                if (irq) irq_seen = 1'b1;
            end

            $display("=== N_ITER=%0d : DONE after %0d cycles (%0.4f cycles/iter) ===",
                      n_iter, cycle_count, real'(cycle_count) / real'(n_iter));

            for (i = 0; i < 35; i = i + 1) begin
                mmio_read(8'h40 + i*8'd4, rdata);
                $display("word[%0d] = %h", i, rdata);
            end
            $display("");
        end
    endtask

    initial begin
        run_case(1);
        run_case(2);
        run_case(5);
        $finish;
    end
endmodule
