#!/usr/bin/env python3
"""Generate scenes/fx_frames.tres — the shared SpriteFrames for one-shot FX
(dust puffs). All players' Effects nodes share this single sheet. Edit the
ANIMS table and re-run to add/adjust FX:

    python3 tools/generate_fx_frames.py

Each entry: (anim_name, folder, file_prefix, frame_count, speed_fps).
FX anims always loop=false (they play once and the node frees itself on
`animation_finished` — see scenes/dust.tscn).
Frames are expected at res://sprites/Sprites/FX/<folder>/<file_prefix><NN>.png
(1-based, 2 digits).
"""
import os

ANIMS = [
    # (anim_name,     folder,          prefix,          frames, fps)
    ("jump_dust",    "JumpDust",      "JumpDust",       7, 24.0),
    ("landing_dust", "LandingDust",   "LandingDust",    6, 24.0),
    ("run_dust",     "RunDustFront",  "RunDustFront",   8, 22.0),
    ("slide_dust",   "SlideDust",     "SlideDust",      6, 22.0),
    ("roll_dust",    "RollDust",      "RollDust",       7, 22.0),
]

ROOT = os.path.join(os.path.dirname(__file__), "..")


def main():
    ext_lines = []
    anim_blocks = []
    next_id = 1

    for name, folder, prefix, count, speed in ANIMS:
        frame_ids = []
        for i in range(1, count + 1):
            rel = f"sprites/Sprites/FX/{folder}/{prefix}{i:02d}.png"
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
            '{\n"frames": [%s],\n"loop": false,\n"name": &"%s",\n"speed": %s\n}'
            % (frames, name, speed)
        )

    load_steps = next_id  # one per ext_resource + the resource itself
    out = os.path.join(ROOT, "scenes", "resources", "fx_frames.tres")
    with open(out, "w") as f:
        f.write(f'[gd_resource type="SpriteFrames" load_steps={load_steps} format=3]\n\n')
        f.write("\n".join(ext_lines))
        f.write("\n\n[resource]\n")
        f.write("animations = [" + ", ".join(anim_blocks) + "]\n")

    print(f"wrote {len(ANIMS)} FX animations, {next_id - 1} frames -> {os.path.abspath(out)}")


if __name__ == "__main__":
    main()
