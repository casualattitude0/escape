extends RefCounted
class_name DevSnapshot

## Dev-only match persistence, so a script edit + restart drops you back into the
## in-progress round instead of a fresh lobby. The host writes a snapshot of the
## match (layout seed, item/grapple/winner state, player positions) to disk every
## couple of seconds; on the next launch the host restores it and syncs everyone.
##
## Entirely gated behind the "dev_resume" feature tag (set on the editor's
## Run-Multiple-Instances config). In a real game / exported build the tag is
## absent, so nothing here ever runs. See scripts/ui/menu.gd for the matching
## host/join auto-connect that makes the F5 loop hands-free.

const PATH := "user://dev_snapshot.cfg"

static func enabled() -> bool:
	# Net.dev_resume is set by the lobby from the "resume" launch token (and the
	# dev_resume feature). Fall back to the raw feature in case the world scene is
	# somehow reached without the lobby (e.g. a direct scene run).
	return Net.dev_resume or OS.has_feature("dev_resume")

static func save(data: Dictionary) -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("snapshot", "data", data)
	cfg.save(PATH)

## Returns the saved snapshot, or an empty Dictionary if there is none.
static func load_data() -> Dictionary:
	if not FileAccess.file_exists(PATH):
		return {}
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return {}
	var data = cfg.get_value("snapshot", "data", {})
	return data if data is Dictionary else {}

static func clear() -> void:
	if FileAccess.file_exists(PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))
