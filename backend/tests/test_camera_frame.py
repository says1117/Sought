"""Pure camera core checks, runnable with unittest and Pillow alone."""
import io
import unittest
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import patch

from PIL import Image

from backend.camera_frame import LatestFrame, MAX_FRAME_BYTES, is_stale, validate_frame


def image_bytes(size=(640, 480), format="JPEG"):
    output = io.BytesIO()
    Image.new("RGB", size, "red").save(output, format=format)
    return output.getvalue()


class CameraFrameTests(unittest.TestCase):
    def test_accepts_valid_jpeg_and_exact_byte_limit(self):
        data = image_bytes()
        validate_frame(data)
        validate_frame(data + b"\0" * (MAX_FRAME_BYTES - len(data)))

    def test_rejects_invalid_or_truncated_images(self):
        for data in [b"", b"invalid", image_bytes(format="PNG"), image_bytes()[:-100]]:
            with self.subTest(length=len(data)), self.assertRaises(ValueError):
                validate_frame(data)

    def test_rejects_byte_and_dimension_limits(self):
        for data in [b"x" * (MAX_FRAME_BYTES + 1), image_bytes((641, 10)), image_bytes((10, 641))]:
            with self.subTest(length=len(data)), self.assertRaises(ValueError):
                validate_frame(data)

    def test_rejects_decompression_bomb(self):
        data = image_bytes((20, 20))
        with patch.object(Image, "MAX_IMAGE_PIXELS", 300), self.assertRaises(ValueError):
            validate_frame(data)

    def test_replacement_and_independent_stores(self):
        first, other = LatestFrame(), LatestFrame()
        self.assertIsNone(first.get(0))
        first.put(b"one", 100)
        first.put(b"two", 101)
        self.assertEqual(first.get(102), (b"two", 1))
        self.assertIsNone(other.get(102))

    def test_receipt_age_stale_boundary_and_nonnegative_age(self):
        store = LatestFrame()
        store.put(b"frame", 100)
        self.assertEqual(store.get(99), (b"frame", 0))
        self.assertFalse(is_stale(store.get(105)[1]))
        self.assertTrue(is_stale(store.get(105.001)[1]))

    def test_concurrent_store_snapshots_are_consistent(self):
        store = LatestFrame()

        def write_and_read(index):
            store.put(str(index).encode(), float(index))
            data, age = store.get(1000)
            self.assertEqual(age, 1000 - int(data))

        with ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(write_and_read, range(100)))


if __name__ == "__main__":
    unittest.main()
