"""One offline reading request over UTF-8 stdin/stdout. Offsets are UTF-16."""
import json
import re
import sys

from sudachipy import dictionary, tokenizer

HAN = re.compile(r"[㐀-䶿一-鿿々𠀀-𯨟]")
CONTEXT = {
    "行っ": [(r"(駅|学校|病院|会社|公園|店|東京|京都|家|旅行|買い物)(へ|に)$", "いっ"),
            (r"(会議|調査|試験|実験|検査|手術|練習|授業|選挙|式典|研究)を$", "おこなっ")],
    "開く": [(r"(扉|ドア|窓|門|蓋|ふた|店)が$", "あく"),
            (r"(扉|ドア|窓|門|蓋|ふた|本|傘|会議|会|店|口|目)を$", "ひらく"),
            (r"(会議|会|店|花|花びら)が$", "ひらく")],
}

def size(text):
    return len(text.encode("utf-16-le")) // 2

def annotate(text):
    engine = dictionary.Dictionary(dict="core").tokenizer()
    notes = []
    offset = 0
    # Sudachi has a byte limit per call. Keep ordinary sentences intact.
    for fragment in re.findall(r"[^。！？\n]{1,4000}[。！？\n]?|[。！？\n]", text):
        for word in engine.tokenize(fragment, tokenizer.Tokenizer.SplitMode.C):
            surface = word.surface()
            start = offset
            offset += size(surface)
            if word.is_oov() or not HAN.search(surface):
                continue
            kana = ''.join(chr(ord(c)-96) if 'ァ' <= c <= 'ヶ' else c for c in word.reading_form())
            if surface in CONTEXT and (surface != '行っ' or fragment[word.end():word.end()+1] in ('て','た')):
                before = fragment[max(0,word.begin()-20):word.begin()]
                chosen = next((r for p,r in CONTEXT[surface] if re.search(p,before)), None)
                if chosen:
                    kana = chosen
                else:
                    continue
            if not re.fullmatch(r'[ぁ-ゖゝゞー]+', kana):
                continue
            while surface and kana and surface[-1] == kana[-1]:
                surface, kana = surface[:-1], kana[:-1]
            while surface and kana and surface[0] == kana[0]:
                start += size(surface[0])
                surface, kana = surface[1:], kana[1:]
            if surface and kana:
                notes.append(dict(start=start, surface=surface, kana=kana))
    return notes

if __name__ == '__main__':
    data = sys.stdin.buffer.read().decode('utf8')
    sys.stdout.buffer.write(json.dumps(annotate(data),ensure_ascii=False).encode('utf8'))
