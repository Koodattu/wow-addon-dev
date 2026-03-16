from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

import luadata


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", default="ProfessionRecipeExporter.lua")
    parser.add_argument("--out-dir", default="parsed")
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
        numeric = []
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


def normalize_bool(value: Any) -> bool | None:
    if isinstance(value, bool):
        return value
    return None


def build_reagent_candidates(raw_reagents: list[Any], fallback_reagents: list[Any]) -> list[dict[str, Any]]:
    if not raw_reagents and not fallback_reagents:
        return []

    fallback_name_by_item_id: dict[int, str] = {}
    for fallback in fallback_reagents:
        if not isinstance(fallback, dict):
            continue
        fallback_item_id = normalize_int(fallback.get("itemID"))
        fallback_item_name = normalize_name(fallback.get("itemName"))
        if fallback_item_id is None or fallback_item_name is None:
            continue
        fallback_name_by_item_id[fallback_item_id] = fallback_item_name

    reagent_candidates: list[dict[str, Any]] = []
    max_len = max(len(raw_reagents), len(fallback_reagents))
    for index in range(max_len):
        raw_reagent = raw_reagents[index] if index < len(raw_reagents) and isinstance(raw_reagents[index], dict) else {}
        fallback_reagent = (
            fallback_reagents[index] if index < len(fallback_reagents) and isinstance(fallback_reagents[index], dict) else {}
        )

        item_id = normalize_int(raw_reagent.get("itemID"))
        if item_id is None:
            item_id = normalize_int(fallback_reagent.get("itemID"))

        item_name = normalize_name(raw_reagent.get("itemName"))
        if item_name is None:
            item_name = normalize_name(fallback_reagent.get("itemName"))
        if item_name is None and item_id is not None:
            item_name = fallback_name_by_item_id.get(item_id)

        reagent_candidates.append(
            {
                "itemID": item_id,
                "itemName": item_name,
            }
        )

    return reagent_candidates


def normalize_salvage_targets(raw_targets: Any) -> list[dict[str, Any]]:
    targets: list[dict[str, Any]] = []
    for raw_target in listify(raw_targets):
        if not isinstance(raw_target, dict):
            continue
        item_id = normalize_int(raw_target.get("itemID"))
        item_name = normalize_name(raw_target.get("itemName"))
        if item_id is None:
            continue
        targets.append(
            {
                "itemID": item_id,
                "itemName": item_name,
            }
        )
    return targets


def profession_expansion_name(profession_data: dict[str, Any]) -> str:
    profession_info = profession_data.get("professionInfo")
    if isinstance(profession_info, dict):
        value = profession_info.get("expansionName")
        if isinstance(value, str):
            return value
    return ""


def profession_name(profession_data: dict[str, Any]) -> str:
    profession_info = profession_data.get("professionInfo")
    if isinstance(profession_info, dict):
        value = profession_info.get("professionName")
        if isinstance(value, str):
            return value
    return ""


def build_category_map(categories: list[Any]) -> dict[int, dict[str, Any]]:
    category_map: dict[int, dict[str, Any]] = {}
    for category in categories:
        if not isinstance(category, dict):
            continue
        category_id = normalize_int(category.get("categoryID"))
        info = category.get("info") if isinstance(category.get("info"), dict) else {}
        category_name = info.get("name") if isinstance(info.get("name"), str) else None
        if category_id is not None:
            category_map[category_id] = {
                "categoryID": category_id,
                "name": category_name,
                "parentCategoryID": normalize_int(info.get("parentCategoryID")),
                "topCategoryID": category_id,
                "topCategoryName": category_name,
            }

        for sub in listify(category.get("subcategories")):
            if not isinstance(sub, dict):
                continue
            sub_id = normalize_int(sub.get("subCategoryID"))
            sub_info = sub.get("info") if isinstance(sub.get("info"), dict) else {}
            sub_name = sub_info.get("name") if isinstance(sub_info.get("name"), str) else None
            if sub_id is None:
                continue
            category_map[sub_id] = {
                "categoryID": sub_id,
                "name": sub_name,
                "parentCategoryID": normalize_int(sub_info.get("parentCategoryID")),
                "topCategoryID": category_id,
                "topCategoryName": category_name,
            }
    return category_map


def is_strict_midnight_recipe(recipe: dict[str, Any]) -> bool:
    expansion_name = recipe.get("professionExpansionName")
    if not (isinstance(expansion_name, str) and expansion_name.strip().lower() == "midnight"):
        return False

    profession_skill_line_id = normalize_int(recipe.get("professionSkillLineID"))
    trade_skill_line_id = normalize_int(recipe.get("tradeSkillLineID"))
    if profession_skill_line_id is None or trade_skill_line_id is None:
        return False
    if profession_skill_line_id != trade_skill_line_id:
        return False

    trade_skill_line_name = recipe.get("tradeSkillLineName")
    if not (isinstance(trade_skill_line_name, str) and "midnight" in trade_skill_line_name.lower()):
        return False

    top_category_name = recipe.get("topCategoryName")
    if not (isinstance(top_category_name, str) and "midnight" in top_category_name.lower()):
        return False

    return True


def is_excluded_strict_midnight_recipe(recipe: dict[str, Any]) -> bool:
    category_name = recipe.get("categoryName")
    if isinstance(category_name, str) and category_name.strip().lower().startswith("appendix"):
        return True

    recipe_name = recipe.get("recipeName")
    if isinstance(recipe_name, str) and recipe_name.strip().lower() == "recraft equipment":
        return True

    return False


def strip_export_fields(record: dict[str, Any]) -> dict[str, Any]:
    result = dict(record)
    result.pop("exportID", None)
    return result


def flatten_exports(data: dict[str, Any]) -> tuple[list[dict[str, Any]], list[dict[str, Any]], dict[str, Any]]:
    exports_value = data.get("exports")
    exports = listify(exports_value)

    recipes_by_key: dict[tuple[int | None, int | None], dict[str, Any]] = {}
    reagents_by_key: dict[tuple[Any, ...], dict[str, Any]] = {}

    total_professions_seen = 0
    total_recipes_seen = 0

    for export in exports:
        if not isinstance(export, dict):
            continue

        export_id = normalize_int(export.get("exportID"))
        completed_at = export.get("completedAtISO8601") if isinstance(export.get("completedAtISO8601"), str) else None
        professions = export.get("professions")
        if not isinstance(professions, dict):
            continue

        for profession_skill_line_key, profession_data in professions.items():
            if not isinstance(profession_data, dict):
                continue

            total_professions_seen += 1
            profession_skill_line_id = normalize_int(profession_skill_line_key)
            if profession_skill_line_id is None:
                profession_skill_line_id = normalize_int(profession_data.get("skillLineID"))

            expansion_name = profession_expansion_name(profession_data)
            prof_name = profession_name(profession_data)
            categories = listify(profession_data.get("categories"))
            category_map = build_category_map(categories)

            for recipe in listify(profession_data.get("recipes")):
                if not isinstance(recipe, dict):
                    continue

                total_recipes_seen += 1
                recipe_id = normalize_int(recipe.get("recipeID"))
                recipe_info = recipe.get("recipeInfo") if isinstance(recipe.get("recipeInfo"), dict) else {}
                recipe_schematic = recipe.get("recipeSchematic") if isinstance(recipe.get("recipeSchematic"), dict) else {}
                recipe_output = recipe.get("recipeOutput") if isinstance(recipe.get("recipeOutput"), dict) else {}
                trade_skill_line = recipe.get("recipeTradeSkillLine") if isinstance(recipe.get("recipeTradeSkillLine"), dict) else {}
                recipe_crafting_stats = (
                    recipe.get("recipeCraftingStats") if isinstance(recipe.get("recipeCraftingStats"), dict) else {}
                )
                recipe_salvage_targets = normalize_salvage_targets(recipe.get("recipeSalvageTargets"))

                category_id = normalize_int(recipe_info.get("categoryID"))
                category_details = category_map.get(category_id or -1, {})

                output_item_id = normalize_int(recipe_output.get("itemID"))
                if output_item_id is None:
                    output_item_id = normalize_int(recipe_schematic.get("outputItemID"))

                recipe_record = {
                    "exportID": export_id,
                    "completedAtISO8601": completed_at,
                    "professionSkillLineID": profession_skill_line_id,
                    "professionName": prof_name,
                    "professionExpansionName": expansion_name,
                    "recipeID": recipe_id,
                    "recipeName": recipe_info.get("name"),
                    "recipeCategoryID": category_id,
                    "categoryName": category_details.get("name"),
                    "topCategoryID": category_details.get("topCategoryID"),
                    "topCategoryName": category_details.get("topCategoryName"),
                    "tradeSkillLineID": normalize_int(trade_skill_line.get("tradeSkillLineID")),
                    "tradeSkillLineName": trade_skill_line.get("tradeSkillLineName"),
                    "outputItemID": output_item_id,
                    "outputQuantityMin": normalize_int(recipe_schematic.get("quantityMin")),
                    "outputQuantityMax": normalize_int(recipe_schematic.get("quantityMax")),
                    "qualityItemIDs": listify(recipe.get("qualityItemIDs")),
                    "qualityIDs": listify(recipe.get("qualityIDs")),
                    "supportsCraftingStats": bool(recipe_info.get("supportsCraftingStats")),
                    "canCreateMultiple": bool(recipe_info.get("canCreateMultiple")),
                    "isRecraft": bool(recipe_info.get("isRecraft")),
                    "isSalvageRecipe": bool(recipe_info.get("isSalvageRecipe")),
                    "craftable": bool(recipe_info.get("craftable")),
                    "apiAffectedByMulticraft": normalize_bool(recipe_crafting_stats.get("affectedByMulticraft")),
                    "apiAffectedByResourcefulness": normalize_bool(recipe_crafting_stats.get("affectedByResourcefulness")),
                    "apiAffectedByIngenuity": normalize_bool(recipe_crafting_stats.get("affectedByIngenuity")),
                    "apiBonusStats": listify(recipe_crafting_stats.get("bonusStats")),
                    "salvageTargets": recipe_salvage_targets,
                }

                recipe_key = (profession_skill_line_id, recipe_id)
                existing_recipe = recipes_by_key.get(recipe_key)
                if existing_recipe is None or (export_id or -1) >= (existing_recipe.get("exportID") or -1):
                    recipes_by_key[recipe_key] = recipe_record

                for slot in listify(recipe.get("recipeReagentSlots")):
                    if not isinstance(slot, dict):
                        continue

                    slot_index = normalize_int(slot.get("slotIndex"))
                    raw = slot.get("raw") if isinstance(slot.get("raw"), dict) else {}
                    raw_reagents = listify(raw.get("reagents"))
                    fallback_reagents = listify(slot.get("reagents"))
                    reagent_candidates = build_reagent_candidates(raw_reagents, fallback_reagents)

                    quantity_required = normalize_int(raw.get("quantityRequired"))
                    required = raw.get("required")
                    if not isinstance(required, bool):
                        required = True

                    reagent_type = normalize_int(raw.get("reagentType"))
                    data_slot_index = normalize_int(raw.get("dataSlotIndex"))
                    slot_text = None
                    slot_info = raw.get("slotInfo") if isinstance(raw.get("slotInfo"), dict) else {}
                    if isinstance(slot_info.get("slotText"), str):
                        slot_text = slot_info.get("slotText")

                    for option_index, reagent in enumerate(reagent_candidates, start=1):
                        if not isinstance(reagent, dict):
                            continue
                        reagent_item_id = normalize_int(reagent.get("itemID"))
                        reagent_item_name = reagent.get("itemName") if isinstance(reagent.get("itemName"), str) else None
                        reagent_record = {
                            "exportID": export_id,
                            "completedAtISO8601": completed_at,
                            "professionSkillLineID": profession_skill_line_id,
                            "recipeID": recipe_id,
                            "slotIndex": slot_index,
                            "dataSlotIndex": data_slot_index,
                            "slotText": slot_text,
                            "required": required,
                            "reagentType": reagent_type,
                            "quantityRequired": quantity_required,
                            "optionIndex": option_index,
                            "reagentItemID": reagent_item_id,
                            "reagentItemName": reagent_item_name,
                        }

                        reagent_key = (
                            profession_skill_line_id,
                            recipe_id,
                            slot_index,
                            data_slot_index,
                            option_index,
                            reagent_item_id,
                            required,
                            quantity_required,
                        )
                        existing_reagent = reagents_by_key.get(reagent_key)
                        if existing_reagent is None or (export_id or -1) >= (existing_reagent.get("exportID") or -1):
                            reagents_by_key[reagent_key] = reagent_record

    recipes = sorted(
        recipes_by_key.values(),
        key=lambda rec: (
            rec.get("professionExpansionName") or "",
            rec.get("professionName") or "",
            rec.get("recipeID") or 0,
        ),
    )
    reagents = sorted(
        reagents_by_key.values(),
        key=lambda rec: (
            rec.get("professionSkillLineID") or 0,
            rec.get("recipeID") or 0,
            rec.get("slotIndex") or 0,
            rec.get("optionIndex") or 0,
        ),
    )

    summary = {
        "schemaVersion": data.get("schemaVersion"),
        "runCount": data.get("runCount"),
        "latestExportID": data.get("latestExportID"),
        "exportsFound": len(exports),
        "totalProfessionSnapshotsSeen": total_professions_seen,
        "totalRecipeSnapshotsSeen": total_recipes_seen,
        "recipesDeduplicated": len(recipes),
        "reagentsDeduplicated": len(reagents),
    }
    return recipes, reagents, summary


def write_json(path: Path, payload: Any) -> None:
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def main() -> None:
    args = parse_args()
    input_path = Path(args.input)
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    data = load_saved_variables(input_path)
    recipes, reagents, summary = flatten_exports(data)

    midnight_candidates = [
        recipe
        for recipe in recipes
        if is_strict_midnight_recipe(recipe) and not is_excluded_strict_midnight_recipe(recipe)
    ]

    midnight_by_recipe_id: dict[int, dict[str, Any]] = {}
    for recipe in midnight_candidates:
        recipe_id = normalize_int(recipe.get("recipeID"))
        if recipe_id is None:
            continue

        existing = midnight_by_recipe_id.get(recipe_id)
        if existing is None:
            midnight_by_recipe_id[recipe_id] = recipe
            continue

        existing_completed = existing.get("completedAtISO8601") or ""
        current_completed = recipe.get("completedAtISO8601") or ""
        if current_completed >= existing_completed:
            midnight_by_recipe_id[recipe_id] = recipe

    midnight_recipes = sorted(
        midnight_by_recipe_id.values(),
        key=lambda rec: (
            rec.get("professionName") or "",
            rec.get("recipeID") or 0,
        ),
    )

    midnight_recipe_keys = {
        (recipe.get("professionSkillLineID"), recipe.get("recipeID")) for recipe in midnight_recipes
    }

    midnight_reagents = [
        reagent
        for reagent in reagents
        if (reagent.get("professionSkillLineID"), reagent.get("recipeID")) in midnight_recipe_keys
    ]

    midnight_recipes_output = [strip_export_fields(recipe) for recipe in midnight_recipes]
    midnight_reagents_output = [strip_export_fields(reagent) for reagent in midnight_reagents]

    write_json(out_dir / "midnight_recipes_dedup.json", midnight_recipes_output)
    write_json(out_dir / "midnight_recipe_reagents_dedup.json", midnight_reagents_output)

    print(json.dumps(
        {
            **summary,
            "midnightRecipes": len(midnight_recipes_output),
            "midnightReagents": len(midnight_reagents_output),
            "outputDir": str(out_dir.resolve()),
        },
        ensure_ascii=False,
        indent=2,
    ))


if __name__ == "__main__":
    main()