# 架空の個人情報を含むテスト画像を作る（実在の人物・住所ではない）
import json, random, sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

out = sys.argv[1]
W3 = "/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc"
W6 = "/System/Library/Fonts/ヒラギノ角ゴシック W6.ttc"
MIN = "/System/Library/Fonts/ヒラギノ明朝 ProN.ttc"
random.seed(1)
truth = {}

def noisy_bg(w, h, c1, c2):
    img = Image.new("RGB", (w, h), c1)
    d = ImageDraw.Draw(img)
    for y in range(h):
        t = y / h
        d.line([(0, y), (w, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(c1, c2)))
    for _ in range(w * h // 40):
        x, y = random.randrange(w), random.randrange(h)
        p = img.getpixel((x, y))
        n = random.randint(-18, 18)
        img.putpixel((x, y), tuple(max(0, min(255, v + n)) for v in p))
    return img

def card(lines, size, pad=40, bg=(250, 250, 245)):
    fonts = [ImageFont.truetype(f, s) for f, s in lines_fonts(lines)]
    dummy = ImageDraw.Draw(Image.new("RGB", (1, 1)))
    boxes = [dummy.textbbox((0, 0), t, font=f) for (t, _, _), f in zip(lines, fonts)]
    w = max(b[2] for b in boxes) + pad * 2
    h = sum(b[3] for b in boxes) + pad * (len(lines) + 1)
    img = Image.new("RGBA", (w, h), bg + (255,))
    d = ImageDraw.Draw(img)
    y = pad
    for (t, _, _), f, b in zip(lines, fonts, boxes):
        d.text((pad, y), t, font=f, fill=(20, 20, 20))
        y += b[3] + pad
    return img

def lines_fonts(lines):
    return [(f, s) for _, f, s in lines]

def paste_rotated(bg, fg, xy, angle, blur=0):
    fg = fg.rotate(angle, expand=True, resample=Image.BICUBIC)
    if blur:
        fg = fg.filter(ImageFilter.GaussianBlur(blur))
    bg.paste(fg, xy, fg)
    return bg

# 1. 名札（首から下げた名札を斜めに撮った想定）
lines = [("株式会社カメレオン", W3, 44), ("営業部", W3, 40), ("山田 花子", W6, 96)]
img = noisy_bg(1200, 1600, (90, 110, 140), (40, 50, 70))
img = paste_rotated(img, card(lines, 0), (220, 500), 8)
img.save(f"{out}/1_name_tag.jpg", quality=90)
truth["1_name_tag.jpg"] = [t for t, _, _ in lines]

# 2. 宛名（封筒のラベル）
lines = [("〒150-0002", W3, 52), ("東京都渋谷区渋谷1丁目2-3", W3, 52), ("カメレオンビル5F", W3, 52), ("佐藤 太郎 様", MIN, 84)]
img = noisy_bg(1200, 1600, (200, 180, 150), (170, 150, 120))
img = paste_rotated(img, card(lines, 0, bg=(255, 255, 255)), (120, 450), -3, blur=0.8)
img.save(f"{out}/2_address_label.jpg", quality=85)
truth["2_address_label.jpg"] = [t for t, _, _ in lines]

# 3. 部屋の写真の隅に小さく写った書類（小さい・ぼけ・傾き）
lines = [("請求書", W6, 40), ("鈴木 一郎 様", W3, 30), ("090-1234-5678", W3, 30)]
img = noisy_bg(1200, 1600, (220, 210, 190), (120, 100, 80))
d = ImageDraw.Draw(img)
d.rectangle([100, 900, 1100, 1250], fill=(130, 90, 60))  # 机
d.ellipse([200, 300, 700, 800], fill=(80, 140, 90))      # 観葉植物
img = paste_rotated(img, card(lines, 0, pad=24), (700, 980), 15, blur=1.2)
img.save(f"{out}/3_small_document.jpg", quality=80)
truth["3_small_document.jpg"] = [t for t, _, _ in lines]

# 4. 文字のない写真（誤検出の確認）
img = noisy_bg(1200, 1600, (150, 190, 230), (60, 120, 60))
d = ImageDraw.Draw(img)
for _ in range(30):
    x, y, r = random.randrange(1200), random.randrange(1600), random.randint(20, 120)
    d.ellipse([x - r, y - r, x + r, y + r], fill=tuple(random.randrange(256) for _ in range(3)))
d.rectangle([0, 1200, 1200, 1600], fill=(70, 110, 50))
img.save(f"{out}/4_no_text.jpg", quality=85)
truth["4_no_text.jpg"] = []

json.dump(truth, open(f"{out}/truth.json", "w"), ensure_ascii=False, indent=1)
