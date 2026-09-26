"""Safety checks shared by destructive real-SketchUp smoke scripts."""

FIXTURE_ID = "homecad-smoke-v1"


class SmokeGuardError(RuntimeError):
    pass


def validate_disposable_fixture(confirmed: bool, model_info: dict) -> None:
    if not confirmed:
        raise SmokeGuardError("pass --confirm-disposable")
    if model_info.get("dev_fixture") is not True or model_info.get("dev_fixture_id") != FIXTURE_ID:
        raise SmokeGuardError(
            "REFUSED: active model is not the designated HomeCAD smoke fixture"
        )
