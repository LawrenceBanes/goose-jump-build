import sys
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import audit


@unittest.skipUnless(audit.EXE.is_file() and audit.META.is_file(),
                     "private source app inputs are absent from source-only CI")
class SourceAppAuditTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.macho = audit.macho_info(audit.EXE)
        cls.metadata = audit.metadata_info(audit.META)

    def test_original_ipa_executable_matches_extracted_copy(self):
        path = f"Payload/{audit.APP.name}/{audit.EXE.name}"
        with zipfile.ZipFile(audit.IPA) as archive:
            import hashlib
            archived = hashlib.sha256(archive.read(path)).hexdigest()
        self.assertEqual(archived, audit.sha256(audit.EXE))

    def test_header_only_xor_reconstructs_metadata_version_24(self):
        self.assertEqual(self.metadata["first_four_transform"], "xor-0x5a")
        self.assertEqual(self.metadata["version"], 24)
        self.assertEqual(self.metadata["type_count"], 7899)
        self.assertEqual(self.metadata["method_count"], 54921)
        found = {(c["namespace"], c["name"]): c for c in self.metadata["classes"]}
        self.assertIn(("Mobile", "MobileControlsManager"), found)
        self.assertIn(("", "Mover"), found)
        mover = found[("", "Mover")]
        self.assertIn("rb", [f["name"] for f in mover["fields"]])
        self.assertIn("FixedUpdate", [m["name"] for m in mover["methods"]])

    def test_ui_methods_are_function_entries_and_button_calls_match(self):
        starts = set(self.macho["function_starts"])
        for address in (0x101102FC8, 0x101108804, 0x10110B524):
            self.assertIn(address, starts)
        executable = audit.EXE.read_bytes()
        for address in (0x10110349C, 0x101103540, 0x1011035E4,
                        0x101103688, 0x101103A1C, 0x101103ABC):
            word = int.from_bytes(executable[address - 0x100000000:address - 0x100000000 + 4], "little")
            immediate = word & 0x03FFFFFF
            if immediate & (1 << 25):
                immediate -= 1 << 26
            self.assertEqual(word >> 26, 0b100101)
            self.assertEqual(address + immediate * 4, 0x101108804)

    def test_movement_hook_lead_is_not_a_function_entry(self):
        self.assertNotIn(0x1011107E0, self.macho["function_starts"])

    def test_suggested_data_address_is_unsectioned_zero_fill(self):
        candidate = 0x102E1B000
        data = next(s for s in self.macho["segments"] if s["name"] == "__DATA")
        self.assertTrue(data["vmaddr"] <= candidate < data["vmaddr"] + data["vmsize"])
        self.assertFalse(any(s["addr"] <= candidate < s["addr"] + s["size"]
                             for s in data["sections"]))
        self.assertGreater(candidate, data["vmaddr"] + data["filesize"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
