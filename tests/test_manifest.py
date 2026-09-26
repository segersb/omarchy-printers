import json
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class ManifestTests(unittest.TestCase):
    def test_manifest_declares_summonable_panel(self):
        manifest = json.loads((ROOT / "manifest.json").read_text())

        self.assertEqual(manifest["schemaVersion"], 1)
        self.assertEqual(manifest["id"], "segersb.omarchy-printers")
        self.assertIn("panel", manifest["kinds"])
        self.assertIn("bar-widget", manifest["kinds"])
        self.assertIn("service", manifest["kinds"])
        self.assertEqual(manifest["entryPoints"]["service"], "PrinterService.qml")
        self.assertEqual(manifest["entryPoints"]["panel"], "PrinterPanel.qml")
        self.assertEqual(
            manifest["entryPoints"]["barWidget"], "PrinterQuickPanel.qml"
        )

    def test_entry_points_exist(self):
        manifest = json.loads((ROOT / "manifest.json").read_text())

        for entry_point in manifest["entryPoints"].values():
            self.assertTrue((ROOT / entry_point).is_file())

    def test_menu_snippet_targets_plugin(self):
        menu = json.loads((ROOT / "docs" / "omarchy-menu.jsonc").read_text())

        self.assertIn("segersb.omarchy-printers", menu["setup.printers"]["action"])


if __name__ == "__main__":
    unittest.main()
