#!/usr/bin/env python3
"""Generate the panel's closed/open padlock strip as a white, tintable TGA."""

import math
import struct
from pathlib import Path


ICON_SIZE = 32
SAMPLES = 4
OUTPUT = Path(__file__).resolve().parents[1] / "Media/PanelLock.tga"


def opaque(x: float, y: float, unlocked: bool) -> bool:
	body = 8 <= x <= 24 and 14 <= y <= 27
	if body:
		# Round the body corners and cut a transparent keyhole.
		corner_x = max(10, min(22, x))
		corner_y = max(16, min(25, y))
		body = math.hypot(x - corner_x, y - corner_y) <= 2
		keyhole = math.hypot(x - 16, y - 19) <= 1.5 or (15 <= x <= 17 and 19 <= y <= 23)
		if body and not keyhole:
			return True

	shackle_y = 10.5 if unlocked else 13
	arch = y <= shackle_y and abs(math.hypot(x - 16, y - shackle_y) - 5) <= 1.25
	left_end = 11.5 if unlocked else 16
	left = abs(x - 11) <= 1.25 and shackle_y <= y <= left_end
	right = abs(x - 21) <= 1.25 and shackle_y <= y <= 16
	return arch or left or right


def generate() -> bytes:
	width, height = ICON_SIZE * 2, ICON_SIZE
	# Uncompressed BGRA, eight alpha bits, top-left origin.
	header = struct.pack(
		"<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, width, height, 32, 0x28
	)
	pixels = bytearray()
	for y in range(height):
		for x in range(width):
			covered = sum(
				opaque(
					x % ICON_SIZE + (sx + 0.5) / SAMPLES,
					y + (sy + 0.5) / SAMPLES,
					x >= ICON_SIZE,
				)
				for sy in range(SAMPLES)
				for sx in range(SAMPLES)
			)
			pixels.extend((255, 255, 255, round(covered * 255 / SAMPLES**2)))
	return header + pixels


if __name__ == "__main__":
	_ = OUTPUT.write_bytes(generate())
	print(f"Generated {OUTPUT}")
