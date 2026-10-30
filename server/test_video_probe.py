from pathlib import Path
import unittest
from unittest.mock import patch
from video_probe import _analyze
import subprocess
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

    def log(self, crop, count=10):
        return 'Duration: 00:02:00.00\nVideo: h264, yuv420p, 720x1280\n' + (crop+'\n')*count

    def test_dark_opening_uses_later_independent_windows(self):
        dark = self.log('crop=0:0:0:0')
        picture = self.log('crop=180:320:270:480')
        with patch('video_probe._sample', side_effect=[dark, picture, picture]) as sample:
            result = _analyze('ffmpeg', Path('synthetic'))
        self.assertEqual((result['w'], result['h']), (188, 328))
        self.assertEqual([c.args[2] for c in sample.call_args_list], [0, 42, 84])

    def test_wider_later_scene_is_not_cut_off(self):
        small = self.log('crop=180:320:270:480')
        wide = self.log('crop=720:1280:0:0', 1)
        with patch('video_probe._sample', side_effect=[small, small, small+wide]):
            result = _analyze('ffmpeg', Path('synthetic'))
        self.assertEqual((result['x'], result['y'], result['w'], result['h']), (0, 0, 720, 1280))

    def test_insufficient_evidence_and_failed_window_do_not_crop(self):
        dark = self.log('crop=0:0:0:0')
        picture = self.log('crop=180:320:270:480')
        for windows in ([dark, dark, picture], [picture, '', picture]):
            with patch('video_probe._sample', side_effect=windows):
                self.assertEqual(_analyze('ffmpeg', Path('synthetic')), {})

    def test_rotation_is_not_mistaken_for_source_coordinates(self):
        with patch('video_probe._sample', return_value=self.log('crop=180:320:270:480')+'rotation of -90.00 degrees') as sample:
            self.assertEqual(_analyze('ffmpeg', Path('synthetic')), {})
            self.assertEqual(sample.call_count, 1)
