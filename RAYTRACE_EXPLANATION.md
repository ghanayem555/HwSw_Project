# Raytrace Benchmark — Full Explanation
# What it does, how we profiled it, what we found, and how we fixed it

---

## 1. What is the Raytrace Benchmark?

The benchmark is a classic **Whitted-style recursive ray tracer**, written entirely in
pure Python (standard library only — `math` and `array`). It renders a 100×100 pixel
image of a 3D scene and measures how long that takes.

### The scene
- 7 spheres (one large yellow sphere + 6 small colored spheres in a row)
- 1 infinite checkerboard floor (a `Halfspace` — a plane that extends forever)
- 2 point lights at fixed positions

### What happens for every pixel (the rendering algorithm)
For each of the 10,000 pixels (100×100):

1. **Cast a primary ray** from the camera through the pixel into the scene
2. **Intersection test**: loop through all 8 scene objects, compute where the ray hits each one, pick the nearest hit
3. **Shade the hit point** using a Phong-style model:
   - **Specular**: cast a reflected ray recursively back into the scene (up to 3 bounces deep)
   - **Lambert diffuse**: for each light, cast a shadow ray — if the light is visible, add its contribution based on the angle
   - **Ambient**: a flat base color contribution
4. **Write the resulting RGB color** into a flat byte array (the canvas)

So for every pixel there are potentially dozens of rays cast (primary + shadow + reflections),
and every ray involves testing against all 8 objects.

### The math objects — why they matter
Every single piece of 3D math uses hand-rolled Python classes: `Vector` and `Point`.
Operations like `.dot()`, `.cross()`, `.scale()`, `.normalized()`, `.reflectThrough()`
**each create and return a brand new Python object**. In a single render pass of 100×100 pixels,
tens of thousands of `Vector` and `Point` objects are allocated and thrown away.

---

## 2. Where is the Code?

```
src/raytrace_optimized.py   ← the optimized version we submitted
```

The original (unmodified) version comes from the `pyperformance` benchmark suite:
`bm_raytrace/run_benchmark.py`. Our file is identical except for the one change
described in Section 5.

### Key classes and where they live in the file

| Class | Line | What it is |
|---|---|---|
| `Vector` | 33 | 3D vector — x,y,z + all math ops |
| `Point` | 108 | 3D point — same x,y,z but different type semantics |
| `Sphere` | 145 | Geometric primitive: sphere |
| `Halfspace` | 169 | Geometric primitive: infinite plane |
| `Ray` | 190 | A ray: origin point + direction vector |
| `Canvas` | 207 | The pixel buffer (flat byte array) |
| `Scene` | 240 | Holds all objects, lights, camera; runs the render loop |
| `SimpleSurface` | 323 | Phong shading model for solid-color surfaces |
| `CheckerboardSurface` | 360 | Same but alternates two colors in a grid pattern |
| `bench_raytrace` | 379 | The benchmark entry point — the timed loop |

---

## 3. How We Ran the Baseline

We used `pyperformance`, the official Python benchmark suite runner:

```bash
python3 -m pyperformance run --bench raytrace
```

This runs the benchmark in a controlled way: it does warmup iterations first
(to let the JIT/interpreter settle), then collects multiple timed samples,
and reports the median with standard deviation.

**Baseline result (on the course VM, naranja14):**
```
raytrace: 799 ms +- 8 ms
```

Environment:
- Machine: QEMU/KVM guest (course VM), 1 vCPU
- CPU: Intel Xeon E5-2630 v3 @ 2.40 GHz
- OS: Ubuntu 22.04, Linux 5.15.0-1080-kvm
- Python: CPython 3.10.12

The ±8 ms standard deviation (about 1%) is clean — it means the measurements
are stable and trustworthy.

---

## 4. How We Profiled It — Finding the Bottleneck

### The problem with `perf record` on this VM

`perf` is the standard Linux profiling tool. Normally you would use hardware
performance counters (CPU cycles) like this:

```bash
perf record -e cycles -g -- python3 script.py
```

But on this KVM virtual machine, the hardware PMU (Performance Monitoring Unit)
had a known limitation: `perf record` with hardware events produced **0 samples**.
`perf stat` (summary counts only) worked, but not the per-function sampling.

**Solution**: use the **software `cpu-clock` event** instead — this is a kernel
timer interrupt fired at a fixed frequency, which works in any environment:

```bash
perf record -e cpu-clock -F 999 -g -o perf.data -- \
    python3-dbg -m pyperformance run --bench raytrace
```

Flags:
- `-e cpu-clock` — use the software timer event
- `-F 999` — sample 999 times per second
- `-g` — record full call stacks (not just the top function)
- `python3-dbg` — the debug build of Python, which has proper symbol names in the call stack
  (the regular build strips most internal function names)

This produced ~209,000 samples.

### Reading the results

```bash
perf report --stdio
```

This shows each function ranked by how many samples landed in it. We also
generated a **flame graph** (see `reports/raytrace_artifacts/raytrace_flamegraph.svg`) —
a visual where wide bars = more time spent there.

---

## 5. What the Profiling Found — The Actual Problem

Here are the top functions from `perf report`, with what each one means:

| Function | % of samples | What it means |
|---|---|---|
| `_PyEval_EvalFrameDefault` | ~26% | The CPython bytecode interpreter main loop — unavoidable overhead |
| `_PyEval_Vector` / `_PyEval_MakeFrameVector` / `frame_dealloc` | ~9.5% | **Function call overhead** — pushing and popping Python stack frames |
| `_PyType_Lookup` | ~4.5% | **Method resolution** — finding `.dot()` or `.cross()` on the class |
| `_PyDict_GetItemHint` / `insertdict` | ~4.4% | **Instance attribute dict lookups** — reading/writing `self.x`, `self.y`, `self.z` |
| `binary_op1` / `float_mul` | ~4.7% | Arithmetic dispatch tax |

### What this tells us

The ~26% in the main interpreter loop is expected and unavoidable in pure Python.
But the next big chunk — **~18% combined** from the three function/attribute hotspots —
is specific to how this code is structured:

**Problem 1: Every vector operation is a function call.**
`ray.vector.dot(cp)` → Python looks up `.dot` on the `Vector` class, creates a new
stack frame, executes the function, destroys the frame. Same for `.cross()`, `.scale()`,
`.normalized()`, `.reflectThrough()`. All of this is `_PyEval_Vector` + `frame_dealloc`
overhead. This showed up in raytrace but NOT in the nbody benchmark because nbody
is a flat numerical loop, not OOP method calls.

**Problem 2: Every attribute access (`self.x`, `self.y`, `self.z`) is a dict lookup.**
This is the key one. In Python, by default, every object instance stores its attributes
in a `__dict__` — a hash table. So when `Vector.dot()` does:

```python
return (self.x * other.x) + (self.y * other.y) + (self.z * other.z)
```

Each `self.x`, `self.y`, `self.z`, `other.x`, `other.y`, `other.z` is a **dictionary
hash table lookup**. For `Vector` and `Point`, which are read in every single math
operation, and which are created in the thousands per render, this is enormous overhead.
That is exactly what `_PyDict_GetItemHint` and `insertdict` in the profile represent.

**Problem 3: `_PyType_Lookup` — method resolution overhead.**
Every time you call `self.dot(other)`, Python has to walk the class's MRO
(Method Resolution Order) to find the `dot` method. With no caching, this happens
on every call. Again: `Vector` methods are called in every pixel, in every ray,
in every object intersection test.

### Why these classes in particular

`Vector` and `Point` are the worst offenders because:
- They are the smallest (only 3 attributes: x, y, z)
- They are created and destroyed the most (every math op returns a new one)
- They are accessed the most (every `self.x` in every dot product)

`Scene`, `Canvas`, `Sphere`, etc. are created once per render and accessed far less
often — but they still carry the same unnecessary overhead.

---

## 6. The Fix — `__slots__`

### What `__slots__` does

Normally, a Python object stores its instance attributes in a per-object dictionary (`__dict__`).
That means:
- Every object carries a full hash table, even if it only has 3 attributes
- Reading `self.x` means hashing the string `"x"`, looking it up in the table, and returning the value
- Writing `self.x = val` means inserting into the hash table

`__slots__` is a class-level declaration that tells CPython: "this class only ever has
these specific attributes — skip the dict, use fixed-offset slots instead."

```python
class Vector(object):
    __slots__ = ('x', 'y', 'z')   # ← this is the entire change
    ...
```

With `__slots__`:
- There is **no `__dict__`** on each instance
- `self.x` becomes a direct struct field access (offset read from a C struct) — like reading `obj->x` in C
- It is faster to read, faster to write, and uses less memory

### Exactly what we changed — all 9 classes

Every hand-rolled class in the file got `__slots__`. Here is each one:

**`Vector` (line 34):**
```python
__slots__ = ('x', 'y', 'z')
```
Most impactful — used in every single math operation. Thousands of instances per render.

**`Point` (line 109):**
```python
__slots__ = ('x', 'y', 'z')
```
Same as Vector — same access pattern, same frequency.

**`Sphere` (line 146):**
```python
__slots__ = ('centre', 'radius')
```

**`Halfspace` (line 170):**
```python
__slots__ = ('point', 'normal')
```

**`Ray` (line 191):**
```python
__slots__ = ('point', 'vector')
```
Also frequently created — one new `Ray` per pixel for primary rays, more for shadow/reflection rays.

**`Canvas` (line 208):**
```python
__slots__ = ('bytes', 'width', 'height')
```

**`Scene` (line 241):**
```python
__slots__ = ('objects', 'lightPoints', 'position', 'lookingAt',
             'fieldOfView', 'recursionDepth')
```

**`SimpleSurface` (line 327):**
```python
__slots__ = ('baseColour', 'specularCoefficient', 'lambertCoefficient',
             'ambientCoefficient')
```

**`CheckerboardSurface` (line 361):**
```python
__slots__ = ('otherColour', 'checkSize')
```
Note: `CheckerboardSurface` inherits from `SimpleSurface`. When using `__slots__`
with inheritance, the subclass only declares the *new* attributes it adds — the
parent's slots are already handled by `SimpleSurface.__slots__`.

### What we did NOT change

Nothing else. The algorithm, the scene setup, the shading model, the math, the
output format — all identical to the original. This is intentional: to make it
a fair, isolated comparison that proves the optimization itself is responsible
for the speedup.

---

## 7. Results

We re-ran with `pyperformance` after the change:

```bash
python3 -m pyperformance run --bench raytrace --output raytrace_optimized.json
python3 -m pyperf compare_to baseline.json raytrace_optimized.json
```

**Before (baseline):**  `799 ms +- 8 ms`
**After (optimized):**  `693 ms +- 7 ms`
**Improvement:**        `(799 - 693) / 799 = 13.3% faster`

Raw numbers from `raytrace_optimized.json` — individual run values (seconds):
```
0.691, 0.692, 0.690, 0.691, 0.690, 0.698, 0.697, 0.696, 0.687, 0.688, 0.688,
0.694, 0.695, 0.697, 0.689, 0.693, 0.695, 0.695, 0.694, 0.695, 0.691, 0.692,
0.693, 0.695, 0.695, 0.696, 0.691, 0.689, 0.687, 0.686, 0.694, 0.695, 0.694,
0.695, 0.696, 0.689, 0.691, 0.695, 0.688, 0.686, 0.686, 0.696, 0.697, 0.694,
0.692, 0.691, 0.693, 0.695, 0.688, 0.687, 0.686, 0.695, 0.697, 0.694
```

All values tightly clustered around 0.691–0.698 seconds. Clean, stable measurements.

### Why the improvement is "only" 13% and not more

The ~18% overhead we identified in the profile (dict access + method resolution)
is an upper bound on what `__slots__` can eliminate — and even then, `__slots__`
only addresses the *attribute dict* part of that, not the function-call frame overhead.
The remaining ~26% interpreter overhead and ~4.7% arithmetic dispatch are structural
CPython costs that `__slots__` cannot touch.

### The Mac sanity check

The same code change ran on an Apple Silicon Mac (Python 3.9):
- Before: 533 ms
- After:  338 ms
- Improvement: **37%**

The direction is the same (always faster), but the magnitude is larger on newer
hardware/Python. This is expected — `__slots__` benefit is proportional to how
expensive Python's dict operations are relative to everything else. On Apple Silicon
with a faster memory subsystem and a newer Python version, the dict operations are
relatively more expensive vs. other overhead, so eliminating them helps more.
The Linux VM result (13.3%) is the authoritative number used for submission.

---

## 8. Summary — The Full Chain of Reasoning

```
Benchmark runs slow (799ms)
         ↓
perf record -e cpu-clock (hardware events broken on KVM VM)
         ↓
Flame graph + perf report --stdio
         ↓
Found: ~9.5% in _PyEval_Vector (function call frames)
       ~4.5% in _PyType_Lookup (method resolution)
       ~4.4% in _PyDict_GetItemHint/insertdict (attribute dict access)
         ↓
Root cause: all 9 classes have no __slots__
            → every instance carries a per-object __dict__
            → every self.x / self.y / self.z is a hash table lookup
            → Vector/Point are created thousands of times per render
         ↓
Fix: add __slots__ to all 9 classes (9 one-line additions)
     → removes per-instance __dict__
     → self.x becomes a fixed-offset C struct read
     → zero behavioral change, zero algorithm change
         ↓
Result: 799ms → 693ms, 13.3% improvement
        Verified clean: std dev stays at ±7–8ms on both runs
        Meets the assignment's ≥7% threshold
```

---

## 9. Files Reference

| File | What it is |
|---|---|
| `src/raytrace_optimized.py` | The optimized Python source (the one-line-per-class `__slots__` change) |
| `reports/report_raytrace.txt` | Full written report submitted with the assignment |
| `reports/baseline.json` | Raw pyperf JSON output for the original unmodified benchmark |
| `reports/raytrace_optimized.json` | Raw pyperf JSON output for our optimized version |
| `reports/raytrace_artifacts/raytrace_flamegraph.svg` | Flame graph from perf — visual of where time was spent |
| `reports/raytrace_artifacts/perf_report.txt` | Full `perf report --stdio` text output (3.6 MB) |
| `scripts/script_raytrace.sh` | Shell script used to automate the benchmark runs |
