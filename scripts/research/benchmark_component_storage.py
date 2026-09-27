"""Compare lossless containers for a local SKP catalog; never save model data.

Archives are constructed and verified in memory. Only aggregate measurements
and input hashes are written to the JSON report. Timings exclude source disk I/O
and SketchUp loading; each codec is measured once.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import lzma
import platform
import tarfile
import time
import zipfile
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    paths = sorted(set(args.directory.glob("Blum Antaro *.skp")) |
                   set(args.directory.glob("Blum MERIVOBOX *.skp")))
    if not paths:
        parser.error("No Antaro or MERIVOBOX SKP models found")
    if args.output.resolve().is_relative_to(args.directory.resolve()):
        parser.error("Report must be outside the source directory")
    sources = {path.name: path.read_bytes() for path in paths}
    hashes = {name: hashlib.sha256(data).hexdigest()
              for name, data in sources.items()}
    results = []
    for label, codec, level in (("zip_deflate_6", zipfile.ZIP_DEFLATED, 6),
                                ("zip_deflate_9", zipfile.ZIP_DEFLATED, 9),
                                ("zip_lzma", zipfile.ZIP_LZMA, None)):
        started = time.perf_counter()
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w", compression=codec,
                             compresslevel=level) as archive:
            for name, data in sources.items():
                entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                archive.writestr(entry, data, compress_type=codec,
                                 compresslevel=level)
        packed = buffer.getvalue()
        encode_seconds = time.perf_counter() - started
        started = time.perf_counter()
        with zipfile.ZipFile(io.BytesIO(packed)) as archive:
            restored = {name: archive.read(name) for name in archive.namelist()}
        decode_seconds = time.perf_counter() - started
        if restored != sources:
            raise RuntimeError(f"Byte comparison failed: {label}")
        results.append({"format": label, "bytes": len(packed),
                        "encode_seconds": encode_seconds,
                        "decode_seconds": decode_seconds,
                        "byte_equal": True})
        print(json.dumps(results[-1]), flush=True)

    # A single LZMA stream can exploit repetition across neighboring files.
    started = time.perf_counter()
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.PAX_FORMAT) as archive:
        for name, data in sources.items():
            entry = tarfile.TarInfo(name)
            entry.size = len(data)
            entry.mtime = 0
            archive.addfile(entry, io.BytesIO(data))
    packed = lzma.compress(buffer.getvalue(), preset=6)
    encode_seconds = time.perf_counter() - started
    started = time.perf_counter()
    with tarfile.open(fileobj=io.BytesIO(lzma.decompress(packed)), mode="r:") as archive:
        restored = {entry.name: archive.extractfile(entry).read()
                    for entry in archive.getmembers()}
    decode_seconds = time.perf_counter() - started
    if restored != sources:
        raise RuntimeError("Byte comparison failed: tar_xz_6")
    results.append({"format": "tar_xz_6", "bytes": len(packed),
                    "encode_seconds": encode_seconds,
                    "decode_seconds": decode_seconds, "byte_equal": True})
    print(json.dumps(results[-1]), flush=True)
    report = {"files": len(sources), "source_bytes": sum(map(len, sources.values())),
              "python": platform.python_version(), "platform": platform.platform(),
              "method": "single run in memory; byte comparison after decode",
              "input_sha256": hashes, "results": results}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n",
                           encoding="utf-8")


if __name__ == "__main__":
    main()
