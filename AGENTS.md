# escape — project conventions

## Scene and resource layout

`scenes/` holds **no files directly**. Every `.tscn` and `.tres` lives in exactly one subfolder:

| Folder | Contents |
|---|---|
| `scenes/actors/` | player, item, escape_door — anything instanced into a world |
| `scenes/levels/` | level, level2, world, world2 — level geometry and world roots |
| `scenes/resources/` | tilesets, SpriteFrames, fonts — shared `.tres` resources |
| `scenes/fx/` | dust and other visual effects |
| `scenes/ui/` | menu and other UI scenes |

Before creating a scene or resource, check whether it already exists in one of these
subfolders. `scenes/*.tscn` and `scenes/*.tres` are gitignored to enforce this — a file
written to the root will be silently untracked rather than committed.

This layout was established in `e9128bd`. Commit `df7975c` then recreated five files at
the old root paths (`scenes/level.tscn`, `scenes/world.tscn`, ...), leaving orphaned
duplicates that nothing referenced but Godot still imported. Do not reintroduce them.

Levels reference their tileset via `ext_resource` pointing at `scenes/resources/`.
Do not inline a tileset as a `sub_resource` — that forks the tile definitions and the
collision polygons drift out of sync between levels.
