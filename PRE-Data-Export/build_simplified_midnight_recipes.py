from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build simplified midnight recipes JSON from deduplicated recipe and reagent exports."
    )
    parser.add_argument(
        "--recipes-input",
        default="parsed/midnight_recipes_dedup.json",
        help="Path to deduplicated recipes JSON.",
    )
    parser.add_argument(
        "--reagents-input",
        default="parsed/midnight_recipe_reagents_dedup.json",
        help="Path to deduplicated reagents JSON.",
    )
    parser.add_argument(
        "--output",
        default="parsed/midnight_recipes_simplified.json",
        help="Path to output simplified JSON.",
    )
    parser.add_argument(
        "--reagents-output",
        default="parsed/midnight_reagents_used.json",
        help="Path to output unique reagents used by simplified recipes.",
    )
    parser.add_argument(
        "--include-optional",
        action="store_true",
        default=True,
        help="Include optional reagent slots where required == false (default behavior; kept for compatibility).",
    )
    parser.add_argument(
        "--required-only",
        action="store_true",
        help="Exclude optional reagent slots and keep only required reagents.",
    )
    return parser.parse_args()


def load_json_array(path: Path) -> list[dict[str, Any]]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, list):
        raise ValueError(f"Expected JSON array in {path}")
    return [row for row in payload if isinstance(row, dict)]


def normalize_int(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, str) and value.isdigit():
        return int(value)
    return None


def normalize_name(value: Any) -> str:
    if isinstance(value, str):
        return value.strip()
    return ""


def normalize_bool(value: Any) -> bool | None:
    if isinstance(value, bool):
        return value
    return None


def build_recipe_name_map(recipes: list[dict[str, Any]]) -> dict[int, str]:
    recipe_name_map: dict[int, str] = {}
    for recipe in recipes:
        recipe_id = normalize_int(recipe.get("recipeID"))
        recipe_name = normalize_name(recipe.get("recipeName"))
        if recipe_id is None or not recipe_name:
            continue
        recipe_name_map[recipe_id] = recipe_name
    return recipe_name_map


def build_recipe_row_map(recipes: list[dict[str, Any]]) -> dict[int, dict[str, Any]]:
    recipe_row_map: dict[int, dict[str, Any]] = {}
    for recipe in recipes:
        recipe_id = normalize_int(recipe.get("recipeID"))
        if recipe_id is None:
            continue
        recipe_row_map[recipe_id] = recipe
    return recipe_row_map


def include_reagent_row(row: dict[str, Any], include_optional: bool) -> bool:
    required = row.get("required")
    if include_optional:
        return True
    if isinstance(required, bool):
        return required
    return True


def reagent_sort_key(slot_row: dict[str, Any]) -> tuple[int, int]:
    slot_index = normalize_int(slot_row.get("slotIndex"))
    data_slot_index = normalize_int(slot_row.get("dataSlotIndex"))
    return (slot_index if slot_index is not None else 10**9, data_slot_index if data_slot_index is not None else 10**9)


def build_reagent_name_by_item_id(reagents: list[dict[str, Any]]) -> dict[int, str]:
    counts: dict[int, dict[str, int]] = {}
    for row in reagents:
        reagent_item_id = normalize_int(row.get("reagentItemID"))
        reagent_item_name = normalize_name(row.get("reagentItemName"))
        if reagent_item_id is None or not reagent_item_name:
            continue

        item_counts = counts.setdefault(reagent_item_id, {})
        item_counts[reagent_item_name] = item_counts.get(reagent_item_name, 0) + 1

    result: dict[int, str] = {}
    for reagent_item_id, item_counts in counts.items():
        best_name = max(item_counts.items(), key=lambda pair: pair[1])[0]
        result[reagent_item_id] = best_name
    return result


def reagent_name_from_row(
    slot_row: dict[str, Any],
    reagent_name_by_item_id: dict[int, str],
) -> tuple[int | None, str]:
    reagent_item_id = normalize_int(slot_row.get("reagentItemID"))
    reagent_name = normalize_name(slot_row.get("slotText"))
    if not reagent_name:
        reagent_name = normalize_name(slot_row.get("reagentItemName"))
    if not reagent_name and reagent_item_id is not None:
        reagent_name = reagent_name_by_item_id.get(reagent_item_id, "")
    if not reagent_name:
        if reagent_item_id is not None:
            reagent_name = f"Unknown Reagent ID {reagent_item_id}"
        else:
            reagent_name = "Unknown Reagent"
    return reagent_item_id, reagent_name


def reagent_option_sort_key(slot_row: dict[str, Any]) -> tuple[int, int]:
    slot_key = reagent_sort_key(slot_row)
    option_index = normalize_int(slot_row.get("optionIndex"))
    option_sort = option_index if option_index is not None else 10**9
    return (slot_key[0] * 10**6 + slot_key[1], option_sort)


def normalize_salvage_targets(raw_targets: Any) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    for raw_target in raw_targets if isinstance(raw_targets, list) else []:
        if not isinstance(raw_target, dict):
            continue
        item_id = normalize_int(raw_target.get("itemID"))
        if item_id is None:
            continue
        result.append(
            {
                "itemID": item_id,
                "itemName": normalize_name(raw_target.get("itemName")),
            }
        )
    return result


def build_simplified(
    recipes: list[dict[str, Any]],
    reagents: list[dict[str, Any]],
    include_optional: bool,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    recipe_name_map = build_recipe_name_map(recipes)
    recipe_row_map = build_recipe_row_map(recipes)
    reagent_name_by_item_id = build_reagent_name_by_item_id(reagents)

    grouped_by_recipe: dict[int, list[dict[str, Any]]] = {}
    for row in reagents:
        recipe_id = normalize_int(row.get("recipeID"))
        if recipe_id is None or recipe_id not in recipe_name_map:
            continue
        if not include_reagent_row(row, include_optional):
            continue
        grouped_by_recipe.setdefault(recipe_id, []).append(row)

    simplified: list[dict[str, Any]] = []
    reagent_usage: dict[int | None, dict[str, Any]] = {}

    for recipe_id, recipe_name in recipe_name_map.items():
        recipe_row = recipe_row_map.get(recipe_id, {})
        slot_rows = grouped_by_recipe.get(recipe_id, [])
        slot_rows.sort(key=reagent_option_sort_key)

        api_affected_by_multicraft = normalize_bool(recipe_row.get("apiAffectedByMulticraft"))
        api_affected_by_resourcefulness = normalize_bool(recipe_row.get("apiAffectedByResourcefulness"))
        api_affected_by_ingenuity = normalize_bool(recipe_row.get("apiAffectedByIngenuity"))

        fallback_crafting_stats = bool(recipe_row.get("supportsCraftingStats")) and not bool(recipe_row.get("isRecraft"))
        affected_by_multicraft = (
            api_affected_by_multicraft if api_affected_by_multicraft is not None else fallback_crafting_stats
        )
        affected_by_resourcefulness = (
            api_affected_by_resourcefulness if api_affected_by_resourcefulness is not None else fallback_crafting_stats
        )
        affected_by_ingenuity = (
            api_affected_by_ingenuity if api_affected_by_ingenuity is not None else fallback_crafting_stats
        )

        reagent_list: list[dict[str, Any]] = []
        slot_map: dict[tuple[int | None, int | None], dict[str, Any]] = {}
        for slot_row in slot_rows:
            reagent_item_id, reagent_name = reagent_name_from_row(slot_row, reagent_name_by_item_id)
            quantity = normalize_int(slot_row.get("quantityRequired"))
            slot_index = normalize_int(slot_row.get("slotIndex"))
            data_slot_index = normalize_int(slot_row.get("dataSlotIndex"))
            option_index = normalize_int(slot_row.get("optionIndex"))
            reagent_type = normalize_int(slot_row.get("reagentType"))
            slot_text = normalize_name(slot_row.get("slotText"))
            required_raw = slot_row.get("required")
            required = required_raw if isinstance(required_raw, bool) else True
            quantity_value = quantity if quantity is not None else 0

            slot_key = (slot_index, data_slot_index)
            slot_entry = slot_map.get(slot_key)
            if slot_entry is None:
                slot_entry = {
                    "slotIndex": slot_index,
                    "dataSlotIndex": data_slot_index,
                    "slotText": slot_text,
                    "quantity": quantity_value,
                    "required": required,
                    "reagentType": reagent_type,
                    "options": [],
                }
                slot_map[slot_key] = slot_entry
                reagent_list.append(slot_entry)

            slot_entry["options"].append(
                {
                    "optionIndex": option_index,
                    "reagentItemID": reagent_item_id,
                    "reagentName": reagent_name,
                }
            )

            usage_row = reagent_usage.get(reagent_item_id)
            if usage_row is None:
                usage_row = {
                    "reagentItemID": reagent_item_id,
                    "reagentName": reagent_name,
                    "recipeIDs": set(),
                    "professionNames": set(),
                    "totalRequiredQuantityAcrossRecipes": 0,
                }
                reagent_usage[reagent_item_id] = usage_row

            usage_row["recipeIDs"].add(recipe_id)
            profession_name = normalize_name(recipe_row.get("professionName"))
            if profession_name:
                usage_row["professionNames"].add(profession_name)
            usage_row["totalRequiredQuantityAcrossRecipes"] += quantity_value

        simplified.append(
            {
                "recipeID": recipe_id,
                "recipeName": recipe_name,
                "professionSkillLineID": normalize_int(recipe_row.get("professionSkillLineID")),
                "professionName": normalize_name(recipe_row.get("professionName")),
                "professionExpansionName": normalize_name(recipe_row.get("professionExpansionName")),
                "recipeCategoryID": normalize_int(recipe_row.get("recipeCategoryID")),
                "categoryName": normalize_name(recipe_row.get("categoryName")),
                "topCategoryID": normalize_int(recipe_row.get("topCategoryID")),
                "topCategoryName": normalize_name(recipe_row.get("topCategoryName")),
                "outputItemID": normalize_int(recipe_row.get("outputItemID")),
                "outputQuantityMin": normalize_int(recipe_row.get("outputQuantityMin")),
                "outputQuantityMax": normalize_int(recipe_row.get("outputQuantityMax")),
                "supportsCraftingStats": bool(recipe_row.get("supportsCraftingStats")),
                "affectedByMulticraft": affected_by_multicraft,
                "affectedByResourcefulness": affected_by_resourcefulness,
                "affectedByIngenuity": affected_by_ingenuity,
                "apiBonusStats": recipe_row.get("apiBonusStats") if isinstance(recipe_row.get("apiBonusStats"), list) else [],
                "salvageTargets": normalize_salvage_targets(recipe_row.get("salvageTargets")),
                "reagents": reagent_list,
            }
        )

    simplified.sort(key=lambda row: (normalize_name(row.get("recipeName")), normalize_int(row.get("recipeID")) or 0))

    unique_reagents: list[dict[str, Any]] = []
    for usage_row in reagent_usage.values():
        recipe_ids = sorted(usage_row["recipeIDs"])
        profession_names = sorted(usage_row["professionNames"])
        unique_reagents.append(
            {
                "reagentItemID": usage_row["reagentItemID"],
                "reagentName": usage_row["reagentName"],
                "usedInRecipeCount": len(recipe_ids),
                "professionNames": profession_names,
                "totalRequiredQuantityAcrossRecipes": usage_row["totalRequiredQuantityAcrossRecipes"],
            }
        )

    unique_reagents.sort(
        key=lambda row: (
            normalize_name(row.get("reagentName")),
            normalize_int(row.get("reagentItemID")) or 0,
        )
    )

    return simplified, unique_reagents


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def main() -> None:
    args = parse_args()

    recipes_input = Path(args.recipes_input)
    reagents_input = Path(args.reagents_input)
    output_path = Path(args.output)
    reagents_output_path = Path(args.reagents_output)

    recipes = load_json_array(recipes_input)
    reagents = load_json_array(reagents_input)

    include_optional = bool(args.include_optional) and not bool(args.required_only)
    simplified, unique_reagents = build_simplified(recipes, reagents, include_optional=include_optional)
    write_json(output_path, simplified)
    write_json(reagents_output_path, unique_reagents)

    print(
        json.dumps(
            {
                "recipesInput": str(recipes_input.resolve()),
                "reagentsInput": str(reagents_input.resolve()),
                "recipesOutput": str(output_path.resolve()),
                "reagentsOutput": str(reagents_output_path.resolve()),
                "includeOptional": include_optional,
                "requiredOnly": bool(args.required_only),
                "simplifiedRecipesWritten": len(simplified),
                "uniqueReagentsWritten": len(unique_reagents),
            },
            ensure_ascii=False,
            indent=2,
        )
    )


if __name__ == "__main__":
    main()