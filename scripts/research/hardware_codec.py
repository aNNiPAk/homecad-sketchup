"""Research-only SketchUp mesh/instance codec and size benchmark.

Reads SKP files through SketchUp's C API. The HCG1 payload is zlib-compressed
JSON with content-addressed mesh definitions shared across input models.
It intentionally does not preserve SketchUp materials, textures, attributes,
curves, free edges, or Dynamic Components behavior.
"""

from __future__ import annotations

import argparse
import ctypes as C
import hashlib
import json
import os
import struct
import sys
import time
import zlib
from pathlib import Path


MM_PER_INCH = 25.4
GRID_PER_MM = 100  # 0.01 mm geometry/translation grid.
LINEAR_GRID = 1_000_000
MAGIC = b"HCG1"
SIZE_T = C.c_size_t
REF = C.c_void_p


class Point(C.Structure):
    _fields_ = [("x", C.c_double), ("y", C.c_double), ("z", C.c_double)]


class Transform(C.Structure):
    _fields_ = [("values", C.c_double * 16)]


class BoundingBox(C.Structure):
    _fields_ = [("min_point", Point), ("max_point", Point)]


class SketchUpReader:
    def __init__(self, dll_path: Path):
        if not dll_path.is_file():
            raise FileNotFoundError(dll_path)
        self.dll = C.CDLL(str(dll_path))
        self._bind("SUInitialize", None)
        self._bind("SUTerminate", None)
        self._bind("SUModelCreateFromFile", C.c_int, C.POINTER(REF), C.c_char_p)
        self._bind("SUModelRelease", C.c_int, C.POINTER(REF))
        self._bind("SUModelGetEntities", C.c_int, REF, C.POINTER(REF))
        self._bind("SUModelGetNumMaterials", C.c_int, REF, C.POINTER(SIZE_T))
        self._bind("SUModelGetMaterials", C.c_int, REF, SIZE_T,
                   C.POINTER(REF), C.POINTER(SIZE_T))
        self._bind("SUMaterialGetTexture", C.c_int, REF, C.POINTER(REF))
        self._bind("SUEntitiesGetBoundingBox", C.c_int, REF,
                   C.POINTER(BoundingBox))
        for kind in ("Faces", "Groups", "Instances"):
            self._bind(f"SUEntitiesGetNum{kind}", C.c_int, REF, C.POINTER(SIZE_T))
            self._bind(f"SUEntitiesGet{kind}", C.c_int, REF, SIZE_T,
                       C.POINTER(REF), C.POINTER(SIZE_T))
        self._bind("SUEntitiesGetNumEdges", C.c_int, REF, C.c_bool,
                   C.POINTER(SIZE_T))
        self._bind("SUEntitiesGetEdges", C.c_int, REF, C.c_bool, SIZE_T,
                   C.POINTER(REF), C.POINTER(SIZE_T))
        self._bind("SUEdgeGetStartVertex", C.c_int, REF, C.POINTER(REF))
        self._bind("SUEdgeGetEndVertex", C.c_int, REF, C.POINTER(REF))
        self._bind("SUVertexGetPosition", C.c_int, REF, C.POINTER(Point))
        self._bind("SUGroupGetEntities", C.c_int, REF, C.POINTER(REF))
        self._bind("SUGroupGetTransform", C.c_int, REF, C.POINTER(Transform))
        self._bind("SUComponentInstanceGetDefinition", C.c_int, REF, C.POINTER(REF))
        self._bind("SUComponentInstanceGetTransform", C.c_int, REF, C.POINTER(Transform))
        self._bind("SUComponentDefinitionGetEntities", C.c_int, REF, C.POINTER(REF))
        self._bind("SUMeshHelperCreate", C.c_int, C.POINTER(REF), REF)
        self._bind("SUMeshHelperRelease", C.c_int, C.POINTER(REF))
        self._bind("SUMeshHelperGetNumVertices", C.c_int, REF, C.POINTER(SIZE_T))
        self._bind("SUMeshHelperGetNumTriangles", C.c_int, REF, C.POINTER(SIZE_T))
        self._bind("SUMeshHelperGetVertices", C.c_int, REF, SIZE_T,
                   C.POINTER(Point), C.POINTER(SIZE_T))
        self._bind("SUMeshHelperGetVertexIndices", C.c_int, REF, SIZE_T,
                   C.POINTER(SIZE_T), C.POINTER(SIZE_T))
        self.dll.SUInitialize()
        self.definitions: dict[str, dict] = {}
        self.counts = {"faces": 0, "triangles": 0, "edges": 0,
                       "instances": 0, "groups": 0}
        self.max_coordinate_error_mm = 0.0
        self.max_translation_error_mm = 0.0
        self.max_linear_error = 0.0
        self.active: set[int] = set()
        self.memo: dict[int, str] = {}
        self.material_stats: dict[str, dict[str, int]] = {}

    def _bind(self, name: str, result, *args):
        fn = getattr(self.dll, name)
        fn.argtypes = list(args)
        fn.restype = result

    def _call(self, name: str, *args):
        result = getattr(self.dll, name)(*args)
        if result != 0:
            raise RuntimeError(f"{name} failed with SUResult={result}")

    def close(self):
        self.dll.SUTerminate()

    def _refs(self, entities: REF, kind: str) -> list[REF]:
        count = SIZE_T()
        self._call(f"SUEntitiesGetNum{kind}", entities, C.byref(count))
        if not count.value:
            return []
        refs = (REF * count.value)()
        got = SIZE_T()
        self._call(f"SUEntitiesGet{kind}", entities, count, refs, C.byref(got))
        if got.value != count.value:
            raise RuntimeError(f"{kind}: count changed during read")
        return list(refs)

    def _point(self, point: Point) -> tuple[int, int, int]:
        values = []
        for coordinate in (point.x, point.y, point.z):
            mm = coordinate * MM_PER_INCH
            q = round(mm * GRID_PER_MM)
            self.max_coordinate_error_mm = max(self.max_coordinate_error_mm,
                                               abs(mm - q / GRID_PER_MM))
            values.append(q)
        return tuple(values)

    def _transform(self, ref: REF, kind: str) -> list[int]:
        transform = Transform()
        self._call(f"SU{kind}GetTransform", ref, C.byref(transform))
        result = []
        for i, value in enumerate(transform.values):
            scale = MM_PER_INCH * GRID_PER_MM if i in (12, 13, 14) else LINEAR_GRID
            quantized = round(value * scale)
            if i in (12, 13, 14):
                self.max_translation_error_mm = max(
                    self.max_translation_error_mm,
                    abs(value * MM_PER_INCH - quantized / GRID_PER_MM))
            else:
                self.max_linear_error = max(self.max_linear_error,
                                            abs(value - quantized / scale))
            result.append(quantized)
        return result

    def _mesh(self, faces: list[REF]) -> tuple[list[list[int]], list[int]]:
        vertices: list[list[int]] = []
        triangles: list[int] = []
        lookup: dict[tuple[int, int, int], int] = {}
        for face in faces:
            helper = REF()
            self._call("SUMeshHelperCreate", C.byref(helper), face)
            try:
                nv = SIZE_T()
                nt = SIZE_T()
                self._call("SUMeshHelperGetNumVertices", helper, C.byref(nv))
                self._call("SUMeshHelperGetNumTriangles", helper, C.byref(nt))
                if not nv.value or not nt.value:
                    continue
                points = (Point * nv.value)()
                got_points = SIZE_T()
                self._call("SUMeshHelperGetVertices", helper, nv, points,
                           C.byref(got_points))
                indices = (SIZE_T * (nt.value * 3))()
                got_indices = SIZE_T()
                self._call("SUMeshHelperGetVertexIndices", helper, nt.value * 3,
                           indices, C.byref(got_indices))
                if got_points.value != nv.value or got_indices.value != nt.value * 3:
                    raise RuntimeError("Incomplete tessellation")
                local = []
                for point in points:
                    key = self._point(point)
                    if key not in lookup:
                        lookup[key] = len(vertices)
                        vertices.append(list(key))
                    local.append(lookup[key])
                triangles.extend(local[index] for index in indices)
                self.counts["triangles"] += nt.value
            finally:
                self._call("SUMeshHelperRelease", C.byref(helper))
        self.counts["faces"] += len(faces)
        return vertices, triangles

    def _standalone_edges(self, entities: REF, vertices: list[list[int]]) -> list[int]:
        count = SIZE_T()
        self._call("SUEntitiesGetNumEdges", entities, True, C.byref(count))
        if not count.value:
            return []
        refs = (REF * count.value)()
        got = SIZE_T()
        self._call("SUEntitiesGetEdges", entities, True, count, refs, C.byref(got))
        if got.value != count.value:
            raise RuntimeError("Standalone edge count changed during read")
        lookup = {tuple(point): i for i, point in enumerate(vertices)}
        lines = []
        for edge in refs:
            for endpoint in ("Start", "End"):
                vertex = REF()
                point = Point()
                self._call(f"SUEdgeGet{endpoint}Vertex", edge, C.byref(vertex))
                self._call("SUVertexGetPosition", vertex, C.byref(point))
                key = self._point(point)
                if key not in lookup:
                    lookup[key] = len(vertices)
                    vertices.append(list(key))
                lines.append(lookup[key])
        self.counts["edges"] += count.value
        return lines

    def _definition(self, entities: REF) -> str:
        key = int(entities.value)
        if key in self.memo:
            return self.memo[key]
        if key in self.active:
            raise RuntimeError("Recursive component definition")
        self.active.add(key)
        try:
            vertices, triangles = self._mesh(self._refs(entities, "Faces"))
            lines = self._standalone_edges(entities, vertices)
            children = []
            for group in self._refs(entities, "Groups"):
                nested = REF()
                self._call("SUGroupGetEntities", group, C.byref(nested))
                children.append([self._definition(nested), self._transform(group, "Group")])
                self.counts["groups"] += 1
            for instance in self._refs(entities, "Instances"):
                definition = REF()
                nested = REF()
                self._call("SUComponentInstanceGetDefinition", instance, C.byref(definition))
                self._call("SUComponentDefinitionGetEntities", definition, C.byref(nested))
                children.append([self._definition(nested),
                                 self._transform(instance, "ComponentInstance")])
                self.counts["instances"] += 1
            node = {"v": vertices, "t": triangles, "l": lines, "c": children}
            data = json.dumps(node, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
            digest = hashlib.sha256(data).hexdigest()
            self.definitions.setdefault(digest, node)
            self.memo[key] = digest
            return digest
        finally:
            self.active.remove(key)

    def read(self, path: Path) -> tuple[str, list[list[float]]]:
        model = REF()
        self._call("SUModelCreateFromFile", C.byref(model), str(path).encode("utf-8"))
        try:
            count = SIZE_T()
            self._call("SUModelGetNumMaterials", model, C.byref(count))
            materials = (REF * count.value)()
            if count.value:
                got = SIZE_T()
                self._call("SUModelGetMaterials", model, count, materials, C.byref(got))
                if got.value != count.value:
                    raise RuntimeError("Material count changed during read")
            textured = 0
            for material in materials:
                texture = REF()
                if self.dll.SUMaterialGetTexture(material, C.byref(texture)) == 0:
                    textured += 1
            self.material_stats[path.name] = {"materials": count.value,
                                              "textured_materials": textured}
            self.memo.clear()
            entities = REF()
            self._call("SUModelGetEntities", model, C.byref(entities))
            bbox = BoundingBox()
            self._call("SUEntitiesGetBoundingBox", entities, C.byref(bbox))
            bounds = [[getattr(bbox.min_point, axis) * MM_PER_INCH for axis in "xyz"],
                      [getattr(bbox.max_point, axis) * MM_PER_INCH for axis in "xyz"]]
            return self._definition(entities), bounds
        finally:
            self._call("SUModelRelease", C.byref(model))


def encode(payload: dict) -> bytes:
    raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":"),
                     sort_keys=True).encode("utf-8")
    return MAGIC + struct.pack("<Q", len(raw)) + zlib.compress(raw, level=9)


def decode(data: bytes) -> dict:
    if data[:4] != MAGIC:
        raise ValueError("Not an HCG1 file")
    expected = struct.unpack("<Q", data[4:12])[0]
    raw = zlib.decompress(data[12:])
    if len(raw) != expected:
        raise ValueError("HCG1 uncompressed size mismatch")
    return json.loads(raw)


def referenced_definitions(root: str, definitions: dict) -> set[str]:
    found = set()
    pending = [root]
    while pending:
        digest = pending.pop()
        if digest in found:
            continue
        found.add(digest)
        pending.extend(child[0] for child in definitions[digest]["c"])
    return found


def model_bounds(root: str, definitions: dict) -> list[list[float]]:
    minimum = [float("inf")] * 3
    maximum = [float("-inf")] * 3
    identity = [1.0 if i in (0, 5, 10, 15) else 0.0 for i in range(16)]

    def visit(digest: str, matrix: list[float]):
        node = definitions[digest]
        vertices = node["v"]
        triangles = node["t"]
        if any(index < 0 or index >= len(vertices) for index in triangles):
            raise ValueError(f"Invalid triangle index in definition {digest}")
        if any(index < 0 or index >= len(vertices) for index in node["l"]):
            raise ValueError(f"Invalid line index in definition {digest}")
        for qpoint in vertices:
            point = [value / GRID_PER_MM for value in qpoint]
            for axis in range(3):
                value = sum(matrix[axis + 4 * j] * point[j] for j in range(3)) + matrix[axis + 12]
                minimum[axis] = min(minimum[axis], value)
                maximum[axis] = max(maximum[axis], value)
        for child, qmatrix in node["c"]:
            local = [value / (GRID_PER_MM if i in (12, 13, 14) else LINEAR_GRID)
                     for i, value in enumerate(qmatrix)]
            combined = [sum(matrix[row + 4 * k] * local[k + 4 * col]
                            for k in range(4))
                        for col in range(4) for row in range(4)]
            visit(child, combined)

    visit(root, identity)
    return [minimum, maximum]


def export_obj(root: str, definitions: dict, path: Path) -> dict[str, int]:
    identity = [1.0 if i in (0, 5, 10, 15) else 0.0 for i in range(16)]
    vertex_count = 0
    triangle_count = 0
    line_count = 0
    minimum = [float("inf")] * 3
    maximum = [float("-inf")] * 3
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as stream:
        stream.write("# HCG1 geometry preview; coordinates in millimeters\n")

        def visit(digest: str, matrix: list[float]):
            nonlocal vertex_count, triangle_count, line_count
            node = definitions[digest]
            offset = vertex_count
            for qpoint in node["v"]:
                point = [value / GRID_PER_MM for value in qpoint]
                coords = [sum(matrix[axis + 4 * j] * point[j] for j in range(3))
                          + matrix[axis + 12] for axis in range(3)]
                for axis, value in enumerate(coords):
                    minimum[axis] = min(minimum[axis], value)
                    maximum[axis] = max(maximum[axis], value)
                stream.write("v " + " ".join(f"{value:.6f}" for value in coords) + "\n")
                vertex_count += 1
            for i in range(0, len(node["t"]), 3):
                stream.write("f " + " ".join(str(offset + node["t"][i + j] + 1)
                                              for j in range(3)) + "\n")
                triangle_count += 1
            for i in range(0, len(node["l"]), 2):
                stream.write("l " + " ".join(str(offset + node["l"][i + j] + 1)
                                              for j in range(2)) + "\n")
                line_count += 1
            for child, qmatrix in node["c"]:
                local = [value / (GRID_PER_MM if i in (12, 13, 14) else LINEAR_GRID)
                         for i, value in enumerate(qmatrix)]
                combined = [sum(matrix[row + 4 * k] * local[k + 4 * col]
                                for k in range(4))
                            for col in range(4) for row in range(4)]
                visit(child, combined)

        visit(root, identity)
    return {"vertices": vertex_count, "triangles": triangle_count,
            "lines": line_count, "bounds_mm": [minimum, maximum]}


def main() -> bool:
    sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dll", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--unpack", type=Path,
                        help="Decode an HCG1 file to readable JSON without SketchUp")
    parser.add_argument("--obj", type=Path,
                        help="When unpacking, reconstruct one root as an OBJ mesh preview")
    parser.add_argument("--root-name",
                        help="Root filename to export when an HCG1 bundle has multiple models")
    parser.add_argument("inputs", nargs="*", type=Path)
    args = parser.parse_args()
    if args.unpack:
        if args.inputs or args.dll:
            parser.error("--unpack takes no SKP inputs or --dll")
        if args.output.resolve() == args.unpack.resolve():
            parser.error("--output must differ from --unpack")
        if args.obj and args.obj.resolve() in (args.unpack.resolve(), args.output.resolve()):
            parser.error("--obj must differ from the input and JSON output")
        payload = decode(args.unpack.read_bytes())
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(payload, ensure_ascii=False, indent=2),
                               encoding="utf-8")
        summary = {"roots": len(payload["roots"]),
                   "definitions": len(payload["definitions"]),
                   "json_bytes": args.output.stat().st_size}
        if args.obj:
            name = args.root_name
            if name is None:
                if len(payload["roots"]) != 1:
                    parser.error("--root-name is required for a bundle with multiple roots")
                name = next(iter(payload["roots"]))
            if name not in payload["roots"]:
                parser.error(f"Unknown root name: {name}")
            summary.update(export_obj(payload["roots"][name],
                                      payload["definitions"], args.obj))
            summary["obj_bytes"] = args.obj.stat().st_size
        print(json.dumps(summary, indent=2))
        return False
    if args.obj or args.root_name:
        parser.error("--obj and --root-name require --unpack")
    if not args.dll or not args.inputs:
        parser.error("encoding requires --dll and at least one SKP input")
    if args.output.suffix.lower() != ".hcg":
        parser.error("encoding --output must use the .hcg extension")
    protected = {path.resolve() for path in args.inputs}
    if args.output.resolve() in protected:
        parser.error("--output must not overwrite an input SKP")
    if args.report and args.report.resolve() in protected | {args.output.resolve()}:
        parser.error("--report must differ from inputs and HCG output")
    for path in args.inputs:
        if not path.is_file() or path.suffix.lower() != ".skp":
            parser.error(f"Not an SKP file: {path}")
    reader = SketchUpReader(args.dll)
    start = time.perf_counter()
    try:
        if len({path.name for path in args.inputs}) != len(args.inputs):
            parser.error("Input basenames must be unique")
        reads = {path.name: reader.read(path) for path in args.inputs}
        after_read = time.perf_counter()
        roots = {name: result[0] for name, result in reads.items()}
        payload = {"format": "HCG1", "units": "0.01 mm", "linear_grid": LINEAR_GRID,
                   "roots": roots, "definitions": reader.definitions}
        encoded = encode(payload)
        after_encode = time.perf_counter()
        restored = decode(encoded)
        after_decode = time.perf_counter()
        if restored != payload:
            raise RuntimeError("HCG1 round trip differs from extracted geometry")
        reference_sets = {name: referenced_definitions(root, restored["definitions"])
                          for name, root in roots.items()}
        individual_bytes = sum(len(encode({**restored, "roots": {name: roots[name]},
                                           "definitions": {key: restored["definitions"][key]
                                                           for key in keys}}))
                               for name, keys in reference_sets.items())
        bounds_comparison = {
            name: {"source_mm": original,
                   "decoded_mm": model_bounds(roots[name], restored["definitions"])}
            for name, (_, original) in reads.items()
        }
        bounds_error = max(abs(item["source_mm"][side][axis] -
                               item["decoded_mm"][side][axis])
                           for item in bounds_comparison.values()
                           for side in range(2) for axis in range(3))
        reused_definitions = sum(sum(key in keys for keys in reference_sets.values()) > 1
                                 for key in reader.definitions)
        after_validation = time.perf_counter()
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(encoded)
        original = sum(path.stat().st_size for path in args.inputs)
        separately_zlib = sum(len(zlib.compress(path.read_bytes(), 9)) for path in args.inputs)
        after_zlib = time.perf_counter()
        report = {"files": len(args.inputs), "skp_bytes": original,
                  "skp_zlib_bytes": separately_zlib, "hcg1_bytes": len(encoded),
                  "ratio_to_skp": round(len(encoded) / original, 4),
                  "individual_hcg1_bytes_sum": individual_bytes,
                  "definitions": len(reader.definitions),
                  "reused_definitions": reused_definitions,
                  "max_bounds_error_mm": bounds_error,
                  "bounds": bounds_comparison, **reader.counts,
                  "materials_total_per_file": sum(item["materials"] for item in
                                                   reader.material_stats.values()),
                  "textured_materials_total_per_file": sum(
                      item["textured_materials"] for item in reader.material_stats.values()),
                  "material_stats": reader.material_stats,
                  "max_coordinate_error_mm": reader.max_coordinate_error_mm,
                  "max_translation_error_mm": reader.max_translation_error_mm,
                  "max_linear_error": reader.max_linear_error,
                  "extract_seconds": round(after_read - start, 3),
                  "encode_seconds": round(after_encode - after_read, 3),
                  "decode_seconds": round(after_decode - after_encode, 3),
                  "validate_seconds": round(after_validation - after_decode, 3),
                  "skp_zlib_seconds": round(after_zlib - after_validation, 3),
                  "elapsed_seconds": round(after_zlib - start, 3)}
        if args.report:
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2),
                                   encoding="utf-8")
        print(json.dumps({key: value for key, value in report.items()
                          if key not in ("bounds", "material_stats")},
                         ensure_ascii=False, indent=2))
    finally:
        reader.close()
    return True


if __name__ == "__main__":
    if main():
        # The SketchUp C API has been released above. In this bundled Python runtime,
        # normal interpreter shutdown after reading an SKP raises an unrelated
        # "remaining subinterpreters" fatal error. Exit after flushing the result.
        sys.stdout.flush()
        sys.stderr.flush()
        os._exit(0)
