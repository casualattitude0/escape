#!/usr/bin/env python3
"""Generate scenes/player_frames.tres — the shared SpriteFrames for players.

Both Runner and Hunter use this single humanoid sheet (differentiated at
runtime by tint). Edit the ANIMS table and re-run to add/adjust animations:

    python3 tools/generate_player_frames.py

Each entry: (anim_name, folder, file_prefix, frame_count, loop, speed_fps)
Frames are expected at res://sprites/<folder>/<file_prefix><NN>.png (1-based, 2 digits).
"""
import os

ANIMS = [
    # --- locomotion ---------------------------------------------------------
    ("idle",     "Sprites/Idle",           "Idle",            7, True,  10.0),
    ("run",      "Sprites/Run",            "Run",             8, True,  12.0),
    ("jump",     "Sprites/Jump",           "Jump",            3, False, 10.0),
    ("fall",     "Sprites/JumpFall",       "JumpFall",        1, True,   5.0),
    ("slide",    "Sprites/Slide",          "Slide",           4, False, 12.0),
    ("crawl",    "Sprites/Crawl",          "Crawl",           8, True,  10.0),
    ("crouch",   "Sprites/Crouch",         "Crouch",          6, False,  9.0),
    # --- combat / capture (GDD 4.4 / 4.5) -----------------------------------
    ("attack",   "Sprites/Combat/Punch01", "Punch01",         6, False, 16.0),  # Runner melee
    ("grab",     "Sprites/InteractionPull","InteractionPull", 6, False, 12.0),  # Hunter suppression: lunge then hold
    ("struggle", "Sprites/Combat/Stunned", "Stunned",         7, True,  10.0),  # Runner being suppressed
    ("die",      "Sprites/Die",            "Die",             9, False, 12.0),  # Hunter killed
]

ROOT = os.path.join(os.path.dirname(__file__), "..")


def main():
    ext_lines = []
    anim_blocks = []
    next_id = 1

    for name, folder, prefix, count, loop, speed in ANIMS:
        frame_ids = []
        for i in range(1, count + 1):
            rel = f"sprites/{folder}/{prefix}{i:02d}.png"
            abs_path = os.path.join(ROOT, rel)
            if not os.path.exists(abs_path):
                raise SystemExit(f"missing frame: {rel}")
            ext_lines.append(
                f'[ext_resource type="Texture2D" path="res://{rel}" id="{next_id}"]'
            )
            frame_ids.append(next_id)
            next_id += 1

        frames = ",\n".join(
            '{\n"duration": 1.0,\n"texture": ExtResource("%d")\n}' % fid
            for fid in frame_ids
        )
        anim_blocks.append(
            '{\n"frames": [%s],\n"loop": %s,\n"name": &"%s",\n"speed": %s\n}'
            % (frames, "true" if loop else "false", name, speed)
        )

    load_steps = next_id  # one per ext_resource + the resource itself
    out = os.path.join(ROOT, "scenes", "player_frames.tres")
    with open(out, "w") as f:
        f.write(f'[gd_resource type="SpriteFrames" load_steps={load_steps} format=3]\n\n')
        f.write("\n".join(ext_lines))
        f.write("\n\n[resource]\n")
        f.write("animations = [" + ", ".join(anim_blocks) + "]\n")

    print(f"wrote {len(ANIMS)} animations, {next_id - 1} frames -> {os.path.abspath(out)}")


if __name__ == "__main__":
    main()
