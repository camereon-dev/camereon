#!/usr/bin/env python3
"""Compare bounded full-image and overlapping-tile text detection locally.

No recognized strings are produced. Private inputs/overlays stay under .private/.
The host reproduction is not a device benchmark or a general accuracy estimate.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import socket
import time

import cv2
import numpy as np
import onnxruntime as ort
from PIL import Image, ImageDraw, ImageOps

from text_v5 import detect


def tile_starts(length, edge):
    if length <= edge:
        return [0]
    count = math.ceil((length - edge) / (edge * .75)) + 1
    return [int(i * (length - edge) / (count - 1) + .5) for i in range(count)]


def duplicate(a, b):
    aw, ah = a[2] - a[0], a[3] - a[1]
    bw, bh = b[2] - b[0], b[3] - b[1]
    intersection = max(0, min(a[2], b[2]) - max(a[0], b[0])) * max(0, min(a[3], b[3]) - max(a[1], b[1]))
    return (intersection / (aw * ah + bw * bh - intersection) >= .45 or
            (intersection / min(aw * ah, bw * bh) >= .8 and min(ah, bh) / max(ah, bh) >= .35 and
             abs((a[1]+a[3]-b[1]-b[3])/2) <= min(ah,bh)*.5))


def large_line_fragment(a, b):
    aw,ah = a[2]-a[0],a[3]-a[1]
    bw,bh = b[2]-b[0],b[3]-b[1]
    if min(bw,bh)<48 or max(bw,bh)/min(bw,bh)<2:
        return False
    intersection = max(0,min(a[2],b[2])-max(a[0],b[0]))*max(0,min(a[3],b[3])-max(a[1],b[1]))
    return ((aw < bw*.9 or ah < bh*.6) if bw>=bh else (ah<bh*.9 or aw<bw*.6)) and intersection/(aw*ah)>=.9


def merge(found):
    merged = []
    for d in found:
        box = d['box'][:]
        index = 0
        while index < len(merged):
            other = merged[index]['box']
            if duplicate(box, other):
                box = [min(box[0], other[0]), min(box[1], other[1]), max(box[2], other[2]), max(box[3], other[3])]
                merged.pop(index)
                index = 0
            else:
                index += 1
        merged.append({'label': 'text', 'box': box})
    return sorted(merged, key=lambda d: (d['box'][1], d['box'][0]))


def tiled(image, session, oriented=False):
    h, w = image.shape[:2]
    edge = max(384, math.ceil(max(h, w) / 128) * 32)
    output = detect(image, session, 1536 if oriented else 960, oriented=oriented)
    found = []
    tiles = []
    if max(h, w) > 960:
        for y in tile_starts(h, edge):
            for x in tile_starts(w, edge):
                crop = image[y:min(y+edge, h), x:min(x+edge, w)]
                ch, cw = crop.shape[:2]
                scale = 960 / max(ch, cw)
                enlarged = cv2.resize(crop, (int(cw*scale+.5), int(ch*scale+.5)))
                result = detect(enlarged, session, 960, line_filter=True, oriented=oriented)
                tiles.append([x, y, cw, ch])
                for d in result['detections']:
                    a,b,c,e = d['box']
                    a,c = a * cw / enlarged.shape[1], c * cw / enlarged.shape[1]
                    b,e = b * ch / enlarged.shape[0], e * ch / enlarged.shape[0]
                    mapped=[a+x,b+y,c+x,e+y]
                    if not any(large_line_fragment(mapped,d['box']) for d in output['detections']):
                        found.append({'label':'text','box':mapped})
    merged = merge(found)
    for coarse in output['detections']:
        box = coarse['box']
        if not any(duplicate(d['box'],box) and
                   min(d['box'][2]-d['box'][0],box[2]-box[0]) / max(d['box'][2]-d['box'][0],box[2]-box[0]) >= .8
                   for d in merged):
            merged = merge([*merged,coarse])
    return {'detections': merged[:500], 'truncated': len(merged)>500, 'tiles': tiles, 'passes': len(tiles)+1}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('images', nargs='+', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--oriented', action='store_true', help='Also evaluate orientation-aware scoring and 1536px overview')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    model = Path('android/app/src/main/assets/text_detection/inference.onnx')
    digest = hashlib.sha256(model.read_bytes()).hexdigest()
    if digest != 'a431985659dc921974177a95adcfbb90fd9e51989a5e04d70d0b75f597b6e61d':
        parser.error('Unexpected detector asset')
    def no_network(*args, **kwargs):
        raise RuntimeError('Network disabled during evaluation')
    socket.socket.connect = no_network
    socket.socket.connect_ex = no_network
    socket.create_connection = no_network
    options = ort.SessionOptions()
    options.intra_op_num_threads = 2
    options.inter_op_num_threads = 1
    session = ort.InferenceSession(str(model), sess_options=options, providers=['CPUExecutionProvider'])
    report = {'model_sha256': digest, 'android_execution': False, 'images': []}
    for i, path in enumerate(args.images, 1):
        original = ImageOps.exif_transpose(Image.open(path)).convert('RGB')
        original.thumbnail((2560,2560))
        bgr = cv2.cvtColor(np.asarray(original), cv2.COLOR_RGB2BGR)
        runs = {}
        modes = [('global960',lambda:detect(bgr,session,960)),
                         ('global1536',lambda:detect(bgr,session,1536)),
                         ('detailed',lambda:tiled(bgr,session))]
        if args.oriented:
            modes.append(('oriented',lambda:tiled(bgr,session,oriented=True)))
        for name, fn in modes:
            start = time.perf_counter()
            result = fn()
            result['wall_ms'] = round((time.perf_counter()-start)*1000,1)
            runs[name] = result
            canvas = original.copy()
            draw = ImageDraw.Draw(canvas)
            for d in result['detections']:
                draw.rectangle(d['box'], outline='#00bbaa', width=2)
            canvas.save(args.output / f'photo-{i}-{name}.jpg')
            print(i,name,len(result['detections']),result['wall_ms'],flush=True)
        report['images'].append({'id':f'photo-{i}','width':original.width,'height':original.height,'runs':runs})
        (args.output/'results.json').write_text(json.dumps(report,indent=2))


if __name__ == '__main__':
    main()
