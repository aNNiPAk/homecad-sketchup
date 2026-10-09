from zipfile import ZipFile

from homecad_mcp import VERSION

from scripts.build_rbz import build


def test_rbz_contains_loader_and_matching_support_folder():
    output = build()
    with ZipFile(output) as archive:
        names = set(archive.namelist())
        assert "homecad.rb" in names
        assert "homecad/main.rb" in names
        assert "homecad/runtime/server.rb" in names
        required_core_files = {
            "scene", "targeting", "serializer", "inspection", "measurement", "capture",
            "metadata", "mutation", "geometry", "primitives", "mutations", "architecture",
            "wall_attachment", "project_settings", "furniture_data", "furniture",
            "furniture_presets", "hardware_catalog", "drawer_hardware",
            "service_zones", "kitchen", "cutlist",
            "multi_wall_attachment", "corner_kitchen", "kitchen_variants",
            "domain_hooks", "scene_volumes", "electrical_data", "circuits", "electrical",
            "electrical_panels", "electrical_consumers", "electrical_routes", "electrical_rules", "electrical_system",
        }
        assert {f"homecad/core/{name}.rb" for name in required_core_files} <= names
        assert "homecad/catalog/hardware.json" in names
        assert all(name == "homecad.rb" or name.startswith("homecad/") for name in names)
        assert not any(name.startswith(("scripts/", ".homecad-dev/")) for name in names)
        assert f"EXTENSION.version = '{VERSION}'" in archive.read("homecad.rb").decode()
        assert f"VERSION = '{VERSION}'" in archive.read("homecad/main.rb").decode()
