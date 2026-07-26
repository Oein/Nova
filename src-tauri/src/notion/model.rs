//! The slice of Notion's API shape Nova actually reads. Everything we don't
//! model stays as `serde_json::Value` so unknown block types survive a
//! round-trip byte-for-byte.

use serde_json::Value;

#[derive(Debug, Clone)]
pub struct BotInfo {
    pub name: String,
    pub workspace_name: Option<String>,
}

#[derive(Debug, Clone)]
pub struct DbSummary {
    pub id: String,
    pub title: String,
    pub url: Option<String>,
}

#[derive(Debug, Clone)]
pub struct DbInfo {
    pub id: String,
    pub title: String,
    /// Name of the property whose type is `title`. Notion defaults it to
    /// "Name" but users rename it freely, and writing to the wrong property
    /// silently fails, so we always read it back rather than assume.
    pub title_prop: String,
    /// Every property name mapped to its type, so we can check that a
    /// configured timestamp property exists and is actually a `date`.
    pub properties: std::collections::HashMap<String, String>,
}

#[derive(Debug, Clone)]
pub struct PageMeta {
    pub id: String,
    pub title: String,
    pub last_edited_time: String,
    pub created_time: String,
    pub archived: bool,
    pub url: Option<String>,
    /// The page's raw properties, kept so configured columns (currently the
    /// Nova id) can be read without threading names through the API layer.
    pub properties: Value,
}

#[derive(Debug, Clone, Default)]
pub struct PageList {
    pub pages: Vec<PageMeta>,
    pub next_cursor: Option<String>,
}

/// Concatenates a `rich_text` array's plain text. Used for titles and code
/// bodies, where annotations have no markdown spelling anyway.
///
/// Falls back to `text.content` because payloads *we* build carry no
/// `plain_text` — that field is response-only, and the round-trip tests feed
/// our own output straight back into the renderer.
pub fn rich_text_plain(v: &Value) -> String {
    v.as_array()
        .map(|arr| {
            arr.iter()
                .filter_map(|rt| {
                    rt.get("plain_text")
                        .and_then(Value::as_str)
                        .or_else(|| {
                            rt.get("text")
                                .and_then(|t| t.get("content"))
                                .and_then(Value::as_str)
                        })
                })
                .collect::<String>()
        })
        .unwrap_or_default()
}

/// Pulls the title out of a page object by scanning its properties for the
/// one of type `title`. Scanning beats trusting the configured `title_prop`
/// here: a page fetched before we read the database schema still resolves.
pub fn page_title(page: &Value) -> String {
    if let Some(props) = page.get("properties").and_then(Value::as_object) {
        for (_, prop) in props {
            if prop.get("type").and_then(Value::as_str) == Some("title") {
                let t = rich_text_plain(prop.get("title").unwrap_or(&Value::Null));
                if !t.trim().is_empty() {
                    return t.trim().to_string();
                }
                return String::new();
            }
        }
    }
    String::new()
}

pub fn parse_page(page: &Value) -> Option<PageMeta> {
    let id = page.get("id").and_then(Value::as_str)?.to_string();
    Some(PageMeta {
        title: page_title(page),
        last_edited_time: page
            .get("last_edited_time")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        created_time: page
            .get("created_time")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        // `archived` is the legacy flag; newer responses also carry
        // `in_trash`. Either one means the page is gone as far as we care.
        archived: page.get("archived").and_then(Value::as_bool).unwrap_or(false)
            || page.get("in_trash").and_then(Value::as_bool).unwrap_or(false),
        url: page.get("url").and_then(Value::as_str).map(str::to_string),
        properties: page.get("properties").cloned().unwrap_or(Value::Null),
        id,
    })
}

pub fn parse_db_summary(db: &Value) -> Option<DbSummary> {
    let id = db.get("id").and_then(Value::as_str)?.to_string();
    let title = rich_text_plain(db.get("title").unwrap_or(&Value::Null));
    Some(DbSummary {
        id,
        title: if title.trim().is_empty() {
            "Untitled".to_string()
        } else {
            title.trim().to_string()
        },
        url: db.get("url").and_then(Value::as_str).map(str::to_string),
    })
}

pub fn parse_db_info(db: &Value) -> Option<DbInfo> {
    let summary = parse_db_summary(db)?;
    let mut properties = std::collections::HashMap::new();
    if let Some(props) = db.get("properties").and_then(Value::as_object) {
        for (name, p) in props {
            let ty = p
                .get("type")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();
            properties.insert(name.clone(), ty);
        }
    }
    let title_prop = properties
        .iter()
        .find(|(_, ty)| ty.as_str() == "title")
        .map(|(name, _)| name.clone())
        .unwrap_or_else(|| "Name".to_string());
    Some(DbInfo {
        id: summary.id,
        title: summary.title,
        title_prop,
        properties,
    })
}

/// Plain text of a named `rich_text` (or title) property on a page.
pub fn page_property_plain(page_props: &Value, name: &str) -> Option<String> {
    let prop = page_props.get(name)?;
    // Responses carry a `type` discriminator; a payload we built ourselves
    // doesn't, so fall back to the shapes we know how to read.
    let body = match prop.get("type").and_then(Value::as_str) {
        Some(ty) => prop.get(ty)?,
        None => prop.get("rich_text").or_else(|| prop.get("title"))?,
    };
    let text = rich_text_plain(body);
    let text = text.trim();
    if text.is_empty() {
        None
    } else {
        Some(text.to_string())
    }
}

/// Fields Notion computes and rejects on write. Stripped before replaying a
/// cached block back into `append_children`.
const READ_ONLY_FIELDS: &[&str] = &[
    "id",
    "object",
    "created_time",
    "last_edited_time",
    "created_by",
    "last_edited_by",
    "has_children",
    "archived",
    "in_trash",
    "parent",
    "request_id",
];

/// Turns a block object fetched from the API back into a payload that
/// `append_children` will accept.
///
/// Strips only the block's own top-level keys and recurses solely through
/// `children` arrays, which hold blocks. A blanket recursion would reach into
/// `rich_text` too and delete the `id` a page/user/database mention needs —
/// producing a payload Notion rejects with a 400.
pub fn strip_read_only(block: &Value) -> Value {
    let Value::Object(map) = block else {
        return block.clone();
    };
    let mut out = serde_json::Map::new();
    for (k, v) in map {
        if READ_ONLY_FIELDS.contains(&k.as_str()) {
            continue;
        }
        out.insert(k.clone(), strip_nested_children(v));
    }
    Value::Object(out)
}

/// Rewrites a block's type payload so any nested `children` are themselves
/// stripped. Everything else (`rich_text`, `icon`, `external`, …) is copied
/// through untouched.
fn strip_nested_children(payload: &Value) -> Value {
    let Value::Object(obj) = payload else {
        return payload.clone();
    };
    let Some(Value::Array(kids)) = obj.get("children") else {
        return payload.clone();
    };
    let mut out = obj.clone();
    out.insert(
        "children".to_string(),
        Value::Array(kids.iter().map(strip_read_only).collect()),
    );
    Value::Object(out)
}

/// Block types that cannot be recreated from their JSON, so a page containing
/// one can never be safely rebuilt:
///   - `synced_block` — the payload references a source block by id
///   - `child_page` / `child_database` — recreating makes a *different* page
///   - `unsupported` — Notion itself refuses to describe it
pub fn is_recreatable(block_type: &str, block: &Value) -> bool {
    if matches!(
        block_type,
        "synced_block" | "child_page" | "child_database" | "unsupported"
    ) {
        return false;
    }
    // Notion-hosted files carry expiring S3 URLs and there is no upload API
    // that would let us re-attach them. `external`-hosted media is fine.
    if matches!(block_type, "file" | "image" | "video" | "pdf" | "audio") {
        let inner = block.get(block_type);
        let kind = inner.and_then(|v| v.get("type")).and_then(Value::as_str);
        if kind == Some("file") {
            return false;
        }
    }
    true
}

/// Milliseconds since the epoch for a Notion timestamp
/// (`2024-01-02T03:04:05.000Z`). We only need this for `created_time`, so a
/// fixed-format parser beats pulling in chrono; `last_edited_time` is compared
/// as an opaque string and never parsed at all.
pub fn iso8601_to_ms(s: &str) -> Option<i64> {
    let bytes = s.as_bytes();
    if bytes.len() < 19 {
        return None;
    }
    let num = |a: usize, b: usize| -> Option<i64> { s.get(a..b)?.parse::<i64>().ok() };
    let (y, mo, d) = (num(0, 4)?, num(5, 7)?, num(8, 10)?);
    let (h, mi, sec) = (num(11, 13)?, num(14, 16)?, num(17, 19)?);
    if !(1..=12).contains(&mo) || !(1..=31).contains(&d) {
        return None;
    }
    let millis = if bytes.get(19) == Some(&b'.') {
        num(20, 23).unwrap_or(0)
    } else {
        0
    };
    Some((days_from_civil(y, mo, d) * 86_400 + h * 3600 + mi * 60 + sec) * 1000 + millis)
}

/// Inverse of [`iso8601_to_ms`], in UTC. Used to write Nova's note timestamps
/// into Notion `date` properties.
pub fn ms_to_iso8601(ms: i64) -> String {
    let days = ms.div_euclid(86_400_000);
    let rem = ms.rem_euclid(86_400_000);
    let (y, m, d) = civil_from_days(days);
    let (h, mi, s, milli) = (
        rem / 3_600_000,
        (rem / 60_000) % 60,
        (rem / 1000) % 60,
        rem % 1000,
    );
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}Z",
        y, m, d, h, mi, s, milli
    )
}

/// Howard Hinnant's civil-from-days: the inverse of [`days_from_civil`].
fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// Howard Hinnant's days-from-civil: days between 1970-01-01 and y-m-d.
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn epoch_and_known_dates() {
        assert_eq!(iso8601_to_ms("1970-01-01T00:00:00.000Z"), Some(0));
        assert_eq!(iso8601_to_ms("2024-01-02T03:04:05.000Z"), Some(1_704_164_645_000));
        // Leap day, and a timestamp with no millis component.
        assert_eq!(iso8601_to_ms("2024-02-29T00:00:00Z"), Some(1_709_164_800_000));
        assert_eq!(iso8601_to_ms("2000-03-01T00:00:00.500Z"), Some(951_868_800_500));
    }

    #[test]
    fn timestamps_round_trip_through_iso8601() {
        for ms in [
            0i64,
            1_704_164_645_000,
            951_868_800_500,
            1_709_164_800_000,
            // Pre-epoch, to exercise the negative branch of the civil-day math.
            -86_400_000,
            -1,
        ] {
            let s = ms_to_iso8601(ms);
            assert_eq!(iso8601_to_ms(&s), Some(ms), "{} -> {}", ms, s);
        }
        assert_eq!(ms_to_iso8601(0), "1970-01-01T00:00:00.000Z");
        assert_eq!(ms_to_iso8601(1_704_164_645_000), "2024-01-02T03:04:05.000Z");
    }

    #[test]
    fn rejects_garbage_timestamps() {
        assert_eq!(iso8601_to_ms(""), None);
        assert_eq!(iso8601_to_ms("not-a-date"), None);
        assert_eq!(iso8601_to_ms("2024-13-01T00:00:00Z"), None);
    }

    #[test]
    fn title_found_by_property_type_not_name() {
        // Property renamed away from the default "Name".
        let page = json!({
            "id": "p1",
            "properties": {
                "Tags": {"type": "multi_select", "multi_select": []},
                "제목": {"type": "title", "title": [{"plain_text": "안녕 "}, {"plain_text": "세상"}]}
            }
        });
        assert_eq!(page_title(&page), "안녕 세상");
    }

    #[test]
    fn page_parses_trash_flags() {
        let page = json!({
            "id": "p1", "last_edited_time": "t1", "created_time": "t0",
            "in_trash": true, "properties": {}
        });
        assert!(parse_page(&page).unwrap().archived);
    }

    #[test]
    fn db_info_reads_renamed_title_prop() {
        let db = json!({
            "id": "db1",
            "title": [{"plain_text": "My DB"}],
            "properties": {
                "Status": {"type": "select"},
                "Headline": {"type": "title"}
            }
        });
        let info = parse_db_info(&db).unwrap();
        assert_eq!(info.title, "My DB");
        assert_eq!(info.title_prop, "Headline");
        assert_eq!(info.properties.get("Status").map(String::as_str), Some("select"));
    }

    #[test]
    fn strip_read_only_recurses_into_children() {
        let block = json!({
            "object": "block", "id": "b1", "type": "quote", "has_children": true,
            "created_by": {"id": "u"},
            "quote": {
                "rich_text": [{"type": "text", "text": {"content": "hi"}, "plain_text": "hi"}],
                "children": [{"object": "block", "id": "b2", "type": "paragraph",
                              "paragraph": {"rich_text": []}}]
            }
        });
        let out = strip_read_only(&block);
        assert!(out.get("id").is_none());
        assert!(out.get("has_children").is_none());
        assert_eq!(out["type"], "quote");
        let child = &out["quote"]["children"][0];
        assert!(child.get("id").is_none());
        assert_eq!(child["type"], "paragraph");
    }

    #[test]
    fn strip_read_only_leaves_mention_targets_alone() {
        // `mention.page.id` is a required *input* field. Stripping it (as a
        // blanket recursion would) makes Notion reject the whole append.
        let block = json!({
            "object": "block", "id": "b1", "type": "callout", "created_time": "t",
            "callout": {"icon": {"emoji": "💡"}, "rich_text": [
                {"type": "mention", "plain_text": "Roadmap",
                 "mention": {"type": "page", "page": {"id": "page-abc"}}}
            ]}
        });
        let out = strip_read_only(&block);
        assert!(out.get("id").is_none());
        assert!(out.get("created_time").is_none());
        assert_eq!(out["callout"]["rich_text"][0]["mention"]["page"]["id"], "page-abc");
        assert_eq!(out["callout"]["icon"]["emoji"], "💡");
    }

    #[test]
    fn recreatable_rejects_notion_hosted_media_only() {
        assert!(!is_recreatable("synced_block", &json!({})));
        assert!(!is_recreatable(
            "image",
            &json!({"image": {"type": "file", "file": {"url": "https://s3…"}}})
        ));
        assert!(is_recreatable(
            "image",
            &json!({"image": {"type": "external", "external": {"url": "https://x/y.png"}}})
        ));
        assert!(is_recreatable("callout", &json!({})));
    }
}
