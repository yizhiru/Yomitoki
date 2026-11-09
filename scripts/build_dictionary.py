import argparse
import json
from pathlib import Path
import sqlite3
import tarfile


def entries(words):
    for word in words:
        kanji = word["kanji"]
        for form in kanji + word["kana"]:
            key = form["text"]
            if form in kanji:
                head = key
                read = next(
                    (r for r in word["kana"] if "*" in r["appliesToKanji"] or key in r["appliesToKanji"]),
                    word["kana"][0],
                )
            else:
                read = form
                head = next(
                    (k["text"] for k in kanji if "*" in read["appliesToKanji"] or k["text"] in read["appliesToKanji"]),
                    key,
                )
            reading = read["text"]
            senses = [
                sense for sense in word["sense"]
                if ("*" in sense["appliesToKanji"] or head in sense["appliesToKanji"])
                and ("*" in sense["appliesToKana"] or reading in sense["appliesToKana"])
            ]
            glosses = ["; ".join(g["text"] for g in sense["gloss"][:5]) for sense in senses if sense["gloss"]]
            if glosses:
                pos = sorted({tag for sense in senses for tag in sense["partOfSpeech"]})
                yield key, head, reading, "\n".join(dict.fromkeys(glosses))[:1300], " ".join(pos), int(form["common"])


def main():
    parser = argparse.ArgumentParser(description="Build the local JMdict index")
    parser.add_argument("archive", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    with tarfile.open(args.archive, "r:gz") as archive:
        member = next(member for member in archive.getmembers() if member.isfile() and member.name.endswith(".json"))
        words = json.load(archive.extractfile(member))["words"]

    temporary = args.output.with_suffix(".tmp")
    temporary.unlink(missing_ok=True)
    try:
        db = sqlite3.connect(temporary)
        try:
            with db:
                db.execute("CREATE TABLE entries(form TEXT, head TEXT, reading TEXT, meaning TEXT, pos TEXT, rank INTEGER)")
                db.executemany("INSERT INTO entries VALUES(?,?,?,?,?,?)", entries(words))
                db.execute("CREATE INDEX by_form ON entries(form, rank DESC)")
        finally:
            db.close()
        temporary.replace(args.output)
    finally:
        temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
