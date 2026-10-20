"""Generate original synthetic vision controls, with no real personal data."""

import hashlib
import json
from pathlib import Path
import shutil
import sys

from PIL import Image, ImageDraw


def generate(directory):
    directory.mkdir(parents=True, exist_ok=True)
    definitions = [
        ('red_circle', 'A single large red circle on a white background.'),
        ('blue_bars', 'Three blue vertical rectangles on a white background.'),
        ('parcel_label', 'A white shipping label on a brown parcel, with fictional name and address.'),
    ]
    manifest = []
    for index, (identifier, expected) in enumerate(definitions, start=1):
        image = Image.new('RGB', (640, 640), '#fffdf6')
        draw = ImageDraw.Draw(image)
        if identifier == 'red_circle':
            draw.ellipse((140, 140, 500, 500), fill='#dc3038')
        elif identifier == 'blue_bars':
            for x, height in ((95, 200), (275, 300), (455, 400)):
                draw.rectangle((x, 540-height, x+90, 540), fill='#2766d8')
        else:
            draw.rectangle((40, 90, 600, 570), fill='#ba8b59')
            draw.rectangle((291, 90, 349, 570), fill='#d6b38b')
            draw.rectangle((115, 200, 525, 450), fill='white')
            for y, text in [(240, 'DELIVERY'), (285, 'HANAKO SAMPLE'), (330, '123 EXAMPLE STREET'), (375, 'SAMPLE CITY 000-0000')]:
                draw.text((145, y), text, fill='#202020', font_size=24)
        path = directory / f'image_{index:02d}.png'
        image.save(path)
        manifest.append({'id': identifier, 'file': path.name, 'expected': expected, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
    fixtures = Path(__file__).resolve().parent/'fixtures'
    japanese = json.loads((fixtures/'parcel_ja.json').read_text())
    shutil.copyfile(fixtures/'parcel_ja.png', directory/japanese['file'])
    manifest.append(japanese)
    (directory/'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')


if __name__ == '__main__':
    generate(Path(sys.argv[1]))
