"""Compare production scalar Rodrigues rotations with the unchanged vector solver.

The minimal vector API keeps AngleEx's forward/up basis rather than converting
it back to Euler angles, so wrapping and gimbal representations cannot hide an
orientation difference. This verifies the math; in-engine verification remains
necessary for Source bone matrices. Requires `pip install lupa`.
"""
import math
from pathlib import Path
import random
import re
import unittest

from lupa.luajit21 import LuaRuntime

SOURCE = Path(__file__).resolve().parents[1] / "mmd_vmd_npc/lua/mmd_vmd_npc/cl_menu.lua"


def production_function(source, name):
    start = source.index("local function " + name + "(")
    following = re.search(r"\nlocal function ", source[start + 1:])
    end = start + 1 + following.start() if following else len(source)
    return source[start:end]


def quaternion_basis(q):
    x, y, z, w = q
    # Source's Right is the negative second rotation-matrix column.
    return (
        (1 - 2*(y*y+z*z), 2*(x*y+z*w), 2*(x*z-y*w)),
        (-(2*(x*y-z*w)), -(1-2*(x*x+z*z)), -(2*(y*z+x*w))),
        (2*(x*z+y*w), 2*(y*z-x*w), 1-2*(x*x+y*y)),
    )


def random_basis(rng):
    q = [rng.gauss(0, 1) for _ in range(4)]
    length = math.sqrt(sum(v*v for v in q))
    return quaternion_basis([v/length for v in q])


def euler_basis(pitch, yaw, roll):
    # Unit quaternion from intrinsic XYZ angles, including pitch singularities.
    sx, cx = math.sin(math.radians(roll)/2), math.cos(math.radians(roll)/2)
    sy, cy = math.sin(math.radians(pitch)/2), math.cos(math.radians(pitch)/2)
    sz, cz = math.sin(math.radians(yaw)/2), math.cos(math.radians(yaw)/2)
    return quaternion_basis((sx*cy*cz-cx*sy*sz, cx*sy*cz+sx*cy*sz,
                             cx*cy*sz-sx*sy*cz, cx*cy*cz+sx*sy*sz))


class BuildRotationTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(r'''
            local vector = {}; vector.__index = vector
            vector_allocations, sine_calls, cosine_calls = 0, 0, 0
            local realSin, realCos = math.sin, math.cos
            math.sin = function(x) sine_calls = sine_calls + 1; return realSin(x) end
            math.cos = function(x) cosine_calls = cosine_calls + 1; return realCos(x) end
            local ffi = require("ffi")
            local function scalar(v)
                return float32 and tonumber(ffi.cast("float", v)) or v
            end
            function Vector(x,y,z)
                vector_allocations = vector_allocations + 1
                return setmetatable({x=scalar(x),y=scalar(y),z=scalar(z)}, vector)
            end
            function vector:LengthSqr() return self.x*self.x+self.y*self.y+self.z*self.z end
            function vector:Dot(b) return self.x*b.x+self.y*b.y+self.z*b.z end
            function vector:Cross(b)
                return Vector(self.y*b.z-self.z*b.y, self.z*b.x-self.x*b.z, self.x*b.y-self.y*b.x)
            end
            function vector:Normalize()
                local n=math.sqrt(self:LengthSqr())
                if n>0 then self.x,self.y,self.z=scalar(self.x/n),scalar(self.y/n),scalar(self.z/n) end
            end
            function vector.__add(a,b) return Vector(a.x+b.x,a.y+b.y,a.z+b.z) end
            function vector.__mul(a,b) return Vector(a.x*b,a.y*b,a.z*b) end
            function vector:AngleEx(up) return {forward=self,up=up} end
            function clean_angle(v) return v end
            function basis_angle(f,r,u)
                return {
                    Forward=function() return Vector(f[1],f[2],f[3]) end,
                    Right=function() return Vector(r[1],r[2],r[3]) end,
                    Up=function() return Vector(u[1],u[2],u[3]) end,
                }
            end
            function cached_axes(model)
                local axes={model:Right(),model:Forward(),model:Up()}
                for _,a in ipairs(axes) do a:Normalize() end
                return axes
            end
            function reset_counts() vector_allocations,sine_calls,cosine_calls=0,0,0 end
        ''')
        source = SOURCE.read_text(encoding="utf-8")
        chunk = "\n".join(production_function(source, name) for name in (
            "rotate_vector_around_axis", "rotate_angle_around_sequential_model_axes", "fast_rotate_model_angle"))
        self.api = self.lua.execute(chunk + "\nreturn {legacy=rotate_angle_around_sequential_model_axes,fast=fast_rotate_model_angle}")

    def angle(self, basis):
        return self.lua.globals().basis_angle(*(self.lua.table_from(v) for v in basis))

    def check_rotation(self, baseline_basis, model_basis, degrees, tolerance=2e-12):
        baseline, model = self.angle(baseline_basis), self.angle(model_basis)
        axes = self.lua.globals().cached_axes(model)
        degrees = self.lua.table_from(degrees)
        expected = self.api.legacy(baseline, model, degrees)
        actual = self.api.fast(baseline, axes, degrees)
        for key in ("forward", "up"):
            err = math.sqrt(sum((actual[key][a] - expected[key][a])**2 for a in ("x", "y", "z")))
            self.assertLessEqual(err, tolerance, (key, err))
        return actual, expected

    def test_randomized_baseline_and_model_orientations(self):
        rng = random.Random(214850)
        for _ in range(2000):
            self.check_rotation(random_basis(rng), random_basis(rng),
                                {a: rng.uniform(-1080,1080) for a in ("x","y","z")})

    def test_zero_wraps_and_positive_negative_single_axes(self):
        baseline, model = euler_basis(42,-130,27), euler_basis(-21,76,155)
        for angle in (0,1e-6,0.000009999,0.00001,0.000010001,-0.00001,
                      45,-45,90,-90,180,-180,360,-360,720,-720,1000000,-1000000):
            for axis in ("x","y","z"):
                degrees = {"x":0,"y":0,"z":0}
                degrees[axis] = angle
                self.check_rotation(baseline, model, degrees)

    def test_gimbal_orientations_preserve_basis(self):
        for pitch in (90,-90,89.999999,-89.999999,0,180):
            for yaw in (0,90,180,-90,360):
                self.check_rotation(euler_basis(pitch,yaw,47), euler_basis(-pitch,37,-yaw),
                                    {"x":90,"y":-90,"z":180})

    def test_float32_vector_rounding_stays_below_engine_tolerance(self):
        # This models rounding at vector API boundaries, not Source internals.
        # Eliminating intermediate vectors changes rounding, but not the pose.
        self.lua.globals().float32 = True
        rng = random.Random(71121)
        for _ in range(1000):
            self.check_rotation(random_basis(rng), random_basis(rng),
                                {a:rng.uniform(-360,360) for a in ("x","y","z")},
                                tolerance=2e-6)

    def test_three_rotations_halve_trigonometry_and_reduce_vector_allocations(self):
        baseline, model = self.angle(euler_basis(30,60,90)), self.angle(euler_basis(-20,55,80))
        axes = self.lua.globals().cached_axes(model)
        degrees = self.lua.table_from({"x":12,"y":34,"z":56})
        counts = []
        for fn, axis_arg in ((self.api.legacy,model),(self.api.fast,axes)):
            self.lua.globals().reset_counts()
            fn(baseline,axis_arg,degrees)
            counts.append(tuple(self.lua.globals()[name] for name in
                                ("vector_allocations","sine_calls","cosine_calls")))
        self.assertEqual(counts[0][1:],(6,6))
        self.assertEqual(counts[1],(4,3,3))
        self.assertLess(counts[1][0],counts[0][0]/4)


if __name__ == "__main__":
    unittest.main()