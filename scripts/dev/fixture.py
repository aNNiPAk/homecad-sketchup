"""Create the marked disposable model through a one-shot SketchUp startup script."""

from __future__ import annotations

import json
import os
import secrets
import shutil
import stat
import tempfile
from pathlib import Path

from .core import FIXTURE_ID, DevError, local_root


def _ruby_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=True)


def discover_blank_template(sketchup_exe: Path) -> Path:
    for locale in ("ru", "en-US"):
        candidate = sketchup_exe.parent / "resources" / locale / "Templates" / "Temp01b - Simple.skp"
        if candidate.is_file():
            return candidate.resolve()
    raise DevError("SketchUp's installed Simple template was not found; cannot safely bootstrap an empty model")


def prepare_writable_template(root: Path, sketchup_exe: Path) -> Path:
    """Open a disposable copy so SketchUp never prompts about Program Files read-only access."""
    source = discover_blank_template(sketchup_exe)
    directory = local_root(root) / "fixture"
    directory.mkdir(parents=True, exist_ok=True)
    handle, name = tempfile.mkstemp(prefix="SketchUp-Simple-Working-Copy-", suffix=".skp", dir=directory)
    os.close(handle)
    target = Path(name)
    try:
        shutil.copyfile(source, target)
        os.chmod(target, stat.S_IREAD | stat.S_IWRITE)
        return target.resolve()
    except Exception:
        target.unlink(missing_ok=True)
        raise


def install_bootstrap(root: Path, config: dict, template: Path) -> tuple[Path, str, Path]:
    """Install an authenticated temporary .rb startup script; caller removes it in finally."""
    token = secrets.token_urlsafe(32)
    result_path = local_root(root) / "bootstrap-result.json"
    result_path.unlink(missing_ok=True)
    bootstrap = local_root(root) / f"bootstrap_{token[:12]}.rb"
    model_path = Path(config["test_model"]).resolve()
    script = f'''# Temporary HomeCAD fixture bootstrap. Authenticated by this process environment.
require 'json'
require 'fileutils'
expected_token = {_ruby_string(token)}
result_path = {_ruby_string(str(result_path))}
fixture_path = {_ruby_string(str(model_path))}
bootstrap_path = {_ruby_string(str(bootstrap))}
template_path = {_ruby_string(str(template.resolve()))}
started_at = Time.now
new_model_requested = false
write_result = lambda do |data|
  File.write(result_path, JSON.generate(data))
end
unless ENV['HOMECAD_DEV_BOOTSTRAP_TOKEN'] == expected_token
  write_result.call({{status: 'error', message: 'bootstrap token mismatch'}})
  File.delete(bootstrap_path) if File.file?(bootstrap_path)
else
  attempt = nil
  attempt = lambda do
    begin
      model = Sketchup.active_model
      if model.nil?
        if Time.now - started_at > 90
          raise 'SketchUp has no active model after 90 seconds'
        end
        UI.start_timer(1.0, false) {{ attempt.call }}
        next
      end
      unless new_model_requested
        normalize = lambda {{ |path| File.expand_path(path.to_s).downcase }}
        unless normalize.call(model.path) == normalize.call(template_path)
          raise 'refusing to bootstrap from a model other than the installed SketchUp Simple template'
        end
        Sketchup.file_new
        new_model_requested = true
        UI.start_timer(1.0, false) {{ attempt.call }}
        next
      end
      raise 'refusing to mark a saved model as disposable' unless model.path.to_s.empty?
      # SketchUp's default new-model template can insert one scale figure.
      # This is a newly created, unsaved model in our dedicated process.
      if model.entities.length == 1 && model.entities.first.is_a?(Sketchup::ComponentInstance)
        model.entities.first.erase!
      end
      raise 'refusing to mark a nonempty model as disposable' unless model.entities.length.zero?
      group = model.entities.add_group
      group.name = 'HomeCAD Smoke Target'
      points = [[0,0,0], [100,0,0], [100,100,0], [0,100,0]].map {{ |p| Geom::Point3d.new(p[0].mm, p[1].mm, p[2].mm) }}
      face = group.entities.add_face(points)
      raise 'fixture target face could not be created' unless face
      face.pushpull(100.mm)
      model.set_attribute('HomeCADDev', 'fixture_id', {_ruby_string(FIXTURE_ID)})
      model.set_attribute('HomeCADDev', 'disposable', true)
      FileUtils.mkdir_p(File.dirname(fixture_path))
      raise 'fixture model save failed' unless model.save(fixture_path)
      write_result.call({{status: 'success', fixture_id: {_ruby_string(FIXTURE_ID)}, path: model.path, root_entity_count: model.entities.length}})
      File.delete(bootstrap_path) if File.file?(bootstrap_path)
    rescue => error
      write_result.call({{status: 'error', message: error.message, backtrace: error.backtrace&.first(5)}})
      File.delete(bootstrap_path) if File.file?(bootstrap_path)
    end
  end
  UI.start_timer(1.0, false) {{ attempt.call }}
end
'''
    bootstrap.parent.mkdir(parents=True, exist_ok=True)
    with bootstrap.open("x", encoding="utf-8") as stream:
        stream.write(script)
    return bootstrap, token, result_path


def read_bootstrap_result(path: Path) -> dict | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except (OSError, json.JSONDecodeError) as error:
        raise DevError(f"invalid fixture bootstrap result {path}: {error}") from error
