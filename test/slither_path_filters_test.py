"""Keep project libraries visible to the pinned Slither path filtering API."""

import json
from pathlib import Path
import unittest

from slither.core.slither_core import SlitherCore


ROOT = Path(__file__).resolve().parents[1]


class SlitherPathFilterTest(unittest.TestCase):
    def assert_visible(self, relative_path, expected):
        config = json.loads((ROOT / ".slither.config.json").read_text(encoding="utf-8"))
        analyzer = SlitherCore()
        # Exercise path filtering without triage, dependency or ignore-comment state.
        analyzer._show_ignored_findings = True
        for pattern in config["filter_paths"].split(","):
            analyzer.add_path_to_filter(pattern)
        result = {
            "id": relative_path,
            "elements": [{"source_mapping": {"filename_absolute": str(ROOT / relative_path)}}],
        }
        self.assertEqual(analyzer.valid_result(result), expected, relative_path)

    def test_keeps_production_libraries(self):
        self.assert_visible("contracts/libraries/LibCreditLedger.sol", True)

    def test_keeps_production_facets(self):
        self.assert_visible("contracts/facets/reservation/ReservationSessionFacet.sol", True)

    def test_keeps_production_interfaces(self):
        self.assert_visible("contracts/interfaces/IDiamond.sol", True)

    def test_keeps_similar_library_directory_names(self):
        self.assert_visible("contracts/library-tools/Helper.sol", True)

    def test_keeps_similar_test_directory_names(self):
        self.assert_visible("contracts/libraries/test-utils/Helper.sol", True)

    def test_excludes_vendored_dependencies(self):
        self.assert_visible("lib/openzeppelin-contracts/contracts/utils/Arrays.sol", False)

    def test_excludes_facet_test_helpers(self):
        self.assert_visible("contracts/facets/test/TestHelperFacet.sol", False)

    def test_excludes_contract_harnesses(self):
        self.assert_visible("contracts/test/LibHeapHarness.sol", False)

    def test_excludes_test_suites(self):
        self.assert_visible("test/CreditLedger.t.sol", False)


if __name__ == "__main__":
    unittest.main()
