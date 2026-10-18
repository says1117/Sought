# Builds code.js from code.template.js by embedding simulator screenshots as base64.
# Usage: python3 -I build.py <folder with home_scrolled.jpg, items.jpg, ...>
import base64, json, pathlib, sys
here = pathlib.Path(__file__).parent
shots = pathlib.Path(sys.argv[1])
screens = {p.stem: base64.b64encode(p.read_bytes()).decode() for p in sorted(shots.glob('*.jpg'))}
src = (here / 'code.template.js').read_text().replace('__SCREENS__', json.dumps(screens))
(here / 'code.js').write_text(src)
print(f'code.js: {len(src) // 1024} KB, {len(screens)} screenshots')
