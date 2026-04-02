# 設定ファイルリファレンス

設定ファイルは Lua テーブルを返すファイルです。スクリプト初回起動時にデフォルト値で自動生成されます。

```lua
return {
  voicevox = { ... },
  resolve  = { ... },
  runtime  = { ... },
}
```

---

## `voicevox` セクション

VOICEVOX エンジンへのリクエストに関する設定です。

| キー | 型 | デフォルト | 説明 |
|---|---|---|---|
| `speaker_id` | number | `1` | 話者 ID（VOICEVOX の `/speakers` で確認できます） |
| `speed_scale` | number | `1.0` | 話速の倍率。値が大きいほど速くなります |
| `pitch_scale` | number | `0.0` | ピッチの調整値。正で高く、負で低くなります |
| `intonation_scale` | number | `1.0` | イントネーションの強さ。`0` で平坦、大きいほど抑揚が強くなります |
| `volume_scale` | number | `1.0` | 音量の倍率 |
| `pre_phoneme_length` | number | `0.1` | 発話前の無音時間（秒） |
| `post_phoneme_length` | number | `0.1` | 発話後の無音時間（秒） |
| `sample_rate` | number | `48000` | 出力音声のサンプリングレート（Hz）。DaVinci Resolve のプロジェクト設定に合わせてください |
| `output_stereo` | boolean | `true` | `true` でステレオ出力、`false` でモノラル出力 |

---

## `resolve` セクション

DaVinci Resolve のタイムライン操作に関する設定です。

| キー | 型 | デフォルト | 説明 |
|---|---|---|---|
| `text_track_index` | number | `1` | **Text+** クリップを読み取るビデオトラックの番号（1 始まり） |
| `audio_track_index` | number | `1` | 音声クリップを配置するオーディオトラックの番号（1 始まり） |

---

## `runtime` セクション

スクリプトの動作全般に関する設定です。

| キー | 型 | デフォルト | 説明 |
|---|---|---|---|
| `output_dir` | string | `""` | WAV の保存先ディレクトリ。指定したフォルダへ直接 WAV を保存します。空文字の場合はスクリプトと同じディレクトリに保存します |
| `log_path` | string | `"./run.log"` | ログファイルの出力先パス |
| `overwrite` | boolean | `false` | `true` にすると同名の音声ファイルが既に存在する場合でも上書き生成します |
| `audio_padding_sec` | number | `0.15` | 音声クリップの長さに加算するパディング時間（秒）。クリップの末尾に余白を設けます |
| `watch_interval_sec` | number | `2` | 自動監視モード（`auto_watch`）でタイムラインの変化をポーリングする間隔（秒） |
| `watch_stable_cycles` | number | `2` | タイムラインの変化が「安定した」と判定するまでに変化なしが続く必要があるポーリング回数 |
| `watch_delete_grace_cycles` | number | `4` | クリップの削除を確定と判断するまでに待機するポーリング回数 |
| `watch_stop_file` | string | `"./watch.stop"` | このパスにファイルが存在すると自動監視を停止します（`stop_watch.lua` が作成します） |
| `watch_lock_file` | string | `"./watch.lock"` | 二重起動を防ぐためのロックファイルのパス |
| `managed_clip_prefix` | string | `"vvauto"` | スクリプトが管理するクリップを識別するための名前プレフィックス。このプレフィックスが付いたクリップのみ自動更新・削除の対象になります |
| `link_clips` | boolean | `false` | `true` にすると Text+ クリップと配置した音声クリップをリンクします |
