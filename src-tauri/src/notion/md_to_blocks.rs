//! Markdown -> Notion block payloads.
//!
//! The output is a list of [`Desired`] entries rather than plain JSON, because
//! a placeholder line doesn't become a *new* block — it means "replay the
//! cached JSON for this block id". Push consumes both kinds in order.

use serde_json::{json, Value};

use crate::notion::blocks_to_md::{parse_placeholder, Ann, READONLY_MARKER};

/// Notion accepts a block plus two levels of nested children per request,
/// which matches the three list levels the renderer emits.
const MAX_DEPTH: usize = 2;
/// Hard limit on a single `rich_text` element's content.
const RICH_TEXT_LIMIT: usize = 2000;

#[derive(Debug, Clone, PartialEq)]
pub enum Desired {
    /// A block to create from scratch.
    Block(Value),
    /// Replay the cached JSON for this original block id.
    Restore(String),
}

pub fn parse_body(md: &str) -> Vec<Desired> {
    let lines: Vec<&str> = md.lines().collect();
    let mut out = Vec::new();
    let mut i = 0;
    while i < lines.len() {
        let line = lines[i];
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed == READONLY_MARKER {
            i += 1;
            continue;
        }
        if let Some((_, id)) = parse_placeholder(line) {
            out.push(Desired::Restore(id));
            i += 1;
            continue;
        }
        if let Some(fence) = fence_len(trimmed) {
            let info = trimmed[fence..].trim().to_string();
            let mut body = Vec::new();
            i += 1;
            while i < lines.len() {
                let t = lines[i].trim();
                if fence_len(t).is_some_and(|n| n >= fence) && t[fence_len(t).unwrap()..].trim().is_empty()
                {
                    i += 1;
                    break;
                }
                // Verbatim: leading whitespace inside a fence is content, and
                // trimming it silently destroys indented code.
                body.push(lines[i]);
                i += 1;
            }
            out.push(Desired::Block(code_block(&body.join("\n"), &info)));
            continue;
        }
        if is_divider(trimmed) {
            out.push(Desired::Block(json!({
                "object": "block", "type": "divider", "divider": {}
            })));
            i += 1;
            continue;
        }
        if let Some((level, text)) = heading_of(trimmed) {
            out.push(Desired::Block(heading_block(level, text)));
            i += 1;
            continue;
        }
        if trimmed.starts_with('>') {
            let mut parts = Vec::new();
            while i < lines.len() {
                let t = lines[i].trim_start();
                match t.strip_prefix('>') {
                    Some(rest) => parts.push(rest.strip_prefix(' ').unwrap_or(rest).to_string()),
                    None => break,
                }
                i += 1;
            }
            out.push(Desired::Block(simple_block("quote", &parts.join("\n"))));
            continue;
        }
        if let Some(img) = image_block(trimmed) {
            out.push(Desired::Block(img));
            i += 1;
            continue;
        }
        if list_marker(line).is_some() {
            let mut items = Vec::new();
            while i < lines.len() {
                match list_marker(lines[i]) {
                    Some((depth, block)) => {
                        items.push((depth, block));
                        i += 1;
                    }
                    None => break,
                }
            }
            let mut idx = 0;
            for b in nest(&items, &mut idx, 0) {
                out.push(Desired::Block(b));
            }
            continue;
        }
        // Everything else is a paragraph; consecutive plain lines belong to the
        // same one, matching how a multi-line rich_text is rendered.
        let mut parts = Vec::new();
        while i < lines.len() {
            let t = lines[i].trim();
            if t.is_empty()
                || t == READONLY_MARKER
                || parse_placeholder(lines[i]).is_some()
                || fence_len(t).is_some()
                || is_divider(t)
                || heading_of(t).is_some()
                || t.starts_with('>')
                || list_marker(lines[i]).is_some()
                || image_block(t).is_some()
            {
                break;
            }
            parts.push(lines[i]);
            i += 1;
        }
        out.push(Desired::Block(simple_block("paragraph", &parts.join("\n"))));
    }
    out
}

/// Every block id referenced by a placeholder, in document order.
pub fn referenced_block_ids(desired: &[Desired]) -> Vec<String> {
    desired
        .iter()
        .filter_map(|d| match d {
            Desired::Restore(id) => Some(id.clone()),
            _ => None,
        })
        .collect()
}

// ---------------------------------------------------------------------------
// line classification
// ---------------------------------------------------------------------------

fn fence_len(trimmed: &str) -> Option<usize> {
    let n = trimmed.chars().take_while(|&c| c == '`').count();
    if n >= 3 {
        Some(n)
    } else {
        None
    }
}

fn is_divider(t: &str) -> bool {
    (t.len() >= 3 && t.chars().all(|c| c == '-')) || (t.len() >= 3 && t.chars().all(|c| c == '*'))
}

fn heading_of(t: &str) -> Option<(usize, &str)> {
    let n = t.chars().take_while(|&c| c == '#').count();
    if n == 0 {
        return None;
    }
    let rest = &t[n..];
    let body = rest.strip_prefix(' ')?;
    Some((n.min(3), body))
}

fn image_block(t: &str) -> Option<Value> {
    let rest = t.strip_prefix("![")?;
    let close = rest.find("](")?;
    let alt = &rest[..close];
    let url = rest[close + 2..].strip_suffix(')')?;
    if url.is_empty() || url.contains(char::is_whitespace) {
        return None;
    }
    let mut img = json!({"type": "external", "external": {"url": url}});
    if !alt.is_empty() {
        img["caption"] = Value::Array(rich_text(alt));
    }
    Some(json!({"object": "block", "type": "image", "image": img}))
}

/// `(depth, block)` when the line is a list item of any flavour.
fn list_marker(line: &str) -> Option<(usize, Value)> {
    let indent = line.len() - line.trim_start().len();
    let depth = (indent / 2).min(MAX_DEPTH);
    let t = line.trim_start();
    if let Some(rest) = t.strip_prefix("- [ ] ") {
        return Some((depth, todo_block(rest, false)));
    }
    if let Some(rest) = t.strip_prefix("- [x] ").or_else(|| t.strip_prefix("- [X] ")) {
        return Some((depth, todo_block(rest, true)));
    }
    if let Some(rest) = t.strip_prefix("- ").or_else(|| t.strip_prefix("* ")) {
        return Some((depth, simple_block("bulleted_list_item", rest)));
    }
    if let Some(n) = ordered_marker_len(t) {
        return Some((depth, simple_block("numbered_list_item", &t[n..])));
    }
    None
}

fn ordered_marker_len(s: &str) -> Option<usize> {
    let digits = s.chars().take_while(char::is_ascii_digit).count();
    if digits == 0 || digits > 9 {
        return None;
    }
    if s[digits..].starts_with(". ") {
        Some(digits + 2)
    } else {
        None
    }
}

/// Turns a flat `(depth, block)` sequence into a nested one. A run that starts
/// over-indented is promoted rather than dropped.
fn nest(items: &[(usize, Value)], idx: &mut usize, depth: usize) -> Vec<Value> {
    let mut out: Vec<Value> = Vec::new();
    while *idx < items.len() {
        let (d, v) = &items[*idx];
        if *d < depth {
            break;
        }
        if *d > depth {
            let children = nest(items, idx, depth + 1);
            match out.last_mut() {
                Some(last) => attach_children(last, children),
                None => out.extend(children),
            }
            continue;
        }
        out.push(v.clone());
        *idx += 1;
    }
    out
}

fn attach_children(block: &mut Value, children: Vec<Value>) {
    if children.is_empty() {
        return;
    }
    if let Some(ty) = block.get("type").and_then(Value::as_str).map(str::to_string) {
        block[ty]["children"] = Value::Array(children);
    }
}

// ---------------------------------------------------------------------------
// block builders
// ---------------------------------------------------------------------------

fn simple_block(ty: &str, text: &str) -> Value {
    json!({"object": "block", "type": ty, ty: {"rich_text": rich_text(text)}})
}

fn todo_block(text: &str, checked: bool) -> Value {
    json!({"object": "block", "type": "to_do",
           "to_do": {"rich_text": rich_text(text), "checked": checked}})
}

fn heading_block(level: usize, text: &str) -> Value {
    let ty = format!("heading_{}", level);
    json!({"object": "block", "type": ty, ty: {"rich_text": rich_text(text)}})
}

fn code_block(content: &str, info: &str) -> Value {
    json!({"object": "block", "type": "code", "code": {
        "rich_text": plain_rich_text(content),
        "language": notion_language(info),
    }})
}

/// Notion validates `language` against a fixed enum and 400s on anything else,
/// so unknown info strings degrade to plain text rather than failing the push.
fn notion_language(info: &str) -> String {
    let key = info.trim().to_lowercase();
    let mapped = match key.as_str() {
        "" | "text" | "txt" | "plain" | "plaintext" => "plain text",
        "js" | "jsx" | "node" => "javascript",
        "ts" | "tsx" => "typescript",
        "py" => "python",
        "rs" => "rust",
        "sh" | "zsh" | "bash" | "shell" => "shell",
        "yml" => "yaml",
        "md" => "markdown",
        "rb" => "ruby",
        "kt" => "kotlin",
        "cs" => "c#",
        "cpp" | "cc" | "cxx" => "c++",
        "objc" => "objective-c",
        "golang" => "go",
        "htm" => "html",
        "psql" | "postgres" => "sql",
        "dockerfile" => "docker",
        other => {
            if NOTION_LANGUAGES.contains(&other) {
                other
            } else {
                "plain text"
            }
        }
    };
    mapped.to_string()
}

const NOTION_LANGUAGES: &[&str] = &[
    "abap", "arduino", "bash", "basic", "c", "c#", "c++", "clojure", "coffeescript", "css", "dart",
    "diff", "docker", "elixir", "elm", "erlang", "flow", "fortran", "f#", "gherkin", "glsl", "go",
    "graphql", "groovy", "haskell", "html", "java", "javascript", "json", "julia", "kotlin",
    "latex", "less", "lisp", "livescript", "lua", "makefile", "markdown", "markup", "matlab",
    "mermaid", "nix", "objective-c", "ocaml", "pascal", "perl", "php", "plain text", "powershell",
    "prolog", "protobuf", "python", "r", "reason", "ruby", "rust", "sass", "scala", "scheme",
    "scss", "shell", "sql", "swift", "typescript", "vb.net", "verilog", "vhdl", "visual basic",
    "webassembly", "xml", "yaml",
];

// ---------------------------------------------------------------------------
// inline parsing
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
struct Seg {
    text: String,
    ann: Ann,
    link: Option<String>,
}

/// Code content is literal — no escape or emphasis processing.
fn plain_rich_text(text: &str) -> Vec<Value> {
    chunk(text)
        .into_iter()
        .map(|c| rt_item(&c, Ann::default(), None))
        .collect()
}

pub fn rich_text(text: &str) -> Vec<Value> {
    let chars: Vec<char> = text.chars().collect();
    let mut segs = Vec::new();
    parse_run(&chars, Ann::default(), None, &mut segs);

    let mut merged: Vec<Seg> = Vec::new();
    for s in segs {
        if s.text.is_empty() {
            continue;
        }
        match merged.last_mut() {
            Some(p) if p.ann == s.ann && p.link == s.link => p.text.push_str(&s.text),
            _ => merged.push(s),
        }
    }
    merged
        .into_iter()
        .flat_map(|s| {
            chunk(&s.text)
                .into_iter()
                .map(move |c| rt_item(&c, s.ann, s.link.as_deref()))
                .collect::<Vec<_>>()
        })
        .collect()
}

fn chunk(text: &str) -> Vec<String> {
    if text.chars().count() <= RICH_TEXT_LIMIT {
        return vec![text.to_string()];
    }
    text.chars()
        .collect::<Vec<_>>()
        .chunks(RICH_TEXT_LIMIT)
        .map(|c| c.iter().collect())
        .collect()
}

fn rt_item(text: &str, ann: Ann, link: Option<&str>) -> Value {
    json!({
        "type": "text",
        "text": {
            "content": text,
            "link": link.map(|u| json!({"url": u})).unwrap_or(Value::Null),
        },
        "annotations": {
            "bold": ann.bold, "italic": ann.italic, "strikethrough": ann.strike,
            "underline": false, "code": ann.code, "color": "default",
        },
    })
}

fn parse_run(chars: &[char], ann: Ann, link: Option<&str>, out: &mut Vec<Seg>) {
    let mut buf = String::new();
    let mut i = 0;
    macro_rules! flush {
        () => {
            if !buf.is_empty() {
                out.push(Seg {
                    text: std::mem::take(&mut buf),
                    ann,
                    link: link.map(str::to_string),
                });
            }
        };
    }
    while i < chars.len() {
        let c = chars[i];
        if c == '\\' {
            if let Some(&n) = chars.get(i + 1) {
                if n.is_ascii_punctuation() {
                    buf.push(n);
                    i += 2;
                    continue;
                }
            }
        }
        if c == '`' {
            let n = run_len(chars, i, '`');
            if let Some(j) = find_run(chars, i + n, '`', n) {
                let raw: String = chars[i + n..j].iter().collect();
                // CommonMark's "one space on each side is padding" rule — the
                // renderer adds it when the content itself starts or ends with
                // a backtick.
                let content = match (raw.strip_prefix(' '), raw.strip_suffix(' ')) {
                    (Some(_), Some(_)) if raw.trim().len() > 0 => {
                        raw[1..raw.len() - 1].to_string()
                    }
                    _ => raw,
                };
                flush!();
                out.push(Seg {
                    text: content,
                    ann: Ann { code: true, ..ann },
                    link: link.map(str::to_string),
                });
                i = j + n;
                continue;
            }
        }
        if c == '*' && chars.get(i + 1) == Some(&'*') {
            if let Some(j) = find_pair(chars, i + 2, '*') {
                if j > i + 2 {
                    flush!();
                    parse_run(&chars[i + 2..j], Ann { bold: true, ..ann }, link, out);
                    i = j + 2;
                    continue;
                }
            }
        }
        if c == '~' && chars.get(i + 1) == Some(&'~') {
            if let Some(j) = find_pair(chars, i + 2, '~') {
                if j > i + 2 {
                    flush!();
                    parse_run(&chars[i + 2..j], Ann { strike: true, ..ann }, link, out);
                    i = j + 2;
                    continue;
                }
            }
        }
        if c == '*' && chars.get(i + 1) != Some(&'*') {
            if let Some(j) = find_char(chars, i + 1, '*') {
                if j > i + 1 {
                    flush!();
                    parse_run(&chars[i + 1..j], Ann { italic: true, ..ann }, link, out);
                    i = j + 1;
                    continue;
                }
            }
        }
        if c == '[' {
            if let Some((label_end, url, end)) = try_link(chars, i) {
                flush!();
                parse_run(&chars[i + 1..label_end], ann, Some(&url), out);
                i = end;
                continue;
            }
        }
        buf.push(c);
        i += 1;
    }
    flush!();
}

fn run_len(chars: &[char], start: usize, target: char) -> usize {
    chars[start..].iter().take_while(|&&c| c == target).count()
}

/// Index of the next run of exactly `n` `target` chars at or after `from`.
fn find_run(chars: &[char], from: usize, target: char, n: usize) -> Option<usize> {
    let mut i = from;
    while i < chars.len() {
        if chars[i] == target {
            let len = run_len(chars, i, target);
            if len == n {
                return Some(i);
            }
            i += len;
        } else {
            i += 1;
        }
    }
    None
}

/// Scans forward honouring backslash escapes, so `*a\*b*` closes at the right
/// asterisk.
fn find_char(chars: &[char], from: usize, target: char) -> Option<usize> {
    let mut i = from;
    while i < chars.len() {
        if chars[i] == '\\' {
            i += 2;
            continue;
        }
        if chars[i] == target {
            return Some(i);
        }
        i += 1;
    }
    None
}

/// Same, but for a doubled delimiter (`**`, `~~`).
fn find_pair(chars: &[char], from: usize, target: char) -> Option<usize> {
    let mut i = from;
    while i + 1 < chars.len() {
        if chars[i] == '\\' {
            i += 2;
            continue;
        }
        if chars[i] == target && chars[i + 1] == target {
            return Some(i);
        }
        i += 1;
    }
    None
}

fn try_link(chars: &[char], start: usize) -> Option<(usize, String, usize)> {
    let close = find_char(chars, start + 1, ']')?;
    if chars.get(close + 1) != Some(&'(') {
        return None;
    }
    let end = find_char(chars, close + 2, ')')?;
    let url: String = chars[close + 2..end].iter().collect();
    if url.is_empty() || url.contains(char::is_whitespace) {
        return None;
    }
    Some((close, url, end + 1))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::notion::blocks_to_md::{placeholder_line, render_body, render_page};

    fn blocks(md: &str) -> Vec<Value> {
        parse_body(md)
            .into_iter()
            .map(|d| match d {
                Desired::Block(v) => v,
                Desired::Restore(id) => json!({"restore": id}),
            })
            .collect()
    }

    fn plain(v: &Value, ty: &str) -> String {
        v[ty]["rich_text"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| r["text"]["content"].as_str().unwrap())
            .collect()
    }

    #[test]
    fn parses_each_supported_construct() {
        let b = blocks("# H1\n\n## H2\n\npara\n\n- a\n- b\n\n1. one\n2. two\n\n- [x] done\n\n> quoted\n\n---");
        let types: Vec<&str> = b.iter().map(|v| v["type"].as_str().unwrap()).collect();
        assert_eq!(
            types,
            vec![
                "heading_1",
                "heading_2",
                "paragraph",
                "bulleted_list_item",
                "bulleted_list_item",
                "numbered_list_item",
                "numbered_list_item",
                "to_do",
                "quote",
                "divider"
            ]
        );
        assert!(b[7]["to_do"]["checked"].as_bool().unwrap());
    }

    #[test]
    fn consecutive_plain_lines_form_one_paragraph() {
        let b = blocks("line one\nline two\n\nsecond para");
        assert_eq!(b.len(), 2);
        assert_eq!(plain(&b[0], "paragraph"), "line one\nline two");
        assert_eq!(plain(&b[1], "paragraph"), "second para");
    }

    #[test]
    fn quote_lines_merge_into_one_block() {
        let b = blocks("> a\n> b");
        assert_eq!(b.len(), 1);
        assert_eq!(plain(&b[0], "quote"), "a\nb");
    }

    #[test]
    fn nested_list_items_become_children() {
        let b = blocks("- top\n  - kid\n    - grandkid\n- second");
        assert_eq!(b.len(), 2);
        let kid = &b[0]["bulleted_list_item"]["children"][0];
        assert_eq!(plain(kid, "bulleted_list_item"), "kid");
        let grand = &kid["bulleted_list_item"]["children"][0];
        assert_eq!(plain(grand, "bulleted_list_item"), "grandkid");
    }

    #[test]
    fn over_indented_list_start_is_promoted_not_dropped() {
        let b = blocks("    - orphan");
        assert_eq!(b.len(), 1);
        assert_eq!(plain(&b[0], "bulleted_list_item"), "orphan");
    }

    #[test]
    fn placeholders_become_restores_and_survive_ordering() {
        let md = format!("intro\n\n{}\n\noutro", placeholder_line("callout", "c1"));
        let d = parse_body(&md);
        assert_eq!(d[1], Desired::Restore("c1".into()));
        assert_eq!(referenced_block_ids(&d), vec!["c1".to_string()]);
    }

    #[test]
    fn readonly_marker_is_ignored() {
        let d = parse_body("<!-- notion:readonly-body -->\n\nbody");
        assert_eq!(d.len(), 1);
    }

    #[test]
    fn code_fence_language_is_mapped_and_content_kept_literal() {
        let b = blocks("```js\nconst a = `x`;\n```");
        assert_eq!(b[0]["code"]["language"], "javascript");
        assert_eq!(plain(&b[0], "code"), "const a = `x`;");
        assert_eq!(blocks("```\nraw\n```")[0]["code"]["language"], "plain text");
        // Unknown languages must not 400 the push.
        assert_eq!(blocks("```wat\nx\n```")[0]["code"]["language"], "plain text");
    }

    #[test]
    fn code_block_indentation_is_preserved() {
        let b = blocks("```python\ndef f():\n    return 1\n```");
        assert_eq!(plain(&b[0], "code"), "def f():\n    return 1");
    }

    #[test]
    fn longer_fence_lets_inner_fences_through() {
        let b = blocks("````md\n```\ninner\n```\n````");
        assert_eq!(b.len(), 1);
        assert_eq!(plain(&b[0], "code"), "```\ninner\n```");
    }

    #[test]
    fn image_lines_become_external_images() {
        let b = blocks("![alt text](https://x/y.png)");
        assert_eq!(b[0]["image"]["external"]["url"], "https://x/y.png");
        // A missing/whitespace URL stays a paragraph rather than a broken image.
        assert_eq!(blocks("![a](not a url)")[0]["type"], "paragraph");
    }

    #[test]
    fn inline_emphasis_maps_to_annotations() {
        let rt = rich_text("a **b** *i* ~~s~~ `c`");
        let got: Vec<(&str, bool, bool, bool, bool)> = rt
            .iter()
            .map(|r| {
                (
                    r["text"]["content"].as_str().unwrap(),
                    r["annotations"]["bold"].as_bool().unwrap(),
                    r["annotations"]["italic"].as_bool().unwrap(),
                    r["annotations"]["strikethrough"].as_bool().unwrap(),
                    r["annotations"]["code"].as_bool().unwrap(),
                )
            })
            .collect();
        assert_eq!(
            got,
            vec![
                ("a ", false, false, false, false),
                ("b", true, false, false, false),
                (" ", false, false, false, false),
                ("i", false, true, false, false),
                (" ", false, false, false, false),
                ("s", false, false, true, false),
                (" ", false, false, false, false),
                ("c", false, false, false, true),
            ]
        );
    }

    #[test]
    fn nested_emphasis_inside_a_link() {
        let rt = rich_text("[**bold link**](https://x.dev)");
        assert_eq!(rt.len(), 1);
        assert_eq!(rt[0]["text"]["content"], "bold link");
        assert_eq!(rt[0]["text"]["link"]["url"], "https://x.dev");
        assert_eq!(rt[0]["annotations"]["bold"], true);
    }

    #[test]
    fn unterminated_markup_stays_literal() {
        for s in ["**abc", "*abc", "~~abc", "`abc", "[abc](", "[abc]"] {
            let rt = rich_text(s);
            let joined: String = rt
                .iter()
                .map(|r| r["text"]["content"].as_str().unwrap())
                .collect();
            assert_eq!(joined, s, "input {:?}", s);
        }
    }

    #[test]
    fn escapes_are_consumed_and_underscores_are_literal() {
        let rt = rich_text("snake_case \\*not emphasis\\* \\\\");
        let joined: String = rt
            .iter()
            .map(|r| r["text"]["content"].as_str().unwrap())
            .collect();
        assert_eq!(joined, "snake_case *not emphasis* \\");
        assert!(rt.iter().all(|r| r["annotations"]["italic"] == false));
    }

    #[test]
    fn escaped_delimiter_does_not_close_emphasis() {
        let rt = rich_text("*a\\*b*");
        assert_eq!(rt.len(), 1);
        assert_eq!(rt[0]["text"]["content"], "a*b");
        assert_eq!(rt[0]["annotations"]["italic"], true);
    }

    #[test]
    fn long_text_is_chunked_under_the_api_limit() {
        let rt = rich_text(&"가".repeat(5000));
        assert_eq!(rt.len(), 3);
        for r in &rt {
            assert!(r["text"]["content"].as_str().unwrap().chars().count() <= RICH_TEXT_LIMIT);
        }
    }

    // -- round trip ---------------------------------------------------------

    /// `md -> blocks -> md` must be the identity for canonical markdown. This
    /// is the property that keeps a push from showing up as a spurious remote
    /// change on the very next pull.
    fn assert_roundtrip(md: &str) {
        let desired = parse_body(md);
        let blocks: Vec<Value> = desired
            .iter()
            .map(|d| match d {
                Desired::Block(v) => v.clone(),
                Desired::Restore(_) => unreachable!(),
            })
            .collect();
        assert_eq!(render_body(&blocks).markdown, md, "roundtrip failed");
    }

    #[test]
    fn roundtrips_canonical_markdown() {
        for md in [
            "hello world\n",
            "para one\n\npara two\n",
            "multi line\nsame paragraph\n",
            "# H1\n\n## H2\n\n### H3\n",
            "- a\n- b\n- c\n",
            "1. one\n2. two\n3. three\n",
            "- [ ] todo\n- [x] done\n",
            "> quoted\n> lines\n",
            "---\n",
            "- top\n  - kid\n    - grandkid\n",
            "```rust\nfn main() {}\n```\n",
            "```\nplain\n```\n",
            // Indentation inside a fence is content, not layout.
            "```python\ndef f():\n    if x:\n        return 1\n```\n",
            "```yaml\nroot:\n  child: 1\n```\n",
            "![alt](https://x/y.png)\n",
            "text with **bold** and *italic* and ~~strike~~ and `code`\n",
            "a [link](https://x.dev) inline\n",
            "snake_case stays literal\n",
            "escaped \\* star and \\` tick\n",
            "한글 **강조** 테스트\n",
            "- a\n\nbreak\n\n- b\n",
        ] {
            assert_roundtrip(md);
        }
    }

    /// The whole file — heading included — is what becomes the page body, so
    /// the round trip runs over the entire document.
    #[test]
    fn roundtrips_full_pages_including_the_title() {
        for md in [
            "# 제목입니다\n\n본문 첫 줄\n\n- 항목 *하나*\n- 항목 둘\n",
            "# Title\n\nbody\n",
            // A first line far past the 120-char title cap must survive whole.
            &format!("# {}\n\nbody\n", "가".repeat(400)),
        ] {
            let title = crate::commands::workspace::first_line_title(md, "Untitled");
            let blocks: Vec<Value> = parse_body(md)
                .into_iter()
                .map(|d| match d {
                    Desired::Block(v) => v,
                    Desired::Restore(_) => unreachable!(),
                })
                .collect();
            assert_eq!(render_page(&title, &blocks).markdown, *md);
        }
    }

    #[test]
    fn restore_ids_survive_a_full_roundtrip() {
        let md = format!(
            "# T\n\nbefore\n\n{}\n\nafter\n",
            placeholder_line("table", "tbl-1")
        );
        let ids = referenced_block_ids(&parse_body(&md));
        assert_eq!(ids, vec!["tbl-1".to_string()]);
    }
}
