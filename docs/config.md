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
| `text_track_index` | number | `1` | **Text+** クリップを読み取るビデオトラックの番号（1 始まり）。同じ番号のオーディオトラックに音声クリップが配置されます |

---

## `runtime` セクション

スクリプトの動作全般に関する設定です。

| キー | 型 | デフォルト | 説明 |
|---|---|---|---|
| `output_dir` | string | `""` | WAV の保存先ディレクトリ。指定したフォルダへ直接 WAV を保存します。空文字の場合はスクリプトと同じディレクトリに保存します |
| `log_path` | string | `"./run.log"` | ログファイルの出力先パス |
