# LensTrue ビルド用リポジトリ(Windows から iPhone に入れる)

## A. GitHub でアプリをビルドする(最初の1回)
1. https://github.com でアカウントを作る(無料)。
2. 右上の「+」→「New repository」。名前は `lenstrue`、「Public」を選んで「Create repository」。
3. 次の画面の「uploading an existing file」をクリック。
4. この zip を展開したフォルダの中身(`.github` フォルダ、`LensTrue` フォルダ、`project.yml`)を、すべてブラウザにドラッグ。
5. 下の「Commit changes」を押す。
6. 上の「Actions」タブを開く。「Build iOS IPA」が動いていれば待つ(5〜10分)。動いていなければ、左の「Build iOS IPA」→「Run workflow」。
7. 緑のチェックになったら、その実行をクリックし、下の「Artifacts」の `LensTrue-ipa` をダウンロード。展開すると `LensTrue.ipa` が出てきます。
   - 赤い ✗ になったら、失敗したステップのログのエラー部分をコピーして Claude に送ってください。

## B. iPhone に入れる(Windows)
1. https://sideloadly.io から Sideloadly をダウンロードしてインストール。案内に従い、必要なら iTunes と iCloud(Apple のサイト版)も入れる。
2. iPhone を USB でつなぎ、「このコンピュータを信頼」を選ぶ。
3. iPhone で「設定 → プライバシーとセキュリティ → デベロッパモード」をオンにする(再起動が必要)。
4. Sideloadly に `LensTrue.ipa` をドラッグし、Apple ID を入力して「Start」。2段階認証のコードを聞かれたら入力。
   - Apple ID のパスワードを入力するソフトです。不安なら、無料の別の Apple ID を作ってそれを使ってください。
5. iPhone で「設定 → 一般 → VPNとデバイス管理」を開き、自分の Apple ID を「信頼」する。
6. ホーム画面の LensTrue を開き、カメラと写真の許可を「許可」にする。

## C. 7日後(期限切れ)
同じ `LensTrue.ipa` を、もう一度 Sideloadly で入れ直すだけです(手順 B の 4)。

## 使い方
- 背面: スマホを動かしてスキャン → 対象をタップ → 「視点を引く」を調整 → シャッター
- 自撮り: 上部の「自撮り」ボタン → 顔を向けてシャッター(TrueDepth の顔メッシュで実測)
