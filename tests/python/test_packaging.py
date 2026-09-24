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
        assert all(name == "homecad.rb" or name.startswith("homecad/") for name in names)
        assert f"EXTENSION.version = '{VERSION}'" in archive.read("homecad.rb").decode()
        assert f"VERSION = '{VERSION}'" in archive.read("homecad/main.rb").decode()
