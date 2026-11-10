# アプリ紹介・ダウンロードサイト

公開先: https://camereon-dev.github.io/camereon/

HTML・CSS・JavaScript の静的サイト。Node.js や Flutter のビルドは不要。
アプリの現在の機能を、実機の画面で紹介する。

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

画像はユーザー提供の Android 実機スクリーンショット（1220×2712）を、画面全体を保ったまま 720×1600 の WebP に縮小したもの。掲載例はノートパソコンを撮影した写真で、アプリ内の「サンプルで試す」（架空の宛名ラベル）とは異なる。

| ファイル | 場所 | 内容 |
| --- | --- | --- |
| `screen-camera.webp` | 使い方 1 | カメラで撮影する画面 |
| `screen-detect.webp` | 使い方 2 | 文字57か所・画面3か所を検出した画面 |
| `screen-select.webp` | メインビジュアル・使い方 3 | 文字18か所を選択した画面 |
| `screen-confirm.webp` | 使い方 4 | 隠した結果を保存前に確認する画面 |

撮り直すときは、実在の人の顔・名前・住所などが写っていないか確認し、ステータスバーから操作部分まで画面全体を残す。HTML の縦横サイズと代替テキストも更新する。使い方の画像はタップで拡大でき、閉じるボタン・Escape・背景クリックで戻れる。JavaScript が無効な場合は通常の画像として表示する。

立体感はスマホ外枠の傾き、厚み、影と説明カードの段差で表現し、スクリーンショットそのものは加工しない。スマホでは4ステップを縦に並べ、画面と説明を横に置いて読み進めやすくしている。

## テーマ

初回は端末のライト・ダーク設定に合わせる。ヘッダーのボタンで切り替えられ、選択はブラウザーに保存する。
保存が使えない環境でも切り替え可能。JavaScript が無効な場合も CSS で端末のテーマに追従する。
フォント・画像は自サイトから配信し、アクセス解析は利用しない。
ヒーローの極太文字には、必要文字だけに絞った Noto Sans JP（約 10 KB）を同梱している。ライセンスは `assets/NotoSansJP-OFL.txt`。

ヒーローの虹色はカーソルとスクロールに反応する。文字の位置自体は動かさず、画面外では描画更新を止める。
`prefers-reduced-motion` では静止し、強制カラーモードでは通常の文字色にする。

サイト専用の色は `styles.css` の CSS 変数で設定する。画面幅に合わせてレイアウトを変更し、`prefers-reduced-motion` に対応する。
