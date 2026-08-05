// Generated from MADLAD's own SentencePiece vocabulary. Do not hand-edit.
//
//   Source:  aufklarer/MADLAD400-3B-MT-MLX — int4/tokenizer.json
//   Command: see the generator note in the plan; it extracts every `<2xx>`
//            token, then drops the ones that are not languages at all:
//            bare ISO-15924 scripts (<2Arab>, <2Hans>), bare regions (<2CA>)
//            and control tokens (<2translate>, <2back_translated>).
//   Date:    2026-08-05
//
// This ships static rather than being parsed from tokenizer.json at runtime,
// because the language picker has to work BEFORE the 1.86 GB download — a user
// needs to see that MADLAD is the engine that can do Swahili in order to pick
// it. The staleness risk is handled where it matters instead: `prepare` probes
// the real on-disk vocabulary for the one code actually in use.

import Foundation

enum MADLADLanguages {

    /// Every target-language token MADLAD accepts, in its own spelling —
    /// underscores, never hyphens.
    /// 452 entries.
    static let tokens: Set<String> = [
        "abt", "ace", "ace_Arab", "acf", "ada", "adh", "ady", "af", "agr", "ahk", "ak",
        "akb", "alt", "alz", "am", "amu", "an", "ang", "ann", "ape", "ar", "arn", "ary",
        "arz", "as", "av", "awa", "ay", "az", "az_RU", "ba", "ban", "bar", "bas", "bbc",
        "bci", "be", "ber", "ber_Latn", "bew", "bg", "bg_Latn", "bgp", "bho", "bi", "bik",
        "bim", "bjn", "bjn_Arab", "bm", "bn", "bn_Latn", "bo", "bqc", "br", "bru", "brx",
        "bs", "bts", "btx", "bua", "bug", "bum", "bus", "bzj", "ca", "cab", "cac", "cak",
        "cbk", "cce", "ce", "ceb", "cfm", "ch", "chk", "chm", "chr", "ckb", "cnh", "co",
        "cr_Latn", "crh", "crh_Latn", "crs", "cs", "ctd_Latn", "ctu", "cuk", "cv", "cy",
        "da", "de", "din", "dje", "djk", "dln", "doi", "dov", "dtp", "dv", "dwr", "dyu",
        "dz", "ee", "el", "el_Latn", "emp", "en", "enq", "eo", "es", "et", "eu", "fa",
        "ff", "ffm", "fi", "fil", "fip", "fj", "fo", "fon", "fr", "fr_CA", "frp", "fur",
        "fuv", "fy", "ga", "gag", "gbm", "gd", "gl", "gn", "gof", "gom", "gom_Latn", "gor",
        "grc", "gsw", "gu", "gu_Latn", "gub", "guc", "guh", "gui", "gv", "gvl", "gym",
        "ha", "haw", "he", "hi", "hi_Latn", "hif", "hil", "hmn", "hne", "ho", "hr", "ht",
        "hu", "hui", "hus", "hvn", "hy", "iba", "ibb", "id", "ify", "ig", "ilo", "inb",
        "io", "is", "iso", "it", "iu", "ium", "izz", "ja", "jac", "jam", "jiv", "jv",
        "jvn", "ka", "kaa", "kaa_Latn", "kac", "kbd", "kbp", "kek", "kg", "kha", "kj",
        "kjg", "kjh", "kk", "kl", "km", "kmb", "kmz_Latn", "kn", "kn_Latn", "knj", "ko",
        "koi", "kos", "kr", "kr_Arab", "krc", "kri", "ks", "ks_Deva", "ksd", "ksw", "ktu",
        "ku", "kum", "kv", "kw", "kwi", "ky", "la", "laj", "lb", "lg", "lhu", "li", "lij",
        "lmo", "ln", "lo", "lrc", "lt", "ltg", "lu", "lus", "lv", "mad", "mag", "mai",
        "mak", "mam", "mas", "maz", "mbt", "mdf", "meo", "meu", "mfe", "mg", "mgh", "mh",
        "mi", "min", "miq", "mk", "mkn", "ml", "ml_Latn", "mn", "mni", "mps", "mqy", "mr",
        "mrj", "mrw", "ms", "ms_Arab", "ms_Arab_BN", "msb", "msi", "msm", "mt", "mwl",
        "my", "myv", "nan_Latn_TW", "ndc_ZW", "nds", "nds_NL", "ne", "new", "ngu", "nhe",
        "nia", "nij", "niq", "nl", "nn", "nnb", "no", "noa", "nog", "nr", "nso", "nus",
        "nut", "nv", "ny", "nyu", "nzi", "oc", "oj", "om", "or", "os", "otq", "pa", "pag",
        "pap", "pau", "pck", "pis", "pl", "pon", "ppk", "prs", "ps", "pt", "qu", "qub",
        "quc", "quf", "quh", "qup", "quy", "qvc", "qvi", "qvz", "qxr", "raj", "rcf", "rki",
        "rm", "rmc", "rn", "ro", "rom", "ru", "ru_Latn", "rw", "rwo", "sa", "sah",
        "sat_Latn", "sc", "scn", "sd", "sda", "se", "seh", "sg", "sh", "shn", "shp", "si",
        "sja", "sk", "skr", "sl", "sm", "smt", "sn", "so", "spp", "sq", "sr", "srm", "srn",
        "ss", "st", "stq", "su", "sus", "suz", "sv", "sw", "sxn", "syr", "szl", "ta",
        "ta_Latn", "tab", "taj", "taq", "taq_Tfng", "tbz", "tca", "tcy", "tdx", "te",
        "te_Latn", "teo", "tet", "tg", "th", "ti", "tiv", "tk", "tks", "tlh", "tll",
        "tly_IR", "tn", "to", "toj", "tr", "trp", "ts", "tsc", "tsg", "tt", "tuc", "tvl",
        "twu", "tyv", "tyz", "tzh", "tzj", "tzm", "tzo", "ubu", "udm", "ug", "uk", "ur",
        "uz", "ve", "vec", "vi", "wa", "wal", "war", "wo", "wuu", "xal", "xh", "yap", "yi",
        "yo", "yua", "zap", "zh", "zh_Hant", "zh_Latn", "zne", "zu", "zza",
    ]

    /// BCP-47 spellings the app or macOS may hand us that MADLAD spells its own
    /// way. Everything else is resolved by the fallback ladder in
    /// `MADLADLanguageProvider.nativeCode(for:)`.
    ///
    /// `zh-Hans` is the one that mattered: it is what the app persisted and what
    /// Apple's framework uses, MADLAD has no such token, and the tokenizer threw
    /// an error that a `try?` swallowed — so Chinese produced no translation and
    /// no message.
    static let aliases: [String: String] = [
        "zh-Hans": "zh", "zh-CN": "zh", "zh-SG": "zh",
        "zh-Hant": "zh_Hant", "zh-TW": "zh_Hant", "zh-HK": "zh_Hant", "zh-MO": "zh_Hant",
        "tl": "fil",        // Tagalog is spelled Filipino here
        "nb": "no", "nn": "nn",
        "iw": "he", "in": "id", "ji": "yi",   // deprecated ISO codes still in the wild
    ]

    /// Canonical BCP-47 codes to offer in the picker: MADLAD's own tokens with
    /// underscores turned into hyphens, plus the alias spellings so a language
    /// the user already has selected is findable under the name they know.
    static var canonicalCodes: Set<String> {
        Set(tokens.map { $0.replacingOccurrences(of: "_", with: "-") })
            .union(aliases.keys)
    }
}
