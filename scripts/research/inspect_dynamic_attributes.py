"""Read Dynamic Component dictionaries from SKP files without mutating them.

Enumerates existing dictionaries through the SketchUp C API. It deliberately
avoids SUEntityGetAttributeDictionary, whose documented behavior can create a
missing dictionary. Raw output is intended for ignored local research folders.
"""

from __future__ import annotations

import argparse
import ctypes as C
import hashlib
import json
import os
import sys
import zlib
from collections import Counter
from pathlib import Path

from hardware_codec import REF, SIZE_T, SketchUpReader


TYPE_NAMES = ("empty", "byte", "short", "int32", "float", "double", "bool",
              "color", "time", "string", "vector3d", "array")


class DynamicReader(SketchUpReader):
    def __init__(self, dll_path: Path):
        super().__init__(dll_path)
        self._bind("SUStringCreate", C.c_int, C.POINTER(REF))
        self._bind("SUStringRelease", C.c_int, C.POINTER(REF))
        self._bind("SUStringGetUTF8Length", C.c_int, REF, C.POINTER(SIZE_T))
        self._bind("SUStringGetUTF8", C.c_int, REF, SIZE_T, C.c_void_p,
                   C.POINTER(SIZE_T))
        self._bind("SUEntityGetNumAttributeDictionaries", C.c_int, REF,
                   C.POINTER(SIZE_T))
        self._bind("SUEntityGetAttributeDictionaries", C.c_int, REF, SIZE_T,
                   C.POINTER(REF), C.POINTER(SIZE_T))
        self._bind("SUAttributeDictionaryGetName", C.c_int, REF, C.POINTER(REF))
        self._bind("SUAttributeDictionaryGetNumKeys", C.c_int, REF,
                   C.POINTER(SIZE_T))
        self._bind("SUAttributeDictionaryGetKeys", C.c_int, REF, SIZE_T,
                   C.POINTER(REF), C.POINTER(SIZE_T))
        self._bind("SUAttributeDictionaryGetValue", C.c_int, REF, C.c_char_p,
                   C.POINTER(REF))
        self._bind("SUTypedValueCreate", C.c_int, C.POINTER(REF))
        self._bind("SUTypedValueRelease", C.c_int, C.POINTER(REF))
        self._bind("SUTypedValueGetType", C.c_int, REF, C.POINTER(C.c_int))
        self._bind("SUTypedValueGetString", C.c_int, REF, C.POINTER(REF))
        for kind, ctype in (("Byte", C.c_uint8), ("Int16", C.c_int16),
                            ("Int32", C.c_int32), ("Float", C.c_float),
                            ("Double", C.c_double), ("Bool", C.c_bool),
                            ("Time", C.c_int64)):
            self._bind(f"SUTypedValueGet{kind}", C.c_int, REF,
                       C.POINTER(ctype))
        self._bind("SUTypedValueGetVector3d", C.c_int, REF,
                   C.POINTER(C.c_double))
        self._bind("SUTypedValueGetNumArrayItems", C.c_int, REF,
                   C.POINTER(SIZE_T))
        self._bind("SUTypedValueGetArrayItems", C.c_int, REF, SIZE_T,
                   C.POINTER(REF), C.POINTER(SIZE_T))
        for kind in ("Group", "ComponentInstance", "ComponentDefinition"):
            self._bind(f"SU{kind}ToEntity", REF, REF)
            self._bind(f"SU{kind}GetName", C.c_int, REF, C.POINTER(REF))
        self._bind("SUGroupGetDefinition", C.c_int, REF, C.POINTER(REF))
        self.dictionary_names = Counter()

    def _text(self, string: REF) -> str:
        length = SIZE_T()
        self._call("SUStringGetUTF8Length", string, C.byref(length))
        buffer = C.create_string_buffer(length.value + 1)
        copied = SIZE_T()
        self._call("SUStringGetUTF8", string, len(buffer), buffer, C.byref(copied))
        return buffer.value.decode("utf-8")

    def _name(self, function: str, ref: REF) -> str:
        string = REF()
        self._call("SUStringCreate", C.byref(string))
        try:
            self._call(function, ref, C.byref(string))
            return self._text(string)
        finally:
            self._call("SUStringRelease", C.byref(string))

    def _typed(self, typed: REF, depth: int = 0) -> dict:
        code = C.c_int()
        self._call("SUTypedValueGetType", typed, C.byref(code))
        name = TYPE_NAMES[code.value] if 0 <= code.value < len(TYPE_NAMES) else f"unknown_{code.value}"
        if name == "string":
            value = self._name("SUTypedValueGetString", typed)
        elif name in ("byte", "short", "int32", "float", "double", "bool", "time"):
            suffix, kind = {
                "byte": ("Byte", C.c_uint8),
                "short": ("Int16", C.c_int16),
                "int32": ("Int32", C.c_int32),
                "float": ("Float", C.c_float),
                "double": ("Double", C.c_double),
                "bool": ("Bool", C.c_bool),
                "time": ("Time", C.c_int64),
            }[name]
            result = kind()
            self._call(f"SUTypedValueGet{suffix}", typed, C.byref(result))
            value = result.value
        elif name == "vector3d":
            result = (C.c_double * 3)()
            self._call("SUTypedValueGetVector3d", typed, result)
            value = list(result)
        elif name == "array":
            if depth >= 4:
                raise ValueError("Nested typed-value array exceeds depth 4")
            count = SIZE_T()
            self._call("SUTypedValueGetNumArrayItems", typed, C.byref(count))
            items = (REF * count.value)()
            got = SIZE_T()
            if count.value:
                self._call("SUTypedValueGetArrayItems", typed, count, items,
                           C.byref(got))
            value = [self._typed(item, depth + 1) for item in items[:got.value]]
        elif name == "empty":
            value = None
        else:
            raise NotImplementedError(f"Unsupported typed-value type: {name}")
        return {"type": name, "value": value}

    def _dictionary(self, dictionary: REF) -> dict:
        count = SIZE_T()
        self._call("SUAttributeDictionaryGetNumKeys", dictionary, C.byref(count))
        if not count.value:
            return {}
        keys = (REF * count.value)()
        for i in range(count.value):
            pointer = C.cast(C.byref(keys, i * C.sizeof(REF)), C.POINTER(REF))
            self._call("SUStringCreate", pointer)
        try:
            got = SIZE_T()
            self._call("SUAttributeDictionaryGetKeys", dictionary, count,
                       keys, C.byref(got))
            if got.value != count.value:
                raise RuntimeError("Dictionary key count changed during read")
            result = {}
            for string in keys:
                key = self._text(string)
                typed = REF()
                self._call("SUTypedValueCreate", C.byref(typed))
                try:
                    status = self.dll.SUAttributeDictionaryGetValue(
                        dictionary, key.encode("utf-8"), C.byref(typed))
                    if status == 9:  # SU_ERROR_NO_DATA: key with no stored value.
                        result[key] = {"type": "missing", "value": None}
                    elif status == 0:
                        result[key] = self._typed(typed)
                    else:
                        raise RuntimeError(f"SUAttributeDictionaryGetValue({key}) "
                                           f"failed with SUResult={status}")
                finally:
                    self._call("SUTypedValueRelease", C.byref(typed))
            return result
        finally:
            for string in keys:
                self._call("SUStringRelease", C.byref(REF(string)))

    def _attributes(self, entity: REF) -> dict:
        count = SIZE_T()
        self._call("SUEntityGetNumAttributeDictionaries", entity, C.byref(count))
        if not count.value:
            return {}
        dictionaries = (REF * count.value)()
        got = SIZE_T()
        self._call("SUEntityGetAttributeDictionaries", entity, count,
                   dictionaries, C.byref(got))
        result = {}
        for dictionary in dictionaries[:got.value]:
            name = self._name("SUAttributeDictionaryGetName", dictionary)
            self.dictionary_names[name] += 1
            if name in ("dynamic_attributes", "dc_change_mat"):
                result[name] = self._dictionary(dictionary)
            else:
                result[name] = None
        return result

    def inspect(self, path: Path) -> dict:
        model = REF()
        self._call("SUModelCreateFromFile", C.byref(model),
                   str(path).encode("utf-8"))
        visited_definitions: set[int] = set()
        visited_entities: set[int] = set()
        records = []

        def record(kind: str, ref: REF, location: str):
            entity = getattr(self.dll, f"SU{kind}ToEntity")(ref)
            attrs = self._attributes(entity)
            if attrs:
                records.append({"kind": kind, "path": location,
                                "name": self._name(f"SU{kind}GetName", ref),
                                "dictionaries": attrs})

        def scan(entities: REF, location: str):
            if entities.value in visited_entities:
                return
            visited_entities.add(entities.value)
            for i, group in enumerate(self._refs(entities, "Groups")):
                child_location = f"{location}/group[{i}]"
                record("Group", group, child_location)
                definition = REF()
                self._call("SUGroupGetDefinition", group, C.byref(definition))
                if definition.value not in visited_definitions:
                    visited_definitions.add(definition.value)
                    record("ComponentDefinition", definition,
                           child_location + "/definition")
                nested = REF()
                self._call("SUGroupGetEntities", group, C.byref(nested))
                scan(nested, child_location)
            for i, instance in enumerate(self._refs(entities, "Instances")):
                child_location = f"{location}/instance[{i}]"
                record("ComponentInstance", instance, child_location)
                definition = REF()
                self._call("SUComponentInstanceGetDefinition", instance,
                           C.byref(definition))
                if definition.value not in visited_definitions:
                    visited_definitions.add(definition.value)
                    record("ComponentDefinition", definition,
                           child_location + "/definition")
                    nested = REF()
                    self._call("SUComponentDefinitionGetEntities", definition,
                               C.byref(nested))
                    scan(nested, child_location + "/definition")

        try:
            entities = REF()
            self._call("SUModelGetEntities", model, C.byref(entities))
            scan(entities, "model")
            return {"file": path.name, "records": records,
                    "definitions_scanned": len(visited_definitions)}
        finally:
            self._call("SUModelRelease", C.byref(model))


def summarize(models: list[dict]) -> dict:
    keys = Counter()
    types = Counter()
    values = Counter()
    formulas = Counter()
    onclick = Counter()
    formula_locations = Counter()
    parent_formulas = 0
    main_menu_formulas = 0
    material_markers = 0
    unique_payloads = {}
    payload_links = []
    inline_payloads = []
    instance_records = 0
    definition_records = 0
    group_records = 0
    attribute_count = 0
    for model in models:
        for record in model["records"]:
            attrs = record["dictionaries"].get("dynamic_attributes")
            if attrs is None:
                continue
            canonical = json.dumps(attrs, ensure_ascii=False, sort_keys=True,
                                   separators=(",", ":")).encode("utf-8")
            digest = hashlib.sha256(canonical).hexdigest()
            unique_payloads[digest] = attrs
            payload_links.append([model["file"], record["path"], digest])
            inline_payloads.append([model["file"], record["path"], attrs])
            if record["kind"] == "ComponentInstance":
                instance_records += 1
            if record["kind"] == "ComponentDefinition":
                definition_records += 1
            if record["kind"] == "Group":
                group_records += 1
            if record["dictionaries"].get("dc_change_mat"):
                material_markers += 1
            for key, typed in attrs.items():
                attribute_count += 1
                keys[key] += 1
                types[typed["type"]] += 1
                value = typed["value"]
                if isinstance(value, (str, int, float, bool)):
                    values[(key, str(value))] += 1
                if key.startswith("_") and key.endswith("_formula") and isinstance(value, str):
                    formulas[value] += 1
                    formula_locations[record["kind"]] += 1
                    parent_formulas += "parent!" in value.lower()
                    main_menu_formulas += "main_menu!" in value.lower()
                if key == "onclick" and isinstance(value, str):
                    onclick[value] += 1
    # This estimates dictionary storage only. It does not include SketchUp
    # materials, textures, geometry, or a Dynamic Components evaluator.
    deduplicated = json.dumps({"payloads": unique_payloads, "links": payload_links},
                              ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    inline = json.dumps(inline_payloads, ensure_ascii=False,
                        separators=(",", ":")).encode("utf-8")
    return {"files": len(models), "records": sum(len(m["records"]) for m in models),
            "instance_dynamic_records": instance_records,
            "definition_dynamic_records": definition_records,
            "group_dynamic_records": group_records,
            "dynamic_attribute_entries": attribute_count,
            "distinct_keys": len(keys), "formula_entries": sum(formulas.values()),
            "distinct_formulas": len(formulas),
            "formula_locations": dict(formula_locations),
            "parent_formula_entries": parent_formulas,
            "main_menu_formula_entries": main_menu_formulas,
            "onclick_entries": sum(onclick.values()),
            "distinct_onclick": len(onclick),
            "onclick_values": onclick.most_common(),
            "dc_change_mat_marked_records": material_markers,
            "unique_dynamic_payloads": len(unique_payloads),
            "inline_payload_json_bytes": len(inline),
            "inline_payload_zlib_bytes": len(zlib.compress(inline, 9)),
            "deduplicated_payload_json_bytes": len(deduplicated),
            "deduplicated_payload_zlib_bytes": len(zlib.compress(deduplicated, 9)),
            "types": dict(types), "top_keys": keys.most_common(40),
            "top_formulas": formulas.most_common(15),
            "top_key_values": [[key, value, count]
                               for (key, value), count in values.most_common(20)]}


def main() -> bool:
    sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dll", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("inputs", nargs="+", type=Path)
    args = parser.parse_args()
    protected = {path.resolve() for path in args.inputs}
    if args.output.resolve() in protected:
        parser.error("--output must not overwrite an input")
    if any(not path.is_file() or path.suffix.lower() != ".skp"
           for path in args.inputs):
        parser.error("Every input must be an existing SKP file")
    reader = DynamicReader(args.dll)
    try:
        models = [reader.inspect(path) for path in args.inputs]
        summary = summarize(models)
        result = {"summary": summary, "dictionary_names":
                  dict(reader.dictionary_names), "models": models}
        raw = json.dumps(result, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        summary["json_bytes"] = len(raw)
        summary["zlib_bytes"] = len(zlib.compress(raw, 9))
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2),
                               encoding="utf-8")
        print(json.dumps({key: value for key, value in summary.items()
                          if key not in ("top_keys", "top_formulas", "top_key_values",
                                         "onclick_values")},
                         ensure_ascii=False, indent=2))
    finally:
        reader.close()
    return True


if __name__ == "__main__":
    if main():
        # See hardware_codec.py: the bundled Python runtime needs a direct
        # process exit after releasing SketchUp C API objects.
        sys.stdout.flush()
        sys.stderr.flush()
        os._exit(0)
