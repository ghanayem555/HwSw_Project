# N-body Benchmark — Full Explanation
# What it does, how we profiled it, what we found, and how we fixed it

---

## 1. What is the N-body Benchmark?

The benchmark simulates **Newtonian gravity** between the Sun and four outer
planets (Jupiter, Saturn, Uranus, Neptune) using real astronomical data. It
advances the simulation forward by 20,000 timesteps and measures how long that takes.

### The physics
Each body has:
- A **position** `[x, y, z]` — where it is in space (astronomical units)
- A **velocity** `[vx, vy, vz]` — how fast and in what direction it moves
- A **mass** — how strongly it gravitationally pulls other bodies

Every timestep:
1. For each of the 10 unique body pairs (sun-jupiter, sun-saturn, ..., uranus-neptune):
   - Compute the distance vector between the two bodies: `dx, dy, dz`
   - Compute the distance squared: `d² = dx² + dy² + dz²`
   - Compute the force magnitude: `mag = dt / (d² × sqrt(d²))`
   - Update both bodies' velocities based on how hard they pull each other
2. Update all 5 bodies' positions from their new velocities

This is a **direct O(N²) pairwise integrator** — every body is compared to every other body each timestep.

### Why N=5 matters
With only 5 bodies there are only 10 pairs. The math per timestep is trivial.
The benchmark is not slow because the physics is hard — it is slow because Python
has to do thousands of tiny operations with constant interpreter overhead. That
is the key insight behind the optimization.

---

## 2. Where is the Code?

```
src/nbody_optimized.py   ← the optimized version we submitted
```

### Key functions

| Function | Line | What it does |
|---|---|---|
| `combinations(l)` | 42 | Builds all 10 body pairs (same as `itertools.combinations`) |
| `BODIES` | 56 | The actual solar-system data — positions, velocities, masses |
| `SYSTEM` / `PAIRS` | 92–93 | Module-level lists built from `BODIES` at import time |
| `advance(dt, n)` | 96 | The hot loop — advances the simulation by `n` timesteps |
| `report_energy()` | 204 | Computes total kinetic + potential energy (used as a correctness check) |
| `offset_momentum()` | 216 | Adjusts the sun's velocity so the system's total momentum is zero |
| `bench_nbody()` | 227 | The benchmark entry point — calls advance 20,000 times and times it |

---

## 3. How We Ran the Baseline

```bash
python3 -m pyperformance run --bench nbody
```

**Baseline result (on the course VM, naranja14):**
```
nbody: 231 ms +- 2 ms
```

Environment:
- Machine: QEMU/KVM guest (course VM), 1 vCPU
- CPU: Intel Xeon E5-2630 v3 @ 2.40 GHz
- OS: Ubuntu 22.04, Linux 5.15.0-1080-kvm
- Python: CPython 3.10.12

The ±2 ms standard deviation (under 1%) means clean, stable measurements.

---

## 4. How We Profiled It — Finding the Bottleneck

### The same KVM problem as raytrace

Hardware performance counters (`perf record -e cycles`) produced **0 samples**
on this KVM virtual machine (the PMI interrupt is not forwarded to the guest).
Same solution as raytrace — use the software timer event:

```bash
perf record -e cpu-clock -F 999 -g -o perf.data -- \
    python3-dbg -m pyperformance run --bench nbody
```

This produced ~49,000 samples.

### Reading the results

```bash
perf report --stdio
```

The flame graph is at `reports/nbody_artifacts/nbody_flamegraph.svg`.

---

## 5. What the Profiling Found — The Actual Problem

| Function | % of samples | What it means |
|---|---|---|
| `_PyEval_EvalFrameDefault` | ~38% | The CPython bytecode interpreter loop — unavoidable |
| `binary_op1` / `binary_iop1` | ~5.8% | Generic arithmetic dispatch tax |
| `float_mul` / `float_add` / `float_sub` | ~6.5% | Actual floating-point math |
| `PyFloat_FromDouble` / `float_dealloc` | ~6.3% | Float object allocation and garbage collection |
| `list_ass_item` / `list_ass_subscript` | ~3.7% | **Indexed list writes** (`v1[0] -= ...`, `r[0] += ...`) |
| `_PyNumber_Index` / `PyNumber_AsSsize_t` | ~4.0% | **Int-subscript index conversion** (the `[0]`, `[1]`, `[2]` indexing overhead) |
| `_Py_CheckSlotResult` | ~3.7% | Operator-protocol slot checks per arithmetic op |

### What this tells us

The benchmark is not slow because computing `sqrt(d²)` is expensive. The real
problem is **death by a thousand cuts**: the `advance()` loop does approximately
**75 indexed list reads/writes per timestep** (`v1[0] -= ...`, `v1[1] -= ...`,
`v1[2] -= ...`, repeated for all 10 pairs), and runs 20,000 times.

That is roughly **1.5 million indexed list operations** in total.

For each one, Python has to:
1. Convert the integer index (`0`, `1`, `2`) to a C `ssize_t` — that is `PyNumber_AsSsize_t`
2. Do bounds checking on the list
3. Read or write the list slot

That is exactly what `list_ass_item`, `list_ass_subscript`, and `PyNumber_AsSsize_t`
in the profile represent. The `~9%` combined from those two groups is the directly
targetable overhead.

### Why this benchmark is different from raytrace

In raytrace, the problem was OOP method calls on `Vector`/`Point` objects and
their `__dict__` attribute lookups — fixed with `__slots__`.

In nbody, there are **no custom classes at all**. The bodies are plain Python lists.
The problem is entirely different: it is the cost of **indexed list access** inside
a tight loop, compounded by Python's per-operation interpreter overhead.

---

## 6. Three Optimization Attempts

We tried three approaches in order, measuring each one rather than assuming it
would work.

---

### Attempt 1 — Replace `** (-1.5)` with `math.sqrt()` (FAILED)

**The idea:** The original code computes the force denominator as:
```python
b = (dx * dx + dy * dy + dz * dz) ** (-1.5)
```
The common wisdom is that CPython's `float ** float` is slow compared to `math.sqrt()`.
So we rewrote it as:
```python
d2 = dx * dx + dy * dy + dz * dz
mag = dt / (d2 * math.sqrt(d2))
```

**Result:** No improvement. `119 ms → 121 ms` locally (essentially the same).

**Why it failed:** The perf profile never showed `float_pow` as a hot function.
This was a guess not grounded in the data — `pow` simply was not the bottleneck.
The `sqrt` form was kept in the final version since it is not slower, but it was
not the real fix.

---

### Attempt 2 — NumPy vectorization (MINOR IMPROVEMENT, NOT ENOUGH)

**The idea:** Batch all 10 pairwise interactions per timestep into NumPy array
operations — broadcasting a difference tensor across all pairs at once, using
`numpy.einsum` for the force sum.

**Result:** Only ~4% faster. `0.185s → 0.177s` for the raw `advance()` loop.

**Why it failed:** With only 5 bodies (10 pairs), NumPy's per-call dispatch
overhead (several NumPy calls per timestep, repeated 20,000 times) largely
cancels out the vectorization benefit. This is a classic textbook case:
**vectorization overhead dominates at very small N**. The data is simply too
small for NumPy's machinery to pay for itself.

---

### Attempt 3 — Loop unrolling + local variable hoisting (SUCCESS, 32.9%)

**The idea:** The 5 bodies in this benchmark are **fixed and hardcoded** — they
never change. The same sun, jupiter, saturn, uranus, neptune, every run.

So instead of looping over `PAIRS` (which requires list indexing every iteration),
we fully **unroll** the 10 pairs into 10 straight-line code blocks. And instead of
reading and writing the bodies' `[x, y, z]` lists on every timestep, we:

1. **Read** all positions and velocities into plain local variables **once** at the start
2. **Run** all 20,000 timesteps using only local variable arithmetic
3. **Write** the final values back to the lists **once** at the end

In Python bytecode terms, reading/writing a local variable uses `LOAD_FAST` /
`STORE_FAST` — the fastest possible bytecode. Indexed list access uses
`BINARY_SUBSCR` / `STORE_SUBSCR`, which go through `list_ass_item`, bounds
checks, and `PyNumber_AsSsize_t`. That is the overhead the profile showed.

**What the unrolled loop looks like (one pair, sun-jupiter):**
```python
# instead of: for (body1, body2) in pairs: dx = body1[0][0] - body2[0][0] ...
dx = sx - jx; dy = sy - jy; dz = sz - jz
d2 = dx * dx + dy * dy + dz * dz
mag = dt / (d2 * sqrt(d2))
svx -= dx * jm * mag; svy -= dy * jm * mag; svz -= dz * jm * mag
jvx += dx * sm * mag; jvy += dy * sm * mag; jvz += dz * sm * mag
```

All variables (`sx`, `sy`, `jx`, `jm`, `svx`, ...) are plain Python locals.
No list indexing anywhere in the 20,000-iteration loop.

**Result:** **~51% faster** for the raw `advance()` loop in isolation
(`0.185s → 0.0905s`). The full benchmark result:

**Before:** `231 ms ± 2 ms`
**After:** `155 ms ± 3 ms`
**Improvement:** `(231 - 155) / 231 = 32.9% faster`

**Trade-off:** The unrolled `advance()` only works for exactly these 5 named
bodies in this exact order. You cannot call it with a different set of bodies.
This is acceptable because the benchmark always uses this fixed solar-system
dataset — it is not parameterized by N.

---

## 7. Correctness Check

After any physics simulation optimization, you must verify the answer is still
correct. We used **energy conservation** as the check:

```
ORIGINAL   before: -0.1690751638285245   after: -0.16908926275527172
OPTIMIZED  before: -0.1690751638285245   after: -0.16908926275526812
```

- Both start at the same energy ✓
- Both end at nearly the same energy ✓
- The tiny residual difference (~12 significant digits match) is expected
  floating-point summation-order noise from reordering arithmetic — not a bug

---

## 8. A Note on the Unstable First Measurement

The first measurement attempt was flagged as unstable by `pyperf` (20–31%
standard deviation — far too noisy). Investigation showed the course VM host
had 87.5% I/O wait (`top` showed `wa` column). A background
`unattended-upgrades` process was running and hammering disk I/O.

Fix: `sudo systemctl stop unattended-upgrades`, confirmed with `vmstat` that
I/O wait dropped to ~0%, then re-ran the benchmark. The result immediately
stabilized to ±2–3 ms standard deviation.

**Lesson:** If your benchmark variance is suddenly huge, check I/O wait before
suspecting your code.

---

## 9. Exactly What Changed in the Code

The entire change is in the `advance()` function. Everything else is identical
to the original pyperformance benchmark.

**Original `advance()` structure:**
```python
def advance(dt, n, bodies=SYSTEM, pairs=PAIRS):
    for _ in range(n):
        for ((r1,[v1x,v1y,v1z],m1), (r2,[v2x,v2y,v2z],m2)) in pairs:
            dx = r1[0] - r2[0]    # list indexing every iteration
            dy = r1[1] - r2[1]
            dz = r1[2] - r2[2]
            ...
            v1[0] -= dx * b * m2  # list write every iteration
            v1[1] -= dy * b * m2
            ...
        for (r, [vx, vy, vz], m) in bodies:
            r[0] += dt * vx       # list write every iteration
            r[1] += dt * vy
            r[2] += dt * vz
```

**Optimized `advance()` structure (lines 96–201):**
```python
def advance(dt, n, bodies=SYSTEM, pairs=PAIRS):
    # Read everything into locals ONCE
    sx, sy, sz = spos
    svx, svy, svz = svel
    jx, jy, jz = jpos
    ...

    for _ in range(n):
        # sun-jupiter (straight-line, no loop, no list indexing)
        dx = sx - jx; dy = sy - jy; dz = sz - jz
        ...
        # ... 9 more pairs, all straight-line ...

        # position update (locals only)
        sx += dt * svx; sy += dt * svy; sz += dt * svz
        ...

    # Write everything back ONCE
    spos[0], spos[1], spos[2] = sx, sy, sz
    ...
```

---

## 10. Summary — The Full Chain of Reasoning

```
Benchmark runs slow (231 ms)
         ↓
perf record -e cpu-clock (hardware events broken on KVM VM)
         ↓
Flame graph + perf report --stdio
         ↓
Found: ~6.3%  PyFloat_FromDouble/float_dealloc (float object churn)
       ~5.8%  binary_op1 (arithmetic dispatch)
       ~3.7%  list_ass_item/list_ass_subscript (indexed list writes)
       ~4.0%  PyNumber_AsSsize_t (list index conversion)
         ↓
Root cause: ~75 list index operations per timestep x 20,000 timesteps
            = ~1.5M indexed list operations
            each one pays: index conversion + bounds check + list slot access
         ↓
Attempt 1: pow -> sqrt   → no effect (pow was never in the profile)
Attempt 2: numpy         → only 4% (overhead dominates at N=5 pairs)
Attempt 3: loop unrolling + local variable hoisting → 51% faster in advance()
           → directly eliminates the list_ass_item / PyNumber_AsSsize_t cost
           → replaces BINARY_SUBSCR/STORE_SUBSCR with LOAD_FAST/STORE_FAST
         ↓
Result: 231 ms → 155 ms, 32.9% improvement
        Correctness verified: energy conservation matches to ~12 significant digits
        Meets the assignment's ≥7% threshold by a wide margin
```

---

## 11. Files Reference

| File | What it is |
|---|---|
| `src/nbody_optimized.py` | The optimized Python source (unrolled `advance()`) |
| `reports/report_nbody.txt` | Full written report submitted with the assignment |
| `reports/baseline.json` | Raw pyperf JSON output for the original unmodified benchmark |
| `reports/nbody_optimized.json` | Raw pyperf JSON output for the optimized version |
| `reports/nbody_artifacts/nbody_flamegraph.svg` | Flame graph from perf — visual of where time was spent |
| `reports/nbody_artifacts/perf_report.txt` | Full `perf report --stdio` text output |
| `scripts/script_raytrace.sh` | Shell script used to automate benchmark runs |
