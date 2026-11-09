import Foundation

/// Labels for JMdict POS codes. Keep the original code for lookup and tooltips.
/// Reference: https://www.edrdg.org/jmdict/jmdict_dtd_h.html
struct DictionaryPartOfSpeech: Equatable {
    let code: String

    var label: String {
        if let label = Self.labels[code] { return label }
        if code.hasPrefix("v5"), let row = Self.rows[String(code.dropFirst(2))] {
            return "五段动词（\(row)行）"
        }
        if code.hasPrefix("v4"), let row = Self.rows[String(code.dropFirst(2))] {
            return "四段动词（古语・\(row)行）"
        }
        let parts = code.split(separator: "-")
        if parts.count == 2, parts[0].hasPrefix("v2"),
           let row = Self.rows[String(parts[0].dropFirst(2))], parts[1] == "k" || parts[1] == "s" {
            let kind = parts[1] == "k" ? "上二段" : "下二段"
            return "\(kind)动词（古语・\(row)行）"
        }
        // A new dictionary code remains visible instead of being guessed or dropped.
        return code
    }

    private static let rows = [
        "u": "わ", "k": "か", "g": "が", "s": "さ", "t": "た", "d": "だ", "n": "な",
        "h": "は", "b": "ば", "m": "ま", "r": "ら", "y": "や", "w": "わ", "z": "ざ"
    ]

    private static let labels = [
        "n": "名词", "n-adv": "副词性名词", "n-pr": "专有名词", "n-t": "时间名词",
        "n-pref": "前缀性名词", "n-suf": "后缀性名词", "pn": "代词", "num": "数词", "ctr": "量词",
        "adj-i": "い形容词", "adj-ix": "い形容词（いい／よい类）",
        "adj-na": "な形容词（形容动词）", "adj-no": "名词（可接の）", "adj-pn": "连体词",
        "adj-f": "名词／动词的连体用法", "adj-t": "たる形容词",
        "adj-ku": "ク活用形容词（古语）", "adj-shiku": "シク活用形容词（古语）",
        "adj-kari": "カリ活用形容词（古语）", "adj-nari": "ナリ活用形容动词（古语／书面语）",
        "adv": "副词", "adv-to": "副词（接と）", "aux": "辅助成分", "aux-v": "助动词", "aux-adj": "辅助形容词",
        "conj": "接续词", "cop": "系词", "cop-da": "系词", "exp": "惯用表达／短语", "int": "感叹词",
        "pref": "前缀", "suf": "后缀", "prt": "助词", "unc": "未分类",
        "v-unspec": "动词（类型未标明）", "v1": "一段动词", "v1-s": "一段动词（くれる类）",
        "vi": "自动词", "vt": "他动词", "vk": "カ变动词（来る）",
        "vs": "サ变名词（可接する）", "vs-i": "サ变动词（する类）", "vs-s": "サ变动词（特殊类）",
        "vs-c": "す动词（古语）", "vz": "ずる动词（一段动词的异形）",
        "vn": "ナ变动词（古语）", "vr": "ラ变动词（古语）",
        "v5aru": "五段动词（ある特殊类）", "v5k-s": "五段动词（行く／ゆく类）",
        "v5r-i": "五段动词（ら行不规则）", "v5u-s": "五段动词（う特殊类）",
        "v5uru": "うる动词（得る的古形）", "v2a-s": "二段动词（古语・う结尾）"
    ]
}
