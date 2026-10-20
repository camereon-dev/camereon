# アプリ紹介・ダウンロードサイト

公開先: https://camereon-dev.github.io/camereon/

HTML・CSS・JavaScript の静的サイト。Node.js や Flutter のビルドは不要。
アプリの現在の機能と、完成イメージ・開発中の機能を区別して紹介する。

## ローカルで表示する

```sh
python3 site/build.py
python3 -m http.server 8080 --directory dist/site
```

`http://localhost:8080` を開く。公開済みのベータ版から APK・SHA-256 が揃った最新のものを取得し、ダウンロード先を HTML に埋め込む。
GitHub API が利用できない環境では `python3 site/build.py --offline` でプレビューできる（リンク先は Release 一覧になる）。

## 更新と公開

- `site/` または `.github/workflows/pages.yml` を main に取り込むと GitHub Pages へ公開する。
- ベータ版の公開ワークフロー **Checks and beta release** が main で成功した後にも更新し、新しい APK へ案内する。
- **Deploy website → Run workflow** でも更新できる。公開元のコードは常に main。
- GitHub の安定版専用 `/releases/latest` は利用せず、公開済み Pre-release と APK・チェックサムの存在を確認してリンクを生成する。
- GitHub API はデプロイ時だけ利用する。訪問者のブラウザーから GitHub API を呼ばず、JavaScript が無効でも紹介・ダウンロード・FAQ は利用できる。
- GitHub Pages はリポジトリの **Settings → Pages → Source: GitHub Actions** を使う。
- この workflow は Python 標準ライブラリだけで構築する。Android のビルドやエミュレーターの起動は行わない。

## 画像を入れ替える

現在の画像はサイト専用のオリジナル SVG イラスト。実際の個人情報は使っていない。
実機スクリーンショットを入れる場合は、撮影した人や住所などの情報が残っていないことを確認する。

| 場所             | HTML の目印                 | 目安                                                                                       |
| ---------------- | --------------------------- | ------------------------------------------------------------------------------------------ |
| メインビジュアル | `data-media-slot="hero"`    | 縦長の大きなスマートフォン画面。実画面を入れる場合は `.phone` 内のイメージ UI と置き換える |
| 撮る             | `data-media-slot="capture"` | `3:4` 前後の縦長画像                                                                       |
| 隠す             | `data-media-slot="cover"`   | 加工中の画面や使用例                                                                       |
| 保存             | `data-media-slot="keep"`    | 保存前確認の画面や使用例                                                                   |

画像は `site/assets/` に置き、HTML の該当箇所を `<img>` または `<picture>` に差し替える。
`width`・`height` と代替テキストを指定し、表示内容が実装済みになった時点で「完成イメージ」「開発中」の表記も更新する。
ヒーロー以外は `loading="lazy"` を使い、大きな画像は WebP / AVIF などで軽量化する。

## テーマ

初回は端末のライト・ダーク設定に合わせる。ヘッダーのボタンで切り替えられ、選択はブラウザーに保存する。
保存が使えない環境でも切り替え可能。JavaScript が無効な場合も CSS で端末のテーマに追従する。
フォント・画像は自サイトから配信し、アクセス解析は利用しない。
ヒーローの極太文字には、必要文字だけに絞った Noto Sans JP（約 10 KB）を同梱している。ライセンスは `assets/NotoSansJP-OFL.txt`。

ヒーローの虹色はカーソルとスクロールに反応する。文字の位置自体は動かさず、画面外では描画更新を止める。
`prefers-reduced-motion` では静止し、強制カラーモードでは通常の文字色にする。

サイト専用の色は `styles.css` の CSS 変数で設定する。画面幅に合わせてレイアウトを変更し、`prefers-reduced-motion` に対応する。
