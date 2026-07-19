class_name Items

# Définitions et génération des objets d'équipement.
# Un objet = un Dictionary : {slot, rarity, name, damage?, health?, speed?}.
# Les stats scalent avec le niveau du joueur au moment du drop.

const RARITY_NAMES := ["Commun", "Rare", "Épique", "Légendaire"]
const RARITY_COLORS := [
	Color(0.85, 0.85, 0.85), # commun — blanc
	Color(0.35, 0.60, 1.00), # rare — bleu
	Color(0.75, 0.40, 1.00), # épique — violet
	Color(1.00, 0.60, 0.15), # légendaire — orange
]
const RARITY_MULT := [1.0, 1.5, 2.1, 3.0]
const RARITY_MATERIALS := ["en cuivre", "en fer", "en acier", "en mithril"]
const SLOT_NAMES := {"weapon": "Arme", "armor": "Armure", "amulet": "Amulette"}

static func roll_rarity() -> int:
	var r := randf()
	if r < 0.55:
		return 0
	elif r < 0.82:
		return 1
	elif r < 0.95:
		return 2
	return 3

static func roll_item(level: int) -> Dictionary:
	var slot: String = ["weapon", "armor", "amulet"][randi() % 3]
	var rarity := roll_rarity()
	var mult: float = RARITY_MULT[rarity]
	var lvl_scale := 1.0 + 0.25 * (level - 1)
	var item := {
		"slot": slot,
		"rarity": rarity,
		"name": "%s %s" % [SLOT_NAMES[slot], RARITY_MATERIALS[rarity]],
	}
	match slot:
		"weapon":
			item["damage"] = int(round(randf_range(4.0, 8.0) * mult * lvl_scale))
		"armor":
			item["health"] = int(round(randf_range(10.0, 18.0) * mult * lvl_scale))
		"amulet":
			item["health"] = int(round(randf_range(4.0, 8.0) * mult * lvl_scale))
			item["damage"] = int(round(randf_range(1.0, 3.0) * mult * lvl_scale))
			item["speed"] = snappedf(randf_range(0.2, 0.5) * mult, 0.1)
	return item

# Résumé lisible des bonus, pour l'inventaire.
static func describe(item: Dictionary) -> String:
	var parts: PackedStringArray = []
	if item.get("damage", 0) > 0:
		parts.append("+%d dégâts" % item["damage"])
	if item.get("health", 0) > 0:
		parts.append("+%d PV" % item["health"])
	if item.get("speed", 0.0) > 0.0:
		parts.append("+%.1f vitesse" % item["speed"])
	parts.append(RARITY_NAMES[item["rarity"]])
	return "  ·  ".join(parts)
