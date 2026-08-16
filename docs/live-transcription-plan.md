# Live recitation transcription → ayah matching — implementation plan

Status: implemented 2026-08-16 (§1-10 done, build green, ASR sanity-checked against `test.wav` — matches reference transcript word-for-word). Only §10.3 (manual mic test with a human reciting) remains — needs a person, not an agent. Written 2026-08-16 so a fresh session (zero prior context) can pick this up and execute directly. Everything needed is below — file paths, exact APIs, decisions, and why.

## 1. Goal

While the user is reciting (mic on), transcribe their speech on-device and figure out *which ayah* they're reciting, in close to real time. For this v1:
- Print the resolved ayah (`surah:ayah` + text) to **stdout** when identified.
- Show the live in-progress transcript in a **small** UI element (delegate exact visual design to the `ui-designer` agent during implementation — constraint is just "small", shouldn't compete with the existing accuracy/mistakes line in the recitation control).
- No real accuracy/mistakes scoring yet — that's a later step this unblocks.

## 2. Current app state (confirmed by direct exploration, 2026-08-15/16)

Repo: `/Users/luxbug/Work/Quran`, SwiftUI **macOS-only** app, `Quran.xcodeproj`, scheme `Quran`. Build with:
```
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project Quran.xcodeproj -scheme Quran -destination 'platform=macOS' build
```
(No Xcode GUI in this environment — hand-edit `project.pbxproj` for anything that would normally need Xcode's GUI, then verify with a real `xcodebuild` build. This pattern is already used/approved for this repo.)

**Swift files** (all under `Quran/`, which is a `PBXFileSystemSynchronizedRootGroup` — any file placed anywhere under `Quran/` is automatically picked up as a build/bundle member, no pbxproj edit needed for new files or resources placed there):
- `Quran/QuranApp.swift`, `Quran/ContentView.swift`, `Quran/QuranPageStore.swift`, `Quran/SVGPageView.swift`, `Quran/RecitationControlBar.swift`, `Quran/Color+Hex.swift`.
- `Quran/Resources/quran.sqlite` — already built (see §3).

**Zero audio/ML infrastructure exists yet**: no SPM dependencies at all (checked `project.pbxproj` for `XCRemoteSwiftPackageReference`/`XCSwiftPackageProductDependency` — none; only linked framework is `WebKit.framework`), no `AVFoundation`/`AVAudioEngine`/`Speech` imports anywhere, no entitlements file, no `NSMicrophoneUsageDescription`. **The app is NOT sandboxed** (no `ENABLE_APP_SANDBOX` in pbxproj). ~~mic access only needs an `NSMicrophoneUsageDescription` Info.plist key, not an entitlements file~~ **— wrong, corrected 2026-08-16**: `ENABLE_HARDENED_RUNTIME = YES` *is* set, and Hardened Runtime (independent of App Sandbox) requires the `com.apple.security.device.audio-input` entitlement before TCC will show the mic dialog at all — without it, TCC's "Policy disallows prompt" and silently denies every request, no dialog, ever, regardless of `NSMicrophoneUsageDescription`. Needed `Quran/Quran.entitlements` + `CODE_SIGN_ENTITLEMENTS` (see §9.2). App uses `GENERATE_INFOPLIST_FILE = YES` (no source Info.plist file to edit — add `INFOPLIST_KEY_NSMicrophoneUsageDescription` as a build setting instead, in both Debug and Release configs).

**Page-tracking state** — `ContentView.swift`:
```swift
@State private var rightPage = 1
```
(line ~14). This is the odd-numbered right page of a two-page spread; `rightPage + 1` is the left page. Changes only inside `commit(toward:width:)`. There is currently no external access point to this value — it's private `@State`. The live-transcription feature needs to read "what page(s) is the user currently on" (`rightPage` and `rightPage + 1`), so plumbing (a closure passed down, most likely) is needed.

**Recitation control integration point** — `ContentView.swift`:
```swift
@State private var recitationBar = RecitationBarState()
...
.overlay(alignment: .bottom) {
    RecitationControlBar(state: recitationBar) {
        // TODO: wire up live transcription start
        print("Start Reciting tapped")
    }
}
```
`RecitationControlBar.swift` has `@Observable final class RecitationBarState` with `isRecording`, `isPaused`, `elapsed`, `accuracy`, `mistakes` (`accuracy`/`mistakes` are currently mocked — comment: `// Mock values until real live-transcription scoring is wired up.`). The mic button's action is:
```swift
Button {
    onStartReciting()
    state.startRecording()
} label: { ... }
```
i.e. `onStartReciting` (the closure from `ContentView`) fires right before `state.startRecording()`. There is currently **no** corresponding stop/teardown closure — only `state.endRecording()` is called by the "Done" button, with no external hook. This plan adds a matching `onStopReciting` closure param to `RecitationControlBar`'s init so `ContentView` can tear down the audio session.

## 3. `quran.sqlite` (already built — do not rebuild unless MushafPages SVGs change)

Location: `Quran/Resources/quran.sqlite` (bundled automatically). Built by `scripts/build_database.py` (already exists and works; rerunnable). Schema:

```sql
CREATE TABLE surahs (
  number INTEGER PRIMARY KEY, name_arabic TEXT, name_simple TEXT, name_complex TEXT,
  name_translation TEXT, revelation_place TEXT, revelation_order INTEGER,
  bismillah_pre INTEGER, ayah_count INTEGER, start_page INTEGER, end_page INTEGER
);
CREATE TABLE pages (
  number INTEGER PRIMARY KEY, line_count INTEGER,
  first_surah INTEGER, first_ayah INTEGER, last_surah INTEGER, last_ayah INTEGER, juz_number INTEGER
);
CREATE TABLE ayahs (
  id INTEGER PRIMARY KEY,             -- surah*1000 + ayah_number
  surah INTEGER, ayah_number INTEGER,
  text_uthmani TEXT,                  -- full diacritized text
  text_imlaei TEXT,                   -- simplified, no diacritics — used for skeleton matching, see §7
  word_count INTEGER,
  start_page INTEGER, end_page INTEGER, start_line INTEGER, end_line INTEGER,
  juz_number INTEGER, hizb_number INTEGER, rub_el_hizb_number INTEGER, manzil_number INTEGER, ruku_number INTEGER,
  is_sajda INTEGER, sajda_type TEXT,
  UNIQUE(surah, ayah_number)
);
CREATE TABLE words (
  id INTEGER PRIMARY KEY AUTOINCREMENT, surah INTEGER, ayah_number INTEGER, word_index INTEGER,
  page INTEGER, line INTEGER, text_uthmani TEXT, text_imlaei TEXT,
  word_type TEXT,                     -- 'word' | 'waqf' | 'juz-star' | 'sajda-mehrab'
  waqf_kind TEXT, is_waw_alatf INTEGER, svg_element_id TEXT
);
```
6236 ayahs, 114 surahs, 604 pages, 91451 words. `ayahs.text_imlaei` is the column matched against (skeleton, harakat-stripped) to identify the ayah; `ayahs.text_uthmani` is used separately for the non-blocking tashkeel-correctness check and for display — see §7, final design 2026-08-16.

## 4. The ASR model (already exported and validated — files exist on disk)

`onnx-export/` (all files already present, already validated end-to-end in Python):
| File | Size |
|---|---|
| `encoder.int8.onnx` | ~125MB |
| `decoder.int8.onnx` | ~3.8MB |
| `joiner.int8.onnx` | ~1.3MB |
| `tokens.txt` | 1025 lines: SentencePiece BPE vocab (Arabic **with diacritics/tashkeel**) + `<blk>` blank token |
| `test.wav` | known-good test audio |

Source model: NeMo `EncDecHybridRNNTCTCBPEModel` (FastConformer-RNNT, HuggingFace `mohammed/fastconformer-quran-ar`, checkpoint `phase3_full/phase3_full_wer0.0014.nemo`), only the RNNT branch exported (CTC branch dropped). Key facts:
- **16kHz mono** input, **80 mel bins**, subsampling factor 8.
- **This is an OFFLINE/full-context model, not true streaming** — the encoder ONNX graph has no cache-state input/output tensors. Greedy RNNT decoding (`greedy_batch`, `max_symbols_per_step: 10`) was used for export/validation.
- Feature extraction must match NeMo's training-time convention exactly or output is silently garbled (not a crash) — see §5 for the exact required config, already solved.
- Use the **int8** quantized files (smaller, already validated to produce correct output).

## 5. Reference implementation already exists — `~/Work/tarteel/` (sibling dir, NOT in this git repo)

**Read these files before writing any Swift ASR code.** This is a machine-local sibling checkout at `/Users/luxbug/Work/tarteel/` (outside `/Users/luxbug/Work/Quran`, not version-controlled with this repo) containing already-validated Python prototypes:
- `live_transcribe_onnx.py` — the actual reference for the live loop: mic → buffer → periodic full re-decode via onnxruntime directly (not sherpa-onnx). Confirms:
  - Growing-buffer + periodic full re-decode pattern (not true streaming) is the *correct, deliberate, already-validated* design — not a limitation to work around.
  - `transcript_onnx.log` in that directory is a real captured session showing correct, continuous, multi-ayah, cross-surah transcription with no reset — proof this approach works in practice, not just theory.
  - **Exact required feature-extraction config** (`kaldi_native_fbank.FbankOptions`), hard-won ("we already hit and fixed [framing bugs]" per the docstring):
    ```python
    opts.frame_opts.dither = 0
    opts.frame_opts.remove_dc_offset = False
    opts.frame_opts.window_type = "hann"
    opts.mel_opts.low_freq = 0
    opts.mel_opts.num_bins = 80
    opts.mel_opts.is_librosa = True
    ```
    plus post-hoc per-utterance mean/std normalization (`normalize_type = "per_feature"`, read from the ONNX model's embedded metadata).
  - Interval: 0.5s between re-decode passes; keep the longest transcript seen across passes (a re-decode can occasionally come back shorter mid-word — never let the displayed/matched text shrink).
- `live_transcribe_nemo.py` — same pattern via the raw NeMo model (slower, reference/accuracy baseline). Its docstring explains *why* offline-redecode was chosen over true streaming: NeMo's own cache-aware streaming mode is buggy/incomplete per the model card, and a genuinely-streaming alternative model (`Muno459/fastconformer-quran-streaming`) has much worse accuracy (~20% WER) vs. this model's near-perfect accuracy. This tradeoff is already settled, not open.
- `transcribe_offline_nemo.py` — trivial one-shot offline transcribe, useful as a sanity CLI.

## 6. Swift ASR integration: sherpa-onnx, `model_type = "nemo_transducer"`

Use **k2-fsa/sherpa-onnx**'s Swift package (confirmed real, at `https://github.com/k2-fsa/sherpa-onnx`, `Package.swift` at repo root, product name `sherpa-onnx`, platforms `.iOS(.v15)`/`.macOS(.v10_15)` — compatible with this project's `MACOSX_DEPLOYMENT_TARGET = 14.0`). It ships prebuilt xcframeworks (static or shared) downloaded from GitHub Releases on first SPM resolve, plus an `onnxruntime-libs` dependency — sizable one-time download.

**Critical, already-confirmed-by-reading-the-source detail**: sherpa-onnx has TWO offline-transducer model types sharing the same `SherpaOnnxOfflineTransducerModelConfig` struct (encoder/decoder/joiner paths):
- `modelType: "transducer"` — generic, defaults to Kaldi-style features (povey window, `is_librosa=false`, DC offset removed, `low_freq=20`). **Wrong for this model** — would silently produce garbled output, same class of bug §5's Python scripts already fixed.
- `modelType: "nemo_transducer"` — dispatches internally to `OfflineRecognizerTransducerNeMoImpl` (confirmed in sherpa-onnx's C++ source, `offline-recognizer-impl.cc`), whose documented supported-model list explicitly includes **`EncDecHybridRNNTCTCBPEModel`** (our exact NeMo model class) alongside Parakeet/Canary. The official usage example for this exact struct shape in sherpa-onnx's `c-api.h` is literally a Parakeet TDT model (same encoder/decoder/joiner/tokens.txt shape). **Use this one.**

Swift usage (confirmed against sherpa-onnx's actual `swift-api-examples/SherpaOnnx.swift` wrapper source):
```swift
let transducer = sherpaOnnxOfflineTransducerModelConfig(
    encoder: encoderPath, decoder: decoderPath, joiner: joinerPath
)
let modelConfig = sherpaOnnxOfflineModelConfig(
    tokens: tokensPath, transducer: transducer, modelType: "nemo_transducer"
)
let featConfig = sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80)
var config = sherpaOnnxOfflineRecognizerConfig(featConfig: featConfig, modelConfig: modelConfig)
let recognizer = SherpaOnnxOfflineRecognizer(config: &config)
// ...
let result = recognizer.decode(samples: floatArray, sampleRate: 16000)
print(result.text)
```
`decode(samples:sampleRate:)` is a blocking call — run off the main thread. Before trusting live mic input, **sanity-check this exact path against `onnx-export/test.wav`** and diff the output against `~/Work/tarteel/transcript_onnx.log` / `nemo_ref.log`'s known-correct text (see §9 Verification) — this confirms `nemo_transducer` is really giving correct NeMo-style features in the actual linked build, not just in theory.

## 7. Matching algorithm (final design, revised 2026-08-16 twice — see history below)

**Final design**: two-tier, superseding both the original (§7v1, harakat-stripped-only) and an intermediate (§7v2, harakat-strict-only) approach — see "Design history" below for why each was replaced.

**Tier 1 — candidate search, harakat-stripped ("skeleton")**: forgiving by design, since a single wrong diacritic (or a representation difference between the ASR's plain-Arabic output and QUL's Uthmani-script text — see below) must never block recognizing *which ayah* is being recited.
- `normalizeArabicSkeleton(_:)` (`Quran/Data/ArabicNormalization.swift`): strips all diacritics (U+0610–U+061A, U+064B–U+065F, U+0670, U+06D6–U+06ED), strips tatweel (U+0640), folds `أ/إ/آ/ٱ` → `ا`, collapses/trims whitespace.
- Applied to `ayahs.text_imlaei` (already diacritic-free) for the database side, and to the ASR transcript for the live side.
- `QuranDatabase.candidates(forSkeletonSubstring:)` does the substring scan.

**Tier 2 — tashkeel-correctness check, harakat-aware, non-blocking**: once an ayah is already identified via Tier 1, a *separate* per-word comparison flags diacritic mistakes without ever stalling recognition — a foundation for a future accuracy/mistakes counter (not implemented yet; today it just `print`s mismatches).
- `normalizeArabicTashkeel(_:)`: keeps only the 8 standard diacritics the ASR's vocabulary can actually produce (U+064B–U+0652 — confirmed by inspecting `onnx-export/tokens.txt`: the model's vocab is plain Arabic letters + these 8 marks + hamza-carrying letters, nothing else). Maps the two QUL-only marks that carry real phonetic content to their standard equivalents (U+06E1, Uthmani's small-high-rounded-zero used as sukun → U+0652 standard sukun; U+0670 superscript alef, an elongation the ASR can only spell as a full letter → U+0627 alef). Strips everything else Quran-specific and non-phonetic that the ASR could never produce anyway (waqf/pause signs, idgham/iqlab indicator letters, honorific marks — the rest of U+0610–U+061A, U+0653–U+065F, U+06D6–U+06ED). Folds alif variants, strips tatweel, collapses whitespace, and — critically — **canonicalizes combining-mark order via NFC** (`.precomposedStringWithCanonicalMapping`): the ASR and QUL can encode the same sound (e.g. "رُّ") with shadda and the vowel mark in different Unicode order, which renders identically but compares unequal without this.
- Applied to `ayahs.text_uthmani` (full diacritics), split into `Ayah.tashkeelWords: [String]`.

**Matching loop** (`Quran/Recitation/AyahMatcher.swift`'s `attemptAyahMatch`, called from `RecitationSession.tick()` every ~0.5s and reused verbatim by offline tests — keep it a pure function, no session state, so it stays independently testable):
1. Maintain a **word-indexed cursor** (not a character offset — character offsets don't survive the skeleton/tashkeel dual-normalization cleanly) into `normalizeArabicTashkeel(transcript).split(separator: " ")`.
2. `tailWords` = words from the cursor onward. **Skip matching if fewer than 3 words** (known gap: this means ayahs shorter than 3 words, e.g. muqatta'at like "الم", can never resolve standalone — pre-existing in the original design too, not introduced by the rewrites below; not fixed, flag to the user before touching).
3. `candidates` = ayahs whose skeleton **contains** `normalizeArabicSkeleton(tailWords.joined)` as a substring, at any position (not prefix-only).
4. Resolution: unique on-page match wins immediately; else a unique global match; else (zero or ambiguous) don't resolve this tick.
5. **On no match**: leave the cursor alone (don't discard the tail) so the next tick retries with more context as the reciter keeps talking — see "Design history" for why this replaced resync-to-end. **Exception**: if the tail has grown past 20 words with zero candidates, drop just the oldest word (cursor += 1) instead of waiting forever — otherwise a single unmatchable leading token (e.g. the ASR gluing two ayahs together with no space) would block all future progress permanently, since a substring search can never skip past a leading token it can't place.
6. On resolve: run the Tier 2 tashkeel check over `min(tailWords.count, ayah.tashkeelWords.count)` words (print-only for now), print `"\(surah):\(ayahNumber)  \(textUthmani)"`, advance the cursor by `ayah.tashkeelWords.count` (not to the full tail end — any extra already-spoken words beyond this ayah stay in the tail so the *next* ayah can still be found in them).

**Audio buffer is a rolling 30-second window** (older samples dropped as new ones arrive), not left to grow unboundedly for the whole session — this bounds re-decode cost. (Deliberately accepted tradeoff: could truncate the very start of an unusually long ayah if the reciter pauses a long time beforehand — the alternative, letting the buffer grow for the whole session, was validated to work by `~/Work/tarteel/transcript_onnx.log` but has unbounded compute growth; 30s rolling was chosen over both a full reset-per-ayah and unbounded growth.)

**Database fix required alongside this** (`scripts/build_database.py`, rerun and re-copied to `Quran/Resources/quran.sqlite` on 2026-08-16): the `words` table already flagged proclitic `وَ` words with `is_waw_alatf=1`, but the ayah-level `text_uthmani`/`text_imlaei` fields were built with a naive `" ".join(...)` that inserted a space before them anyway (`"وَ هُم"` instead of the correct `"وَهُمْ"`) — real Arabic never separates that prefix. Added a `join_words()` helper that skips the space after any `is_waw_alatf` word. This affected matching regardless of harakat mode (it's a data bug, not a normalization one) and touches a large fraction of ayat, since `و` is extremely common.

### Matching algorithm v2 (2026-08-16, later same day) — whole-Quran continuity, muqatta'at, single-word-on-page

Three gaps closed after the v3 design above shipped, all in `attemptAyahMatch` (`Quran/Recitation/AyahMatcher.swift`) and `QuranDatabase.swift`, per user request — full plan at `/Users/luxbug/.claude/plans/lets-work-on-the-clever-bubble.md`:

1. **Cross-ayah-boundary starts**: if the reciter's very first captured words straddle an ayah boundary (e.g. last 2 words of ayah N + first 2 of N+1, before anything has resolved), no single ayah's skeleton contains the whole tail. Fixed by `QuranDatabase.ayahPairs` — every canonically-adjacent ayah pair (surah boundaries included), each with a `joinedSkeleton`. When the normal single-ayah search finds nothing, `pairCandidates(forSkeletonSubstring:)` is tried; on a unique hit, resolves to the **earlier** ayah of the pair only (cursor advances by just that ayah's word count, leaving the next ayah's already-captured start words in the tail for the following tick).
2. **Muqatta'at glomming**: no real speech pause after a disconnected-letters token (e.g. "الم"), so the ASR can glue it onto whatever follows ("المذلك..."), matching neither ayah under normal space-aware matching. Fixed with a **targeted** (not general) hardcoded table of the ~30 known muqatta'at-opening `(surah, ayah)` pairs (`QuranDatabase.muqattaatEntries`, `muqattaatAyahs`) — deliberately narrow per user's explicit choice over a general space-insensitive mode. Each entry pairs the muqatta'at letters with just the **single word immediately following them** (not the whole rest of the ayah/next ayah) — some muqatta'at ayahs are composite (e.g. 14:1 "الر ۚ كتاب..." carries real text after the letters, in the *same* ayah), and matching against a full ayah's worth of text risked false-positive substring collisions with unrelated common words elsewhere in the transcript (caught by testing — see below). Matched via `stripped.contains(entry.strippedJoined)` (tail contains the short signature, not the reverse) so it keeps matching as the tail grows across ticks, not just on the very first one.
3. **Single-word resolution when the page is already open**: `currentPages` already narrows candidates to a handful of ayahs, so a single unique on-page word now resolves immediately, bypassing the old 3-word minimum — tried before the muqatta'at fallback and before the 3-word gate.

**Testing found one real pre-existing Tier-1 gap, left unfixed (flag before touching)**: `normalizeArabicSkeleton` strips a Uthmani dagger-alef (U+0670) as a diacritic when applied to *raw* Uthmani/Imlaei text — but the live pipeline applies it to text that already went through `normalizeArabicTashkeel` first (needed for the Tier-2 word array), which **converts** U+0670 into a real alif *letter* (U+0627) rather than deleting it (since "the ASR can only spell it as a full letter" — see Tier 2 above). So for any word where Uthmani spells a long vowel via dagger-alef but Imlaei's spelling omits the letter entirely (e.g. "ذَٰلِكَ" → tashkeel-then-skeleton yields "ذالك", 4 letters, vs. `text_imlaei`'s "ذلك", 3 letters), Tier-1 substring matching can silently fail. Confirmed via `QuranTests/AyahMatcherTests.swift`'s muqatta'at test, which had to be rewritten to build its synthetic tail from skeleton words instead of tashkeel words to sidestep this. Pre-existing in the v3 design, not introduced by v2 — a real fix belongs in `normalizeArabicSkeleton` or the pipeline that feeds it, and needs its own design discussion (how common this is across the whole Quran isn't yet measured).

### Design history (why this took three passes)

- **§7v1 (original plan, this file's first draft)**: harakat-stripped only, matched against `text_imlaei`. Never actually mic-tested until 2026-08-16.
- **§7v2 (first revision, same day)**: user asked to make matching harakat-aware; implemented as *strict* full-harakat matching against `text_uthmani`, discarding the tail on any miss. First real mic test (Al-Ikhlas, "قُلْ هُوَ اللَّهُ أَحَدٌ") produced zero candidates every time. Root-caused through several distinct bugs, in order found:
  1. **Discard-tail-on-miss** meant any single miss only ever left 3-ish fresh words to retry with — user's own fix suggestion, implemented first: stop discarding, let the tail grow.
  2. **Unicode codepoint mismatch**: QUL's Uthmani text uses Quran-specific marks (`U+06E1` alternate sukun, `U+0670` superscript alef, `U+06D6`–`U+06ED` waqf/annotation marks) that literally don't exist in the ASR's vocabulary (confirmed by inspecting `tokens.txt` — only U+064B–U+0652 present). Exact matching against raw `text_uthmani` could never fully succeed regardless of ASR accuracy.
  3. **Database join bug**: the `is_waw_alatf` spacing bug above, found by diffing a specific mismatch (`"وَ هُم"` vs `"وَهُمْ"`).
  4. **Combining-mark order**: shadda-then-vowel vs vowel-then-shadda encodings of the same sound compared unequal without NFC normalization.
  5. Even after fixing 2–4, strict full-harakat matching remained fragile in principle: diacritic-level ASR accuracy is generally lower than word-level accuracy, so requiring an *exact* harakat match across a growing multi-word tail means almost any single diacritic slip anywhere in it blocks resolution.
- **§7v3 (this section, final)**: user proposed splitting the concerns — skeleton match to find the ayah (robust), separate non-blocking per-word tashkeel check to flag correctness (strict, but never blocks). Validated end-to-end: Python prototype confirmed all 6 tested ayat (Surah 30:1–6) skeleton-match their known-correct ASR reference transcript exactly; Swift-side `attemptAyahMatch` confirmed via a temporary self-test to correctly resolve Al-Ikhlas 112:1 from the user's actual live ASR output. Self-test files removed after verification (`Quran/DebugMatchSelfTest.swift`, `QURAN_MATCH_SELFTEST`/`QURAN_TEXT_MATCH_SELFTEST` env vars) — this repo has no permanent test target yet.

## 8. Files to add/modify

All new files go under `Quran/` (auto-bundled/auto-compiled via the existing synced-folder group — no pbxproj edit needed for new Swift files or new resource files placed anywhere under `Quran/`).

**New:**
- `Quran/Audio/MicrophoneCapture.swift` — `AVAudioEngine` input tap; converts to 16kHz mono Float32 (input node's native format is whatever the device gives, typically 44.1/48kHz — needs an `AVAudioConverter`); maintains the rolling 30s buffer; `start()`/`stop()`.
- `Quran/ASR/QuranTranscriber.swift` — wraps sherpa-onnx as in §6. Model files (`encoder.int8.onnx`, `decoder.int8.onnx`, `joiner.int8.onnx`, `tokens.txt`) copied from `onnx-export/` into `Quran/Resources/`.
- `Quran/Data/ArabicNormalization.swift` — `normalizeArabicSkeleton(_:)` and `normalizeArabicTashkeel(_:)` per §7.
- `Quran/Data/QuranDatabase.swift` — opens `quran.sqlite` via the raw `SQLite3` C API (need to link `libsqlite3.tbd`, see §9), loads all 6236 ayahs once at launch into `struct Ayah { id, surah, ayahNumber, textUthmani, skeletonText, tashkeelWords, startPage, endPage }`, exposes `func candidates(forSkeletonSubstring:) -> [Ayah]`.
- `Quran/Recitation/AyahMatcher.swift` — pure, stateless `attemptAyahMatch(words:cursor:database:currentPages:) -> AyahMatchAttempt` implementing the §7 matching loop; kept separate from `RecitationSession` specifically so it's independently testable without a live mic session.
- `Quran/Recitation/RecitationSession.swift` — orchestrates §7: owns `MicrophoneCapture` + `QuranTranscriber` + the word cursor, a repeating `Task` (~0.5s) that calls `attemptAyahMatch`, reads current page via an injected `() -> ClosedRange<Int>` closure, updates `RecitationBarState.liveTranscript`, prints on resolve. `start()`/`stop()`.

**Modified:**
- `Quran/RecitationControlBar.swift` — add `var liveTranscript: String = ""` to `RecitationBarState`. Add a small transcript label somewhere in `recordingContent` — **use the `ui-designer` agent for the exact placement/styling**, constraint: small, must not compete visually with the existing accuracy/mistakes line. Add an `onStopReciting: () -> Void` closure param to `RecitationControlBar`'s init (mirrors existing `onStartReciting`), called from the "Done" button alongside `state.endRecording()`.
- `Quran/ContentView.swift` — replace the `// TODO: wire up live transcription start` closure: construct a `RecitationSession` on start (pass `{ rightPage...(rightPage+1) }` and `recitationBar`), call `.start()`; call `.stop()` from the new `onStopReciting` closure. Needs `rightPage` readable from a closure (it already is, since the closure captures `self`/the view's state — no additional plumbing needed beyond passing the closure itself into `RecitationControlBar`).

## 9. Xcode project changes (hand-edit `project.pbxproj`, verify with `xcodebuild`)

1. **SPM dependency**: add `XCRemoteSwiftPackageReference` for `https://github.com/k2-fsa/sherpa-onnx` + `XCSwiftPackageProductDependency` for product `sherpa-onnx`, wired into the `Quran` target's `packageProductDependencies` and the project's `packageReferences`.
2. **Mic permission**: add `INFOPLIST_KEY_NSMicrophoneUsageDescription = "..."` to both Debug and Release build settings (no source Info.plist exists — `GENERATE_INFOPLIST_FILE = YES`). ~~No entitlements file needed (app isn't sandboxed)~~ **— wrong, corrected 2026-08-16**: also required `Quran/Quran.entitlements` (`com.apple.security.device.audio-input = true`) + `CODE_SIGN_ENTITLEMENTS = Quran/Quran.entitlements` in both Debug/Release target configs — `ENABLE_HARDENED_RUNTIME = YES` demands this entitlement independent of App Sandbox, or TCC refuses to ever show the mic dialog (see §2 for the full story of how this was diagnosed).
3. **SQLite linking**: add `libsqlite3.tbd` to the target's linked libraries (same pattern already used for the existing `WebKit.framework` reference in pbxproj).
4. Copy `onnx-export/encoder.int8.onnx`, `decoder.int8.onnx`, `joiner.int8.onnx`, `tokens.txt` into `Quran/Resources/`.
5. **(Hit during implementation, not anticipated above) Codesign fix for a broken upstream xcframework — fixed twice, see below for the final version**: sherpa-onnx's SPM package pulls in `csukuangfj/onnxruntime-libs`, whose macOS `onnxruntime.xcframework` (and `SherpaOnnxC.framework`) has a malformed versioned-bundle layout — `Versions/Current` (and top-level items like `Headers`/`Resources`/the binary) land as real, duplicated files/dirs instead of symlinks into `Versions/A`, because the upstream zip didn't preserve symlinks. This makes the final app-level `codesign` fail with `code object is not signed at all` / `bundle format is ambiguous (could be app or framework)` for these frameworks once Xcode embeds them. Also required `ENABLE_USER_SCRIPT_SANDBOXING = NO` on the target's Debug/Release configs (the default sandboxed script phase silently no-ops writes into the app bundle).
   - **v1 (delete-based, superseded)**: a `PBXShellScriptBuildPhase`, appended last in `Quran`'s `buildPhases`, `alwaysOutOfDate = 1`, that just `rm -rf`'d the broken copies from `Contents/Frameworks` (they're pure build-system vestige — the actual code is already statically linked into `Quran.debug.dylib`). Worked for plain repeated `build`s, but once a `QuranTests` unit-test target existed (2026-08-16), an `xcodebuild test` run — or, worse, a **plain `xcodebuild build` run immediately after a `test` run, including from Xcode's GUI** — could re-materialize the broken frameworks *after* this script had already run (or been skipped as "up to date"; the exact xcodebuild/llbuild incremental-caching trigger was never fully pinned down). An interim fix (a second delete script as `QuranTests`'s own last build phase) narrowed but didn't close the gap — GUI builds still hit it.
   - **v2 (repair-the-source, current, fixes the GUI case too)**: root-caused properly — the *source* xcframework artifacts under DerivedData's `SourcePackages/artifacts/` are themselves broken (confirmed by inspecting them directly: real dirs instead of symlinks, same as the embedded copies), so **every** copy Xcode makes from them inherits the brokenness, regardless of which target's build phases ran or in what order — deleting/repairing only the destination was always racing an uncontrollable, internal SPM-embed step. The `Quran` target's script (still the one `alwaysOutOfDate = 1` phase, `QuranTests`'s extra phase was removed as no longer needed) now: (1) walks `$BUILD_ROOT/../../SourcePackages/artifacts` and repairs+ad-hoc-signs every `*.framework` it finds there (the canonical `Versions/Current → A` symlink plus each top-level item that mirrors something in `Versions/A`), then (2) does the same repair (not delete) for whatever's already been embedded into `Contents/Frameworks` this run, as a defensive fallback. Since the *source* is fixed first, subsequent embeds — whenever and however many times they happen — are correct by construction, which is what actually closes the GUI-build and test→build cases. Verified 2026-08-16 against a **fully wiped DerivedData** (so the source artifacts were freshly re-downloaded and broken again): `build` → `test` → `build` → `test` → `build` → `test`, no `clean` in between, all six succeeded.
   - Uses `find | while read` (not `while read < <(...)`) since `shellPath = /bin/sh` doesn't support process substitution — hit and fixed once already, worth remembering if editing this script again.
   - **Don't remove this script phase** — without it the build fails at the final CodeSign step. If a future sherpa-onnx/onnxruntime-libs release fixes their packaging, this becomes a harmless no-op (every repair step checks `[ ! -L ... ]`/existence before touching anything).

## 10. Verification

1. `xcodebuild -resolvePackageDependencies` then:
   ```
   export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
   xcodebuild -project Quran.xcodeproj -scheme Quran -destination 'platform=macOS' build
   ```
   Confirms the SPM package resolves/links, model files + sqlite bundle correctly, everything compiles. **Done 2026-08-16, BUILD SUCCEEDED.**
2. **Before trusting live mic input**: sanity-check `model_type = "nemo_transducer"` against `onnx-export/test.wav`, diff against `~/Work/tarteel/transcript_onnx.log` / `nemo_ref.log`'s known-correct text. If it doesn't match, the feature-extraction path isn't matching NeMo conventions and needs deeper investigation (possibly hand-porting the exact `kaldi_native_fbank` config from §5 instead of relying on sherpa-onnx's internal NeMo handling). **Done 2026-08-16**, via a temporary env-var-gated self-test hook (`QuranTranscriber().transcribe(samples:)` fed `test.wav`'s raw PCM, removed after use) run through the actual built binary — output matched `onnx_int8.log`'s reference transcript word-for-word across the whole ~82s/multi-ayah clip (one harakat-level diacritic difference in the very first word, nothing else). Confirms `nemo_transducer` is wired correctly end-to-end in the real Swift/sherpa-onnx build, not just in the Python prototype.
3. **Still open** — manual, needs a human with a mic (an agent can't recite): launch the built app, tap "Start Reciting", grant the mic permission prompt, recite a few known consecutive ayat aloud, confirm the small live-transcript UI updates and the console prints each resolved `surah:ayah` in turn.
4. **`QuranTests` regression suite** (added 2026-08-16 for the v2 matching fixes above): `QuranTests/AyahMatcherTests.swift`, 6 cases covering mid-ayah start, cross-ayah-boundary start, muqatta'at glomming, single-word-on-page (both resolving and correctly *not* resolving off-page), and an ambiguity guard. Run via:
   ```
   export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
   xcodebuild -project Quran.xcodeproj -scheme Quran -destination 'platform=macOS' test
   ```
   (`clean` is no longer required first — see §9.5's "v2 (repair-the-source)" fix.)
   **Done 2026-08-16, all 6 pass.**

## 11. Known accepted limitations (not bugs, don't "fix" without asking)

- No visible error state when nothing matches — silent.
- Rolling 30s audio window can truncate an unusually long ayah's start if the reciter pauses a long time before starting it.
- No index on the ayah substring search — linear scan over 6236 ayahs (plus ~6235 pairs, ~30 muqatta'at entries) every ~0.5s tick. Fine at this size, just noting it's not optimized.
- **The 20-word stuck-tail cap** (§7 step 5) that drops the oldest word after 20 words with zero candidates is a blunt instrument — it recovers from one bad leading word, but a *second* bad word shortly after would need another ~20-word wait before the next drop. Not yet an issue in testing; revisit if live use shows it's too slow to recover.
- **Tier-1 dagger-alef representation gap** (found 2026-08-16 while testing the v2 fixes, not fixed — see "Matching algorithm v2" above for the full mechanism): `normalizeArabicSkeleton` applied to already-tashkeel-normalized live-transcript text can retain an extra alif letter that the database's `text_imlaei`-derived skeleton never has, for any word where Uthmani spells a long vowel via dagger-alef (U+0670). Could cause real matching misses for such words on a fresh, unresolved tail — not yet measured how common this is across the Quran.
- Superseded by the "Matching algorithm v2" section above (kept here only as a pointer, not restated): the old 3-word minimum and single-ayah-only substring search no longer apply as unconditionally as this section originally described — muqatta'at, cross-ayah-boundary, and single-word-on-page cases now have dedicated fallbacks.
