from pathlib import Path
import unittest
from video_probe import detect_crop


class CropTests(unittest.TestCase):
    def test_embedded_vertical_picture(self):
        path = Path(__file__).parents[1]/'UITests'/'Fixtures'/'黑边竖屏测试.mkv'
        result = detect_crop(path)
        self.assertEqual(result['width'], 720)
        self.assertEqual(result['height'], 1280)
        self.assertLess(result['w'], 200)
        self.assertLess(result['h'], 340)
        self.assertGreater(result['w'], 175)
        self.assertGreater(result['h'], 315)
        self.assertEqual(detect_crop(path), result)
