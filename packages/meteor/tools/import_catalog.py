#!/usr/bin/env python3
"""Generate the immutable OpenComputers meteor catalogue from a GTNH config.

Only the Python standard library is used.  The source argument may be the
modpack root, its config directory, or config/BloodMagic/meteors itself.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple

BLOODMAGIC_COMMIT = "10a36f6413b8a7ce6ebf16ca8b04614ff15566cd"
OPENCOMPUTERS_COMMIT = "1e4559ff5f2443695cb28c7cdc9fba87219a862b"
DEFAULT_CATALYST = "AWWayofTime:bloodMagicBaseAlchemyItems:2"
DEFAULT_ACTIVATION_LP = 100000
REAGENT_AMOUNT = 1000

_ITEM_COMPONENT = re.compile(r"^([^:]+):(.+?):([0-9]+):([0-9]+)(?::(.*))?$")
_OREDICT_COMPONENT = re.compile(r"^OREDICT:(.+?):([0-9]+)(?::(.*))?$")


def locate_meteors(path: Path) -> Path:
    """Find the directory loaded by Blood Magic's MeteorRegistry."""
    candidates = (
        path / "config" / "BloodMagic" / "meteors",
        path / "BloodMagic" / "meteors",
        path / "meteors",
        path,
    )
    for candidate in candidates:
        if candidate.is_dir() and any(candidate.glob("*.json")):
            return candidate
    raise ValueError(
        "no meteor JSON files found; pass modpack root, config directory, "
        "or config/BloodMagic/meteors"
    )


def parse_descriptor(value: Any) -> Dict[str, Any]:
    """Parse Blood Magic's modid:name(:meta) item-stack spelling."""
    if not isinstance(value, str):
        raise ValueError("focusItem must be a string in Blood Magic's config format")
    bits = value.split(":")
    if len(bits) < 2 or not bits[0] or not bits[1]:
        raise ValueError("invalid focusItem %r" % value)
    damage = 0
    if len(bits) >= 3:
        try:
            damage = int(bits[2])
        except ValueError as exc:
            raise ValueError("invalid focusItem metadata %r" % value) from exc
    # Current GTNH 2.9 configs have no NBT spelling.  Keep the raw value and
    # explicitly mark the descriptor untagged so consumers cannot conflate it
    # with an observable tagged OpenComputers identity.
    return {
        "kind": "item",
        "name": bits[0] + ":" + bits[1],
        "damage": damage,
        "hasTag": False,
        "raw": value,
    }


def parse_component(value: Any) -> Dict[str, Any]:
    """Preserve a MeteorComponent string as an identity plus its weight."""
    if not isinstance(value, str):
        raise ValueError("meteor component must be a string")
    match = _OREDICT_COMPONENT.fullmatch(value)
    if match:
        key = "OREDICT:" + match.group(1)
        weight = int(match.group(2))
        suffix = match.group(3)
        result: Dict[str, Any] = {
            "key": key,
            "weight": weight,
            "kind": "oredict",
            "raw": value,
        }
    else:
        match = _ITEM_COMPONENT.fullmatch(value)
        if not match:
            raise ValueError("invalid meteor component %r" % value)
        key = "%s:%s:%s" % (match.group(1), match.group(2), match.group(3))
        weight = int(match.group(4))
        suffix = match.group(5)
        result = {
            "key": key,
            "weight": weight,
            "kind": "item",
            "raw": value,
        }
    if suffix is not None:
        result["required_reagents"] = [item.strip() for item in suffix.split(",") if item.strip()]
    return result


def parse_components(values: Any, field: str, filename: str) -> List[Dict[str, Any]]:
    if values is None:
        return []
    if not isinstance(values, list):
        raise ValueError("%s in %s must be an array" % (field, filename))
    return [parse_component(value) for value in values]


def ore_miner_annotation(components: List[Dict[str, Any]]) -> Dict[str, Any]:
    """Flag outputs that are not canonical OREDICT:ore* candidates.

    This is deliberately conservative: the importer has no runtime Forge or
    GregTech registry, so a direct block that happens to be an ore is still
    unverified.  The full component list remains available to callers.
    """
    noncanonical = [
        component["key"]
        for component in components
        if component["kind"] != "oredict" or not component["key"][8:].startswith("ore")
    ]
    return {
        "safe_candidate": not noncanonical,
        "noncanonical_keys": noncanonical,
        "reason": "only OREDICT:ore* sources are candidates; direct blocks and other dictionary names require manual review",
    }


def read_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as stream:
        return json.load(stream)


def build_reagents(directory: Path) -> Dict[str, Any]:
    reagent_dir = directory / "reagents"
    result: Dict[str, Any] = {}
    if not reagent_dir.is_dir():
        return result
    for path in sorted(reagent_dir.glob("*.json"), key=lambda item: item.name):
        raw = read_json(path)
        if not isinstance(raw, dict):
            raise ValueError("reagent %s must contain an object" % path.name)
        effect: Dict[str, Any] = {}
        for key, value in raw.items():
            if key == "filler":
                effect[key] = parse_components(value, key, path.name)
            else:
                effect[key] = value
        effect["raw"] = raw
        result[path.stem] = effect
    return result


def build_catalog(directory: Path, revision: Optional[str]) -> Dict[str, Any]:
    meteor_paths = sorted(directory.glob("*.json"), key=lambda item: item.name)
    if not meteor_paths:
        raise ValueError("no top-level meteor JSON files found in %s" % directory)
    recipes: List[Dict[str, Any]] = []
    for path in meteor_paths:
        raw = read_json(path)
        if not isinstance(raw, dict):
            raise ValueError("meteor %s must contain an object" % path.name)
        if "focusItem" not in raw:
            raise ValueError("meteor %s has no focusItem" % path.name)
        if "ores" not in raw:
            raise ValueError("meteor %s has no ores" % path.name)
        focus = parse_descriptor(raw["focusItem"])
        ores = parse_components(raw["ores"], "ores", path.name)
        recipe: Dict[str, Any] = {
            "id": path.stem,
            "label": path.stem,
            "focus": focus,
            "catalyst": parse_descriptor(DEFAULT_CATALYST),
            "catalyst_quantity": 1,
            "lp": int(raw.get("cost", 1000000)),
            "radius": raw.get("radius", 1),
            "ores": ores,
            "ore_miner": ore_miner_annotation(ores),
            "filler": parse_components(raw.get("filler"), "filler", path.name),
            "filler_chance": raw.get("fillerChance", 0),
            "reserve_lp": DEFAULT_ACTIVATION_LP + int(raw.get("cost", 1000000)),
            "reagent_amount": REAGENT_AMOUNT,
            "raw": raw,
        }
        recipes.append(recipe)
    return {
        "activationLP": DEFAULT_ACTIVATION_LP,
        "source": {
            "format": "BloodMagic meteor config",
            "config_directory": "config/BloodMagic/meteors",
            "modpack_revision": revision,
            "bloodmagic_commit": BLOODMAGIC_COMMIT,
            "opencomputers_commit": OPENCOMPUTERS_COMMIT,
            "meteor_count": len(recipes),
            "reagent_amount": REAGENT_AMOUNT,
            "activation_lp": DEFAULT_ACTIVATION_LP,
            "activationLP": DEFAULT_ACTIVATION_LP,
            "activation_lp_config": "lpCosts.Mark of the Falling Tower[0]",
            "default_catalyst_id": DEFAULT_CATALYST,
            "default_catalyst": parse_descriptor(DEFAULT_CATALYST),
            "reagent_effects": {
                "radius_formula": "max(1, radius + largest_positive_radius_change + largest_negative_radius_change)",
                "filler_formula": "100 * (chance + change) / (100 + change), with raw changes applied first",
                "selection": "largest positive and largest negative changes are selected independently; positive branch wins when both exist",
                "reagent_amount_per_effect": REAGENT_AMOUNT,
                "defaults": build_reagents(directory),
            },
        },
        "recipes": recipes,
    }


def lua_string(value: str) -> str:
    # JSON string escaping is accepted by Lua for the generated ASCII strings.
    return json.dumps(value, ensure_ascii=True, separators=(",", ":"))


def lua_literal(value: Any, indent: int = 0) -> str:
    """Encode JSON-shaped values as deterministic Lua literals."""
    if value is None:
        return "nil"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, str):
        return lua_string(value)
    if isinstance(value, (int, float)):
        if isinstance(value, float):
            if value != value or value in (float("inf"), float("-inf")):
                raise ValueError("non-finite JSON number")
            if value.is_integer():
                return str(int(value))
        return repr(value)
    if isinstance(value, list):
        if not value:
            return "{}"
        pad = " " * (indent + 2)
        close = " " * indent
        return "{\n" + ",\n".join(pad + lua_literal(item, indent + 2) for item in value) + "\n" + close + "}"
    if isinstance(value, dict):
        if not value:
            return "{}"
        pad = " " * (indent + 2)
        close = " " * indent
        fields = []
        for key in sorted(value):
            item = value[key]
            # nil dictionary values cannot be represented by Lua tables.  The
            # optional revision is omitted rather than emitting a misleading
            # null field.
            if item is None:
                continue
            fields.append(pad + "[" + lua_string(str(key)) + "] = " + lua_literal(item, indent + 2))
        if not fields:
            return "{}"
        return "{\n" + ",\n".join(fields) + "\n" + close + "}"
    raise TypeError("unsupported value %r" % (value,))


HEADER = """-- GENERATED FILE: do not edit by hand.
-- Regenerate with tools/import_catalog.py <modpack-or-config-path> --revision <commit>.
local data = %s

-- Proxies make every nested table read-only while retaining ipairs/#/pairs access.
local function immutable(value, seen)
  if type(value) ~= \"table\" then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local storage = {}
  local proxy = {}
  seen[value] = proxy
  for key, item in pairs(value) do
    storage[immutable(key, seen)] = immutable(item, seen)
  end
  setmetatable(proxy, {
    __index = storage,
    __newindex = function() error(\"meteor.catalog is immutable\", 2) end,
    __pairs = function() return next, storage, nil end,
    __ipairs = function()
      local index = 0
      return function()
        index = index + 1
        local item = storage[index]
        if item ~= nil then return index, item end
      end
    end,
    __len = function() return #storage end,
    __metatable = \"immutable\",
  })
  return proxy
end

return immutable(data)
"""


def main(argv: Optional[Iterable[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config_path", type=Path)
    parser.add_argument("--revision", help="pinned GTNH/modpack commit (optional)")
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "lib" / "meteor" / "catalog.lua",
        help="generated Lua destination (default: package catalogue)",
    )
    args = parser.parse_args(argv)
    try:
        directory = locate_meteors(args.config_path.resolve())
        catalog = build_catalog(directory, args.revision)
        output = HEADER % lua_literal(catalog)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(output, encoding="utf-8")
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        parser.error(str(exc))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
