import importlib.util
import pathlib
import struct
import unittest

spec = importlib.util.spec_from_file_location('repair', pathlib.Path(__file__).resolve().parents[2] / 'scripts/patch-repair.py')
repair = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repair)


class RepairTests(unittest.TestCase):
    def fixture(self):
        return struct.pack('<IiiIIIII', 0xfeedfacf, 0x100000c, 0, 2, 1, 8, 0, 0) + struct.pack('<II', 0x24, 8) + bytes(256)

    def test_adds_exactly_one_required_load(self):
        binary = repair.inject(self.fixture(), repair.INSTALL_NAME)
        self.assertEqual(struct.unpack_from('<I', binary, 16)[0], 2)
        self.assertEqual(struct.unpack_from('<I', binary, 40)[0], 0xc)
        self.assertIn(repair.INSTALL_NAME.encode() + b'\0', binary)
        self.assertEqual(repair.inject(binary, repair.INSTALL_NAME), binary)

    def test_preserves_bytes_after_padding(self):
        original = self.fixture() + b'unchanged payload'
        self.assertEqual(repair.inject(original, repair.EXT_INSTALL_NAME)[-17:], original[-17:])

    def test_rejects_non_macho(self):
        with self.assertRaises(ValueError):
            repair.inject(b'not an executable', repair.INSTALL_NAME)

    def test_rejects_nonzero_padding(self):
        with self.assertRaisesRegex(ValueError, 'padding'):
            repair.inject(self.fixture()[:40] + b'X' * 256, repair.INSTALL_NAME)

    def test_rejects_invalid_command_length(self):
        original = bytearray(self.fixture())
        struct.pack_into('<I', original, 36, 0)
        with self.assertRaisesRegex(ValueError, 'command'):
            repair.inject(original, repair.INSTALL_NAME)

    def test_rejects_encrypted_input(self):
        header = struct.pack('<IiiIIIII', 0xfeedfacf, 0x100000c, 0, 2, 1, 24, 0, 0)
        encrypted = header + struct.pack('<IIIIII', 0x2c, 24, 0, 4096, 1, 0) + bytes(256)
        with self.assertRaisesRegex(ValueError, 'Encrypted'):
            repair.inject(encrypted, repair.INSTALL_NAME)
