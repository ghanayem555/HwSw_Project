# raytrace — The Original Code, Deeply

This is a line-by-line, math-included walkthrough of the *original*,
unmodified `bm_raytrace/run_benchmark.py` (the pyperformance benchmark
source, before any optimization). Read this to actually understand what
the program computes and why, not just where the profiler's time went —
that story is in `RAYTRACE_EXPLANATION.md`.

The program is a **recursive ray tracer**: for every pixel of an image, it
fires a simulated ray of light backwards from the camera into a 3D scene,
figures out what it hits, and computes a color — including shadows and
mirror-style reflections. This exact technique (minus the recursion depth
limit and the specific shading model) is how early 3D-rendered movies and
games worked before GPUs took over.

---

## 1. `Vector` and `Point` — the two kinds of "three numbers"

```python
class Vector(object):
    def __init__(self, initx, inity, initz):
        self.x = initx
        self.y = inity
        self.z = initz
```
On the surface, `Vector` and `Point` are identical — both just hold three
floats. The code deliberately keeps them as **separate classes** because
they mean different things geometrically:
- A **Point** is a location in 3D space — "where."
- A **Vector** is a direction and magnitude — "which way, how far."

You can add a `Vector` to a `Point` (move to a new location) or subtract
two `Point`s (get the `Vector` between them), but adding two `Point`s
together is geometrically meaningless — so the code actively blocks it:
```python
def mustBeVector(self):
    return self
def mustBePoint(self):
    raise 'Vectors are not points!'
```
Every method that expects one or the other calls these as a runtime check.

### The vector math methods

**`dot(self, other)` — the dot product**
```python
def dot(self, other):
    other.mustBeVector()
    return (self.x * other.x) + (self.y * other.y) + (self.z * other.z)
```
Mathematically: `A·B = Ax·Bx + Ay·By + Az·Bz`. Geometrically, the dot
product tells you how much two vectors point in the same direction — it's
`|A|·|B|·cos(θ)` where θ is the angle between them. This single formula
gets reused for three completely different purposes later in the file:
computing a vector's own length (`dot` with itself), measuring how
directly a light hits a surface (Lambert shading), and solving the
ray-sphere intersection equation (below).

**`cross(self, other)` — the cross product**
```python
def cross(self, other):
    other.mustBeVector()
    return Vector(self.y*other.z - self.z*other.y,
                  self.z*other.x - self.x*other.z,
                  self.x*other.y - self.y*other.x)
```
Produces a new vector that's perpendicular to *both* inputs. Used once, to
build the camera's "right" and "up" directions from its "forward"
direction (see Section 6).

**`magnitude(self)` and `normalized(self)`**
```python
def magnitude(self):
    return math.sqrt(self.dot(self))

def normalized(self):
    return self.scale(1.0 / self.magnitude())
```
`magnitude` is just the vector's length: `|A| = sqrt(A·A) = sqrt(Ax²+Ay²+Az²)`
(the 3D Pythagorean theorem — dotting a vector with itself gives the sum
of its components squared). `normalized` rescales it to length exactly 1
(a "unit vector") — needed everywhere a direction matters but magnitude
shouldn't (e.g. the camera's viewing direction, a surface normal).

**`reflectThrough(self, normal)` — mirror reflection**
```python
def reflectThrough(self, normal):
    d = normal.scale(self.dot(normal))
    return self - d.scale(2)
```
This is the standard reflection formula: `R = V - 2(V·N)N`, where `V` is
the incoming ray direction and `N` is the surface normal. Picture light
bouncing off a mirror at the same angle it came in — this formula computes
exactly that new direction. It's what makes the shiny spheres in the scene
reflect their surroundings.

---

## 2. `Sphere` — where the actual 3D math happens

```python
class Sphere(object):
    def __init__(self, centre, radius):
        self.centre = centre
        self.radius = radius

    def intersectionTime(self, ray):
        cp = self.centre - ray.point
        v = cp.dot(ray.vector)
        discriminant = (self.radius * self.radius) - (cp.dot(cp) - v * v)
        if discriminant < 0:
            return None
        else:
            return v - math.sqrt(discriminant)
```
This answers "does this ray hit this sphere, and if so, how far along the
ray?" — the single most-called function in the whole program (once per
object, per ray, and there are primary rays, shadow rays, and reflection
rays for every pixel).

**The derivation, so the formula isn't a black box:** a point on the ray
at distance `t` is `ray.point + t·ray.vector`. A point is on the sphere's
surface when its distance from the sphere's center equals the radius:
```
|ray.point + t·ray.vector - centre|² = radius²
```
Expand that out and it becomes a quadratic equation in `t`:
`t² - 2(cp·v)t + (cp·cp - r²) = 0` (after using the fact that `ray.vector`
is already normalized, i.e. length 1, which cancels out the `t²`
coefficient). Solving a quadratic `at²+bt+c=0` needs the discriminant
`b²-4ac`; here that simplifies to exactly the `discriminant` computed
above. If it's negative, the equation has no real solution — the ray
misses the sphere entirely (`return None`). If it's non-negative, taking
the square root and picking the smaller root (`v - sqrt(discriminant)`)
gives the *nearest* intersection point — the one you'd actually see, since
anything behind it is hidden.

```python
def normalAt(self, p):
    return (p - self.centre).normalized()
```
Once you know *where* a ray hit the sphere, this gives the direction
"straight out" from the surface at that point — needed for shading
(how does light bounce off this exact spot?) and reflection (which way
does the mirror-bounce go?). For a sphere this is simple: point minus
center, normalized.

---

## 3. `Halfspace` — the infinite checkerboard floor

```python
class Halfspace(object):
    def __init__(self, point, normal):
        self.point = point
        self.normal = normal.normalized()

    def intersectionTime(self, ray):
        v = ray.vector.dot(self.normal)
        if v:
            return 1 / -v
        else:
            return None

    def normalAt(self, p):
        return self.normal
```
A `Halfspace` is an infinite flat plane, defined by one point on it and
its normal (which way it faces). Here it's used as the floor:
`Halfspace(Point(0,0,0), Vector.UP)` — a plane through the origin, facing
straight up. `intersectionTime` is simpler than the sphere's: if the ray
is exactly parallel to the plane (`v == 0`, dot product of two
perpendicular-ish directions is 0), it never hits (`None`); otherwise,
basic ray-plane geometry gives the distance directly. Since a plane is
flat everywhere, `normalAt` doesn't even need to know *where* the ray hit
— the normal is the same everywhere on the plane.

---

## 4. `Ray`, `Canvas`, and `firstIntersection`

```python
class Ray(object):
    def __init__(self, point, vector):
        self.point = point
        self.vector = vector.normalized()

    def pointAtTime(self, t):
        return self.point + self.vector.scale(t)
```
A ray is just an origin (`point`) and a direction (`vector`, always kept
normalized). `pointAtTime(t)` is the same formula used inside the
intersection derivation above: walk `t` units from the origin along the
direction.

```python
class Canvas(object):
    def __init__(self, width, height):
        self.bytes = array.array('B', [0] * (width * height * 3))
        ...
    def plot(self, x, y, r, g, b):
        i = ((self.height - y - 1) * self.width + x) * 3
        self.bytes[i]   = max(0, min(255, int(r * 255)))
        self.bytes[i+1] = max(0, min(255, int(g * 255)))
        self.bytes[i+2] = max(0, min(255, int(b * 255)))
```
The output image, stored as one flat byte array (3 bytes — R,G,B — per
pixel). `plot` converts a color from the shading math's 0.0–1.0 float
range into a 0–255 byte, clamping anything that overshoots (a reflection
can in principle produce a color brighter than "full white"). The
`(height - y - 1)` flips the row order — image formats conventionally
store the *top* row first, but the math below builds the image bottom-up.

```python
def firstIntersection(intersections):
    result = None
    for i in intersections:
        candidateT = i[1]
        if candidateT is not None and candidateT > -EPSILON:
            if result is None or candidateT < result[1]:
                result = i
    return result
```
Given a list of `(object, t, surface)` triples — one per scene object,
some possibly `None` (a miss) — this picks the one with the *smallest*
non-negative `t`, i.e. the closest thing the ray actually hits.
`EPSILON = 0.00001` guards against a ray "hitting itself" due to
floating-point rounding right at its own starting point (a classic ray
tracing bug if you don't account for it — a reflected or shadow ray
starting exactly *on* a surface can numerically re-intersect that same
surface at `t≈0`).

---

## 5. `Scene.render()` — the pixel loop and camera setup

```python
def render(self, canvas):
    fovRadians = math.pi * (self.fieldOfView / 2.0) / 180.0
    halfWidth = math.tan(fovRadians)
    halfHeight = 0.75 * halfWidth
    ...
    eye = Ray(self.position, self.lookingAt - self.position)
    vpRight = eye.vector.cross(Vector.UP).normalized()
    vpUp = vpRight.cross(eye.vector).normalized()

    for y in range(canvas.height):
        for x in range(canvas.width):
            xcomp = vpRight.scale(x * pixelWidth - halfWidth)
            ycomp = vpUp.scale(y * pixelHeight - halfHeight)
            ray = Ray(eye.point, eye.vector + xcomp + ycomp)
            colour = self.rayColour(ray)
            canvas.plot(x, y, *colour)
```
This builds a virtual camera and fires one ray through every pixel.

**The field-of-view math**: `fieldOfView` (45°) is converted to radians
and then to `halfWidth = tan(fovRadians)` — this is standard pinhole
camera math. Imagine the camera as a point with a flat "viewing window" 1
unit in front of it; `tan` of the half-angle gives you how wide that
window needs to be to capture exactly that field of view.
`halfHeight = 0.75 * halfWidth` fixes a 4:3-style aspect ratio.

**Building camera axes with the cross product**: the camera needs three
perpendicular directions — forward (`eye.vector`, from position toward
`lookingAt`), right, and up. `cross(Vector.UP)` finds a vector
perpendicular to *both* "forward" and "world up" — that's the camera's
"right" — and crossing that with "forward" again gives the camera's own
"up" (which won't exactly match world-up unless the camera is perfectly
level). This is a standard technique for turning "which way am I looking"
into a full 3D coordinate frame using only the cross product.

**The pixel loop itself**: for each `(x,y)` pixel, `xcomp`/`ycomp` compute
how far to nudge the ray sideways/vertically across the viewing window
(scaled from pixel coordinates into the `-halfWidth..+halfWidth` range),
and `eye.vector + xcomp + ycomp` builds the direction from the camera
through that specific point on the window — this is why pixels near the
center of the image point almost straight at `lookingAt`, while pixels
near the edges point increasingly off to the side.

---

## 6. `Scene.rayColour()` — the recursive heart of the renderer

```python
def rayColour(self, ray):
    if self.recursionDepth > 3:
        return (0, 0, 0)
    try:
        self.recursionDepth += 1
        intersections = [(o, o.intersectionTime(ray), s)
                         for (o, s) in self.objects]
        i = firstIntersection(intersections)
        if i is None:
            return (0, 0, 0)
        (o, t, s) = i
        p = ray.pointAtTime(t)
        return s.colourAt(self, ray, p, o.normalAt(p))
    finally:
        self.recursionDepth -= 1
```
For any ray (primary, reflected, doesn't matter — this function doesn't
care where the ray came from), the algorithm is:
1. Give up and return black if we've already bounced 3 times (prevents
   infinite recursion between two mirrors facing each other, and caps the
   total work per pixel).
2. Test the ray against **every single object** in the scene — this list
   comprehension is a linear scan, no spatial acceleration structure at
   all (no bounding-volume hierarchy, no grid). For 8 objects this is
   fine; it's also exactly why this profiles the way it does.
3. Find the closest hit (`firstIntersection`).
4. No hit → background color (black).
5. Hit something → find the exact 3D point (`pointAtTime`), find the
   surface normal there, and hand off to that object's *surface* to
   compute the actual color (`colourAt` — see Section 7). This is where
   reflection recursion re-enters `rayColour` if the surface is shiny.

The `try/finally` around `recursionDepth` guarantees it gets decremented
even if something raises an exception midway — standard defensive
bookkeeping for a counter that must stay accurate across recursive calls.

```python
def _lightIsVisible(self, l, p):
    for (o, s) in self.objects:
        t = o.intersectionTime(Ray(p, l - p))
        if t is not None and t > EPSILON:
            return False
    return True
```
Shadow testing: to check if a light is visible from point `p`, fire a ray
from `p` toward the light and see if it hits *anything* along the way
(again, a full linear scan over all 8 objects). If it hits something
before reaching the light, that object is blocking the light — `p` is in
shadow relative to that light.

---

## 7. `SimpleSurface` / `CheckerboardSurface` — the shading model

```python
def colourAt(self, scene, ray, p, normal):
    b = self.baseColourAt(p)
    c = (0, 0, 0)

    if self.specularCoefficient > 0:
        reflectedRay = Ray(p, ray.vector.reflectThrough(normal))
        reflectedColour = scene.rayColour(reflectedRay)
        c = addColours(c, self.specularCoefficient, reflectedColour)

    if self.lambertCoefficient > 0:
        lambertAmount = 0
        for lightPoint in scene.visibleLights(p):
            contribution = (lightPoint - p).normalized().dot(normal)
            if contribution > 0:
                lambertAmount += contribution
        lambertAmount = min(1, lambertAmount)
        c = addColours(c, self.lambertCoefficient * lambertAmount, b)

    if self.ambientCoefficient > 0:
        c = addColours(c, self.ambientCoefficient, b)

    return c
```
This is a simplified Phong-style lighting model, blending three
components whose coefficients sum to 1.0 (set in `__init__`:
`ambientCoefficient = 1.0 - specularCoefficient - lambertCoefficient`):

- **Specular (mirror reflection)**: reflect the incoming ray off the
  surface normal (using `reflectThrough` from Section 1) and recursively
  trace *that* ray — this is the direct recursion back into `rayColour`
  that makes shiny surfaces work, and it's why rendering can go up to 3
  levels deep.
- **Lambert (diffuse shading)**: for each light that's actually visible
  from this point (not blocked — `visibleLights` calls `_lightIsVisible`
  for each light), take the dot product between the direction to the
  light and the surface normal. This is the standard "Lambertian" model:
  a surface facing directly at a light is bright (`dot ≈ 1`), a surface
  facing away receives no light from it (`dot ≤ 0`, skipped by the
  `if contribution > 0` check) — matches how a flashlight looks brightest
  when pointed straight at a wall versus glancing across it.
- **Ambient**: a flat, constant color contribution — approximates all the
  indirect bounced light in a real scene without actually simulating it
  (real global illumination is far more expensive; ambient is the classic
  cheap substitute).

```python
class CheckerboardSurface(SimpleSurface):
    def baseColourAt(self, p):
        v = p - Point.ZERO
        v.scale(1.0 / self.checkSize)
        if ((int(abs(v.x) + 0.5) + int(abs(v.y) + 0.5) + int(abs(v.z) + 0.5)) % 2):
            return self.otherColour
        else:
            return self.baseColour
```
Overrides only `baseColourAt` (everything else — specular, Lambert,
ambient — is inherited unchanged from `SimpleSurface`). Rounds the point's
coordinates to the nearest integer, sums them, and checks if that sum is
even or odd — exactly the same trick as a real checkerboard's alternating
black/white squares, extended into 3D.

---

## 8. `bench_raytrace()` — what's actually being timed

```python
def bench_raytrace(loops, width, height, filename):
    range_it = range(loops)
    t0 = pyperf.perf_counter()

    for i in range_it:
        canvas = Canvas(width, height)
        s = Scene()
        s.addLight(Point(30, 30, 10))
        s.addLight(Point(-10, 100, 30))
        s.lookAt(Point(0, 3, 0))
        s.addObject(Sphere(Point(1, 3, -10), 2),
                    SimpleSurface(baseColour=(1, 1, 0)))
        for y in range(6):
            s.addObject(Sphere(Point(-3 - y*0.4, 2.3, -5), 0.4),
                        SimpleSurface(baseColour=(y/6.0, 1-y/6.0, 0.5)))
        s.addObject(Halfspace(Point(0, 0, 0), Vector.UP),
                    CheckerboardSurface())
        s.render(canvas)

    return pyperf.perf_counter() - t0
```
Every timed loop iteration builds the *entire scene from scratch* (1 big
yellow sphere, 6 small spheres arranged in a fading-color row, a
checkerboard floor, 2 lights) and renders a full 100×100 image, then
throws it all away and does it again — `pyperformance` runs this multiple
times to get a statistically stable timing. Nothing is cached or reused
between iterations, which is exactly why every `Vector`/`Point`/`Sphere`
allocation happens fresh, every time — the profiling story
(`RAYTRACE_EXPLANATION.md`) is a direct consequence of this loop's
structure.

---

## 9. The whole algorithm, in one paragraph

For each of the 10,000 pixels: build a ray from the camera through that
pixel → find the closest of 8 objects it hits (or background) → at that
point, blend three lighting components (mirror-reflect and recursively
trace up to 3 bounces deep, sum up contributions from each unshadowed
light via the dot-product-with-normal rule, add a flat ambient term) →
write the resulting color into the image. Every single step — every dot
product, every intersection test, every shadow check — is implemented as
plain Python method calls on hand-rolled `Vector`/`Point` objects with no
acceleration structures and (originally) no `__slots__`, which is exactly
what the profiling in `RAYTRACE_EXPLANATION.md` measured and what the
`__slots__` fix in `src/raytrace_optimized.py` addressed.
