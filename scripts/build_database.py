#!/usr/bin/env python3
"""Builds Quran/Resources/quran.sqlite from MushafPages/*.svg + the QUL API.

SVGs are authoritative for ayah/word text and page/line/word position (and
the only source of svg_element_id, used by the app to cross-reference back
into a rendered page). The QUL API (qul.tarteel.ai) is authoritative for
surah names and juz/hizb/rub-el-hizb/manzil/ruku/sajdah numbering, which
aren't present in the SVGs. Safe to re-run any time the SVGs change.
"""

import hashlib
import json
import ssl
import sqlite3
import sys
import urllib.parse
import urllib.request
from pathlib import Path

import certifi
from lxml import etree

SSL_CONTEXT = ssl.create_default_context(cafile=certifi.where())

ROOT = Path(__file__).resolve().parent.parent
SVG_DIR = ROOT / "MushafPages"
CACHE_DIR = Path(__file__).resolve().parent / ".qul_cache"
OUT_DB = ROOT / "Quran" / "Resources" / "quran.sqlite"
QUL_BASE = "https://qul.tarteel.ai/api/v1"
VERSE_FIELDS = (
    "juz_number,hizb_number,rub_el_hizb_number,manzil_number,"
    "ruku_number,sajdah_number,sajdah_type,page_number"
)

SCHEMA_SQL = """
PRAGMA foreign_keys = ON;

CREATE TABLE surahs (
  number INTEGER PRIMARY KEY,
  name_arabic TEXT NOT NULL,
  name_simple TEXT NOT NULL,
  name_complex TEXT NOT NULL,
  name_translation TEXT NOT NULL,
  revelation_place TEXT NOT NULL CHECK (revelation_place IN ('makkah','madinah')),
  revelation_order INTEGER NOT NULL,
  bismillah_pre INTEGER NOT NULL,
  ayah_count INTEGER NOT NULL,
  start_page INTEGER NOT NULL,
  end_page INTEGER NOT NULL
);

CREATE TABLE pages (
  number INTEGER PRIMARY KEY,
  line_count INTEGER NOT NULL,
  first_surah INTEGER NOT NULL,
  first_ayah INTEGER NOT NULL,
  last_surah INTEGER NOT NULL,
  last_ayah INTEGER NOT NULL,
  juz_number INTEGER NOT NULL
);

CREATE TABLE ayahs (
  id INTEGER PRIMARY KEY,
  surah INTEGER NOT NULL REFERENCES surahs(number),
  ayah_number INTEGER NOT NULL,
  text_uthmani TEXT NOT NULL,
  text_imlaei TEXT NOT NULL,
  word_count INTEGER NOT NULL,
  start_page INTEGER NOT NULL REFERENCES pages(number),
  end_page INTEGER NOT NULL REFERENCES pages(number),
  start_line INTEGER NOT NULL,
  end_line INTEGER NOT NULL,
  juz_number INTEGER NOT NULL,
  hizb_number INTEGER NOT NULL,
  rub_el_hizb_number INTEGER NOT NULL,
  manzil_number INTEGER NOT NULL,
  ruku_number INTEGER NOT NULL,
  is_sajda INTEGER NOT NULL DEFAULT 0,
  sajda_type TEXT,
  UNIQUE(surah, ayah_number)
);

CREATE TABLE words (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  surah INTEGER NOT NULL,
  ayah_number INTEGER NOT NULL,
  word_index INTEGER NOT NULL,
  page INTEGER NOT NULL REFERENCES pages(number),
  line INTEGER NOT NULL,
  text_uthmani TEXT NOT NULL,
  text_imlaei TEXT NOT NULL,
  word_type TEXT NOT NULL,
  waqf_kind TEXT,
  is_waw_alatf INTEGER NOT NULL DEFAULT 0,
  svg_element_id TEXT NOT NULL,
  FOREIGN KEY (surah, ayah_number) REFERENCES ayahs(surah, ayah_number)
);
CREATE INDEX idx_words_ayah ON words(surah, ayah_number, word_index);
CREATE INDEX idx_words_page ON words(page, line);
"""

TEXT_WORD_TYPES = ("word", "waqf")


# --- QUL API, disk-cached -------------------------------------------------


def qul_get(path, params=None):
    url = f"{QUL_BASE}{path}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cache_file = CACHE_DIR / f"{hashlib.sha256(url.encode()).hexdigest()}.json"
    if cache_file.exists():
        return json.loads(cache_file.read_text())
    req = urllib.request.Request(url, headers={"User-Agent": "quran-db-builder/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=30, context=SSL_CONTEXT) as resp:
            data = json.loads(resp.read())
    except Exception as exc:
        raise RuntimeError(f"QUL request failed: {url}") from exc
    cache_file.write_text(json.dumps(data))
    return data


def fetch_qul_surahs_and_verses():
    chapters = qul_get("/chapters")["chapters"]
    verses_by_key = {}
    for chapter in chapters:
        surah_id = chapter["id"]
        params = {"fields": VERSE_FIELDS, "per_page": 300}
        verses = qul_get(f"/chapters/{surah_id}/verses", params)["verses"]
        for v in verses:
            surah_s, ayah_s = v["verse_key"].split(":")
            verses_by_key[(int(surah_s), int(ayah_s))] = v
    return {c["id"]: c for c in chapters}, verses_by_key


# --- SVG parsing -----------------------------------------------------------


def classify_word(group):
    group_type = group.get("data-type")
    if group_type in ("juz-star", "sajda-mehrab"):
        return group_type, None
    waqf_kind = None
    for el in group.iter():
        if el.get("data-type") == "waqf":
            waqf_kind = el.get("data-waqf")
            break
    return ("waqf" if waqf_kind else "word"), waqf_kind


def parse_svgs():
    ayahs = {}  # (surah, ayah) -> dict
    aya_marks = {}  # (surah, ayah) -> (page, line)
    pages = {}  # page_number -> dict

    for svg_path in sorted(SVG_DIR.glob("*.svg")):
        page_number = int(svg_path.stem)
        tree = etree.parse(str(svg_path))
        root = tree.getroot()

        page_info = {
            "line_count": 0,
            "first": None,
            "last": None,
        }

        for el in root.iter():
            eid = el.get("id")
            if not eid:
                continue

            if eid.startswith("md-line-"):
                line_no = int(el.get("data-line-number"))
                page_info["line_count"] = max(page_info["line_count"], line_no)
                continue

            if eid.startswith("md-aya-mark-"):
                surah = int(el.get("data-surah"))
                ayah_number = int(el.get("data-aya"))
                line_no = int(el.get("data-line-number"))
                aya_marks[(surah, ayah_number)] = (page_number, line_no)
                continue

            if eid.startswith("md-word-"):
                surah = int(el.get("data-surah"))
                ayah_number = int(el.get("data-aya"))
                line_no = int(el.get("data-line-number"))
                word_index = int(el.get("data-word-index-in-ayah"))
                word_type, waqf_kind = classify_word(el)

                word = {
                    "surah": surah,
                    "ayah_number": ayah_number,
                    "word_index": word_index,
                    "page": page_number,
                    "line": line_no,
                    "text_uthmani": el.get("data-hafs") or "",
                    "text_imlaei": el.get("data-imlaey") or "",
                    "word_type": word_type,
                    "waqf_kind": waqf_kind,
                    "is_waw_alatf": 1 if el.get("data-waw-alatf") == "true" else 0,
                    "svg_element_id": eid,
                }

                key = (surah, ayah_number)
                if key not in ayahs:
                    ayahs[key] = {
                        "start_page": page_number,
                        "start_line": line_no,
                        "words": [],
                    }
                ayahs[key]["words"].append(word)

                if page_info["first"] is None:
                    page_info["first"] = (surah, ayah_number)
                page_info["last"] = (surah, ayah_number)

        pages[page_number] = {
            "number": page_number,
            "line_count": page_info["line_count"],
            "first_surah": page_info["first"][0],
            "first_ayah": page_info["first"][1],
            "last_surah": page_info["last"][0],
            "last_ayah": page_info["last"][1],
        }

    return ayahs, aya_marks, pages


# --- Assemble --------------------------------------------------------------


def join_words(words, field):
    """Joins word text into ayah-level text. A word flagged `is_waw_alatf`
    (the وconjunction proclitic) attaches directly to the following word
    with no space - it's never written as its own separate word in real
    Arabic orthography, unlike QUL's per-word API which stores it as one."""
    parts = []
    for i, w in enumerate(words):
        parts.append(w[field])
        if i < len(words) - 1 and not w.get("is_waw_alatf"):
            parts.append(" ")
    return "".join(parts)


def assemble(ayahs, aya_marks, pages, qul_chapters, qul_verses):
    missing_marks = set(ayahs) - set(aya_marks)
    if missing_marks:
        raise AssertionError(f"ayahs with no aya-mark in SVGs: {sorted(missing_marks)[:10]}")
    missing_qul = set(ayahs) - set(qul_verses)
    if missing_qul:
        raise AssertionError(f"ayahs missing from QUL: {sorted(missing_qul)[:10]}")

    ayah_rows = []
    surah_pages = {}  # surah -> [min_page, max_page]
    surah_ayah_count = {}

    for key in sorted(ayahs):
        surah, ayah_number = key
        a = ayahs[key]
        a["words"].sort(key=lambda w: w["word_index"])
        end_page, end_line = aya_marks[key]
        qv = qul_verses[key]

        text_words = [w for w in a["words"] if w["word_type"] in TEXT_WORD_TYPES]
        text_uthmani = join_words(text_words, "text_uthmani")
        text_imlaei = join_words(text_words, "text_imlaei")

        svg_is_sajda = any(w["word_type"] == "sajda-mehrab" for w in a["words"])
        qul_is_sajda = qv.get("sajdah_number") is not None
        if svg_is_sajda != qul_is_sajda:
            raise AssertionError(f"sajda mismatch at {surah}:{ayah_number}: svg={svg_is_sajda} qul={qul_is_sajda}")

        ayah_rows.append({
            "id": surah * 1000 + ayah_number,
            "surah": surah,
            "ayah_number": ayah_number,
            "text_uthmani": text_uthmani,
            "text_imlaei": text_imlaei,
            "word_count": len(text_words),
            "start_page": a["start_page"],
            "end_page": end_page,
            "start_line": a["start_line"],
            "end_line": end_line,
            "juz_number": qv["juz_number"],
            "hizb_number": qv["hizb_number"],
            "rub_el_hizb_number": qv["rub_el_hizb_number"],
            "manzil_number": qv["manzil_number"],
            "ruku_number": qv["ruku_number"],
            "is_sajda": 1 if svg_is_sajda else 0,
            "sajda_type": qv.get("sajdah_type"),
        })

        lo, hi = surah_pages.get(surah, (a["start_page"], a["start_page"]))
        surah_pages[surah] = (min(lo, a["start_page"], end_page), max(hi, a["start_page"], end_page))
        surah_ayah_count[surah] = surah_ayah_count.get(surah, 0) + 1

    surah_rows = []
    for surah_id, chapter in sorted(qul_chapters.items()):
        ayah_count = surah_ayah_count.get(surah_id, 0)
        if ayah_count != chapter["verses_count"]:
            raise AssertionError(
                f"surah {surah_id} ayah count mismatch: svg={ayah_count} qul={chapter['verses_count']}"
            )
        start_page, end_page = surah_pages[surah_id]
        surah_rows.append({
            "number": surah_id,
            "name_arabic": chapter["name_arabic"],
            "name_simple": chapter["name_simple"],
            "name_complex": chapter["name_complex"],
            "name_translation": chapter["translated_name"]["name"],
            "revelation_place": chapter["revelation_place"],
            "revelation_order": chapter["revelation_order"],
            "bismillah_pre": 1 if chapter["bismillah_pre"] else 0,
            "ayah_count": ayah_count,
            "start_page": start_page,
            "end_page": end_page,
        })

    page_rows = []
    for page_number in sorted(pages):
        p = pages[page_number]
        first_juz = qul_verses[(p["first_surah"], p["first_ayah"])]["juz_number"]
        page_rows.append({**p, "juz_number": first_juz})

    word_rows = []
    for key in sorted(ayahs):
        word_rows.extend(ayahs[key]["words"])

    return surah_rows, page_rows, ayah_rows, word_rows


# --- Validation --------------------------------------------------------


def validate(surah_rows, page_rows, ayah_rows, word_rows):
    assert len(surah_rows) == 114, f"expected 114 surahs, got {len(surah_rows)}"
    assert len(ayah_rows) == 6236, f"expected 6236 ayahs, got {len(ayah_rows)}"
    assert len(page_rows) == 604, f"expected 604 pages, got {len(page_rows)}"
    assert sum(s["ayah_count"] for s in surah_rows) == 6236
    sajda_count = sum(a["is_sajda"] for a in ayah_rows)
    assert sajda_count == 15, f"expected 15 sajda ayahs, got {sajda_count}"


# --- Write ---------------------------------------------------------------


def write_db(surah_rows, page_rows, ayah_rows, word_rows):
    OUT_DB.parent.mkdir(parents=True, exist_ok=True)
    if OUT_DB.exists():
        OUT_DB.unlink()
    conn = sqlite3.connect(OUT_DB)
    conn.executescript(SCHEMA_SQL)

    conn.executemany(
        """INSERT INTO surahs
           (number, name_arabic, name_simple, name_complex, name_translation,
            revelation_place, revelation_order, bismillah_pre, ayah_count, start_page, end_page)
           VALUES (:number, :name_arabic, :name_simple, :name_complex, :name_translation,
                   :revelation_place, :revelation_order, :bismillah_pre, :ayah_count, :start_page, :end_page)""",
        surah_rows,
    )
    conn.executemany(
        """INSERT INTO pages
           (number, line_count, first_surah, first_ayah, last_surah, last_ayah, juz_number)
           VALUES (:number, :line_count, :first_surah, :first_ayah, :last_surah, :last_ayah, :juz_number)""",
        page_rows,
    )
    conn.executemany(
        """INSERT INTO ayahs
           (id, surah, ayah_number, text_uthmani, text_imlaei, word_count,
            start_page, end_page, start_line, end_line,
            juz_number, hizb_number, rub_el_hizb_number, manzil_number, ruku_number,
            is_sajda, sajda_type)
           VALUES (:id, :surah, :ayah_number, :text_uthmani, :text_imlaei, :word_count,
                   :start_page, :end_page, :start_line, :end_line,
                   :juz_number, :hizb_number, :rub_el_hizb_number, :manzil_number, :ruku_number,
                   :is_sajda, :sajda_type)""",
        ayah_rows,
    )
    conn.executemany(
        """INSERT INTO words
           (surah, ayah_number, word_index, page, line, text_uthmani, text_imlaei,
            word_type, waqf_kind, is_waw_alatf, svg_element_id)
           VALUES (:surah, :ayah_number, :word_index, :page, :line, :text_uthmani, :text_imlaei,
                   :word_type, :waqf_kind, :is_waw_alatf, :svg_element_id)""",
        word_rows,
    )
    conn.commit()
    conn.close()


def main():
    print(f"Parsing {len(list(SVG_DIR.glob('*.svg')))} SVGs...")
    ayahs, aya_marks, pages = parse_svgs()
    print(f"  {len(ayahs)} ayahs, {len(aya_marks)} aya-marks, {len(pages)} pages")

    print("Fetching QUL chapters/verses (cached under scripts/.qul_cache/)...")
    qul_chapters, qul_verses = fetch_qul_surahs_and_verses()
    print(f"  {len(qul_chapters)} chapters, {len(qul_verses)} verses")

    print("Joining...")
    surah_rows, page_rows, ayah_rows, word_rows = assemble(ayahs, aya_marks, pages, qul_chapters, qul_verses)

    print("Validating...")
    validate(surah_rows, page_rows, ayah_rows, word_rows)

    print(f"Writing {OUT_DB}...")
    write_db(surah_rows, page_rows, ayah_rows, word_rows)

    print(
        f"Done. surahs={len(surah_rows)} pages={len(page_rows)} "
        f"ayahs={len(ayah_rows)} words={len(word_rows)}"
    )


if __name__ == "__main__":
    sys.exit(main())
