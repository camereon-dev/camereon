# オフライン地名辞書

出典はデジタル庁の[アドレス・ベース・レジストリ町字マスター（全国）](https://dataset.address-br.digital.go.jp/documents/b80e77a0e2d24e5692be4af885eb3de7)。カタログ更新日時2026-11-06T15:40:49ZのZIPを固定し、都道府県・郡・市・区・町域/大字・小字を抽出した。詳細な件数・SHA-256は `assets/address_dictionary/manifest.json`、帰属表示と利用条件は同ディレクトリの `NOTICE.txt` に記録する。

市・区・町・村・郡の末尾を外した自治体名と、先頭の「大字」「小字」「字」を外した町字名を別表記として登録する。例えば「豊橋市」「豊橋」「字北山」「北山」をそれぞれ検索できる。町域名そのものの末尾の「町」は削除しない。全角ASCIIを半角化し空白を除去、重複を統合する。数字・記号だけの項目を除いて公開全行を利用し、status_flgによる現行地名の絞り込みは行わない。架空の地名は追加しない。

辞書は408,196語（別表記を含む）、約10MB。1文字の地名・省略表記は漢字のみ収録し、カタカナ・ひらがな・英数字などは除外する（Unicodeコードポイント単位）。「津」「津市」はともに保持する。漢字はUnicode名がCJK UNIFIED IDEOGRAPHまたはCJK COMPATIBILITY IDEOGRAPHで始まる文字として判定する。人名や一般文と一致する場合は候補にする。辞書の網羅性やOCRの完全性を保証するものではない。検索に外部通信は使わない。

## 再生成

リポジトリ直下で実行する（Python標準ライブラリのみ）。ZIPは同梱しない。

```sh
curl -fL https://data.address-br.digital.go.jp/mt_town/mt_town_all.csv.zip -o /tmp/mt_town_all.csv.zip
python3 tools/address-dictionary/build.py /tmp/mt_town_all.csv.zip
flutter test test/core/detection/place_name_dictionary_test.dart test/address_only_editor_test.dart
```

配布元のURLは更新され得る。取得物が固定SHA-256と異なる場合、生成を停止する。更新時は公式カタログ、スキーマ、利用条件と差分を確認し、`build.py` のSOURCE_SHA256とSOURCE_UPDATEDを更新してから生成する。manifest、NOTICE、本文の件数・更新日時も合わせて確認する。現在の収録物を再現するにはmanifestのチェックサムと一致するZIPが必要。

形式はUTF-16トライ。ヘッダーに形式識別子JPN1・ノード数・辺数・最大文字長、ノードに先頭辺・辺数・地名種別フラグ、辺にコード単位と子ノード番号を格納する（リトルエンディアン）。子の文字をソートして二分探索する。Dart文字列と同じUTF-16のオフセットを使い、OCR矩形との対応を保つ。
