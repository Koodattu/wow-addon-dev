from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

import luadata


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Extract salvage recipes and probe results from ProfessionRecipeExporter Lua exports.")
    parser.add_argument("--input", default="ProfessionRecipeExporter-Salvage.lua", help="Path to Lua SavedVariables export.")
    parser.add_argument("--out-dir", default="parsed", help="Output directory for JSON files.")
    parser.add_argument(
        "--export-id",
        type=int,
        default=None,
        help="Export ID to read from ProfessionRecipeExporterDB.exports. Defaults to latest available.",
    )
    return parser.parse_args()


def load_saved_variables(path: Path) -> dict[str, Any]:
    text = path.read_text(encoding="utf-8")
    first_brace = text.find("{")
    if first_brace < 0:
        raise ValueError("No Lua table found in input file")
    payload = text[first_brace:]
    data = luadata.unserialize(payload)
    if not isinstance(data, dict):
        raise ValueError("Root payload is not a dictionary")
    return data


def listify(value: Any) -> list[Any]:
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        numeric: list[tuple[int, Any]] = []
        for key, item in value.items():
            if isinstance(key, int):
                numeric.append((key, item))
            elif isinstance(key, str) and key.isdigit():
                numeric.append((int(key), item))
        if numeric:
            return [item for _, item in sorted(numeric, key=lambda pair: pair[0])]
        return list(value.values())
    return []


def normalize_int(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, str) and value.isdigit():
        return int(value)
    return None


def normalize_name(value: Any) -> str | None:
    if isinstance(value, str):
        stripped = value.strip()
        if stripped:
            return stripped
    return None


def get_exports_from_field(db: dict[str, Any], field_name: str) -> dict[int, dict[str, Any]]:
    exports_raw = db.get(field_name)
    exports: dict[int, dict[str, Any]] = {}

    if isinstance(exports_raw, dict):
        for key, value in exports_raw.items():
            export_id = normalize_int(key)
            if export_id is None and isinstance(value, dict):
                export_id = normalize_int(value.get("exportID"))
            if export_id is None or not isinstance(value, dict):
                continue
            exports[export_id] = value
        return exports

    for index, value in enumerate(listify(exports_raw), start=1):
        if not isinstance(value, dict):
            continue
        export_id = normalize_int(value.get("exportID")) or index
        exports[export_id] = value

    return exports


def get_standard_exports(db: dict[str, Any]) -> dict[int, dict[str, Any]]:
    return get_exports_from_field(db, "exports")


def get_salvage_exports(db: dict[str, Any]) -> dict[int, dict[str, Any]]:
    return get_exports_from_field(db, "salvageExports")


def recipe_looks_salvage(recipe: dict[str, Any]) -> bool:
    recipe_info = recipe.get("recipeInfo") if isinstance(recipe.get("recipeInfo"), dict) else {}
    if recipe_info.get("isSalvageRecipe") is True:
        return True
    if recipe.get("isSalvageRecipe") is True:
        return True
    if len(listify(recipe.get("inputProbes"))) > 0:
        return True
    if len(listify(recipe.get("recipeSalvageTargets"))) > 0:
        return True
    return False


def count_salvage_recipes(export_data: dict[str, Any]) -> int:
    count = 0
    professions = export_data.get("professions")
    if not isinstance(professions, dict):
        return 0

    for _, profession_data in professions.items():
        if not isinstance(profession_data, dict):
            continue
        all_recipes = listify(profession_data.get("salvageRecipes")) + listify(profession_data.get("recipes"))
        for recipe in all_recipes:
            if isinstance(recipe, dict) and recipe_looks_salvage(recipe):
                count += 1
    return count


def choose_export(
    exports: dict[int, dict[str, Any]],
    wanted_export_id: int | None,
    latest_export_hint: int | None = None,
) -> tuple[int, dict[str, Any]]:
    if not exports:
        raise ValueError("No exports found in input file")

    if wanted_export_id is not None:
        selected = exports.get(wanted_export_id)
        if selected is None:
            raise ValueError(f"Export ID {wanted_export_id} not found")
        return wanted_export_id, selected

    latest_export_id = latest_export_hint if latest_export_hint in exports else max(exports.keys())
    latest_export = exports[latest_export_id]
    if count_salvage_recipes(latest_export) > 0:
        return latest_export_id, latest_export

    for export_id in sorted(exports.keys(), reverse=True):
        export_data = exports[export_id]
        if count_salvage_recipes(export_data) > 0:
            return export_id, export_data

    return latest_export_id, latest_export


def extract_salvage(export_id: int, export_data: dict[str, Any]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    recipes_out: list[dict[str, Any]] = []
    probes_out: list[dict[str, Any]] = []

    professions = export_data.get("professions")
    if not isinstance(professions, dict):
        return recipes_out, probes_out

    for profession_key, profession_data in professions.items():
        if not isinstance(profession_data, dict):
            continue

        skill_line_id = normalize_int(profession_key) or normalize_int(profession_data.get("skillLineID"))
        profession_info = profession_data.get("professionInfo") if isinstance(profession_data.get("professionInfo"), dict) else {}
        profession_name = normalize_name(profession_info.get("professionName"))

        all_recipes = listify(profession_data.get("salvageRecipes")) + listify(profession_data.get("recipes"))
        for recipe in all_recipes:
            if not isinstance(recipe, dict):
                continue

            recipe_info = recipe.get("recipeInfo") if isinstance(recipe.get("recipeInfo"), dict) else {}
            if not recipe_looks_salvage(recipe):
                continue

            recipe_id = normalize_int(recipe.get("recipeID"))
            recipe_name = normalize_name(recipe_info.get("name"))
            category_id = normalize_int(recipe_info.get("categoryID"))
            recipe_type = recipe_info.get("recipeType")

            salvage_targets = []
            for target in listify(recipe.get("recipeSalvageTargets")):
                if not isinstance(target, dict):
                    continue
                target_item_id = normalize_int(target.get("itemID"))
                if target_item_id is None:
                    continue
                salvage_targets.append(
                    {
                        "itemID": target_item_id,
                        "itemName": normalize_name(target.get("itemName")),
                    }
                )

            recipe_row = {
                "exportID": export_id,
                "professionSkillLineID": skill_line_id,
                "professionName": profession_name,
                "recipeID": recipe_id,
                "recipeName": recipe_name,
                "categoryID": category_id,
                "recipeType": recipe_type,
                "salvageTargets": salvage_targets,
                "inputProbeCount": len(listify(recipe.get("inputProbes"))),
            }
            recipes_out.append(recipe_row)

            for probe in listify(recipe.get("inputProbes")):
                if not isinstance(probe, dict):
                    continue

                probes_out.append(
                    {
                        "exportID": export_id,
                        "professionSkillLineID": skill_line_id,
                        "professionName": profession_name,
                        "recipeID": recipe_id,
                        "recipeName": recipe_name,
                        "inputItemID": normalize_int(probe.get("itemID")),
                        "inputItemName": normalize_name(probe.get("itemName")),
                        "ownedCount": normalize_int(probe.get("ownedCount")),
                        "hasAllocationItem": probe.get("hasAllocationItem") is True,
                        "allocationItemGUID": normalize_name(probe.get("allocationItemGUID")),
                        "bagIndex": normalize_int(probe.get("bagIndex")),
                        "slotIndex": normalize_int(probe.get("slotIndex")),
                        "outputNoAllocation": probe.get("outputNoAllocation"),
                        "outputWithAllocation": probe.get("outputWithAllocation"),
                        "outputWithAllocationNoReagents": probe.get("outputWithAllocationNoReagents"),
                    }
                )

    recipes_out.sort(key=lambda row: (row.get("professionSkillLineID") or 0, row.get("recipeID") or 0))
    probes_out.sort(
        key=lambda row: (
            row.get("professionSkillLineID") or 0,
            row.get("recipeID") or 0,
            row.get("inputItemID") or 0,
        )
    )

    return recipes_out, probes_out


def build_input_output_mapping(probes_out: list[dict[str, Any]]) -> list[dict[str, Any]]:
    grouped: dict[tuple[int, int], dict[str, Any]] = {}

    for row in probes_out:
        recipe_id = normalize_int(row.get("recipeID"))
        input_item_id = normalize_int(row.get("inputItemID"))
        if recipe_id is None or input_item_id is None:
            continue

        output = row.get("outputWithAllocation") or row.get("outputNoAllocation") or row.get("outputWithAllocationNoReagents") or {}
        output_item_id = normalize_int(output.get("itemID")) if isinstance(output, dict) else None
        output_item_name = normalize_name(output.get("itemName")) if isinstance(output, dict) else None

        key = (recipe_id, input_item_id)
        current = grouped.get(key)
        if current is None:
            grouped[key] = {
                "exportID": row.get("exportID"),
                "professionSkillLineID": row.get("professionSkillLineID"),
                "professionName": row.get("professionName"),
                "recipeID": recipe_id,
                "recipeName": row.get("recipeName"),
                "inputItemID": input_item_id,
                "inputItemName": row.get("inputItemName"),
                "observedOutputItemIDs": [output_item_id] if output_item_id is not None else [],
                "observedOutputItemNames": [output_item_name] if output_item_name else [],
            }
        else:
            if output_item_id is not None and output_item_id not in current["observedOutputItemIDs"]:
                current["observedOutputItemIDs"].append(output_item_id)
            if output_item_name and output_item_name not in current["observedOutputItemNames"]:
                current["observedOutputItemNames"].append(output_item_name)

    result = list(grouped.values())
    result.sort(key=lambda row: (row.get("professionSkillLineID") or 0, row.get("recipeID") or 0, row.get("inputItemID") or 0))
    return result


def main() -> None:
    args = parse_args()
    input_path = Path(args.input)
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    db = load_saved_variables(input_path)
    salvage_exports = get_salvage_exports(db)
    standard_exports = get_standard_exports(db)

    if salvage_exports:
        latest_hint = normalize_int(db.get("latestSalvageExportID"))
        export_id, export_data = choose_export(salvage_exports, args.export_id, latest_hint)
    else:
        latest_hint = normalize_int(db.get("latestExportID"))
        export_id, export_data = choose_export(standard_exports, args.export_id, latest_hint)

    recipes_out, probes_out = extract_salvage(export_id, export_data)
    mapping_out = build_input_output_mapping(probes_out)

    summary = {
        "exportID": export_id,
        "completedAtISO8601": export_data.get("completedAtISO8601"),
        "startedAtISO8601": export_data.get("startedAtISO8601"),
        "salvageRecipeCount": len(recipes_out),
        "inputProbeCount": len(probes_out),
        "outputFiles": {
            "salvageRecipes": "salvage_recipes_only.json",
            "salvageInputResults": "salvage_input_results.json",
            "salvageInputOutputMap": "salvage_input_output_map.json",
        },
    }

    (out_dir / "salvage_recipes_only.json").write_text(json.dumps(recipes_out, ensure_ascii=False, indent=2), encoding="utf-8")
    (out_dir / "salvage_input_results.json").write_text(json.dumps(probes_out, ensure_ascii=False, indent=2), encoding="utf-8")
    (out_dir / "salvage_input_output_map.json").write_text(json.dumps(mapping_out, ensure_ascii=False, indent=2), encoding="utf-8")
    (out_dir / "salvage_summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")

    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
