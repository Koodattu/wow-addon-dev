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
        "--include-optional",
        action="store_true",
        help="Include optional reagent slots where required == false.",
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


def build_recipe_name_map(recipes: list[dict[str, Any]]) -> dict[int, str]:
    recipe_name_map: dict[int, str] = {}
    for recipe in recipes:
        recipe_id = normalize_int(recipe.get("recipeID"))
        recipe_name = normalize_name(recipe.get("recipeName"))
        if recipe_id is None or not recipe_name:
            continue
        recipe_name_map[recipe_id] = recipe_name
    return recipe_name_map


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


def build_simplified(
    recipes: list[dict[str, Any]],
    reagents: list[dict[str, Any]],
    include_optional: bool,
) -> list[dict[str, Any]]:
    recipe_name_map = build_recipe_name_map(recipes)
    reagent_name_by_item_id = build_reagent_name_by_item_id(reagents)

    deduped_slots: dict[tuple[int, int | None, int | None], dict[str, Any]] = {}
    for row in reagents:
        recipe_id = normalize_int(row.get("recipeID"))
        if recipe_id is None or recipe_id not in recipe_name_map:
            continue
        if not include_reagent_row(row, include_optional):
            continue

        slot_index = normalize_int(row.get("slotIndex"))
        data_slot_index = normalize_int(row.get("dataSlotIndex"))
        dedupe_key = (recipe_id, slot_index, data_slot_index)

        existing = deduped_slots.get(dedupe_key)
        if existing is None:
            deduped_slots[dedupe_key] = row
            continue

        existing_option_index = normalize_int(existing.get("optionIndex"))
        current_option_index = normalize_int(row.get("optionIndex"))
        existing_sort = existing_option_index if existing_option_index is not None else 10**9
        current_sort = current_option_index if current_option_index is not None else 10**9
        if current_sort < existing_sort:
            deduped_slots[dedupe_key] = row

    grouped_by_recipe: dict[int, list[dict[str, Any]]] = {}
    for (recipe_id, _slot_index, _data_slot_index), row in deduped_slots.items():
        grouped_by_recipe.setdefault(recipe_id, []).append(row)

    simplified: list[dict[str, Any]] = []
    for recipe_id, recipe_name in recipe_name_map.items():
        slot_rows = grouped_by_recipe.get(recipe_id, [])
        slot_rows.sort(key=reagent_sort_key)

        reagent_list: list[dict[str, Any]] = []
        for slot_row in slot_rows:
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
            quantity = normalize_int(slot_row.get("quantityRequired"))
            reagent_list.append(
                {
                    "reagentName": reagent_name,
                    "quantity": quantity if quantity is not None else 0,
                }
            )

        simplified.append(
            {
                "recipeName": recipe_name,
                "reagents": reagent_list,
            }
        )

    simplified.sort(key=lambda row: row.get("recipeName", ""))
    return simplified


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def main() -> None:
    args = parse_args()

    recipes_input = Path(args.recipes_input)
    reagents_input = Path(args.reagents_input)
    output_path = Path(args.output)

    recipes = load_json_array(recipes_input)
    reagents = load_json_array(reagents_input)

    simplified = build_simplified(recipes, reagents, include_optional=bool(args.include_optional))
    write_json(output_path, simplified)

    print(
        json.dumps(
            {
                "recipesInput": str(recipes_input.resolve()),
                "reagentsInput": str(reagents_input.resolve()),
                "output": str(output_path.resolve()),
                "includeOptional": bool(args.include_optional),
                "simplifiedRecipesWritten": len(simplified),
            },
            ensure_ascii=False,
            indent=2,
        )
    )


if __name__ == "__main__":
    main()