//! Notion REST client.
//!
//! Everything the sync engine needs sits behind the [`NotionApi`] trait for one
//! reason: the executor's interesting behaviour (baseline bookkeeping, conflict
//! detection, block restoration) is testable against an in-memory fake instead
//! of a live workspace.

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use serde_json::{json, Value};
use tokio::sync::Mutex;
use tokio::time::Instant;

use crate::error::{AppError, AppResult};
use crate::notion::model::{
    parse_db_info, parse_db_summary, parse_page, BotInfo, DbInfo, DbSummary, PageList, PageMeta,
};

const API: &str = "https://api.notion.com/v1";
const NOTION_VERSION: &str = "2022-06-28";
/// Notion's published budget is ~3 requests/second averaged; staying just under
/// it keeps us off the 429 path entirely for normal-sized workspaces.
const MIN_INTERVAL: Duration = Duration::from_millis(340);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_RETRIES: u32 = 3;
/// Notion rejects `append_children` payloads longer than this.
pub const APPEND_CHUNK: usize = 100;

#[async_trait]
pub trait NotionApi: Send + Sync {
    async fn me(&self) -> AppResult<BotInfo>;
    async fn search_databases(&self) -> AppResult<Vec<DbSummary>>;
    async fn retrieve_database(&self, db: &str) -> AppResult<DbInfo>;
    async fn query_database(&self, db: &str, cursor: Option<String>) -> AppResult<PageList>;
    async fn retrieve_page(&self, page: &str) -> AppResult<PageMeta>;
    /// Top-level children, following pagination. Nested children are fetched
    /// separately by [`list_children_deep`].
    async fn list_children(&self, block: &str) -> AppResult<Vec<Value>>;
    async fn append_children(&self, block: &str, children: Vec<Value>) -> AppResult<Vec<Value>>;
    async fn delete_block(&self, block: &str) -> AppResult<()>;
    /// `properties` is a Notion properties object, built by the caller — the
    /// title is only one of them once timestamp columns are configured.
    async fn create_page(
        &self,
        db: &str,
        properties: Value,
        children: Vec<Value>,
    ) -> AppResult<PageMeta>;
    async fn update_page(
        &self,
        page: &str,
        properties: Option<Value>,
        archived: Option<bool>,
    ) -> AppResult<PageMeta>;
    /// Adds properties to the database schema. Used to create the timestamp
    /// columns when they don't exist yet.
    async fn add_database_properties(&self, db: &str, properties: Value) -> AppResult<DbInfo>;
}

/// Fetches a block subtree and inlines each block's children under
/// `block[type].children`, which is the shape the renderer expects. Depth is
/// capped to match the three list levels markdown can express — anything deeper
/// is left with `has_children: true` and no `children`, which the renderer
/// reads as "unrepresentable" and preserves as a placeholder.
pub async fn list_children_deep(
    api: &dyn NotionApi,
    block: &str,
    depth: usize,
) -> AppResult<Vec<Value>> {
    let mut blocks = api.list_children(block).await?;
    if depth == 0 {
        return Ok(blocks);
    }
    for b in blocks.iter_mut() {
        let has_children = b
            .get("has_children")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        if !has_children {
            continue;
        }
        let (Some(id), Some(ty)) = (
            b.get("id").and_then(Value::as_str).map(str::to_string),
            b.get("type").and_then(Value::as_str).map(str::to_string),
        ) else {
            continue;
        };
        let kids = Box::pin(list_children_deep(api, &id, depth - 1)).await?;
        if let Some(inner) = b.get_mut(&ty) {
            if inner.is_object() {
                inner["children"] = Value::Array(kids);
            }
        }
    }
    Ok(blocks)
}

/// Serializes requests with a minimum gap between them. The sync engine is
/// sequential, so a single shared instant is all the bookkeeping needed.
pub struct RateLimiter {
    last: Mutex<Option<Instant>>,
    interval: Duration,
}

impl RateLimiter {
    pub fn new(interval: Duration) -> Self {
        Self {
            last: Mutex::new(None),
            interval,
        }
    }

    pub async fn acquire(&self) {
        let mut guard = self.last.lock().await;
        if let Some(prev) = *guard {
            let elapsed = prev.elapsed();
            if elapsed < self.interval {
                tokio::time::sleep(self.interval - elapsed).await;
            }
        }
        *guard = Some(Instant::now());
    }
}

pub struct HttpNotionClient {
    http: reqwest::Client,
    token: String,
    limiter: Arc<RateLimiter>,
}

impl HttpNotionClient {
    pub fn new(http: reqwest::Client, token: String) -> Self {
        Self {
            http,
            token,
            limiter: Arc::new(RateLimiter::new(MIN_INTERVAL)),
        }
    }

    /// Builds a client with sane defaults. Callers that already hold a pooled
    /// `reqwest::Client` should prefer [`HttpNotionClient::new`].
    pub fn default_http() -> reqwest::Client {
        reqwest::Client::builder()
            .timeout(REQUEST_TIMEOUT)
            .build()
            .unwrap_or_default()
    }

    async fn request(&self, method: reqwest::Method, path: &str, body: Option<Value>) -> AppResult<Value> {
        let url = format!("{}{}", API, path);
        let mut attempt = 0u32;
        loop {
            self.limiter.acquire().await;
            let mut req = self
                .http
                .request(method.clone(), &url)
                .header("Authorization", format!("Bearer {}", self.token))
                .header("Notion-Version", NOTION_VERSION)
                .timeout(REQUEST_TIMEOUT);
            if let Some(b) = &body {
                req = req.json(b);
            }
            let res = match req.send().await {
                Ok(r) => r,
                Err(e) => {
                    // Transport errors (DNS, TLS, timeouts) are worth one more
                    // shot; a persistently offline machine fails fast enough.
                    if attempt < MAX_RETRIES && (e.is_timeout() || e.is_connect()) {
                        attempt += 1;
                        tokio::time::sleep(backoff(attempt)).await;
                        continue;
                    }
                    return Err(AppError::Other(format!("notion request failed: {}", e)));
                }
            };
            let status = res.status();
            if status.is_success() {
                return res
                    .json::<Value>()
                    .await
                    .map_err(|e| AppError::Other(format!("notion returned invalid json: {}", e)));
            }
            if status.as_u16() == 429 && attempt < MAX_RETRIES {
                let wait = res
                    .headers()
                    .get("Retry-After")
                    .and_then(|v| v.to_str().ok())
                    .and_then(|v| v.parse::<u64>().ok())
                    .map(Duration::from_secs)
                    .unwrap_or_else(|| backoff(attempt + 1));
                attempt += 1;
                tokio::time::sleep(wait).await;
                continue;
            }
            if status.is_server_error() && attempt < MAX_RETRIES {
                attempt += 1;
                tokio::time::sleep(backoff(attempt)).await;
                continue;
            }
            // 4xx (bad token, unshared database, malformed block) won't get
            // better by retrying — surface Notion's own message.
            let text = res.text().await.unwrap_or_default();
            let message = serde_json::from_str::<Value>(&text)
                .ok()
                .and_then(|v| {
                    v.get("message")
                        .and_then(Value::as_str)
                        .map(str::to_string)
                })
                .unwrap_or(text);
            return Err(AppError::Notion {
                status: status.as_u16(),
                message,
            });
        }
    }
}

fn backoff(attempt: u32) -> Duration {
    Duration::from_secs(1u64 << (attempt.saturating_sub(1)).min(4))
}

/// Notion caps a title at 2000 characters like any other rich_text run.
const TITLE_LIMIT: usize = 2000;

pub fn title_property(title_prop: &str, title: &str) -> Value {
    let trimmed: String = title.chars().take(TITLE_LIMIT).collect();
    json!({ title_prop: { "title": [{ "type": "text", "text": { "content": trimmed } }] } })
}

/// A `date` property carrying a single instant (no end, no time zone field —
/// the timestamp itself is UTC).
pub fn date_property(name: &str, ms: i64) -> Value {
    json!({ name: { "date": { "start": crate::notion::model::ms_to_iso8601(ms) } } })
}

/// A `rich_text` property carrying one plain string.
pub fn text_property(name: &str, value: &str) -> Value {
    json!({ name: { "rich_text": [{ "type": "text", "text": { "content": value } }] } })
}

/// Shallow-merges Notion property objects into one payload.
pub fn merge_properties(parts: impl IntoIterator<Item = Value>) -> Value {
    let mut out = serde_json::Map::new();
    for part in parts {
        if let Value::Object(o) = part {
            out.extend(o);
        }
    }
    Value::Object(out)
}

#[async_trait]
impl NotionApi for HttpNotionClient {
    async fn me(&self) -> AppResult<BotInfo> {
        let v = self.request(reqwest::Method::GET, "/users/me", None).await?;
        Ok(BotInfo {
            name: v
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or("Integration")
                .to_string(),
            workspace_name: v
                .pointer("/bot/workspace_name")
                .and_then(Value::as_str)
                .map(str::to_string),
        })
    }

    async fn search_databases(&self) -> AppResult<Vec<DbSummary>> {
        let mut out = Vec::new();
        let mut cursor: Option<String> = None;
        loop {
            let mut body = json!({
                "filter": {"value": "database", "property": "object"},
                "page_size": 100
            });
            if let Some(c) = &cursor {
                body["start_cursor"] = json!(c);
            }
            let v = self
                .request(reqwest::Method::POST, "/search", Some(body))
                .await?;
            for item in v.get("results").and_then(Value::as_array).unwrap_or(&vec![]) {
                // `search` also returns data sources / wiki databases; only
                // those with a title property can hold our notes.
                if let Some(s) = parse_db_summary(item) {
                    out.push(s);
                }
            }
            match v.get("next_cursor").and_then(Value::as_str) {
                Some(c) if v.get("has_more").and_then(Value::as_bool) == Some(true) => {
                    cursor = Some(c.to_string())
                }
                _ => break,
            }
        }
        Ok(out)
    }

    async fn retrieve_database(&self, db: &str) -> AppResult<DbInfo> {
        let v = self
            .request(reqwest::Method::GET, &format!("/databases/{}", db), None)
            .await?;
        parse_db_info(&v).ok_or_else(|| AppError::Other("unexpected database response".into()))
    }

    async fn query_database(&self, db: &str, cursor: Option<String>) -> AppResult<PageList> {
        let mut body = json!({"page_size": 100});
        if let Some(c) = cursor {
            body["start_cursor"] = json!(c);
        }
        let v = self
            .request(
                reqwest::Method::POST,
                &format!("/databases/{}/query", db),
                Some(body),
            )
            .await?;
        let pages = v
            .get("results")
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(parse_page).collect())
            .unwrap_or_default();
        let next_cursor = if v.get("has_more").and_then(Value::as_bool) == Some(true) {
            v.get("next_cursor").and_then(Value::as_str).map(str::to_string)
        } else {
            None
        };
        Ok(PageList { pages, next_cursor })
    }

    async fn retrieve_page(&self, page: &str) -> AppResult<PageMeta> {
        let v = self
            .request(reqwest::Method::GET, &format!("/pages/{}", page), None)
            .await?;
        parse_page(&v).ok_or_else(|| AppError::Other("unexpected page response".into()))
    }

    async fn list_children(&self, block: &str) -> AppResult<Vec<Value>> {
        let mut out = Vec::new();
        let mut cursor: Option<String> = None;
        loop {
            let mut path = format!("/blocks/{}/children?page_size=100", block);
            if let Some(c) = &cursor {
                path.push_str(&format!("&start_cursor={}", c));
            }
            let v = self.request(reqwest::Method::GET, &path, None).await?;
            if let Some(arr) = v.get("results").and_then(Value::as_array) {
                out.extend(arr.iter().cloned());
            }
            match v.get("next_cursor").and_then(Value::as_str) {
                Some(c) if v.get("has_more").and_then(Value::as_bool) == Some(true) => {
                    cursor = Some(c.to_string())
                }
                _ => break,
            }
        }
        Ok(out)
    }

    async fn append_children(&self, block: &str, children: Vec<Value>) -> AppResult<Vec<Value>> {
        let mut created = Vec::new();
        for batch in children.chunks(APPEND_CHUNK) {
            let v = self
                .request(
                    reqwest::Method::PATCH,
                    &format!("/blocks/{}/children", block),
                    Some(json!({"children": batch})),
                )
                .await?;
            if let Some(arr) = v.get("results").and_then(Value::as_array) {
                created.extend(arr.iter().cloned());
            }
        }
        Ok(created)
    }

    async fn delete_block(&self, block: &str) -> AppResult<()> {
        self.request(reqwest::Method::DELETE, &format!("/blocks/{}", block), None)
            .await?;
        Ok(())
    }

    async fn create_page(
        &self,
        db: &str,
        properties: Value,
        children: Vec<Value>,
    ) -> AppResult<PageMeta> {
        // Only the first chunk can ride along with the page creation; the rest
        // is appended afterwards by the caller.
        let head: Vec<Value> = children.into_iter().take(APPEND_CHUNK).collect();
        let body = json!({
            "parent": {"database_id": db},
            "properties": properties,
            "children": head,
        });
        let v = self
            .request(reqwest::Method::POST, "/pages", Some(body))
            .await?;
        parse_page(&v).ok_or_else(|| AppError::Other("unexpected create page response".into()))
    }

    async fn update_page(
        &self,
        page: &str,
        properties: Option<Value>,
        archived: Option<bool>,
    ) -> AppResult<PageMeta> {
        let mut body = json!({});
        if let Some(p) = properties {
            body["properties"] = p;
        }
        if let Some(a) = archived {
            body["archived"] = json!(a);
        }
        let v = self
            .request(reqwest::Method::PATCH, &format!("/pages/{}", page), Some(body))
            .await?;
        parse_page(&v).ok_or_else(|| AppError::Other("unexpected update page response".into()))
    }

    async fn add_database_properties(&self, db: &str, properties: Value) -> AppResult<DbInfo> {
        let v = self
            .request(
                reqwest::Method::PATCH,
                &format!("/databases/{}", db),
                Some(json!({ "properties": properties })),
            )
            .await?;
        parse_db_info(&v).ok_or_else(|| AppError::Other("unexpected database response".into()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backoff_grows_then_caps() {
        assert_eq!(backoff(1), Duration::from_secs(1));
        assert_eq!(backoff(2), Duration::from_secs(2));
        assert_eq!(backoff(3), Duration::from_secs(4));
        assert_eq!(backoff(9), Duration::from_secs(16));
    }

    #[tokio::test(start_paused = true)]
    async fn rate_limiter_spaces_requests() {
        let l = RateLimiter::new(Duration::from_millis(340));
        let start = Instant::now();
        for _ in 0..4 {
            l.acquire().await;
        }
        // Three gaps between four calls; the first is free.
        assert!(start.elapsed() >= Duration::from_millis(1020));
    }

    #[test]
    fn title_property_uses_the_configured_name_and_respects_the_limit() {
        let v = title_property("Headline", "hi");
        assert_eq!(v["Headline"]["title"][0]["text"]["content"], "hi");
        let long = title_property("Name", &"가".repeat(3000));
        assert_eq!(
            long["Name"]["title"][0]["text"]["content"]
                .as_str()
                .unwrap()
                .chars()
                .count(),
            2000
        );
    }

    #[test]
    fn properties_merge_into_one_payload() {
        let v = merge_properties([
            title_property("Name", "n"),
            date_property("Created", 0),
            date_property("Updated", 1_704_164_645_000),
        ]);
        assert_eq!(v["Name"]["title"][0]["text"]["content"], "n");
        assert_eq!(v["Created"]["date"]["start"], "1970-01-01T00:00:00.000Z");
        assert_eq!(v["Updated"]["date"]["start"], "2024-01-02T03:04:05.000Z");
    }
}
