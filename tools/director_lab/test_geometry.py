import math, random, unittest
from tools.director_lab import geometry as g


class GeometryTests(unittest.TestCase):
    def test_apply_shift_reaches_ideal(self):
        rng = random.Random(1)
        ideal = g.full_image_ideal()
        for _ in range(500):
            cur = g.sample_current_window(ideal, rng, keep_prob=0.0)
            dx, dy, dz, q = g.make_target(cur, ideal)
            nxt = g.apply_shift(cur, dx, dy, dz)
            # 目标未被裁剪时，应当一步回到理想窗口
            if max(abs(dx), abs(dy), abs(dz)) < g.SHIFT_LIMIT - 1e-9:
                self.assertAlmostEqual(nxt.cx, ideal.cx, places=6)
                self.assertAlmostEqual(nxt.cy, ideal.cy, places=6)
                self.assertAlmostEqual(nxt.s, ideal.s, places=6)
            self.assertTrue(0.0 <= q <= 1.0)

    def test_keep_window_is_quality_one(self):
        ideal = g.Window(0.4, 0.55, 0.7)
        dx, dy, dz, q = g.make_target(ideal, ideal)
        self.assertEqual((dx, dy, dz), (0.0, 0.0, 0.0))
        self.assertAlmostEqual(q, 1.0)

    def test_direction_conventions(self):
        ideal = g.full_image_ideal()
        # 当前窗口偏左上 -> 应该向右、向下移动
        cur = g.Window(0.3, 0.3, 0.6)
        dx, dy, dz, _ = g.make_target(cur, ideal)
        self.assertGreater(dx, 0); self.assertGreater(dy, 0)
        # 当前窗口比理想小（放太大了）-> dz<0 拉远
        self.assertLess(dz, 0)
        # 当前窗口比理想大 -> 推近
        _, _, dz2, _ = g.make_target(g.Window(0.5, 0.5, 1.0), g.Window(0.5, 0.5, 0.6))
        self.assertGreater(dz2, 0)

    def test_flip_negates_dx(self):
        ideal = g.Window(0.45, 0.5, 0.8)
        cur = g.Window(0.35, 0.4, 0.6)
        dx, dy, dz, q = g.make_target(cur, ideal)
        fdx, fdy, fdz, fq = g.make_target(g.flip_horizontal(cur), g.flip_horizontal(ideal))
        self.assertAlmostEqual(fdx, -dx); self.assertAlmostEqual(fdy, dy)
        self.assertAlmostEqual(fdz, dz); self.assertAlmostEqual(fq, q)

    def test_sampling_keeps_overlap_and_bounds(self):
        rng = random.Random(7)
        ideal = g.ideal_from_box(0.2, 0.15, 0.5, 0.6)
        for _ in range(500):
            w = g.sample_current_window(ideal, rng)
            x, y, bw, bh = w.box()
            self.assertGreaterEqual(x, -1e-9); self.assertGreaterEqual(y, -1e-9)
            self.assertLessEqual(x + bw, 1 + 1e-9); self.assertLessEqual(y + bh, 1 + 1e-9)

    def test_scene_index(self):
        self.assertEqual(g.scene_index("人物"), 0)
        self.assertEqual(g.scene_index("unlabeled"), -1)
        self.assertEqual(g.scene_index(None), -1)


if __name__ == "__main__":
    unittest.main()
