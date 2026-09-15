import os, re, tempfile
import cairosvg

APP = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.chdir(tempfile.mkdtemp())
# minerfan icon (run: python3 tool/icon/make_icons.py; needs cairosvg): a mining-rig fan (shroud, swept blades, a gem at the hub)
# on a dark rounded square. Writes the full icon and the Android adaptive
# layers (foreground, background, monochrome).

DEFS = '''
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#211814"/>
      <stop offset="1" stop-color="#060607"/>
    </linearGradient>
    <radialGradient id="glow" cx="0.5" cy="0.5" r="0.5">
      <stop offset="0" stop-color="#FF7A1A" stop-opacity="0.60"/>
      <stop offset="0.6" stop-color="#FF6A13" stop-opacity="0.10"/>
      <stop offset="1" stop-color="#FF6A13" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="blade" x1="60" y1="40" x2="430" y2="-160" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#C83200"/>
      <stop offset="0.5" stop-color="#FF7A12"/>
      <stop offset="1" stop-color="#FFC266"/>
    </linearGradient>
    <linearGradient id="shroud" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#FFB14A"/>
      <stop offset="0.5" stop-color="#FF6A13"/>
      <stop offset="1" stop-color="#8A2E00"/>
    </linearGradient>
    <linearGradient id="frame" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#FF8A2A" stop-opacity="0.8"/>
      <stop offset="1" stop-color="#FF6A13" stop-opacity="0.15"/>
    </linearGradient>
    <g id="b">
      <path d="M 92 -56 C 185 -205, 350 -262, 428 -160 C 444 -138, 436 -114, 412 -108 C 320 -96, 212 -44, 128 34 C 108 4, 96 -24, 92 -56 Z" fill="url(#blade)"/>
      <path d="M 100 -66 C 195 -205, 345 -250, 418 -158" fill="none" stroke="#FFFFFF" stroke-opacity="0.45" stroke-width="12" stroke-linecap="round"/>
    </g>
    <g id="bm">
      <path d="M 92 -56 C 185 -205, 350 -262, 428 -160 C 444 -138, 436 -114, 412 -108 C 320 -96, 212 -44, 128 34 C 108 4, 96 -24, 92 -56 Z" fill="#FFFFFF"/>
    </g>
  </defs>'''

GEM = '''
  <polygon points="0,-70 61,-35 61,35 0,70 -61,35 -61,-35" fill="#FFB35A"/>
  <polygon points="0,-70 61,-35 0,0" fill="#FFF3DE"/>
  <polygon points="61,-35 61,35 0,0" fill="#FFB35A"/>
  <polygon points="61,35 0,70 0,0" fill="#FF7A1A"/>
  <polygon points="0,70 -61,35 0,0" fill="#D94400"/>
  <polygon points="-61,35 -61,-35 0,0" fill="#FF9A3C"/>
  <polygon points="-61,-35 0,-70 0,0" fill="#FFD9A0"/>'''

def rotor(scale, ring=True, mono=False):
    use = 'bm' if mono else 'b'
    blades = ''.join(f'<use xlink:href="#{use}" transform="rotate({i * 72})"/>' for i in range(5))
    shroud = ''
    if ring:
        shroud = ('<circle r="452" fill="none" stroke="#FFFFFF" stroke-width="30"/>' if mono else
                  '<circle r="452" fill="none" stroke="url(#shroud)" stroke-width="30"/>'
                  '<circle r="433" fill="none" stroke="#000000" stroke-opacity="0.55" stroke-width="8"/>')
    hub = ('<circle r="112" fill="#FFFFFF"/><polygon points="0,-62 54,-31 54,31 0,62 -54,31 -54,-31" fill="#000000"/>'
           if mono else
           f'<circle r="116" fill="#0B0908" stroke="url(#shroud)" stroke-width="14"/><g transform="scale(1.02)">{GEM}</g>')
    return f'<g transform="translate(512 512) scale({scale})">{shroud}<g transform="rotate(-14)">{blades}</g>{hub}</g>'

def screws():
    out = ''
    for x, y in [(150, 150), (874, 150), (150, 874), (874, 874)]:
        out += (f'<circle cx="{x}" cy="{y}" r="30" fill="#17110E" stroke="#FF6A13" stroke-opacity="0.55" stroke-width="7"/>'
                f'<path d="M {x-14} {y} H {x+14} M {x} {y-14} V {y+14}" stroke="#FF8A2A" stroke-opacity="0.6" stroke-width="7" stroke-linecap="round"/>')
    return out

def svg(body):
    return f'<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 1024 1024" width="1024" height="1024">{DEFS}{body}</svg>\n'

full = svg(f'''
  <rect x="28" y="28" width="968" height="968" rx="230" fill="url(#bg)"/>
  <circle cx="512" cy="512" r="470" fill="url(#glow)"/>
  <rect x="40" y="40" width="944" height="944" rx="218" fill="none" stroke="url(#frame)" stroke-width="10"/>
  {screws()}
  {rotor(0.88)}''')
open('minerfan.svg', 'w').write(full)
# Android adaptive icon (108 dp): the fan within the 66 dp safe zone.
open('fg.svg', 'w').write(svg(rotor(0.6)))
open('bg.svg', 'w').write(svg('<rect width="1024" height="1024" fill="url(#bg)"/><circle cx="512" cy="512" r="420" fill="url(#glow)"/>'))
open('mono.svg', 'w').write(svg(rotor(0.6, mono=True)))


# ---- export ----
RES = APP + '/android/app/src/main/res'
def png(src, dst, size):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    cairosvg.svg2png(url=src, write_to=dst, output_width=size, output_height=size)
# Linux and the app's own asset.
open(APP + '/assets/icon/minerfan.svg', 'w').write(open('minerfan.svg').read())
# (Linux uses the SVG: the launcher entry points at it.)
# Android legacy launcher icons (48 dp) and adaptive layers (108 dp).
dens = {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}
for d, k in dens.items():
    png('minerfan.svg', f'{RES}/mipmap-{d}/ic_launcher.png', int(48 * k))
    png('fg.svg', f'{RES}/mipmap-{d}/ic_launcher_foreground.png', int(108 * k))
    png('bg.svg', f'{RES}/mipmap-{d}/ic_launcher_background.png', int(108 * k))
    png('mono.svg', f'{RES}/mipmap-{d}/ic_launcher_monochrome.png', int(108 * k))
os.makedirs(RES + '/mipmap-anydpi-v26', exist_ok=True)
open(RES + '/mipmap-anydpi-v26/ic_launcher.xml', 'w').write('''<?xml version="1.0" encoding="utf-8"?>
<!-- minerfan: the fan (foreground) on its dark background; monochrome for
     themed icons (Android 13+). -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@mipmap/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
    <monochrome android:drawable="@mipmap/ic_launcher_monochrome" />
</adaptive-icon>
''')
# Notification icon: the fan as a white vector, 5 rotated blades and a hub.
blade = 'M 92 -56 C 185 -205, 350 -262, 428 -160 C 444 -138, 436 -114, 412 -108 C 320 -96, 212 -44, 128 34 C 108 4, 96 -24, 92 -56 Z'
s = 10.5 / 450
def tr(m):
    x, y = float(m.group(1)), float(m.group(2))
    return f'{12 + x * s:.2f},{12 + y * s:.2f}'
p = re.sub(r'(-?\d+(?:\.\d+)?) (-?\d+(?:\.\d+)?)', tr, blade).replace(' ', '')
p = re.sub(r'([MCZ])', r'\1', p)
groups = ''.join(f'''
    <group android:rotation="{i * 72 - 14}" android:pivotX="12" android:pivotY="12">
        <path android:fillColor="#FFFFFFFF" android:pathData="{p}" />
    </group>''' for i in range(5))
open(RES + '/drawable/ic_stat_mining.xml', 'w').write(f'''<?xml version="1.0" encoding="utf-8"?>
<!-- Status bar icon while mining: the minerfan fan. -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24">{groups}
    <path android:fillColor="#FFFFFFFF"
        android:pathData="M12,9.2a2.8,2.8 0,1 1,0 5.6a2.8,2.8 0,1 1,0 -5.6z" />
</vector>
''')
print('ok')
