# VoiceSeparationKit

音声から**人の声**と**それ以外（効果音・環境音など）**を分ける Swift パッケージ。
学習済みモデルを使わず、信号処理（STFT・声の高さの追跡・倍音の除去）だけで動く。外部依存はない。

> **English summary** — A dependency-free Swift package that splits audio into "human voice" and "everything else
> (sound effects, ambience)". It tracks the fundamental frequency of speech and removes its harmonics from the
> spectrogram; no machine-learning model is bundled. An optional companion target asks Apple's SoundAnalysis
> *when* speech is present so that sound effects outside speech are left untouched. It is **not** a
> neural-network separator: see "できないこと" for the honest limits.

## 何ができて、何ができないか

| できること | できないこと |
|---|---|
| 母音・有声子音（声帯が震える音）の除去。合成の話し声で 95〜99%（−13〜−19 dB）のエネルギーが消える | 息の音・「s」「f」のような無声子音の完全な除去（弱めるだけ） |
| 声が無い区間の効果音を壊さない（`VoiceActivity` を与えたとき、ほぼ無傷） | 声と**同じ周波数で同時に**鳴る音（笛・電子音・楽器）の保護。声の倍音と重なる所は一緒に削れる |
| 声と同時に鳴る雑音・衝撃音をなるべく残す（谷の高さまでしか削らない） | 複数人が同時に話す声の分離（いちばん目立つ 1 人の高さを追う） |
| ステレオの左右の違いを保つ | 歌声の分離・楽曲のステム分離（Demucs などの学習型の領域） |
| 声以外を「音楽」と「効果音」に分ける API（`separateComponents`）を持つ | **音楽と効果音を、実用になる精度で見分けること**（下の「音楽と効果音」参照） |

**学習型の分離器（Demucs・Spleeter など）ほどは分けられない。** 声の除去量は声によって違う（下の測定を参照）。
音楽用の分離器が欲しいなら、それらを使うこと。

## 使い方

```swift
import VoiceSeparation

let signal = AudioSignal(sampleRate: 44_100, channels: [left, right])   // [Float] の配列
let result = VoiceSeparator().separate(signal)

result.background   // 声を取り除いた音（効果音・環境音）
result.voice        // 取り除いた声。voice + background は入力に一致する
result.pitch        // 声の高さの流れ（診断用）
```

声がどこにあるかが分かっているなら、`VoiceActivity` で教えると、声が無い所を壊さない。
Apple 標準の音分類（SoundAnalysis）で調べるのが `VoiceSeparationSoundAnalysis`：

```swift
import VoiceSeparation
import VoiceSeparationSoundAnalysis

let activity = try SpeechActivityDetector().detect(signal)        // 端末の中だけで動く
let result = VoiceSeparator().separate(signal, voiceActivity: activity)
```

**声の度合い（`voiceActivity`）は、事実上必須。** 与えないと、和音・笛・楽器のように倍音が整数倍に並ぶ音が、声と誤られて取り除かれる。

声・音楽・効果音の3つに分けるとき（音楽と効果音の見分けは、おおまか。下の「音楽と効果音」を必ず読むこと）：

```swift
let activities = try SpeechActivityDetector().detectActivities(signal)   // 声・音楽・効果音の度合い
let parts = VoiceSeparator().separateComponents(
  signal, voiceActivity: activities.voice, musicActivity: activities.music, effectsActivity: activities.effects
)
let withoutVoice = parts.mixed(voice: false, music: true, effects: true)   // 選んだ成分だけを足す
```

`SpeechActivityDetector` は、窓（既定 1 秒）より短い音では判断できず、値が空の `VoiceActivity` を返す。
その場合 `separate` は声の度合いを使わずに分ける。**声の判定が安定するよう、使いたい範囲の前後に 1〜2 秒の音を足して渡すとよい。**

Swift Package Manager：

```swift
.package(path: "Packages/VoiceSeparationKit"),   // 公開後は URL に差し替える
.product(name: "VoiceSeparation", package: "VoiceSeparationKit"),
.product(name: "VoiceSeparationSoundAnalysis", package: "VoiceSeparationKit"),   // 任意
```

対応: macOS 13+ / iOS 16+。`VoiceSeparation` は Foundation だけを使うので、SoundAnalysis が無い環境でもビルドできる。

## 仕組み

1. **STFT**（ハン窓・4096 点・1024 サンプルずつずらす）でスペクトルにする。FFT は Swift で書いた基数 2 の実装。
2. **声の高さの追跡**。基本周波数の候補（70〜450 Hz）ごとに、整数倍の位置の山と、その中間の谷の差（対数振幅）を、低い倍音から順に平均する。
   途中までの平均の最大を採る（高い倍音が無い声でも薄まらない）。雑音や衝撃音は山と谷の差が出ないので、声と誤られにくい。
   時間方向はビタビ法でつなぎ、声の有無も同時に決める。
3. **倍音の除去**。低い倍音の実測位置から倍音の間隔を精密に求め直し、各倍音の山の位置と、両側の谷（隣の倍音との中間の最小値）を実測する。
   谷から谷までを直線でつないだ高さを「声が無かったときの高さ」とみなし、山のまわりでそれを超える分だけを削る。
   倍音を丸ごと 0 にしないので、声と同時に鳴っていた雑音や、倍音の間にある音は残る。
   高域（1.5 kHz 以上）で周りの倍音より飛び抜けて強い山は、別の音が重なっているとみなし、声の分（周りの 2 倍まで）だけを削る。
4. 位相は入力のまま使い、逆 STFT で波形に戻す。声は入力から背景を引いたもの。

## 測定

合成音声（macOS の `say`）に、macOS のシステム効果音を混ぜ、混ぜる前の声と効果音も別に持って測った。
声だけ・効果音だけ・声と効果音が重なる区間がある 40 秒のステレオ音声。`SpeechActivityDetector` を併用。

| 声 | 声だけの区間で残る量 | 効果音だけの区間で残る量 | 重なり区間の効果音の SDR（入力 → 分離後、2 か所） |
|---|---|---|---|
| 日本語の女声（Kyoko） | −19.3 dB | −0.4 dB | −11.5 → **+0.4** / −11.4 → **+4.4** |
| 英語の女声（Samantha） | −16.9 dB | −0.4 dB | −19.6 → **−4.1** / −19.4 → **−3.3** |
| 英語の男声（Daniel） | −12.8 dB | −0.4 dB | −17.0 → **−5.0** / −16.8 → **−4.1** |
| 英語の男声（Fred、低くて機械的） | −16.2 dB | −0.4 dB | −15.5 → **−1.1** / −15.3 → **+0.2** |

読み方: 「声だけの区間で残る量」は小さい（負で大きい）ほど声が消えている。−13 dB は声のエネルギーの約 5%、−19 dB は約 1%。
SDR は大きいほど、効果音に近い。分離後も負の値が残るのは、声が効果音より十数 dB 大きい所で、取りきれなかった声がまだ効果音より大きいため（改善幅は 12〜16 dB）。

**この測定の限界**: 声は音声合成で、実際の録音ではない（実際の声は息の音・ゆらぎ・残響が多く、より難しい可能性が高い）。
効果音も数種類のシステム音だけ。声の種類（5 種類）と効果音の組み合わせも少ない。
**実際の動画でこの数値が出るとは限らない。** 残っている声の大半は、息の音・無声子音と、声の出始め・終わりの弱い枠。

速度（Apple M3、リリースビルド、ステレオ）: 3 秒の音で声の検出 約 90 ms + 分離 約 30 ms、12 秒で 約 190 ms + 約 130 ms（実時間の 26〜37 倍速）。
**デバッグビルドでは 10〜50 倍遅い**ので、実機の確認はリリースビルドで行うこと。

## 音楽と効果音（実用になる精度には届いていない）

声以外を音楽と効果音に分ける処理（`MusicEffectsSplitter`）は、**スペクトルで見分けているのではない**。
- 周波数の帯ごとに、前後 0.8 秒の強さの中央値を「鳴り続けている分」とみなし、その分を音楽、はみ出した分を効果音とする。
- 音楽の度合い（SoundAnalysis）が低い区間は、すべて効果音にする。
- 効果音の度合い（声でも音楽でもない分類の確からしさ）を与えると、「効果音が起きている区間の突発的な成分」だけを効果音とし、それ以外は音楽にする。

合成した背景音楽（撥弦楽器の和音・ドラム、120 BPM）・話し声・システム効果音を混ぜ、混ぜる前の3つと比べた（40 秒、SDR は大きいほど良い）：

| | 声 | 音楽 | 効果音 |
|---|---|---|---|
| 混ぜたまま | −0.2 | −0.3 | −14.9 |
| 鳴り続けるかだけで分ける | 6.1 | 1.4 | −9.3 |
| 効果音の度合いも使う（既定、しきい値 0.3/0.6） | 6.1 | 5.2 | **−0.8（効果音の出力がほぼ空）** |
| 同、しきい値 0.05/0.15 | 6.1 | 2.0 | −8.3 |

読み方: 効果音は、どの設定でも **0 dB を超えなかった**。「効果音の出力が空」（0 dB 付近）か、「音楽のドラムなどの突発音が混ざる」（−8 dB）かのどちらかで、効果音だけを取り出せてはいない。
音楽の SDR が高いのは、効果音が音楽より 12 dB 小さく、「ほぼ全部を音楽に入れた」だけで高く出るため。
**声の分離だけが、実際に効いている。** 音楽と効果音を実用的に分けるには、学習型のモデルが要る。

この測定の限界: 効果音は macOS のシステム音（電子音）で、SoundAnalysis が効果音と認識しにくい（「音楽」と判定する）。
衝撃・足音・ドアなどの実際の効果音では、効果音の度合いがもっと高く出て、結果が変わる可能性はあるが、確かめていない。

## 調整項目（`VoiceSeparationConfiguration`）

| 項目 | 既定 | 説明 |
|---|---|---|
| `fftSize` / `hopSize` | 4096 / 1024 | 長いほど低い声の倍音を分けられるが、声の高さが動く所はにじむ |
| `minimumPitch` / `maximumPitch` | 70 / 450 Hz | 声の基本周波数を探す範囲 |
| `voicingThreshold` | 0.45 | 声とみなす「倍音の山と谷の差」。小さいほど声を拾うが、効果音を声と誤る |
| `lowPitchBias` | 0.1 | 本来の数倍の高さを選ぶ誤りを減らすための、低い周波数への偏り |
| `maximumRemovedFrequency` | 5000 Hz | これより上の倍音は残す |
| `breathReduction` | 0.7 | 声の区間で高さが見つからない枠（息の音・子音）の高域を弱める量。同じ周波数の効果音も弱まる |
| `activityInfluence` | 1.0 | `VoiceActivity` を重く見る度合い。0 なら無視 |
| `removalStrength` | 1.0 | 声を取り除く強さ |
| `musicGateLow` / `musicGateHigh` | 0.4 / 0.7 | 音楽の度合いが、この範囲で、音楽を認める度合いが 0→1 になる |
| `effectsGateLow` / `effectsGateHigh` | 0.3 / 0.6 | 効果音の度合いが、この範囲で、突発成分を効果音とみなす度合いが 0→1 になる |
| `musicStationarySeconds` | 0.8 | 「鳴り続けている音」を見分ける、前後の長さ（秒） |

## テスト

```bash
swift test
```

合成した声（高さが動く・ビブラート・音節の強弱）と効果音（雑音の衝撃・電子音）での検証と、
macOS の `say` で作った本物の話し声を使う検出器のテストがある（`say` が無い環境では、そのテストは飛ばされる）。

## ライセンス

未設定。公開する前に決める。
