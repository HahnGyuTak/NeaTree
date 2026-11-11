"""Recreate the v4 surface microtexture from the supplied original reference.

Usage: python extract-psilo-paper-grain.py reference.png output.png
Requires Pillow. The source image is user supplied; no personal paths are saved.
"""
import argparse
from statistics import mean
from PIL import Image, ImageFilter, ImageOps

parser = argparse.ArgumentParser()
parser.add_argument('reference')
parser.add_argument('output')
args = parser.parse_args()
patch = Image.open(args.reference).convert('L').crop((468, 490, 596, 618))
low = patch.filter(ImageFilter.GaussianBlur(5))
residual = [a - b for a, b in zip(patch.getdata(), low.getdata())]
center = mean(residual)
tile_patch = Image.new('L', patch.size)
tile_patch.putdata([max(0, min(255, round(127.5 + (v - center) * 255 / 40)))
                    for v in residual])
tile = Image.new('L', (256, 256))
tile.paste(tile_patch, (0, 0))
tile.paste(ImageOps.mirror(tile_patch), (128, 0))
tile.paste(ImageOps.flip(tile_patch), (0, 128))
tile.paste(ImageOps.flip(ImageOps.mirror(tile_patch)), (128, 128))
tile.save(args.output)
