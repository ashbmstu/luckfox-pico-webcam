from PIL import Image, ImageFilter, ImageStat
import sys

# q-98: full 1920x1080 frame, no crop
# q-88: EPTZ crop of 1600x900+160+90 scaled up to 1920x1080
# Put both into the same field of view at the same pixel count (1600x900),
# then compare high-frequency energy. If the ISP crops before the
# sensor->1080p downscale, q-88 carries MORE real detail and wins clearly.
full = Image.open(sys.argv[1]).convert('L')
crop = Image.open(sys.argv[2]).convert('L')

full_f = full.crop((160, 90, 1760, 990))            # same field as the EPTZ rect
crop_f = crop.resize((1600, 900), Image.LANCZOS)    # undo the 1.2x upscale

def hf(img, box=None):
    im = img.crop(box) if box else img
    e = im.filter(ImageFilter.Kernel((3, 3), [0, -1, 0, -1, 4, -1, 0, -1, 0], 1, 128))
    return ImageStat.Stat(e).stddev[0]

regions = [("whole field", None),
           ("left third", (0, 0, 530, 900)),
           ("upper band", (0, 0, 1600, 300)),
           ("centre", (550, 300, 1050, 600))]

print("%-12s %8s %8s %8s" % ("region", "full", "cropped", "ratio"))
for name, box in regions:
    a, b = hf(full_f, box), hf(crop_f, box)
    print("%-12s %8.2f %8.2f %8.2f" % (name, a, b, b / a))
