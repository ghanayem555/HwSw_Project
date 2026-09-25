# N-Body Gravity Accelerator — float32, Verified

This is the project's hardware acceleration proposal for the `nbody`
benchmark: an IEEE-754 **float32** design (`hw/nbody_accelerator_fp32.sv`),
debugged and verified end-to-end with real RTL simulation, not just read and
reasoned about (see Section 5).

Everything below reflects the actual, current state of
`hw/nbody_accelerator_fp32.sv` after the two bug fixes described in
[What Was Actually Broken, and What Was Fixed](#5-what-was-actually-broken-and-what-was-fixed).

---

## 1. What this is

A memory-mapped hardware accelerator that runs the *entire* `advance()` inner
loop of the pyperformance `nbody` benchmark — the 10-pair gravitational
force update plus 5-body position update, repeated for however many
iterations the host requests — autonomously in hardware, between two MMIO
round trips (write state + trigger, then read result). The core idea:
the benchmark's cost is ~1.5M tiny interpreter-level operations, not one
expensive computation, so the accelerator's value comes from removing the
CPU/interpreter from the loop entirely, not from speeding up one arithmetic
op the CPU would still have to dispatch through software.

## 2. Numeric format: IEEE-754 float32

Every value (positions, velocities, masses) is a standard 32-bit IEEE-754
single-precision float: 1 sign bit, 8 exponent bits (bias 127), 23 mantissa
bits (24-bit significand with the implicit leading 1).

Float32 was chosen over a fixed-point (Q16.16) design because Q16.16 cannot
represent this workload at all: a design review found that 8 of the 10
pairwise force terms underflow to exactly zero in Q16.16 (its ~1.5e-5
resolution can't hold force magnitudes around 4e-7), and some intermediate
values overflow Q16.16's ±32768 range in the other direction. Float32 has
none of that problem, and was already checked in that same review to keep
the benchmark's energy nearly conserved - while being far cheaper in
hardware than a wider floating-point format, since the iterative `fp_sqrt`/
`fp_div` units' latency scales with the significand width they need to
converge (24 bits here).

Precision cost: float32 has ~7 decimal digits of precision, versus Python's
native float64 (~16 digits) - the benchmark's own reference implementation
runs in float64, so that's the ground truth the hardware's output is
checked against (Section 6). The hardware also **truncates** every result
instead of implementing IEEE round-to-nearest, which adds up to another ~1
ULP of error per operation. Section 6 quantifies exactly how this compounds
over the benchmark's 20,000 iterations.

## 3. Interfaces, register map

Raw synchronous memory-mapped register bus (32-bit data, 8-bit address) —
drop-in behind a thin AXI-Lite or Avalon-MM wrapper for real SoC integration.

| Address | Register | Notes |
|---|---|---|
| `0x00` | `CONTROL` | bit 0 = `START` (write 1 to trigger a run) |
| `0x04` | `STATUS` | bit 0 = `BUSY`, bit 1 = `DONE` (sticky, cleared on read) |
| `0x08` | `DT` | float32 timestep (default 0.01 → `0x3C23D70A`) |
| `0x0C` | `N_ITER` | 32-bit iteration count (default 20000) |
| `0x40`–`0xC8` | `BODY_STATE[0..34]` | 35 × 32-bit words, 4-byte stride |

`BODY_STATE` layout: word index = `body*7 + field`, `field` 0-2 = position
x/y/z, 3-5 = velocity x/y/z, 6 = mass. Body index: 0=sun, 1=jupiter,
2=saturn, 3=uranus, 4=neptune (matches `pair_rom`'s pair ordering and the
Python benchmark's `SYSTEM` list order exactly).

`irq`: single-bit line, pulses high for one cycle when a run completes
(`STATUS.DONE` is also available by polling).

**Note the `0x40`–`0xC8` range** — the original file had this as `0x40`–`0x8C`,
which was wrong; see Section 5.

## 4. Architecture

Block diagram: `hw/nbody_block_diagram.svg`.

- **`fp_mul`** — combinational float32 multiply. 0-cycle latency.
- **`fp_add`** — combinational float32 add/subtract (subtraction done by
  flipping the sign bit of the second operand before calling this). Includes
  a leading-zero-count normalization step with an explicit `lz_found`
  early-exit flag, needed so the loop stops at the first (highest) set bit
  instead of the last one it scans (see the file's own "BUG FIX" comment
  above the loop). 0-cycle latency.
- **`fp_sqrt`** — iterative non-restoring digit-recurrence square root.
  25-cycle latency (1 setup + 24 bit-pair iterations). Assumes non-negative
  input (always true for `d²` in this workload).
- **`fp_div`** — iterative restoring divider. 49-cycle latency (1 setup + 48
  iterations — the dividend register is 48 bits wide since `Ma` is
  left-shifted by 24 for fractional precision, so all 48 bits must be
  shifted through for a correct quotient). Assumes non-negative operands.
- **`body_regfile`** — 35 × 32-bit dual-ported on-chip register file (140
  bytes), one port for host MMIO access, one for the core's own read/write
  during computation.
- **`pair_rom`** — the 10 fixed `(body_i, body_j)` index pairs, purely
  combinational, matching Python's `combinations(SYSTEM)` order exactly
  (sun-jupiter, sun-saturn, sun-uranus, sun-neptune, jupiter-saturn,
  jupiter-uranus, jupiter-neptune, saturn-uranus, saturn-neptune,
  uranus-neptune).
- **`nbody_core`** — the 21-state FSM and datapath. For each of `N_ITER`
  iterations: walks all 10 pairs (load both bodies' 7 fields each, compute
  `dx/dy/dz` → `d²` → `sqrt(d²)` → `denom = d²·sqrt(d²)` → `mag = dt/denom`
  → mass-scaled velocity deltas → write both bodies' velocities back), then
  runs the 5-body position-update pass (`pos += dt·vel`).
- **`nbody_accelerator`** — top-level MMIO wrapper: address decode, the
  `CONTROL`/`STATUS`/`DT`/`N_ITER` registers, and the sticky-`DONE`/`irq`
  logic.

Structurally, `nbody_core` is a straightforward 21-state FSM: load both
bodies, compute the pairwise force, write both velocities back, repeat for
all 10 pairs, then update all 5 positions. Two real bugs in that structure
were found and fixed via simulation - see Section 5.

## 5. What Was Actually Broken, and What Was Fixed

Before this pass, **no testbench had ever exercised the full `nbody_core`
FSM** — only the standalone arithmetic primitives (`fp_mul`/`fp_add`/
`fp_sqrt`/`fp_div`) had been unit-tested (`tb_fp32_units.sv`, 14/17 exact
matches, 3 expected 1-ULP truncation diffs — those units were already
correct). Building the missing full-system testbench (`tb_nbody_full_fp32.sv`,
which drives real MMIO writes with the real solar-system data and runs the
FSM for real) immediately surfaced two real, previously-unknown bugs:

### Bug 1 — MMIO address range off by one region-size

```
// before:
//   0x40-0x8C  BODY_STATE[0..34]  35 x float32 words (140 bytes)
if (mmio_addr >= 8'h40 && mmio_addr <= 8'h8C) begin ...
```

`0x8C` (140) is the **size** of the 35-word region, not its last address.
Starting at `0x40`, word index 34 (neptune's mass) is actually at
`0x40 + 34*4 = 0xC8`. The old bound silently dropped every MMIO read/write
at word index ≥ 20 — bodies 3 and 4 (uranus, neptune) never loaded or read
back at all. This is the same class of off-by-one an earlier design review
had already flagged for a prior fixed-point (Q16.16) version of this idea -
reintroduced here and never re-checked until this pass.

**Fix:** changed both occurrences of `8'h8C` to `8'hC8` in the address
decode (`nbody_accelerator`'s write and read paths), and corrected the two
header-comment register-map tables to match.

### Bug 2 — `rf_we` registered one cycle behind `rf_addr`/`rf_wdata`

This was the deeper bug, and the reason correctness failed even for bodies
whose addresses *were* in range. `rf_addr` and `rf_wdata` are driven
combinationally (`always_comb`, valid the same cycle as whatever state/`sub`
the FSM is in). `rf_we` used to be driven from the *sequential* block
instead:

```systemverilog
S_WB_I: begin
    rf_we <= 1'b1;   // registered — takes effect ONE CYCLE LATER
    if (sub==3'd2) begin sub<='0; state<=S_WB_J; end
    else           sub<=sub+3'd1;
end
```

Because `rf_we <= 1'b1` is a non-blocking assignment, it only becomes
visible on the clock edge *after* the one where this branch executed — by
which point `rf_addr`/`rf_wdata` (combinational) have already moved on to
the *next* `sub` value. Two concrete symptoms, both found via
`tb_nbody_full_fp32.sv` and pinned down with a hierarchical signal trace
(`tb_trace_probe.sv`, used during debugging and not part of the final
deliverable):

1. **Every "i"-body's `vx` write-back was silently dropped.** `S_WB_I`
   `sub=0` is entered straight from `S_VELUPD` (which never asserts
   `rf_we`), so `rf_we` reads as `0` during that first cycle — the intended
   write of `vxi` never happens. (`sub=1`/`sub=2`, i.e. `vy`/`vz`, happen to
   work because the *previous* `sub`'s registered `rf_we<=1` has landed by
   then.)
2. **A stray zero got written into the *next* body's `vx` during position
   update.** `S_POSUPD`'s last `pos_step` (9) sets `rf_we<=1'b1`, intending
   to gate *that* cycle's write — but it actually gates the *following*
   cycle, which is `pos_step=0` of the *next* body (a **read** step, whose
   combinational `rf_wdata` defaults to `0`). That leaked write clobbered
   every non-sun body's `vx` register with `0` right as its position-update
   turn began. (Body 0, sun, is spared because its own `pos_step=0` is
   entered from `S_NEXTPAIR`, which never primes `rf_we`.)

This combination is exactly what full-run testing showed before the fix:
sun's own velocity silently never updated across any of its 4 pairs, and
every other body's `vx` came back as an exact `0.0` in the final readback,
while `vy`/`vz` and all positions were fine.

**Fix:** moved `rf_we` into the same `always_comb` block as `rf_addr`/
`rf_wdata`, asserting it explicitly and combinationally in every branch that
intends a write that cycle (`S_WB_I`, `S_WB_J`, and `S_POSUPD` `pos_step`
7/8/9), defaulting to `0` otherwise. Removed the now-redundant `rf_we <= ...`
assignments (including its reset) from the sequential block entirely, since
a signal must be driven from exactly one place in SystemVerilog.

No other RTL changes were made. The FSM's state sequencing, `pair_rom`,
`body_regfile`, and all four arithmetic primitives were untouched — they
were already correct once given a write-enable that lines up with the
address/data it's supposed to gate.

## 6. Verification

### 6.1 Arithmetic unit tests (pre-existing, unchanged)

`hw/tb_fp32_units.sv` / `hw/tb_fp32_units.log`: `fp_mul`, `fp_add`,
`fp_sqrt`, `fp_div` tested in isolation against Python-computed IEEE-754
ground truth. **14/17 exact bit-for-bit matches; the 3 failures are all
exactly 1 ULP off**, the expected consequence of this hardware truncating
instead of implementing round-to-nearest — not a bug.

### 6.2 Full-system test (new: `hw/tb_nbody_full_fp32.sv`, `hw/tb_nbody_long.sv`)

Drives the actual `nbody_accelerator` top level over simulated MMIO with the
**real** solar-system data (post `offset_momentum`, exactly matching
`bench_nbody()`), for real `N_ITER` values, and reads the result back. Every
field of every body is compared against a Python **float64** reference
(`nbody_original.py`'s own `advance()`, unmodified) run for the same
`N_ITER`. Because the hardware is float32-truncating and the reference is
float64-round-to-nearest, exact equality is not the pass criterion — the
criterion is that the relative error sits at float32-epsilon scale for small
`N_ITER` and grows slowly/physically (never diverging or producing NaN/Inf)
as `N_ITER` grows, consistent with normal floating-point precision loss
compounding in a chaotically-sensitive N-body integration:

| N_ITER | Cycles (measured) | Cycles/iter | Worst per-field relative error vs. float64 reference |
|---:|---:|---:|---:|
| 1 | 1,250 | 1250.0 | 2.22e-07 |
| 2 | 2,500 | 1250.0 | 4.32e-07 |
| 5 | 6,250 | 1250.0 | 1.06e-06 |
| 200 | 250,000 | 1250.0 | 3.51e-05 |
| 1,000 | 1,250,000 | 1250.0 | 2.54e-03 |
| 20,000 (the real benchmark) | 25,000,000 | 1250.0 | 6.7 (670%, see below) |

`cycles/iteration` is **exactly** 1250.0 at every single data point,
including the full 20,000-iteration run (25,000,000 cycles measured,
matching the prediction exactly) — this is a real, simulated measurement
(not a hand-derived estimate), and it's exact because the FSM has no
data-dependent branches: it's a fixed 10-pair × 5-body walk driven purely by
counters, so its cycle count cannot vary with the data.

**Why the per-field error explodes at N=20,000, and why that's not a bug.**
An N-body gravitational system is chaotic: two trajectories that start
infinitesimally close (here, float32-truncated hardware arithmetic vs.
Python's float64 round-to-nearest) diverge *exponentially*, not linearly,
over enough steps — the classic "butterfly effect." By iteration 20,000,
jupiter's hardware-computed x position is nowhere near Python's float64
position (670% off) — but that is expected of *any* reduced-precision
integrator run this long, not evidence the datapath is wrong.
Position-by-position comparison stops being a meaningful correctness check
well before N=20,000; it's only useful (as used above) for small N where the
trajectories haven't had time to diverge yet.

The right check at this scale is the same one `report_nbody.txt` §3 used to
validate the *software* optimization: **energy conservation**. Total energy
(potential + kinetic) is a physical invariant a correct integrator should
preserve regardless of trajectory-level chaos. Recomputing that energy in
Python directly from the hardware's final float32 state after the full
20,000-iteration run:

```
Python float64 reference final energy:            -0.16908926275527053
Hardware (float32) final energy (from readback):  -0.1690875636930164
Relative difference:                               1.0e-05
```

A 1.0×10⁻⁵ relative error in the conserved energy after 20,000 iterations of
float32-truncating arithmetic is exactly the order of magnitude you'd expect
from float32 precision (~1e-7 per operation) accumulating over a long
integration — not a functional bug. This is the same conclusion the
project's original correctness methodology was built around, just applied
to the hardware's own output instead of a second software run.

All numbers above came from actually compiling and running the RTL with
Icarus Verilog:
```
iverilog -g2012 -o sim_full tb_nbody_full_fp32.sv nbody_accelerator_fp32.sv
vvp sim_full
```

## 7. Performance, and an honest optimization estimate

**Measured, not estimated:** 1,250 cycles per iteration, confirmed identical
across every run above. For the real benchmark (`N_ITER = 20000`):

```
1,250 cycles/iteration × 20,000 iterations = 25,000,000 cycles
```

At an assumed 200 MHz clock (a conservative target for an iterative
fixed/floating-point datapath of this complexity on a mid-range FPGA or a
small-node ASIC standard-cell flow — **not synthesized or timing-closed**,
stated as a design assumption, same caveat as the rest of this proposal):

```
25,000,000 / 200,000,000 Hz = 0.125 s = 125 ms
```

Compare against the **real, measured** software numbers from
`reports/report_nbody.txt` (genuine `pyperf` runs on the course VM,
independently reproduced and confirmed — see the project's benchmark
reports):

| | Time | vs. hardware (125 ms) |
|---|---:|---:|
| Original (unoptimized) Python `advance()` | 231 ms | hardware is **45.9% faster** (≈1.85×) |
| Optimized (loop-unrolled) Python `advance()` | 155 ms | hardware is **19.4% faster** |

**This is an assumption, explicitly:** it rests on the 200 MHz clock target
holding after real synthesis/place-and-route (not verified here — the
assignment explicitly does not require synthesis), and it compares a
cycle-accurate *simulation* against wall-clock software measurements on a
specific VM. What is *not* an assumption is the 1,250-cycles/iteration
figure and the correctness of the datapath that produces it — both come
from actually running the fixed RTL, not from reading the code and doing
arithmetic on paper.

Given that, **the honest estimate is a genuine, if modest, win: roughly a
19% reduction in runtime versus the already-optimized software, or about
46% versus the unoptimized original** — for a single-shared-datapath design
(one `fp_mul`/`fp_sqrt`/`fp_div` time-multiplexed across all 10 pairs per
iteration, no parallelism). Most of the accelerator's own time is spent
waiting on the iterative `fp_sqrt`
(25 cycles) and `fp_div` (49 cycles) units — the same area/power vs.
latency trade-off applies here: N-way parallel pair-processing datapaths
would cut that dominant cost roughly proportionally, at roughly N× the area
of those two units, and this workload's fixed, tiny problem size (5 bodies,
10 pairs) is exactly what makes that trade affordable in hardware even
though the equivalent move in software (numpy vectorization, tried and
measured in `report_nbody.txt` §3) did not pay off at this scale.

## 8. Trade-offs and limitations (stated honestly)

- **Precision:** float32 truncation introduces real, compounding error —
  0.25% worst-case deviation from the float64 reference by iteration 1,000
  (Section 6.2), growing further by iteration 20,000. This is the accuracy
  the assignment explicitly permits with fp32; the report should not claim
  bit-exact agreement with the software benchmark's Python floats.
- **Not synthesized:** as the assignment allows, this design has not been
  taken through synthesis or timing closure. The 200 MHz target and the
  resulting 125 ms figure are design assumptions, clearly labeled as such.
- **Single shared datapath:** the current design does not parallelize
  across the 10 pairs; that's the main lever left for a bigger speedup
  (Section 7), at a proportional area/power cost.
- **No NaN/Inf/denormal handling** in any of the four arithmetic units —
  acceptable here because every value in this specific workload (positions,
  velocities, masses, and all intermediate products/roots/quotients) is
  always a normal, finite, and for `fp_sqrt`/`fp_div`'s inputs, non-negative
  number.

## 9. Reproducing this

```bash
cd hw

# Arithmetic unit tests (pre-existing)
iverilog -g2012 -o sim_units tb_fp32_units.sv nbody_accelerator_fp32.sv
vvp sim_units

# Full-system test, N_ITER = 1, 2, 5
iverilog -g2012 -o sim_full tb_nbody_full_fp32.sv nbody_accelerator_fp32.sv
vvp sim_full

# Full-system test at an arbitrary iteration count (e.g. the real N_ITER=20000)
iverilog -g2012 -DN_ITER_VAL=20000 -o sim_long tb_nbody_long.sv nbody_accelerator_fp32.sv
vvp sim_long
```

`tb_nbody_full_fp32.sv` and `tb_nbody_long.sv` both read real solar-system
body state from `/tmp/nbody_words32.hex` (35 IEEE-754 float32 hex words,
generated from `src/nbody_original.py`'s actual `BODIES` data post
`offset_momentum` — regenerate with a short Python `struct.pack('<f', ...)`
script over `nbody_original.BODIES` in `SYSTEM` order if that file doesn't
exist locally).
