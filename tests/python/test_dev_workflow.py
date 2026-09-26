import json
import zipfile
from pathlib import Path

import pytest

from scripts.dev import core, package
from scripts.dev import bridge
from scripts import dev_verify
from scripts.dev.fixture import install_bootstrap, prepare_writable_template
from scripts.dev_verify import SMOKES
from scripts.dev.core import DevError
from scripts.dev.package import validate_rbz
from scripts.smoke_guard import SmokeGuardError, validate_disposable_fixture


def test_sketchup_discovery_prefers_explicit_then_configured(tmp_path):
    explicit = tmp_path / "explicit.exe"
    configured = tmp_path / "configured.exe"
    explicit.touch()
    configured.touch()
    assert core.discover_sketchup(explicit, configured, registry_entries=[]) == explicit.resolve()
    assert core.discover_sketchup(None, configured, registry_entries=[]) == configured.resolve()


def test_sketchup_discovery_uses_registry_then_common_program_files(tmp_path):
    installed = tmp_path / "SketchUp 2026" / "SketchUp.exe"
    installed.parent.mkdir()
    installed.touch()
    assert core.discover_sketchup(registry_entries=[("SketchUp 2026", installed.parent)]) == installed.resolve()
    program_files = tmp_path / "Program Files"
    common = program_files / "SketchUp" / "SketchUp 2025" / "SketchUp.exe"
    common.parent.mkdir(parents=True)
    common.touch()
    assert core.discover_sketchup(environ={"ProgramFiles": str(program_files)}, registry_entries=[]) == common.resolve()


def test_plugins_discovery_uses_sketchup_year(tmp_path):
    exe = tmp_path / "SketchUp 2026" / "SketchUp.exe"
    exe.parent.mkdir()
    assert core.discover_plugins(exe, tmp_path / "Roaming") == (
        tmp_path / "Roaming" / "SketchUp" / "SketchUp 2026" / "SketchUp" / "Plugins")


def test_config_setup_is_idempotent_and_keeps_machine_state_local(tmp_path):
    root = tmp_path / "repo"
    exe = tmp_path / "SketchUp 2026" / "SketchUp.exe"
    exe.parent.mkdir(parents=True)
    exe.touch()
    plugins = tmp_path / "Plugins"
    config = core.ensure_config(root=root, sketchup_exe=exe, plugins_dir=plugins,
                                environ={"APPDATA": str(tmp_path / "Roaming")})
    again = core.ensure_config(root=root, sketchup_exe=exe, plugins_dir=plugins,
                               environ={"APPDATA": str(tmp_path / "Roaming")})
    assert config["ownership_id"] == again["ownership_id"]
    assert config["plugins_dir"] == str(plugins.resolve())
    assert core.config_path(root).is_file()
    assert core.load_config(core.config_path(root))["repo_root"] == str(root.resolve())


def test_directory_link_and_loader_managed_copy(tmp_path):
    source = tmp_path / "repo" / "homecad"
    source.mkdir(parents=True)
    (source / "runtime.rb").write_text("one", encoding="utf-8")
    link = tmp_path / "plugins" / "homecad"
    core.create_junction(link, source)
    assert core.canonical(core.link_target(link)) == core.canonical(source)
    core.remove_verified_directory_link(link, source)

    loader_source = tmp_path / "repo" / "homecad.rb"
    loader_source.write_text("first", encoding="utf-8")
    loader_destination = tmp_path / "plugins" / "homecad.rb"
    mode, digest = core.create_loader(loader_source, loader_destination, "copy")
    config = {"loader_mode": mode, "loader_sha256": digest}
    loader_source.write_text("updated", encoding="utf-8")
    core.sync_loader(loader_source, loader_destination, config, tmp_path / "config.json")
    assert loader_destination.read_text(encoding="utf-8") == "updated"
    loader_destination.write_text("external modification", encoding="utf-8")
    with pytest.raises(DevError, match="modified outside"):
        core.sync_loader(loader_source, loader_destination, config, tmp_path / "config.json")


def test_setup_backs_up_and_restores_only_recognized_production_homecad(tmp_path):
    root = tmp_path / "repo"
    (root / "sketchup" / "homecad").mkdir(parents=True)
    (root / "sketchup" / "homecad.rb").write_text("HomeCAD homecad/main VERSION", encoding="utf-8")
    plugins = tmp_path / "Plugins"
    support = plugins / "homecad"
    support.mkdir(parents=True)
    (support / "main.rb").write_text("VERSION = '0.1.0'", encoding="utf-8")
    loader = plugins / "homecad.rb"
    loader.write_text("HomeCAD homecad/main", encoding="utf-8")
    config = {"plugins_dir": str(plugins), "loader_mode": None, "loader_sha256": None,
              "support_target": str(root / "sketchup" / "homecad"), "backup": None}
    config_file = root / ".homecad-dev" / "config.json"
    config_file.parent.mkdir(parents=True)
    core._copy_installation_backup(plugins, config, config_file, root)
    core.ensure_dev_links(root, config)
    assert core.canonical(core.link_target(support)) == core.canonical(root / "sketchup" / "homecad")
    core.remove_dev_links(root, config, restore_backup=True)
    assert (plugins / "homecad" / "main.rb").read_text(encoding="utf-8") == "VERSION = '0.1.0'"
    assert loader.read_text(encoding="utf-8") == "HomeCAD homecad/main"


def test_unknown_plugins_homecad_is_never_replaced(tmp_path):
    root = tmp_path / "repo"
    (root / "sketchup" / "homecad").mkdir(parents=True)
    plugins = tmp_path / "Plugins"
    (plugins / "homecad").mkdir(parents=True)
    (plugins / "homecad" / "user.rb").write_text("keep", encoding="utf-8")
    config = {"plugins_dir": str(plugins), "loader_mode": None, "backup": None}
    with pytest.raises(DevError, match="not a recognized"):
        core.ensure_dev_links(root, config)
    assert (plugins / "homecad" / "user.rb").read_text(encoding="utf-8") == "keep"


def test_remove_dev_links_preflights_both_paths_before_unlinking(tmp_path):
    root = tmp_path / "repo"
    support_source = root / "sketchup" / "homecad"
    support_source.mkdir(parents=True)
    loader_source = root / "sketchup" / "homecad.rb"
    loader_source.write_text("HomeCAD", encoding="utf-8")
    plugins = tmp_path / "Plugins"
    support = plugins / "homecad"
    core.create_junction(support, support_source)
    loader = plugins / "homecad.rb"
    loader.write_text("unknown loader", encoding="utf-8")
    config = {"plugins_dir": str(plugins), "support_target": str(support_source),
              "loader_mode": "symlink", "backup": None}
    with pytest.raises(DevError, match="unverified loader"):
        core.remove_dev_links(root, config)
    assert core.canonical(core.link_target(support)) == core.canonical(support_source)
    assert loader.read_text(encoding="utf-8") == "unknown loader"


def _valid_rbz(path: Path, version="0.6.1"):
    files = {name: "runtime" for name in package.REQUIRED}
    files["homecad.rb"] = f"EXTENSION.version = '{version}'"
    files["homecad/main.rb"] = f"VERSION = '{version}'"
    with zipfile.ZipFile(path, "w") as archive:
        for name, content in files.items():
            archive.writestr(name, content)


def test_rbz_validation_checks_structure_version_and_dev_exclusion(tmp_path):
    good = tmp_path / "good.rbz"
    _valid_rbz(good)
    manifest = validate_rbz(good, "0.6.1")
    assert "homecad/core/furniture.rb" in manifest
    bad_version = tmp_path / "bad-version.rbz"
    _valid_rbz(bad_version, "0.6.0")
    with pytest.raises(DevError, match="version"):
        validate_rbz(bad_version, "0.6.1")
    bad_path = tmp_path / "bad-path.rbz"
    _valid_rbz(bad_path)
    with zipfile.ZipFile(bad_path, "a") as archive:
        archive.writestr("../outside.txt", "no")
    with pytest.raises(DevError, match="unsafe path"):
        validate_rbz(bad_path, "0.6.1")


def test_packaged_install_replaces_only_expected_paths_and_removes_exact_payload(tmp_path):
    rbz = tmp_path / "homecad.rbz"
    _valid_rbz(rbz)
    plugins = tmp_path / "Plugins"
    manifest = package.install_rbz(rbz, plugins, "0.6.1")
    assert set(manifest) == set(validate_rbz(rbz, "0.6.1"))
    assert (plugins / "homecad.rb").is_file()
    assert (plugins / "homecad" / "main.rb").is_file()
    package.remove_packaged_install(plugins, manifest)
    assert not (plugins / "homecad.rb").exists()
    assert not (plugins / "homecad").exists()


def test_packaged_cleanup_refuses_unexpected_changes(tmp_path):
    rbz = tmp_path / "homecad.rbz"
    _valid_rbz(rbz)
    plugins = tmp_path / "Plugins"
    manifest = package.install_rbz(rbz, plugins, "0.6.1")
    (plugins / "homecad" / "main.rb").write_text("unexpected edit", encoding="utf-8")
    with pytest.raises(DevError, match="refusing to delete"):
        package.remove_packaged_install(plugins, manifest)


def test_stale_process_state_is_cleared_but_unowned_process_is_not_terminated(tmp_path, monkeypatch):
    root = tmp_path
    config = {"ownership_id": "test", "sketchup_exe": str(tmp_path / "SketchUp.exe")}
    state_path = core.local_root(root) / core.STATE_NAME
    state_path.parent.mkdir(parents=True)
    state_path.write_text(json.dumps({"pid": 100, "started_by_homecad_dev": True,
        "ownership_id": "test", "sketchup_exe": config["sketchup_exe"],
        "process_created_filetime": 10}), encoding="utf-8")
    monkeypatch.setattr(core, "process_identity", lambda pid: None)
    monkeypatch.setattr(core, "process_exists", lambda pid: False)
    core.stop_owned_process(root, config)
    assert not state_path.exists()

    state_path.write_text(json.dumps({"pid": 101, "started_by_homecad_dev": True,
        "ownership_id": "someone-else", "sketchup_exe": config["sketchup_exe"]}), encoding="utf-8")
    with pytest.raises(DevError, match="not owned"):
        core.stop_owned_process(root, config)
    assert state_path.exists()


def test_live_pid_identity_mismatch_is_refused(tmp_path, monkeypatch):
    root = tmp_path
    exe = tmp_path / "SketchUp.exe"
    config = {"ownership_id": "owned", "sketchup_exe": str(exe)}
    state_path = core.local_root(root) / core.STATE_NAME
    state_path.parent.mkdir(parents=True)
    state_path.write_text(json.dumps({"pid": 102, "started_by_homecad_dev": True,
        "ownership_id": "owned", "sketchup_exe": str(exe), "process_created_filetime": 10}), encoding="utf-8")
    monkeypatch.setattr(core, "process_identity", lambda pid: {"pid": pid, "created_filetime": 11,
        "executable": str(exe)})
    with pytest.raises(DevError, match="refusing to close"):
        core.stop_owned_process(root, config)


def test_fixture_guard_requires_cli_confirmation_and_exact_marker():
    fixture = {"dev_fixture": True, "dev_fixture_id": "homecad-smoke-v1"}
    validate_disposable_fixture(True, fixture)
    with pytest.raises(SmokeGuardError, match="pass --confirm-disposable"):
        validate_disposable_fixture(False, fixture)
    for normal in ({"dev_fixture": False}, {"dev_fixture": True, "dev_fixture_id": "other"}, {}):
        with pytest.raises(SmokeGuardError, match="REFUSED"):
            validate_disposable_fixture(True, normal)


def test_milestone_smoke_mapping_is_explicit_and_fixture_safe():
    assert SMOKES["m1"][0] == ["scripts/smoke_m1.py", "--name", "HomeCAD Smoke Target"]
    for milestone in ("m2", "m3", "m4"):
        assert "--confirm-disposable" in SMOKES[milestone][0]
    assert SMOKES["m4"][1] == "furniture.core.v1"
    for smoke in ("m2", "m3", "m4"):
        source = (Path(__file__).resolve().parents[2] / "scripts" / f"smoke_{smoke}.py").read_text(encoding="utf-8")
        guard = source.index("validate_disposable_fixture(True")
        first_mutation = source.index({
            "m2": 'box, _ = await call("create_box"',
            "m3": 'wall_id = await create_wall(',
            "m4": 'wall, _ = await call("create_wall"',
        }[smoke])
        assert guard < first_mutation


def test_fixture_bootstrap_marks_only_empty_unsaved_model(tmp_path):
    root = tmp_path / "repo"
    config = {"test_model": str(root / ".homecad-dev" / "fixture" / "HomeCAD-Smoke.skp")}
    template = tmp_path / "SketchUp" / "Template.skp"
    template.parent.mkdir()
    template.touch()
    script_path, token, result_path = install_bootstrap(root, config, template)
    script = script_path.read_text(encoding="utf-8")
    assert "Sketchup.file_new" in script and str(template).replace("\\", "\\\\") in script
    assert "raise 'refusing to mark a saved model as disposable' unless model.path.to_s.empty?" in script
    assert "raise 'refusing to mark a nonempty model as disposable' unless model.entities.length.zero?" in script
    assert "model.entities.first.erase!" in script
    assert "HomeCADDev" in script and "homecad-smoke-v1" in script
    assert token in script and result_path.name == "bootstrap-result.json"


def test_fixture_uses_writable_copy_of_installed_template(tmp_path):
    exe = tmp_path / "Program Files" / "SketchUp" / "SketchUp.exe"
    exe.parent.mkdir(parents=True)
    template = exe.parent / "resources" / "en-US" / "Templates" / "Temp01b - Simple.skp"
    template.parent.mkdir(parents=True)
    template.write_bytes(b"installed template")
    template.chmod(0o444)
    working = prepare_writable_template(tmp_path / "repo", exe)
    assert working.read_bytes() == template.read_bytes()
    assert working != template
    assert working.parent == tmp_path / "repo" / ".homecad-dev" / "fixture"
    assert working.stat().st_mode & 0o200


def test_bridge_ready_check_rejects_missing_fixture_and_version(tmp_path, monkeypatch):
    model = tmp_path / "HomeCAD-Smoke.skp"
    config = {"homecad_port": 37941, "repo_root": str(tmp_path), "test_model": str(model),
              "sketchup_exe": "SketchUp.exe", "plugins_dir": "Plugins"}

    async def fake_call(_root, _port, method):
        if method == "homecad_status":
            return {"connection_status": "connected", "protocol_version": 1, "ruby_extension_version": "0.6.1",
                    "capabilities": ["furniture.core.v1"]}
        return {"dev_fixture": False, "dev_fixture_id": None, "path": str(model)}

    monkeypatch.setattr(bridge, "_call", fake_call)
    with pytest.raises(DevError, match="not the designated"):
        __import__("asyncio").run(bridge.poll_bridge(tmp_path, config, expected_version="0.6.1",
                                                     required_capability="furniture.core.v1", timeout=0.1))

    async def wrong_version(_root, _port, method):
        return {"connection_status": "connected", "protocol_version": 1, "ruby_extension_version": "0.5.0",
                "capabilities": ["furniture.core.v1"]}

    monkeypatch.setattr(bridge, "_call", wrong_version)
    with pytest.raises(DevError, match="version mismatch"):
        __import__("asyncio").run(bridge.poll_bridge(tmp_path, config, expected_version="0.6.1",
                                                     required_capability="furniture.core.v1", timeout=0.1))

    async def missing_capability(_root, _port, method):
        return {"connection_status": "connected", "protocol_version": 1, "ruby_extension_version": "0.6.1",
                "capabilities": []}

    monkeypatch.setattr(bridge, "_call", missing_capability)
    with pytest.raises(DevError, match="missing required capability"):
        __import__("asyncio").run(bridge.poll_bridge(tmp_path, config, expected_version="0.6.1",
                                                     required_capability="furniture.core.v1", timeout=0.1))


def _fake_verify_config(tmp_path):
    fixture = tmp_path / ".homecad-dev" / "fixture" / "HomeCAD-Smoke.skp"
    fixture.parent.mkdir(parents=True)
    fixture.write_bytes(b"fixture")
    return {"repo_root": str(tmp_path), "test_model": str(fixture),
            "sketchup_exe": str(tmp_path / "SketchUp.exe"),
            "plugins_dir": str(tmp_path / "Plugins"), "homecad_port": 37941}


def test_fast_verification_uses_links_fresh_process_and_focused_tests(tmp_path, monkeypatch):
    config = _fake_verify_config(tmp_path)
    events = []
    monkeypatch.setattr(dev_verify, "repo_root", lambda: tmp_path)
    monkeypatch.setattr(dev_verify, "ensure_config", lambda **_kwargs: config)
    monkeypatch.setattr(dev_verify, "stop_owned_process", lambda *_args: events.append("stop"))
    monkeypatch.setattr(dev_verify, "ensure_dev_links", lambda *_args: events.append("links") or config)
    monkeypatch.setattr(dev_verify, "sync_loader", lambda *_args: events.append("sync"))
    monkeypatch.setattr(dev_verify, "_run_focused_tests", lambda *_args: events.append("focused") or [])
    monkeypatch.setattr(dev_verify, "start_sketchup", lambda *_args, **_kwargs: events.append("start") or {"pid": 123})

    async def ready(*_args, **_kwargs):
        events.append("bridge")
        return {"sketchup_version": "26.2.243"}, {"dev_fixture": True}

    monkeypatch.setattr(dev_verify, "poll_bridge", ready)
    monkeypatch.setattr(dev_verify, "_run", lambda *_args, **_kwargs: events.append("smoke") or
                        {"returncode": 0, "stdout": "passed", "stderr": ""})
    report = dev_verify.verify("m4", "fast")
    assert report["status"] == "success"
    assert events == ["stop", "focused", "links", "sync", "start", "bridge", "smoke", "stop"]


def test_packaged_install_failure_restores_verified_dev_links(tmp_path, monkeypatch):
    config = _fake_verify_config(tmp_path)
    events = []
    monkeypatch.setattr(dev_verify, "repo_root", lambda: tmp_path)
    monkeypatch.setattr(dev_verify, "ensure_config", lambda **_kwargs: config)
    monkeypatch.setattr(dev_verify, "stop_owned_process", lambda *_args: events.append("stop"))
    monkeypatch.setattr(dev_verify, "_run_full_tests", lambda *_args: events.append("tests") or [])
    monkeypatch.setattr(package, "validate_rbz", lambda *_args: {"homecad.rb": "hash"})
    monkeypatch.setattr(core, "remove_dev_links", lambda *_args, **_kwargs: events.append("remove links"))
    monkeypatch.setattr(dev_verify, "install_rbz", lambda *_args: events.append("install") or
                        (_ for _ in ()).throw(DevError("injected install failure")))
    monkeypatch.setattr(dev_verify, "ensure_dev_links", lambda *_args: events.append("restore links") or config)
    with pytest.raises(DevError, match="injected install failure"):
        dev_verify.verify("m4", "packaged")
    report = json.loads((tmp_path / ".homecad-dev" / "logs" / "last_packaged_verify.json").read_text())
    assert report["status"] == "failed"
    assert report["dev_links_restored"] is True
    assert events == ["stop", "tests", "remove links", "install", "stop", "restore links"]
