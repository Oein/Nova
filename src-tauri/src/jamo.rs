//! Hangul syllable → compatibility jamo normalization.
//!
//! Used by the FTS5 index so that a query like `안녕ㅎ` can match body text
//! `안녕하세요`: both sides collapse to a jamo stream (`ㅇㅏㄴㄴㅕㅇㅎㅏㅅㅔㅇㅛ`
//! vs `ㅇㅏㄴㄴㅕㅇㅎ`) and the FTS5 trigram tokenizer does the substring
//! matching.

const CHO: [char; 19] = [
    'ㄱ', 'ㄲ', 'ㄴ', 'ㄷ', 'ㄸ', 'ㄹ', 'ㅁ', 'ㅂ', 'ㅃ', 'ㅅ', 'ㅆ', 'ㅇ', 'ㅈ', 'ㅉ', 'ㅊ',
    'ㅋ', 'ㅌ', 'ㅍ', 'ㅎ',
];

const JUNG: [char; 21] = [
    'ㅏ', 'ㅐ', 'ㅑ', 'ㅒ', 'ㅓ', 'ㅔ', 'ㅕ', 'ㅖ', 'ㅗ', 'ㅘ', 'ㅙ', 'ㅚ', 'ㅛ', 'ㅜ', 'ㅝ',
    'ㅞ', 'ㅟ', 'ㅠ', 'ㅡ', 'ㅢ', 'ㅣ',
];

// Index 0 == "no final consonant". The remaining 27 map precomposed final
// consonants to compatibility jamo.
const JONG: [Option<char>; 28] = [
    None,
    Some('ㄱ'), Some('ㄲ'), Some('ㄳ'), Some('ㄴ'), Some('ㄵ'), Some('ㄶ'),
    Some('ㄷ'), Some('ㄹ'), Some('ㄺ'), Some('ㄻ'), Some('ㄼ'), Some('ㄽ'),
    Some('ㄾ'), Some('ㄿ'), Some('ㅀ'), Some('ㅁ'), Some('ㅂ'), Some('ㅄ'),
    Some('ㅅ'), Some('ㅆ'), Some('ㅇ'), Some('ㅈ'), Some('ㅊ'), Some('ㅋ'),
    Some('ㅌ'), Some('ㅍ'), Some('ㅎ'),
];

/// Normalize `s` into a jamo stream suitable for FTS5 trigram indexing.
///
/// - Hangul syllables decompose into compatibility jamo (초+중+종).
/// - Conjoining jamo (U+1100 block) map to their compatibility counterparts.
/// - Compatibility jamo pass through as-is.
/// - ASCII letters are lowercased; digits pass through.
/// - Whitespace is kept when `keep_whitespace`; otherwise dropped.
/// - Everything else (punctuation, symbols) is dropped — FTS5 query syntax
///   safety and trigram noise reduction.
pub fn to_jamo(s: &str, keep_whitespace: bool) -> String {
    let mut out = String::with_capacity(s.len() * 2);
    for ch in s.chars() {
        let code = ch as u32;
        if (0xAC00..=0xD7A3).contains(&code) {
            let idx = code - 0xAC00;
            let cho = (idx / 588) as usize;
            let jung = ((idx % 588) / 28) as usize;
            let jong = (idx % 28) as usize;
            out.push(CHO[cho]);
            out.push(JUNG[jung]);
            if let Some(c) = JONG[jong] {
                out.push(c);
            }
        } else if (0x1100..=0x1112).contains(&code) {
            out.push(CHO[(code - 0x1100) as usize]);
        } else if (0x1161..=0x1175).contains(&code) {
            out.push(JUNG[(code - 0x1161) as usize]);
        } else if (0x11A8..=0x11C2).contains(&code) {
            if let Some(c) = JONG[(code - 0x11A7) as usize] {
                out.push(c);
            }
        } else if (0x3131..=0x318E).contains(&code) {
            out.push(ch);
        } else if ch.is_ascii_alphanumeric() {
            for lc in ch.to_lowercase() {
                out.push(lc);
            }
        } else if ch.is_whitespace() {
            if keep_whitespace {
                out.push(' ');
            }
        }
    }
    out
}

/// Returns `true` if the normalized query has enough jamo characters to
/// generate at least one trigram.
pub fn has_trigram(normalized: &str) -> bool {
    normalized.chars().count() >= 3
}

/// Same as [`to_jamo`] but also returns a parallel mapping where each jamo
/// character is paired with the source-string character index it came from.
/// Lets callers find a match position in jamo space and project it back to
/// the original text for snippet extraction.
pub fn to_jamo_with_map(s: &str, keep_whitespace: bool) -> (String, Vec<usize>) {
    let mut flat = String::new();
    let mut map: Vec<usize> = Vec::new();
    for (i, ch) in s.chars().enumerate() {
        let mut buf = [0u8; 4];
        let one = ch.encode_utf8(&mut buf);
        let piece = to_jamo(one, keep_whitespace);
        for jc in piece.chars() {
            flat.push(jc);
            map.push(i);
        }
    }
    (flat, map)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decomposes_syllables() {
        assert_eq!(to_jamo("안녕하세요", false), "ㅇㅏㄴㄴㅕㅇㅎㅏㅅㅔㅇㅛ");
    }

    #[test]
    fn trailing_isolated_cho_matches_prefix() {
        // User partially typed `안녕ㅎ` — should stay as jamo-tail, which is a
        // *substring* of the decomposed body `안녕하세요` in jamo form.
        let body = to_jamo("안녕하세요", false);
        let query = to_jamo("안녕ㅎ", false);
        assert!(body.contains(&query), "body={body}, query={query}");
    }

    #[test]
    fn cross_boundary_substring_matches_tight_but_not_loose() {
        let tight = to_jamo("안녕 하세요", false);
        let loose = to_jamo("안녕 하세요", true);
        let q = to_jamo("녕하세요", false);
        assert!(tight.contains(&q), "tight should cross the space");
        assert!(!loose.contains(&q), "loose keeps space, so trigram chain breaks");
    }

    #[test]
    fn whitespace_preservation() {
        assert_eq!(to_jamo("a b", true), "a b");
        assert_eq!(to_jamo("a b", false), "ab");
    }

    #[test]
    fn ascii_lowercased() {
        assert_eq!(to_jamo("HELLO", false), "hello");
        assert_eq!(to_jamo("Hello123", false), "hello123");
    }

    #[test]
    fn punctuation_stripped() {
        assert_eq!(to_jamo("hi, there!", false), "hithere");
    }

    #[test]
    fn compatibility_jamo_passthrough() {
        assert_eq!(to_jamo("ㅎㅏㅇ", false), "ㅎㅏㅇ");
    }

    #[test]
    fn has_trigram_threshold() {
        assert!(!has_trigram(""));
        assert!(!has_trigram("ㅇㅏ"));
        assert!(has_trigram("ㅇㅏㄴ"));
    }

    #[test]
    fn final_consonant_emitted() {
        // `안` has jong ㄴ; verify all three jamo appear.
        assert_eq!(to_jamo("안", false).chars().count(), 3);
    }

    #[test]
    fn to_jamo_with_map_aligns_source_chars() {
        let (flat, map) = to_jamo_with_map("가b", false);
        // 가 → ㄱㅏ (2 jamo from src idx 0), b → b (1 from src idx 1)
        assert_eq!(flat, "ㄱㅏb");
        assert_eq!(map, vec![0, 0, 1]);
    }

    #[test]
    fn to_jamo_with_map_drops_punct() {
        let (flat, map) = to_jamo_with_map("a!b", false);
        assert_eq!(flat, "ab");
        assert_eq!(map, vec![0, 2]);
    }
}
