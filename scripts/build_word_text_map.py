#!/usr/bin/env python3
"""Precompute global_word_idx -> real Uthmani word text.

The shipped corpus (ordered_quran_phonemes.json) segments each ayah into
phoneme-words for ASR matching, but that segmentation doesn't line up 1:1
with written words -- Tajweed liaison rules merge some adjacent written
words into one phoneme unit (e.g. "مِن قَبْلِكَ" -> one unit), and
muqatta'at letters split one written word into several (e.g. "الٓمٓ" ->
two). So there's no direct way to say "phoneme-word #3 is written word
#3".

This resolves it in two steps, both done here (once, offline) rather than
live:
1. Exact: quran-transcript's own phonetizer (github.com/obadx/quran-transcript,
   already installed -- it's literally the tool that produced the
   corpus's training labels per the model card) exposes a per-input-char
   position mapping (`mappings`) from its phonetization output. Used to
   derive, precisely, which output phoneme span corresponds to each
   written word -- not by naively splitting on spaces (liaison can fuse
   two written words' output together with no space at all).
2. Fuzzy: quran-transcript's phoneme rendering doesn't exactly match this
   corpus's own (different muqatta'at handling, minor spelling/madd
   convention differences even with matched moshaf settings) -- verified
   by direct testing, not assumed. So step 1's per-written-word phoneme
   groups are aligned against the corpus's aya_phonemes_list via a
   word-level edit-distance DP (rapidfuzz-scored), not a strict
   positional match. Mismatches here are typically small and localized
   (an occasional adjacent-word merge), not wholesale restructuring --
   also verified empirically before committing to this approach.

3. Split: for a corpus phoneme-word that covers *multiple* written words
   (the merge case), align/word_split.split_merged_unit does a further
   character-level DP between the corpus word's own phoneme string and
   the concatenation of its qt phoneme groups, to find the real split
   points inside it -- so each written word gets its own phoneme
   sub-span in the corpus's native convention (what the ASR was trained
   on), not just a merged text label. Confidence-gated (MIN_SPLIT_
   CONFIDENCE); below threshold, the unit is kept as one indivisible
   entry rather than guessing wrong boundaries -- see REPORT_PATH.

Output: models/word_text_map.json, a list indexed by (original corpus)
global_word_idx. Each entry is either null (couldn't be confidently
mapped -- logged, not guessed at) or
{"words": [{"text": ..., "phoneme_text": ..., "isolated_phoneme_text": ...,
"continued_phoneme_text": ...}, ...], "continues_previous": bool}.
"isolated_phoneme_text" is that word's own phonetic rendering computed on
its own (see isolated_phonemes()) -- used by align/word_aligner.py to
recover cross-word tajweed-liaison bleed and pause-dropped endings without
needing any context from neighboring words. "continued_phoneme_text" is
null for every word except an ayah's true last one, where it's that word's
rendering if recitation continues straight into the next ayah rather than
pausing there (see last_word_continued_phonemes) -- this corpus phonetizes
every ayah's text alone, so phoneme_text for an ayah-final word always
assumes a pause, which isn't the only valid way to recite past it.
"words" has one entry per real written word this corpus unit resolves to
(more than one only when the split in step 3 succeeded; otherwise a
single entry whose "text" may still be multiple space-joined written
words, same as before that step existed). "continues_previous" is true
when this corpus phoneme-word is part of the *same* real written word as
the immediately preceding global_word_idx (a muqatta'at split, e.g.
"الٓمٓ" spans two phoneme-word units both carrying continues_previous
split across them) -- consumers must treat a continues_previous run as
one logical word, not report each unit as if it were a separate word.

models/word_text_map_overrides.json (optional, hand-maintained -- never
generated) can supply manual fixes for ayahs the automated split
couldn't resolve confidently: same per-entry shape as the main output,
keyed by global_word_idx as a JSON string. Applied on top of the
automated result on every run, so it survives regeneration.
"""

import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

import quran_transcript as qt
import quran_transcript.phonetics.tajweed_rulses as qt_tajweed_rules
from rapidfuzz.distance import Levenshtein

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from qrc.corpus.loader import load_ayahs  # noqa: E402
from qrc.corpus.word_split import rebalance_shared_gemination, split_merged_unit  # noqa: E402


class _PermissiveMaddToTag(dict):
    """quran_transcript, after substituting a word-final glide+consonant
    ("Leen Madd", e.g. the -َيْت of "بَيْت" or -َوْف of "خَوْف" -- any word
    ending in fatha+waw/yaa+another letter, ~3.4% of Quran words), tries to
    retroactively tag *every* unresolved Leen-Madd rule by reading back
    whichever letter is at its recorded position -- but that position can
    land on the wrong letter by the time later operations (idgham,
    shamsiyya, etc.) have run, and LeenMaddRule._madd_to_tag only has
    "waw"/"yaa" keys, so a real consonant there (e.g. "ن", "ش", "ف", "ت")
    KeyErrors and crashes the whole phonetization -- verified upstream
    (site-packages
    quran_transcript/phonetics/conv_base_operation.py:~419) by testing
    every word in the corpus standalone: 2634/77433 words crash this way,
    including 8 whole ayahs where it's the *last* word (55:17, 90:8-10,
    106:1-4) so `$` lands there for the whole-ayah phonetization too.
    `tag` is pure tajweed-rule-annotation metadata (used by explain_error/
    sifat output) -- verified no other code path reads it before we get
    `.phonemes` back -- so returning None for a bad lookup instead of
    raising is safe: it never changes the phoneme string we actually use.
    """

    def __missing__(self, key: str) -> None:
        return None


_original_leen_madd_post_init = qt_tajweed_rules.LeenMaddRule.__post_init__


def _patched_leen_madd_post_init(self: "qt_tajweed_rules.LeenMaddRule") -> None:
    _original_leen_madd_post_init(self)
    self._madd_to_tag = _PermissiveMaddToTag(self._madd_to_tag)


qt_tajweed_rules.LeenMaddRule.__post_init__ = _patched_leen_madd_post_init

MODELS_DIR = Path(__file__).resolve().parent.parent / "models"
CORPUS_PATH = MODELS_DIR / "ordered_quran_phonemes.json"
OUTPUT_PATH = MODELS_DIR / "word_text_map.json"
OVERRIDES_PATH = MODELS_DIR / "word_text_map_overrides.json"
REPORT_PATH = MODELS_DIR / "word_split_report.json"

# Picked empirically by inspecting the confidence-score distribution from
# a full-corpus run (see REPORT_PATH) -- not guessed upfront.
MIN_SPLIT_CONFIDENCE = 0.5

MOSHAF = qt.MoshafAttributes(
    rewaya="hafs",
    madd_monfasel_len=4,
    madd_mottasel_len=4,
    madd_mottasel_waqf=4,
    madd_aared_len=2,
)



def written_word_spans(text: str) -> list[tuple[int, int]]:
    return [(m.start(), m.end()) for m in re.finditer(r"\S+", text)]


def isolated_phonemes(written_word: str) -> str:
    """This word's own phoneme rendering, phonetized on its own rather than
    as part of the ayah -- quran_phonetizer applies waqf (pause) rules at
    the end of whatever text it's given, so feeding it a single word
    (nothing follows) naturally yields that word's standalone/paused
    pronunciation: no liaison merge into a following word, and any
    trailing tanween/short-vowel dropped the way a real pause would drop
    it. Falls back to the word itself (rare phonetizer failure on a lone
    word) rather than raising, since this is a secondary/optional field --
    see align/word_aligner.py.
    """
    try:
        return qt.quran_phonetizer(written_word, MOSHAF).phonemes.strip()
    except Exception:
        return written_word


def last_word_continued_phonemes(this_ayah_text: str, next_ayah_text: str | None) -> str | None:
    """The phonetic rendering of THIS ayah's last written word when
    recitation continues straight into the next ayah, rather than pausing.

    ordered_quran_phonemes.json phonetizes each ayah's text *alone*, so
    "$" (waqf rules apply) always lands on the last word of every single
    ayah -- meaning phoneme_text for every ayah-final word already assumes
    a pause there, regardless of whether a given reciter actually paused.
    For a word whose paused (wasl) and continuous (waqf) forms genuinely
    differ -- e.g. tanween fatha: alif-madd at a pause vs. a nasalized
    "-an" ending mid-recitation -- a reciter who *doesn't* pause there
    (moves straight into the next ayah, entirely valid Tajweed) produces
    audio that legitimately doesn't match phoneme_text at all. Reported
    from a live session: "قَلِيلًا" at 33:18 recited without a following
    pause came back as 'قَلِۦۦلَن' against an expected 'قَلِۦۦلَاا' --
    the *continuous* rendering the reciter actually produced, not a
    mispronunciation.

    Phonetizes this ayah's text immediately followed by the next ayah's
    (so "$" no longer lands on this ayah's last word) and pulls out that
    word's own span via the same char-position mapping qt_phoneme_groups
    uses -- not a fresh single-word call, since the word needs the *next*
    ayah's opening sound right after it for continuation to actually
    apply. None at the true end of the Quran (no next ayah -- waqf is the
    only option there) or if the phonetizer fails on the combined text.

    One adjustment beyond a plain span extraction: where this word ends in
    tanween whose nasal component undergoes idgham bighunna into the next
    word's opening letter (one of ينمو), qt's own per-word split -- like
    this corpus's own convention, see rebalance_shared_gemination -- puts
    the *entire* resulting geminated/extended sound on the next word,
    leaving this word's own span with none of it at all. Reported from a
    live session (33:22 -> 33:23): "وَتَسْلِيمًا" (tanween fatha, followed
    by "مِّنَ") recited correctly came back as '...مَممم' -- a real
    reciter/ASR artifact of where a continuous idgham sound gets split
    between two words, not a genuine extra sound the corpus's own
    from-a-single-word span is missing. One instance of the assimilated
    letter is given back (mirroring rebalance_shared_gemination's "give the
    first word back exactly one instance" rule) -- align/normalize.py's
    tajweed-length collapsing then treats any nonzero trailing run as
    equivalent, so the exact count doesn't need to be right, only that
    it's no longer zero.
    """
    if next_ayah_text is None:
        return None
    groups = qt_phoneme_groups(f"{this_ayah_text} {next_ayah_text}")
    if groups is None:
        return None
    n_this_words = len(written_word_spans(this_ayah_text))
    if not (0 < n_this_words <= len(groups)):
        return None
    continued = groups[n_this_words - 1]
    if continued and n_this_words < len(groups):
        next_group = groups[n_this_words]
        if len(next_group) >= 2 and next_group[0] == next_group[1]:
            continued += next_group[0]
    return continued or None


def qt_phoneme_groups(aya_text: str) -> list[str] | None:
    """Per-written-word phoneme groups from quran-transcript, derived via
    its char-position mapping (not space-splitting -- see module docstring).
    Returns None if the phonetizer itself fails on this ayah.
    """
    try:
        out = qt.quran_phonetizer(aya_text, MOSHAF)
    except Exception:
        return None

    groups = []
    for start, end in written_word_spans(aya_text):
        positions = [out.mappings[i].pos for i in range(start, end) if not out.mappings[i].deleted]
        if not positions:
            groups.append("")
            continue
        lo = min(p[0] for p in positions)
        hi = max(p[1] for p in positions)
        groups.append(out.phonemes[lo:hi].strip())
    return groups


# No observed Tajweed liaison merge spans more than a handful of written
# words (32:8's 5-word merge is the largest seen); capped generously so
# the DP stays cheap without artificially limiting real merges.
_MAX_QT_RUN = 8
# Cost of leaving a qt word completely unattributed to any corpus word --
# an escape valve for content that genuinely fits nowhere, not a normal
# outcome. Must lose to any plausible multi-word run match (a run's
# substitution cost is bounded by 1.0 per word it captures well; this is
# set well above what several correctly-captured words would cost).
_SKIP_PENALTY = 5.0


def align_word_lists(corpus_words: list[str], qt_words: list[str]) -> list[list[int] | None]:
    """Word-level edit-distance alignment (not char-level -- these are
    two different phoneme-word segmentations of the same ayah). Returns,
    per corpus word, the qt_words *indices* it aligns to (not the text --
    the caller must use indices directly, not re-derive them by searching
    for the phoneme text as a substring elsewhere: short/common phoneme
    groups like "لَا" false-match inside many unrelated groups, which is
    exactly what corrupted longer ayahs like 2:255 before this was an
    index-based return).

    Each corpus word is matched against a *run* of one or more consecutive
    qt words (substitution cost = 1 - similarity of the corpus word
    against the run's concatenation), and the DP picks whichever run
    length best explains that corpus word's actual phoneme content. This
    is deliberately not "match 1 qt word, then glue any leftover qt words
    onto whichever corpus word happens to follow": that forward-only
    gluing is directionally biased and got the *wrong* written word
    attached when a merge's extra phonetic content bleeds backward into
    the *previous* corpus word instead (found via 2:12: "لَّا"'s phonemes
    are actually a suffix of "وَلَـٰكِن"'s corpus unit, but forward-gluing
    attached "لَّا" to the next corpus unit, "يَشْعُرُونَ", where its
    phonemes don't appear at all). Letting the run itself carry the
    match means the alignment is chosen by which grouping actually fits
    the content, not by which side of a word it happened to be glued to.

    A corpus word with no qt counterpart at all (DELETE_A -- a muqatta'at
    split, one written word spanning several corpus units) still costs a
    flat 1.0 and is filled from a neighbor below. A qt word matching no
    corpus word (SKIP) is a heavily-penalized escape valve, not an
    expected outcome.
    """
    n, m = len(corpus_words), len(qt_words)
    dp = [[0.0] * (m + 1) for _ in range(n + 1)]
    # bp[i][j] = (prev_i, prev_j, op, run_len) where op is "RUN",
    # "DELETE_A", or "SKIP"; run_len is only meaningful for "RUN".
    bp: list[list[tuple[int, int, str, int | None]]] = [[(0, 0, "SKIP", None)] * (m + 1) for _ in range(n + 1)]

    for j in range(1, m + 1):
        dp[0][j] = dp[0][j - 1] + _SKIP_PENALTY
        bp[0][j] = (0, j - 1, "SKIP", None)
    for i in range(1, n + 1):
        dp[i][0] = dp[i - 1][0] + 1.0
        bp[i][0] = (i - 1, 0, "DELETE_A", None)

    for i in range(1, n + 1):
        for j in range(1, m + 1):
            best_cost = dp[i][j - 1] + _SKIP_PENALTY
            best_bp: tuple[int, int, str, int | None] = (i, j - 1, "SKIP", None)

            delete_a_cost = dp[i - 1][j] + 1.0
            if delete_a_cost < best_cost:
                best_cost, best_bp = delete_a_cost, (i - 1, j, "DELETE_A", None)

            concat = ""
            for k in range(1, min(_MAX_QT_RUN, j) + 1):
                concat = qt_words[j - k] + concat
                sub_cost = 1.0 - Levenshtein.normalized_similarity(corpus_words[i - 1], concat)
                run_cost = dp[i - 1][j - k] + sub_cost
                if run_cost < best_cost:
                    best_cost, best_bp = run_cost, (i - 1, j - k, "RUN", k)

            dp[i][j] = best_cost
            bp[i][j] = best_bp

    result: list[list[int] | None] = [None] * n
    i, j = n, m
    while i > 0 or j > 0:
        prev_i, prev_j, op, k = bp[i][j]
        if op == "RUN":
            result[i - 1] = list(range(j - k, j))
        elif op == "DELETE_A":
            result[i - 1] = None  # filled in from a neighbor below
        # SKIP contributes to no corpus word.
        i, j = prev_i, prev_j

    # Fill DELETE_A gaps from the nearest resolved neighbor (muqatta'at
    # splits: one written word maps to several corpus phoneme-words).
    for i in range(n):
        if result[i] is None:
            for j in range(i - 1, -1, -1):
                if result[j] is not None:
                    result[i] = result[j]
                    break
            else:
                for j in range(i + 1, n):
                    if result[j] is not None:
                        result[i] = result[j]
                        break

    return result


@dataclass
class ResolvedWord:
    text: str
    phoneme_text: str
    isolated_phoneme_text: str
    # Only ever set (by main(), after build_written_word_text returns) on
    # the very last ResolvedWord of an ayah -- see
    # last_word_continued_phonemes.
    continued_phoneme_text: str | None = None


@dataclass
class WordTextMapEntry:
    words: list[ResolvedWord]
    continues_previous: bool
    # None unless this slot was a genuine multi-word merge -- present so
    # main() can report split outcomes without recomputing them.
    split_confidence: float | None = None
    split_succeeded: bool | None = None


def build_written_word_text(
    aya_text: str, corpus_words: list[str], qt_groups: list[str], min_split_confidence: float
) -> list[WordTextMapEntry | None]:
    """Map each corpus phoneme-word back to the real written word(s) it
    corresponds to, by aligning corpus_words<->qt_groups (fuzzy, by index
    -- not by re-deriving indices via substring search, which false-
    matches on short/common phoneme groups like "لَا" appearing inside
    many unrelated groups) and qt_groups<->written_words (exact,
    positional, same list by construction). For a multi-word merge,
    attempts a further character-level split (word_split.split_merged_unit)
    to recover each real word's own phoneme sub-span; falls back to a
    single merged entry (as before that step existed) if the split isn't
    confident.
    """
    written = [aya_text[s:e] for s, e in written_word_spans(aya_text)]
    aligned_indices = align_word_lists(corpus_words, qt_groups)

    result: list[WordTextMapEntry | None] = []
    prev_idxs: list[int] | None = None
    for corpus_idx, idxs in enumerate(aligned_indices):
        if idxs is None:
            result.append(None)
            prev_idxs = None
            continue

        continues_previous = idxs == prev_idxs
        prev_idxs = idxs

        if len(idxs) == 1:
            text = written[idxs[0]]
            words = [ResolvedWord(text=text, phoneme_text=corpus_words[corpus_idx], isolated_phoneme_text=isolated_phonemes(text))]
            result.append(WordTextMapEntry(words=words, continues_previous=continues_previous))
            continue

        split = split_merged_unit(corpus_words[corpus_idx], [qt_groups[i] for i in idxs])
        if split.spans is None or split.confidence < min_split_confidence:
            merged_text = " ".join(written[i] for i in idxs)
            words = [
                ResolvedWord(
                    text=merged_text, phoneme_text=corpus_words[corpus_idx], isolated_phoneme_text=isolated_phonemes(merged_text)
                )
            ]
            result.append(
                WordTextMapEntry(
                    words=words, continues_previous=continues_previous, split_confidence=split.confidence, split_succeeded=False
                )
            )
        else:
            rebalanced_spans = rebalance_shared_gemination([written[i] for i in idxs], split.spans)
            words = [
                ResolvedWord(text=written[i], phoneme_text=p, isolated_phoneme_text=isolated_phonemes(written[i]))
                for i, p in zip(idxs, rebalanced_spans)
            ]
            result.append(
                WordTextMapEntry(
                    words=words, continues_previous=continues_previous, split_confidence=split.confidence, split_succeeded=True
                )
            )
    return result


def _load_overrides() -> dict[int, dict]:
    if not OVERRIDES_PATH.exists():
        return {}
    with open(OVERRIDES_PATH, encoding="utf-8") as f:
        raw: dict[str, dict] = json.load(f)
    return {int(k): v for k, v in raw.items()}


def main() -> None:
    ayahs = load_ayahs(CORPUS_PATH)
    overrides = _load_overrides()

    total_words = sum(len(a.words) for a in ayahs)
    word_text_map: list[dict | None] = [None] * total_words
    failed_ayahs: list[str] = []
    unmapped_words = 0
    merges_attempted = 0
    merges_split = 0
    fallback_report: list[dict] = []

    global_idx = 0
    for ayah_idx, entry in enumerate(ayahs):
        first_global_idx = global_idx
        global_idx += len(entry.words)

        qt_groups = qt_phoneme_groups(entry.aya_text)
        if qt_groups is None:
            failed_ayahs.append(f"{entry.ref.surah}:{entry.ref.ayah}")
            continue

        written_texts = build_written_word_text(entry.aya_text, list(entry.words), qt_groups, MIN_SPLIT_CONFIDENCE)

        # Only the ayah's true last written word needs a continued-form
        # alternative -- every other word already got its connected/wasl
        # form as phoneme_text for free (this ayah's own text never put
        # "$" at their position). Set directly on that ResolvedWord so it
        # flows through the same serialization as every other field below.
        last_item = next((item for item in reversed(written_texts) if item is not None), None)
        if last_item is not None:
            # Same surah only: a surah boundary is a natural, near-universal
            # stopping point (and the recited text there also includes the
            # basmala, absent from this corpus's ayah texts) -- computing a
            # "continues straight into the next ayah" form across it
            # wouldn't reflect a realistic alternative recitation anyway.
            next_ayah = ayahs[ayah_idx + 1] if ayah_idx + 1 < len(ayahs) else None
            next_ayah_text = next_ayah.aya_text if next_ayah is not None and next_ayah.ref.surah == entry.ref.surah else None
            last_word = last_item.words[-1]
            last_word.continued_phoneme_text = last_word_continued_phonemes(entry.aya_text, next_ayah_text)

        for local_idx, item in enumerate(written_texts):
            if item is None:
                unmapped_words += 1
                continue
            gwi = first_global_idx + local_idx
            word_text_map[gwi] = {
                "words": [
                    {
                        "text": w.text,
                        "phoneme_text": w.phoneme_text,
                        "isolated_phoneme_text": w.isolated_phoneme_text,
                        "continued_phoneme_text": w.continued_phoneme_text,
                    }
                    for w in item.words
                ],
                "continues_previous": item.continues_previous,
            }
            if item.split_succeeded is not None:
                merges_attempted += 1
                if item.split_succeeded:
                    merges_split += 1
                else:
                    fallback_report.append(
                        {
                            "surah": entry.ref.surah,
                            "ayah": entry.ref.ayah,
                            "local_word_idx": local_idx,
                            "global_word_idx": gwi,
                            "written_words": item.words[0].text,
                            "confidence": item.split_confidence,
                        }
                    )

        if (ayah_idx + 1) % 1000 == 0:
            print(f"  {ayah_idx + 1}/{len(ayahs)} ayahs...", file=sys.stderr)

    for gwi, override in overrides.items():
        word_text_map[gwi] = override

    OUTPUT_PATH.write_text(json.dumps(word_text_map, ensure_ascii=False))
    REPORT_PATH.write_text(json.dumps(fallback_report, ensure_ascii=False, indent=2))

    print(f"Wrote {OUTPUT_PATH}")
    print(f"Wrote {REPORT_PATH} ({len(fallback_report)} unresolved merges)")
    print(f"Applied {len(overrides)} manual override(s) from {OVERRIDES_PATH}")
    print(f"Failed ayahs (phonetizer crashed): {len(failed_ayahs)} -- {failed_ayahs[:20]}")
    print(f"Unmapped words: {unmapped_words} / {len(word_text_map)} ({100 * unmapped_words / len(word_text_map):.2f}%)")
    print(f"Merges attempted: {merges_attempted}, split successfully: {merges_split} ({100 * merges_split / max(merges_attempted, 1):.1f}%)")


if __name__ == "__main__":
    main()
