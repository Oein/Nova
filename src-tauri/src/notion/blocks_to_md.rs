//! Notion blocks -> markdown.
//!
//! Anything Nova can't represent becomes a single-line placeholder comment and
//! its raw JSON is cached, so a later push can replay it verbatim. The
//! all-or-nothing rule matters: if *any* descendant of a top-level block is
//! unrepresentable, the whole top-level block becomes a placeholder. Push
//! rebuilds a page's top-level children, so a placeholder buried inside a list
//! item could never be restored — keeping them at top level only is what makes
//! restoration possible at all.

use serde_json::Value;

use crate::notion::model::{is_recreatable, rich_text_plain};
use crate::notion::store::CachedBlock;

/// Three levels of list nesting (0, 1, 2). Deeper items render flattened onto
/// the last level rather than being dropped.
const MAX_DEPTH: usize = 2;
const INDENT: &str = "  ";

pub struct Rendered {
    pub markdown: String,
    pub unsupported: Vec<CachedBlock>,
    /// True when at least one cached block can never be recreated, which puts
    /// the whole note into pull-only mode.
    pub has_unrecreatable: bool,
}

pub const READONLY_MARKER: &str = "<!-- notion:readonly-body -->";

pub fn placeholder_line(block_type: &str, block_id: &str) -> String {
    format!("<!-- notion:unsupported type={} id={} -->", block_type, block_id)
}

/// Parses a placeholder line back into `(type, id)`. Returns `None` for any
/// other line — including a half-deleted placeholder, which is intentional:
/// a mangled marker means "the user removed this block".
pub fn parse_placeholder(line: &str) -> Option<(String, String)> {
    let s = line.trim();
    let s = s.strip_prefix("<!--")?.strip_suffix("-->")?.trim();
    let s = s.strip_prefix("notion:unsupported")?.trim();
    let mut ty = None;
    let mut id = None;
    for tok in s.split_whitespace() {
        if let Some(v) = tok.strip_prefix("type=") {
            ty = Some(v.to_string());
        } else if let Some(v) = tok.strip_prefix("id=") {
            id = Some(v.to_string());
        } else {
            return None;
        }
    }
    Some((ty?, id?))
}

/// The page as local markdown.
///
/// The title lives **in the body**, as a leading `# ` heading, so nothing is
/// lost to the 120-character cap `first_line_title` puts on the note title (and
/// the 2000-character cap Notion puts on a title property). Those caps only
/// ever apply to a label derived from the text — never to the text itself.
///
/// A page whose body already opens with that heading is rendered as-is. One
/// that doesn't — anything authored in Notion — gets the heading prepended, so
/// its title survives the trip. After one push the two agree and this is a
/// no-op.
pub fn render_page(title: &str, blocks: &[Value]) -> Rendered {
    let mut r = render_body(blocks);
    let t = title.replace(['\n', '\r'], " ");
    let t = t.trim();
    if body_leads_with_title(&r.markdown, t) {
        return r;
    }
    let mut md = format!("# {}\n", if t.is_empty() { "Untitled" } else { t });
    if !r.markdown.is_empty() {
        md.push('\n');
        md.push_str(&r.markdown);
    }
    r.markdown = md;
    r
}

/// True when the body's first line is a heading that the page title was derived
/// from. Compares through `first_line_title` on both sides, so a title Notion
/// stored truncated still matches the full heading it came from.
fn body_leads_with_title(md: &str, title: &str) -> bool {
    let first = md.lines().next().unwrap_or("");
    if !first.starts_with('#') {
        return false;
    }
    let from_body = crate::commands::workspace::first_line_title(first, "");
    !from_body.is_empty() && from_body == crate::commands::workspace::first_line_title(title, "")
}

pub fn render_body(blocks: &[Value]) -> Rendered {
    let mut unsupported: Vec<CachedBlock> = Vec::new();
    let mut has_unrecreatable = false;
    // (lines, is_list) per top-level block.
    let mut chunks: Vec<(Vec<String>, bool)> = Vec::new();
    let mut counter = ListCounter::default();

    for block in blocks {
        let ty = block_type(block);
        let is_list = matches!(
            ty.as_str(),
            "bulleted_list_item" | "numbered_list_item" | "to_do"
        );
        if !is_list {
            counter.reset();
        }
        match render_block(block, 0, &mut counter) {
            Some(lines) => {
                if !lines.is_empty() {
                    chunks.push((lines, is_list));
                }
            }
            None => {
                counter.reset();
                let id = block
                    .get("id")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string();
                let recreatable = is_recreatable(&ty, block);
                if !recreatable {
                    has_unrecreatable = true;
                }
                chunks.push((vec![placeholder_line(&ty, &id)], false));
                unsupported.push(CachedBlock {
                    block_id: id,
                    ord: unsupported.len() as i64,
                    block_type: ty,
                    raw_json: block.to_string(),
                    recreatable,
                });
            }
        }
    }

    let mut out = String::new();
    let mut prev_list = false;
    for (i, (lines, is_list)) in chunks.iter().enumerate() {
        // Consecutive list items sit on adjacent lines; everything else gets a
        // blank line between it and its neighbour.
        if i > 0 && !(prev_list && *is_list) {
            out.push('\n');
        }
        for l in lines {
            out.push_str(l);
            out.push('\n');
        }
        prev_list = *is_list;
    }
    Rendered {
        markdown: out,
        unsupported,
        has_unrecreatable,
    }
}

fn block_type(block: &Value) -> String {
    block
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or("unsupported")
        .to_string()
}

/// Tracks the ordinal for numbered lists at each nesting depth. Notion stores
/// no numbers of its own, so we generate them and reset whenever a non-numbered
/// sibling breaks the run.
#[derive(Default)]
struct ListCounter {
    stack: Vec<usize>,
}

impl ListCounter {
    fn next(&mut self, depth: usize) -> usize {
        while self.stack.len() <= depth {
            self.stack.push(0);
        }
        self.stack.truncate(depth + 1);
        self.stack[depth] += 1;
        self.stack[depth]
    }
    fn reset(&mut self) {
        self.stack.clear();
    }
    fn reset_at(&mut self, depth: usize) {
        self.stack.truncate(depth);
    }
}

/// `None` means "this block (or something under it) can't be represented".
fn render_block(block: &Value, depth: usize, counter: &mut ListCounter) -> Option<Vec<String>> {
    let ty = block_type(block);
    let inner = block.get(&ty);
    let pad = INDENT.repeat(depth.min(MAX_DEPTH));

    // Only list items nest. An indented code fence or divider would be
    // ambiguous to re-parse, so a non-list child escalates its whole top-level
    // ancestor to a placeholder instead of being rendered wrong.
    if depth > 0
        && !matches!(
            ty.as_str(),
            "bulleted_list_item" | "numbered_list_item" | "to_do"
        )
    {
        return None;
    }

    // A block that claims children we never fetched can't be rendered
    // faithfully, so bail rather than silently drop them.
    let declares_children = block
        .get("has_children")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let children = inner
        .and_then(|v| v.get("children"))
        .and_then(Value::as_array);
    if declares_children && children.is_none() {
        return None;
    }
    let has_children = children.is_some_and(|c| !c.is_empty());

    let rt = |key: &str| -> Option<String> {
        inner
            .and_then(|v| v.get(key))
            .and_then(|v| rich_text_to_md(v))
    };

    match ty.as_str() {
        "paragraph" if !has_children => {
            let text = rt("rich_text")?;
            if text.trim().is_empty() {
                // Spacer paragraphs are dropped; markdown expresses the same
                // thing with the blank line between blocks.
                return Some(Vec::new());
            }
            Some(
                text.split('\n')
                    .map(|l| format!("{}{}", pad, escape_line_start(l)))
                    .collect(),
            )
        }
        "heading_1" | "heading_2" | "heading_3" if !has_children => {
            if inner
                .and_then(|v| v.get("is_toggleable"))
                .and_then(Value::as_bool)
                .unwrap_or(false)
            {
                return None;
            }
            let text = rt("rich_text")?;
            if text.contains('\n') {
                return None;
            }
            let hashes = match ty.as_str() {
                "heading_1" => "#",
                "heading_2" => "##",
                _ => "###",
            };
            Some(vec![format!("{} {}", hashes, text)])
        }
        "quote" if !has_children => {
            let text = rt("rich_text")?;
            Some(prefix_lines(&text, &pad, "> "))
        }
        "divider" => Some(vec![format!("{}---", pad)]),
        "bulleted_list_item" | "numbered_list_item" | "to_do" => {
            let text = rt("rich_text")?;
            if text.contains('\n') {
                return None;
            }
            let marker = match ty.as_str() {
                "bulleted_list_item" => {
                    counter.reset_at(depth);
                    "- ".to_string()
                }
                "numbered_list_item" => format!("{}. ", counter.next(depth)),
                _ => {
                    counter.reset_at(depth);
                    let checked = inner
                        .and_then(|v| v.get("checked"))
                        .and_then(Value::as_bool)
                        .unwrap_or(false);
                    if checked { "- [x] " } else { "- [ ] " }.to_string()
                }
            };
            let mut lines = vec![format!("{}{}{}", pad, marker, text)];
            if let Some(kids) = children {
                let mut child_counter = ListCounter::default();
                for kid in kids {
                    let sub = render_block(kid, depth + 1, &mut child_counter)?;
                    lines.extend(sub);
                }
            }
            Some(lines)
        }
        "code" if !has_children => {
            // A caption has nowhere to live in a fenced block; preserving the
            // block wholesale beats silently dropping the user's note.
            if !rich_text_plain(inner?.get("caption").unwrap_or(&Value::Null)).is_empty() {
                return None;
            }
            let content = rich_text_plain(inner?.get("rich_text")?);
            let lang = inner?
                .get("language")
                .and_then(Value::as_str)
                .unwrap_or("plain text");
            let info = if lang == "plain text" { "" } else { lang };
            let fence = "`".repeat(longest_backtick_run(&content).max(2) + 1);
            let mut lines = vec![format!("{}{}{}", pad, fence, info)];
            for l in content.split('\n') {
                lines.push(format!("{}{}", pad, l));
            }
            lines.push(format!("{}{}", pad, fence));
            Some(lines)
        }
        "image" if !has_children => {
            let img = inner?;
            let url = match img.get("type").and_then(Value::as_str) {
                Some("external") => img.get("external")?.get("url")?.as_str()?,
                // Notion-hosted files have expiring URLs and no re-upload path.
                _ => return None,
            };
            if url.contains(')') || url.chars().any(char::is_whitespace) {
                return None;
            }
            let alt = rich_text_plain(img.get("caption").unwrap_or(&Value::Null));
            if alt.contains(']') || alt.contains('\n') {
                return None;
            }
            Some(vec![format!("{}![{}]({})", pad, alt, url)])
        }
        _ => None,
    }
}

fn prefix_lines(text: &str, pad: &str, marker: &str) -> Vec<String> {
    text.split('\n')
        .map(|l| format!("{}{}{}", pad, marker, l))
        .collect()
}

fn longest_backtick_run(s: &str) -> usize {
    let mut best = 0;
    let mut cur = 0;
    for c in s.chars() {
        if c == '`' {
            cur += 1;
            best = best.max(cur);
        } else {
            cur = 0;
        }
    }
    best
}

// ---------------------------------------------------------------------------
// rich_text -> inline markdown
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, Default, PartialEq, Eq, Debug)]
pub struct Ann {
    pub bold: bool,
    pub italic: bool,
    pub strike: bool,
    pub code: bool,
}

fn ann_of(item: &Value) -> Ann {
    let a = item.get("annotations");
    let f = |k: &str| {
        a.and_then(|v| v.get(k))
            .and_then(Value::as_bool)
            .unwrap_or(false)
    };
    Ann {
        bold: f("bold"),
        italic: f("italic"),
        strike: f("strikethrough"),
        code: f("code"),
    }
}

fn link_of(item: &Value) -> Option<String> {
    item.get("href")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .or_else(|| {
            item.get("text")
                .and_then(|t| t.get("link"))
                .and_then(|l| l.get("url"))
                .and_then(Value::as_str)
                .map(str::to_string)
        })
}

/// `None` when the run contains anything other than plain text — mentions and
/// inline equations have no markdown spelling, so the owning block is escalated
/// to a placeholder rather than losing them.
pub fn rich_text_to_md(v: &Value) -> Option<String> {
    let arr = v.as_array()?;
    // Merge adjacent runs that share formatting first, so "**a****b**" can't
    // happen (Notion splits runs at edit boundaries, not style boundaries).
    let mut merged: Vec<(String, Ann, Option<String>)> = Vec::new();
    for item in arr {
        if item.get("type").and_then(Value::as_str) != Some("text") {
            return None;
        }
        let content = item
            .get("text")
            .and_then(|t| t.get("content"))
            .and_then(Value::as_str)
            .or_else(|| item.get("plain_text").and_then(Value::as_str))
            .unwrap_or_default()
            .to_string();
        if content.is_empty() {
            continue;
        }
        let ann = ann_of(item);
        let link = link_of(item);
        match merged.last_mut() {
            Some((buf, a, l)) if *a == ann && *l == link => buf.push_str(&content),
            _ => merged.push((content, ann, link)),
        }
    }

    let mut out = String::new();
    for (text, ann, link) in merged {
        // Inside a code span markdown can't express any other emphasis, so the
        // code annotation wins and the rest is dropped.
        let body = if ann.code {
            let fence = "`".repeat(longest_backtick_run(&text) + 1);
            let padded = if text.starts_with('`') || text.ends_with('`') {
                format!("{} {} ", fence, text)
            } else {
                format!("{}{}", fence, text)
            };
            format!("{}{}", padded, fence)
        } else {
            let mut b = escape_inline(&text);
            if ann.strike {
                b = format!("~~{}~~", b);
            }
            if ann.italic {
                b = format!("*{}*", b);
            }
            if ann.bold {
                b = format!("**{}**", b);
            }
            b
        };
        match link {
            Some(url) if !url.contains(')') && !url.chars().any(char::is_whitespace) => {
                out.push_str(&format!("[{}]({})", body, url));
            }
            // A URL we can't spell inline degrades to plain text rather than
            // producing markdown that reparses wrong.
            _ => out.push_str(&body),
        }
    }
    Some(out)
}

/// Escapes only what would otherwise reparse as markup. `_` is deliberately
/// left alone (Nova doesn't treat it as emphasis) so snake_case survives
/// unmangled, and `[` is escaped only when a `](` actually follows.
pub fn escape_inline(s: &str) -> String {
    let chars: Vec<char> = s.chars().collect();
    let mut out = String::with_capacity(s.len());
    for (i, &c) in chars.iter().enumerate() {
        let needs = match c {
            '\\' | '*' | '`' | '~' => true,
            '[' => looks_like_link(&chars[i..]),
            _ => false,
        };
        if needs {
            out.push('\\');
        }
        out.push(c);
    }
    out
}

fn looks_like_link(rest: &[char]) -> bool {
    let mut i = 1;
    while i < rest.len() {
        match rest[i] {
            ']' => return rest.get(i + 1) == Some(&'('),
            '\n' => return false,
            _ => i += 1,
        }
    }
    false
}

/// Escapes a leading marker that would make a paragraph line parse as some
/// other block (`- foo`, `# foo`, `> foo`, `1. foo`, `---`, `<!-- … -->`).
///
/// Runs *after* [`escape_inline`], which has already dealt with `*` and
/// backticks — so a line can never legitimately start with an unescaped
/// backslash here, and re-escaping one would corrupt it.
pub fn escape_line_start(line: &str) -> String {
    let t = line.trim_start();
    let indent = &line[..line.len() - t.len()];
    // An ordered marker is disarmed at the dot: `1. x` -> `1\. x`. Escaping the
    // leading digit wouldn't work, since `\` only escapes punctuation.
    if let Some(digits) = ordered_marker_digits(t) {
        return format!("{}{}\\{}", indent, &t[..digits], &t[digits..]);
    }
    let hashes = t.chars().take_while(|&c| c == '#').count();
    let is_marker = t.starts_with("- ")
        || t.starts_with("* ")
        || t.starts_with("> ")
        || (hashes > 0 && t[hashes..].starts_with(' '))
        || t.starts_with("<!--")
        || (t.len() >= 3 && t.chars().all(|c| c == '-'));
    if !is_marker {
        return line.to_string();
    }
    format!("{}\\{}", indent, t)
}

/// Number of leading digits when the string starts with a `123. ` marker.
fn ordered_marker_digits(s: &str) -> Option<usize> {
    let digits = s.chars().take_while(char::is_ascii_digit).count();
    if digits == 0 || digits > 9 {
        return None;
    }
    if s[digits..].starts_with(". ") {
        Some(digits)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::notion::model::strip_read_only;
    use serde_json::json;

    fn text(content: &str) -> Value {
        json!({"type": "text", "text": {"content": content}, "plain_text": content,
               "annotations": {"bold": false, "italic": false, "strikethrough": false,
                               "underline": false, "code": false, "color": "default"}})
    }

    fn styled(content: &str, key: &str) -> Value {
        let mut v = text(content);
        v["annotations"][key] = json!(true);
        v
    }

    fn block(ty: &str, body: Value) -> Value {
        json!({"object": "block", "id": format!("id-{}", ty), "type": ty, ty: body})
    }

    fn para(content: &str) -> Value {
        block("paragraph", json!({"rich_text": [text(content)]}))
    }

    #[test]
    fn renders_the_supported_block_set() {
        let blocks = vec![
            block("heading_1", json!({"rich_text": [text("Title")]})),
            para("hello"),
            block("bulleted_list_item", json!({"rich_text": [text("a")]})),
            block("bulleted_list_item", json!({"rich_text": [text("b")]})),
            block("divider", json!({})),
            block(
                "to_do",
                json!({"rich_text": [text("done")], "checked": true}),
            ),
            block(
                "quote",
                json!({"rich_text": [text("line1\nline2")]}),
            ),
        ];
        let r = render_body(&blocks);
        assert_eq!(
            r.markdown,
            "# Title\n\nhello\n\n- a\n- b\n\n---\n\n- [x] done\n\n> line1\n> line2\n"
        );
        assert!(r.unsupported.is_empty());
    }

    #[test]
    fn numbered_lists_count_and_reset() {
        let n = |s: &str| block("numbered_list_item", json!({"rich_text": [text(s)]}));
        let r = render_body(&[n("a"), n("b"), para("break"), n("c")]);
        assert_eq!(r.markdown, "1. a\n2. b\n\nbreak\n\n1. c\n");
    }

    #[test]
    fn nested_list_children_are_indented() {
        let child = block("bulleted_list_item", json!({"rich_text": [text("kid")]}));
        let parent = json!({
            "object": "block", "id": "p", "type": "bulleted_list_item", "has_children": true,
            "bulleted_list_item": {"rich_text": [text("top")], "children": [child]}
        });
        let r = render_body(&[parent]);
        assert_eq!(r.markdown, "- top\n  - kid\n");
    }

    #[test]
    fn unfetched_children_become_a_placeholder() {
        // has_children with no children array: we'd be dropping data.
        let b = json!({
            "object": "block", "id": "b1", "type": "bulleted_list_item", "has_children": true,
            "bulleted_list_item": {"rich_text": [text("top")]}
        });
        let r = render_body(&[b]);
        assert_eq!(r.markdown, "<!-- notion:unsupported type=bulleted_list_item id=b1 -->\n");
        assert_eq!(r.unsupported.len(), 1);
    }

    #[test]
    fn unsupported_blocks_are_cached_and_flagged() {
        let callout = json!({"object": "block", "id": "c1", "type": "callout",
                             "callout": {"rich_text": [text("hey")]}});
        let synced = json!({"object": "block", "id": "s1", "type": "synced_block",
                            "synced_block": {"synced_from": null}});
        let r = render_body(&[para("x"), callout, synced]);
        assert_eq!(
            r.markdown,
            "x\n\n<!-- notion:unsupported type=callout id=c1 -->\n\n\
             <!-- notion:unsupported type=synced_block id=s1 -->\n"
        );
        assert_eq!(r.unsupported.len(), 2);
        assert!(r.unsupported[0].recreatable);
        assert!(!r.unsupported[1].recreatable);
        assert!(r.has_unrecreatable);
    }

    #[test]
    fn placeholder_parses_back_and_rejects_mangled_lines() {
        let line = placeholder_line("callout", "abc-123");
        assert_eq!(
            parse_placeholder(&line),
            Some(("callout".into(), "abc-123".into()))
        );
        assert_eq!(parse_placeholder("<!-- notion:unsupported type=callout -->"), None);
        assert_eq!(parse_placeholder("plain text"), None);
        assert_eq!(parse_placeholder("<!-- notion:readonly-body -->"), None);
    }

    #[test]
    fn empty_paragraphs_are_dropped() {
        let empty = block("paragraph", json!({"rich_text": []}));
        let r = render_body(&[para("a"), empty, para("b")]);
        assert_eq!(r.markdown, "a\n\nb\n");
    }

    #[test]
    fn inline_annotations_render() {
        let rt = json!([
            text("plain "),
            styled("bold", "bold"),
            text(" "),
            styled("it", "italic"),
            text(" "),
            styled("st", "strikethrough"),
            text(" "),
            styled("c()", "code"),
        ]);
        assert_eq!(
            rich_text_to_md(&rt).unwrap(),
            "plain **bold** *it* ~~st~~ `c()`"
        );
    }

    #[test]
    fn adjacent_runs_with_equal_formatting_merge() {
        let rt = json!([styled("bo", "bold"), styled("ld", "bold")]);
        assert_eq!(rich_text_to_md(&rt).unwrap(), "**bold**");
    }

    #[test]
    fn links_wrap_the_formatted_body() {
        let mut linked = styled("site", "bold");
        linked["text"]["link"] = json!({"url": "https://x.dev"});
        linked["href"] = json!("https://x.dev");
        assert_eq!(
            rich_text_to_md(&json!([linked])).unwrap(),
            "[**site**](https://x.dev)"
        );
    }

    #[test]
    fn mentions_make_the_block_unrepresentable() {
        let rt = json!([{"type": "mention", "plain_text": "@Bob"}]);
        assert!(rich_text_to_md(&rt).is_none());
        let b = block("paragraph", json!({"rich_text": rt}));
        let r = render_body(&[b]);
        assert_eq!(r.unsupported.len(), 1);
    }

    #[test]
    fn escaping_is_minimal_but_sufficient() {
        // Underscores survive; markup characters don't.
        assert_eq!(escape_inline("snake_case"), "snake_case");
        assert_eq!(escape_inline("2 * 3"), "2 \\* 3");
        assert_eq!(escape_inline("[TODO] item"), "[TODO] item");
        assert_eq!(escape_inline("[a](b)"), "\\[a](b)");
        assert_eq!(escape_inline("a`b~c\\d"), "a\\`b\\~c\\\\d");
    }

    #[test]
    fn paragraphs_that_look_like_markers_are_escaped_at_line_start() {
        assert_eq!(escape_line_start("- not a list"), "\\- not a list");
        // The dot carries the escape — `\1` wouldn't unescape (not punctuation).
        assert_eq!(escape_line_start("1. not ordered"), "1\\. not ordered");
        assert_eq!(escape_line_start("# not a heading"), "\\# not a heading");
        assert_eq!(escape_line_start("> not a quote"), "\\> not a quote");
        assert_eq!(escape_line_start("---"), "\\---");
        assert_eq!(escape_line_start("normal"), "normal");
        assert_eq!(escape_line_start("#hashtag"), "#hashtag");
        // escape_inline has already turned a literal backslash into `\\`;
        // touching it again would corrupt the line.
        assert_eq!(escape_line_start("\\*\\*\\*"), "\\*\\*\\*");
    }

    #[test]
    fn code_blocks_widen_the_fence_when_content_has_backticks() {
        let b = block(
            "code",
            json!({"rich_text": [text("let x = \"```\";")], "language": "rust", "caption": []}),
        );
        let r = render_body(&[b]);
        assert_eq!(r.markdown, "````rust\nlet x = \"```\";\n````\n");
    }

    #[test]
    fn plain_text_code_blocks_have_no_info_string() {
        let b = block(
            "code",
            json!({"rich_text": [text("raw")], "language": "plain text", "caption": []}),
        );
        assert_eq!(render_body(&[b]).markdown, "```\nraw\n```\n");
    }

    #[test]
    fn external_images_render_notion_hosted_ones_do_not() {
        let ext = block(
            "image",
            json!({"type": "external", "external": {"url": "https://x/y.png"},
                   "caption": [text("alt")]}),
        );
        assert_eq!(render_body(&[ext]).markdown, "![alt](https://x/y.png)\n");
        let hosted = block(
            "image",
            json!({"type": "file", "file": {"url": "https://s3/x"}, "caption": []}),
        );
        let r = render_body(&[hosted]);
        assert_eq!(r.unsupported.len(), 1);
        assert!(!r.unsupported[0].recreatable);
    }

    #[test]
    fn page_render_prepends_the_title_heading() {
        let r = render_page("My Note", &[para("body")]);
        assert_eq!(r.markdown, "# My Note\n\nbody\n");
        assert_eq!(render_page("", &[]).markdown, "# Untitled\n");
    }

    #[test]
    fn cached_json_keeps_read_only_fields_for_later_stripping() {
        let callout = json!({"object": "block", "id": "c1", "type": "callout",
                             "created_time": "t", "callout": {"rich_text": []}});
        let r = render_body(&[callout]);
        let raw: Value = serde_json::from_str(&r.unsupported[0].raw_json).unwrap();
        assert_eq!(raw["created_time"], "t");
        assert!(strip_read_only(&raw).get("created_time").is_none());
    }
}
