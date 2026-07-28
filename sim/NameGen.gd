class_name NameGen
extends RefCounted

## Nombres deterministas a partir de la semilla del nodo: no se guardan, se regeneran.

const PREFIX := ["Val", "Mor", "Ald", "Bren", "Cast", "Dun", "Eld", "Fenn", "Gar", "Hol",
	"Iver", "Jor", "Kel", "Lum", "Nar", "Oss", "Pel", "Quen", "Rav", "Sel", "Tor", "Umb",
	"Ver", "Wyn", "Yal", "Zir"]
const SUFFIX := ["dor", "heim", "mar", "ton", "vale", "burgo", "gard", "field", "rida",
	"stad", "port", "cova", "landa", "mont", "ría", "sena"]


static func for_node(node_seed: int, tier: int) -> String:
	var rng := RandomNumberGenerator.new()
	rng.seed = node_seed
	var base: String = PREFIX[rng.randi() % PREFIX.size()] + SUFFIX[rng.randi() % SUFFIX.size()]
	if tier >= Content.REGION:
		return "%s de %s" % [Content.tier(tier).name, base]
	return base
