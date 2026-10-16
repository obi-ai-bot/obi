# Draws the app icon and builds icon.icns from it. Run from app/build:
#   python3 make-icon.py
# Needs Pillow; iconutil and sips come with macOS.
#
# STYLE 'rise': Oby's head (oby-head.png: white, eyes cut out, ears up) rises
#   into a black icon from its bottom edge, its top 90% showing (the one in use).
# STYLE 'face': the icon is Oby's face.
# STYLE 'peek': Oby peeks into a black icon from its left edge, tilted.
import os, shutil, subprocess
from PIL import Image, ImageChops, ImageDraw

STYLE = 'rise'

S = 4                     # draw at 4x, scale down for smooth edges
N = 1024 * S
sc = lambda v: int(round(v * S))
IX, IY, IW, IR = 92, 92, 840, 189     # macOS icon grid's 824px rounded square, 16px bigger (corners in step)
OBY = (242, 242, 239)                 # Oby's off-white
INK = (13, 13, 14)                    # its eyes
SHADE = (150, 150, 146)               # the colour shading falls off towards


def shape():
    m = Image.new('L', (N, N), 0)
    ImageDraw.Draw(m).rounded_rectangle([sc(IX), sc(IY), sc(IX + IW), sc(IY + IW)], radius=sc(IR), fill=255)
    return m


def gradient(box, start, end, strength, axis='y'):
    """A ramp mask inside box: 0 before start, rising to strength at end (eased)."""
    g = Image.new('L', (N, N), 0); d = ImageDraw.Draw(g)
    x0, y0, x1, y1 = box
    for v in range(sc(start), sc(end)):
        t = max(0.0, (v / S - start) / (end - start))
        a = int(strength * t ** 1.8)
        d.line([(sc(x0), v), (sc(x1), v)] if axis == 'y' else [(v, sc(y0)), (v, sc(y1))], fill=a)
    return g


def eye(d, x, y, ew, eh, dot):
    """A black pill with its white reflection, a round dot at its upper right."""
    d.rounded_rectangle([sc(x - ew), sc(y - eh), sc(x + ew), sc(y + eh)], radius=sc(ew), fill=INK + (255,))
    rx, ry = x + ew * 0.32, y - eh * 0.5
    d.ellipse([sc(rx - dot), sc(ry - dot), sc(rx + dot), sc(ry + dot)], fill=OBY + (255,))


def face():
    # Oby's face fills the icon, a soft grey fall-off along the bottom
    EYES = ((0.255, 0.33), (0.745, 0.33))   # eye centres, as fractions of the icon
    EW, EH, DOT = 62, 104, 18                # eye half width / half height, reflection radius
    img = Image.new('RGBA', (N, N), (0, 0, 0, 0))
    m = shape()
    img.paste(OBY + (255,), (0, 0), m)
    shade = gradient((0, 0, 1024, 1024), IY + IW * 0.74, IY + IW, 115)
    # and a faint shadow up the sides, from halfway down, strongest at the bottom corners
    left = Image.new('L', (N, N), 0); ld = ImageDraw.Draw(left)
    edge = IW * 0.12
    for x in range(sc(IX), sc(IX + edge)):
        t = 1 - (x / S - IX) / edge
        ld.line([(x, 0), (x, N)], fill=int(255 * t ** 1.8))
    sides = ImageChops.lighter(left, left.transpose(Image.FLIP_LEFT_RIGHT))
    lower = gradient((0, 0, 1024, 1024), IY + IW * 0.45, IY + IW, 70)
    shade = ImageChops.lighter(shade, ImageChops.multiply(sides, lower))
    img.paste(SHADE + (255,), (0, 0), ImageChops.multiply(shade, m))
    d = ImageDraw.Draw(img)
    for fx, fy in EYES:
        eye(d, IX + IW * fx, IY + IW * fy, EW, EH, DOT)
    return img


def peek():
    # like its Hiding peek: tilted, coming in from the left edge of a black icon
    K, ANGLE = 1.6, -12                # size (1 = 560 x 470), tilt in degrees (negative: clockwise)
    REACH, MID_Y = 760, 776            # its far edge reaches this x; its middle sits at this y
    EYES = ((0.34, 0.25), (0.65, 0.25))  # eye centres, as fractions of its width and height
    EYE_W, LOOK = 1.27, (10, -6)       # eye width (1 = usual), where they look (px at K = 1)
    img = Image.new('RGBA', (N, N), (0, 0, 0, 0))
    m = shape()
    bg = Image.new('RGBA', (N, N)); d = ImageDraw.Draw(bg)
    top, bot = (30, 30, 32), (6, 6, 7)
    for y in range(N):
        t = y / N
        d.line([(0, y), (N, y)], fill=tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3)) + (255,))
    img.paste(bg, (0, 0), m)

    W, H = 560 * K, 470 * K
    bx1 = REACH; bx0 = bx1 - W; by0 = MID_Y - H / 2; by1 = by0 + H
    layer = Image.new('RGBA', (N, N), (0, 0, 0, 0))
    body = Image.new('L', (N, N), 0)
    ImageDraw.Draw(body).rounded_rectangle([sc(bx0), sc(by0), sc(bx1), sc(by1)], radius=sc(150 * K), fill=255)
    layer.paste(OBY + (255,), (0, 0), body)
    shade = ImageChops.lighter(gradient((bx0, by0, bx1, by1), bx0 + W * 0.62, bx1, 70, 'x'),
                               gradient((bx0, by0, bx1, by1), by0 + H * 0.55, by1, 50))
    layer.paste(SHADE + (255,), (0, 0), ImageChops.multiply(shade, body))
    d = ImageDraw.Draw(layer)
    for fx, fy in EYES:
        eye(d, bx0 + W * fx + LOOK[0] * K, by0 + H * fy + LOOK[1] * K, 26 * K * EYE_W, 48 * K, 9 * K)
    layer = layer.rotate(ANGLE, resample=Image.BICUBIC, center=(sc((bx0 + bx1) / 2), sc((by0 + by1) / 2)))
    img.paste(layer, (0, 0), ImageChops.multiply(layer.getchannel('A'), m))
    return img


def rise():
    WIDTH, SHOWN = 0.84, 0.9            # the head's width, as a share of the icon's; how much of its height shows
    img = Image.new('RGBA', (N, N), (0, 0, 0, 0))
    m = shape()
    img.paste((0, 0, 0, 255), (0, 0), m)
    head = Image.open('oby-head.png').convert('RGBA')
    # where its sides stop being straight (its bottom corners start curving in)
    alpha = head.getchannel('A')
    straight = next(y for y in range(head.height // 2, head.height) if alpha.getpixel((0, y)) < 250) - 8
    w = sc(IW * WIDTH); h = round(w * head.height / head.width)
    head = head.resize((w, h), Image.LANCZOS)
    layer = Image.new('RGBA', (N, N), (0, 0, 0, 0))
    x0, y0 = (N - w) // 2, sc(IY + IW) - round(h * SHOWN)
    layer.paste(head, (x0, y0))
    # its sides carry straight on down past the icon's edge, rather than curving
    # in at its own bottom corners
    ImageDraw.Draw(layer).rectangle([x0, y0 + round(h * straight / head.height), x0 + w - 1, N], fill=(255, 255, 255, 255))
    img.alpha_composite(Image.composite(layer, Image.new('RGBA', (N, N), (0, 0, 0, 0)), m))
    return img


{'face': face, 'peek': peek, 'rise': rise}[STYLE]().resize((1024, 1024), Image.LANCZOS).save('icon.png')

# icon.icns: every size macOS asks for
os.makedirs('icon.iconset', exist_ok=True)
for s in (16, 32, 128, 256, 512):
    for scale, name in ((1, f'icon_{s}x{s}.png'), (2, f'icon_{s}x{s}@2x.png')):
        subprocess.run(['sips', '-z', str(s * scale), str(s * scale), 'icon.png', '--out', f'icon.iconset/{name}'],
                       check=True, capture_output=True)
subprocess.run(['iconutil', '-c', 'icns', 'icon.iconset', '-o', 'icon.icns'], check=True)
shutil.rmtree('icon.iconset')
