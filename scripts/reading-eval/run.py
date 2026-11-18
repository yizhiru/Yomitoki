"""Compare annotations on Aozora reading spans. Run from any directory."""
import argparse
import csv
import hashlib
import json
import re
import subprocess
import sys
import unicodedata
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
BOOKS = {
    'botchan': '8b1087162da44dbf54705c15f5ba62c7c07db86bb6f38caacd4f5beb62e4618b',
    'chumon': 'a19fa050ab4bf6ecdde7fcb4665f630aa1fdfe7b70b278461140ff4eca9ba8d8',
    'meros': '03def0d5f4322d1cf1bb812a7cca4e490464cb95090182a34a6e2665dde22ba7',
}
HAN = r'㐀-䶿一-鿿々〆ヶ'
RUBY = re.compile(rf'(?:｜([^｜《》]+)|([{HAN}]+))《([^《》]+)》')
KANA = re.compile('[ぁ-ゖァ-ヺーゝゞヽヾ]+')

def hira(s):
    return ''.join(chr(ord(c)-96) if 'ァ' <= c <= 'ヶ' else c for c in unicodedata.normalize('NFC', s))

def paragraphs(directory):
    for name in [*BOOKS, 'modern']:
        if name == 'modern':
            body = (HERE / 'modern.txt').read_text()
        else:
            data = (directory / (name + '.txt')).read_bytes()
            assert hashlib.sha256(data).hexdigest() == BOOKS[name]
            body = re.split(r'^-{20,}\s*$', data.decode('cp932'), maxsplit=2, flags=re.M)[2]
            body = body.split('底本：', 1)[0]
        for line in body.splitlines():
            line = re.sub(r'［＃[^］]*］', '', line)
            text, gold, cursor = '', [], 0
            for m in RUBY.finditer(line):
                base = m[1] or m[2]
                text += line[cursor:m.start()]
                if KANA.fullmatch(m[3]) and re.search(f'[{HAN}]', base):
                    gold.append((len(text), len(text)+len(base), hira(m[3])))
                text += base
                cursor = m.end()
            text += line[cursor:]
            assert not any(c in text for c in '《》'), text[:100]
            if gold:
                yield name, text, gold

def gsd(directory):
    data = (directory / 'gsd.conllu').read_bytes()
    assert hashlib.sha256(data).hexdigest() == '980d24fb9b245880454c088938b8417c13066b169b4f9246a060e2ef8be0c2ac'
    for sample in data.decode().strip().split('\n\n'):
        lines = sample.splitlines()
        text = next(x[9:] for x in lines if x.startswith('# text = '))
        gold, cursor = [], 0
        for line in lines:
            if line.startswith('#'):
                continue
            cols = line.split('\t')
            word = cols[1]
            start = text.index(word, cursor)
            assert not text[cursor:start].strip()
            cursor = start + len(word)
            info = re.search(r'(?:^|\|)UnidicInfo=([^|]+)', cols[9])
            if not info or cols[3] not in ('NOUN', 'PROPN') or not re.fullmatch(f'[{HAN}]+', word):
                continue
            # Standalone unchanged noun spellings avoid guessing rendaku inside compounds.
            if re.search(f'[{HAN}]$', text[:start]) or re.match(f'[{HAN}]', text[cursor:]):
                continue
            fields = info[1].split(',')
            if len(fields) >= 4 and fields[2] == fields[3] == word and KANA.fullmatch(fields[0]):
                gold.append((start, cursor, hira(fields[0])))
        if gold:
            yield 'gsd', text, gold

def external(command, texts):
    result = subprocess.run(command, input=json.dumps(texts), text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr)
    records = json.loads(result.stdout)
    assert len(texts) == len(records)
    for text, annotations in zip(texts, records):
        offsets, units = {0: 0}, 0
        for i, c in enumerate(text, 1):
            units += 1 + (ord(c) > 65535)
            offsets[units] = i
        yield [(offsets[a], offsets[b], r) for a,b,r in annotations]

def trim(text, spans):
    for a,b,r in spans:
        r = hira(r)
        while a < b and r and text[a] == r[0]:
            a, r = a+1, r[1:]
        while a < b and r and text[b-1] == r[-1]:
            b, r = b-1, r[:-1]
        if a < b and r:
            yield a,b,r

def project(text, start, end, spans):
    reading, pos = '', start
    matches = [(a,b,r) for a,b,r in spans if a < end and b > start]
    # A missing kanji is observable; an annotation crossing the reference boundary
    # is present but its pronunciation cannot always be split safely.
    for a,b,r in matches:
        if a < start or b > end:
            return 'boundary', ''
        reading += text[pos:a] + r
        pos = b
    reading = hira(reading + text[pos:end])
    return ('read', reading) if KANA.fullmatch(reading) else ('missing', '')

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('corpus', type=Path)
    parser.add_argument('koe', type=Path)
    parser.add_argument('details', type=Path)
    args = parser.parse_args()
    sys.path.insert(0, str(args.koe))
    from backend.readings import annotate
    resource = ROOT/'desktop/.build/resources'
    assert (resource/'jmdict.sqlite').is_file()
    items = [*paragraphs(args.corpus), *gsd(args.corpus)]
    texts = [r[1] for r in items]
    electron = list(external(['node', HERE/'electron.cjs', resource], texts))
    native = list(external([ROOT/'.build/eval-readings', resource], texts))
    counts = Counter()
    with args.details.open('w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(['book','paragraph','surface','start','reference','engine','status','prediction'])
        for i,(name,text,targets) in enumerate(items):
            spans, pos = [], 0
            for token in annotate(text):
                end = pos + len(token['surface'])
                assert token['surface'] == text[pos:end]
                if token['reading']:
                    spans.append((pos,end,token['reading']))
                pos = end
            assert pos == len(text)
            sudachi = list(trim(text, spans))
            win = list(trim(text,electron[i]))
            fill = [s for s in sudachi if not any(a < s[1] and b > s[0] for a,b,_ in win)]
            # Route only the two ambiguous spellings covered by the reader's existing rules.
            guarded = []
            current_at = {(a,b): r for a,b,r in win}
            for start,end,r in spans:
                surface = text[start:end]
                if surface == '開く' or (surface == '行っ' and text[end:end+1] in ('た','て')):
                    chosen = current_at.get((start,start+1))
                    if chosen:
                        guarded.append((start,start+1,chosen))
                else:
                    guarded.extend(trim(text, [(start,end,r)]))
            engines = {'Sudachi+verbs':guarded, 'Electron':win,'Swift':list(trim(text,native[i])),
                       'Sudachi':sudachi,'Electron+fill':sorted(win+fill)}
            for a,b,ref in targets:
                for engine, notes in engines.items():
                    state, reading = project(text,a,b,notes)
                    if state == 'read':
                        state = 'correct' if ref == reading else 'different'
                    counts[name,engine,state] += 1
                    writer.writerow([name,i,text[a:b],a,ref,engine,state,reading])
    for name in [*BOOKS,'modern','gsd']:
        for engine in engines:
            print(name,engine,*[counts[name,engine,s] for s in ('correct','different','missing','boundary')])

if __name__ == '__main__':
    main()
