# HWSW Project: Benchmark Optimization, Analysis, and Hardware Acceleration Proposal

Course: 00460882 - HW/SW Co-design
Author: Khaled Gharra

## Overview

This repository contains the analysis, optimization, and hardware acceleration
proposal for two benchmarks selected from the `pyperformance` framework, as
required by the course final project.

Selected benchmarks: **Raytrace** and **Nbody**

## Repository Structure

```
.
├── reports/          # report_<benchmark>.txt, baseline/optimized pyperf data, perf reports, flame graphs
├── scripts/          # script_<benchmark>.sh - setup, run, profile, compare
├── hw/               # Hardware accelerator (SystemVerilog), testbenches, block diagram
├── src/              # Original and optimized benchmark code
├── presentation/     # Slides for the project presentation
└── README.md
```

## Reproducing the Software Results

Each `scripts/script_<benchmark>.sh` handles environment setup, baseline
`pyperformance` profiling (`perf` + flame graph), the optimized run, and the
`pyperf compare_to` comparison. See each `reports/report_<benchmark>.txt` for
the full write-up (overview, profiling analysis, optimizations, performance
comparison) for that benchmark.

Both **nbody (32.9% faster)** and **raytrace (13.3% faster)** clear the
assignment's 7% improvement threshold, with real, statistically-verified
`pyperf` measurements (`reports/baseline_nbody.json`,
`reports/baseline_raytrace.json`, `reports/nbody_optimized.json`,
`reports/raytrace_optimized.json`).

## Hardware Acceleration Proposal

The hardware proposal (`hw/nbody_accelerator_fp32.sv`) targets nbody only,
per course guidance that one proposal is sufficient across the two selected
benchmarks. It is a **Pairwise Gravity Accelerator**: an IEEE-754 float32
datapath that holds all 5 bodies' state on-chip and runs the benchmark's
entire 20,000-iteration force-update loop autonomously between two MMIO
round-trips, rather than accelerating a single arithmetic operation the CPU
would still have to dispatch through software for every one of the ~1.5M
individual operations profiling identified as the real cost.

Unlike a design that is only described on paper, this one was **debugged and
verified with real RTL simulation**:
- `hw/tb_fp32_units.sv` unit-tests the four arithmetic primitives
  (`fp_mul`/`fp_add`/`fp_sqrt`/`fp_div`) against Python-computed IEEE-754
  ground truth: 14/17 exact matches, 3 expected 1-ULP truncation
  differences.
- `hw/tb_nbody_full_fp32.sv` and `hw/tb_nbody_long.sv` drive the full FSM
  through simulated MMIO with the benchmark's real solar-system data,
  found and fixed two real RTL bugs in the process, and verified
  correctness all the way out to the real `N_ITER=20000`, using energy
  conservation as the correctness check once per-position comparison stops
  being meaningful (an N-body system is chaotically sensitive to precision
  differences over that many steps).

Full architecture, register map, both bugs (with root cause), the
verification methodology, and a measured (not hand-derived) performance
estimate are in `NBODY_FP32_ACCELERATOR.md` and summarized in
`reports/report_nbody.txt` Section 5. Block diagram: `hw/nbody_block_diagram.svg`.

**Bottom line, stated as what it is - a real, simulated measurement plus a
stated assumption:** the accelerator's cycle count (1250 cycles/iteration)
is measured directly from simulation and confirmed identical from
`N_ITER=1` up through the real `N_ITER=20000` (25,000,000 cycles total).
At an assumed 200MHz clock (not synthesized - the assignment does not
require this), that's ~125ms, an estimated ~19.4% further improvement over
the optimized software (155ms), or ~45.9% over the original (231ms).
