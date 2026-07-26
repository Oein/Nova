//! In-memory [`NotionApi`] for tests.
//!
//! Faithful about the two behaviours the executor actually depends on:
//! `append_children` assigns fresh block ids and returns them in payload order,
//! and any mutation bumps the page's `last_edited_time`. The second one is what
//! makes the "our own push echoes back as a remote change" regression test
//! meaningful.

#![cfg(test)]

use std::collections::HashMap;
use std::sync::Mutex;

use async_trait::async_trait;
use serde_json::{json, Value};

use crate::error::{AppError, AppResult};
use crate::notion::client::NotionApi;
use crate::notion::model::{BotInfo, DbInfo, DbSummary, PageList, PageMeta};

#[derive(Default)]
struct Inner {
    clock: u64,
    next_id: u64,
    pages: Vec<String>,
    page_meta: HashMap<String, PageMeta>,
    blocks: HashMap<String, Value>,
    children: HashMap<String, Vec<String>>,
    parent: HashMap<String, String>,
    /// Raw properties payload last written to each page.
    page_props: HashMap<String, serde_json::Map<String, Value>>,
}

type Hook = Box<dyn Fn() + Send + Sync>;

pub struct FakeNotion {
    inner: Mutex<Inner>,
    pub database_id: String,
    pub title_prop: String,
    /// Database schema: property name -> type. Seeded with just the title.
    schema: Mutex<HashMap<String, String>>,
    /// Fails the Nth `append_children` chunk (1-based). Models Notion
    /// rejecting one malformed block partway through a multi-chunk push.
    fail_append_at: Mutex<Option<usize>>,
    append_calls: Mutex<usize>,
    /// Runs once, on the first `list_children`. Used to simulate the user
    /// saving a note while a sync is mid-flight.
    on_list_children: Mutex<Option<Hook>>,
}

impl FakeNotion {
    pub fn new(database_id: &str) -> Self {
        Self {
            inner: Mutex::new(Inner::default()),
            database_id: database_id.to_string(),
            title_prop: "Name".to_string(),
            schema: Mutex::new(HashMap::from([("Name".to_string(), "title".to_string())])),
            fail_append_at: Mutex::new(None),
            append_calls: Mutex::new(0),
            on_list_children: Mutex::new(None),
        }
    }

    /// Adds a property to the fake database schema, as a Notion user would.
    pub fn add_property(&self, name: &str, ty: &str) {
        self.schema
            .lock()
            .unwrap()
            .insert(name.to_string(), ty.to_string());
    }

    pub fn schema(&self) -> HashMap<String, String> {
        self.schema.lock().unwrap().clone()
    }

    /// The `date` value stored on a page for the given property, if any.
    pub fn page_date(&self, page_id: &str, prop: &str) -> Option<String> {
        self.inner
            .lock()
            .unwrap()
            .page_props
            .get(page_id)?
            .get(prop)?
            .pointer("/date/start")
            .and_then(Value::as_str)
            .map(str::to_string)
    }

    /// The `rich_text` value stored on a page for the given property.
    pub fn page_text(&self, page_id: &str, prop: &str) -> Option<String> {
        let inner = self.inner.lock().unwrap();
        let v = inner.page_props.get(page_id)?.get(prop)?;
        Some(crate::notion::model::rich_text_plain(v.get("rich_text")?))
    }

    pub fn fail_append_at(&self, nth: usize) {
        *self.fail_append_at.lock().unwrap() = Some(nth);
        *self.append_calls.lock().unwrap() = 0;
    }

    /// Registers a one-shot callback fired at the start of the next
    /// `list_children`, i.e. from inside a running sync.
    pub fn once_during_fetch(&self, f: impl Fn() + Send + Sync + 'static) {
        *self.on_list_children.lock().unwrap() = Some(Box::new(f));
    }

    fn touch(inner: &mut Inner, page_id: &str) {
        inner.clock += 1;
        let stamp = format!("2024-01-01T00:00:{:02}.000Z", inner.clock.min(59));
        if let Some(p) = inner.page_meta.get_mut(page_id) {
            // Include the counter so successive edits are distinguishable even
            // past 59 — Notion's second granularity is simulated separately by
            // `edit_page_titleless`, which reuses a stamp on purpose.
            p.last_edited_time = format!("{}#{}", stamp, inner.clock);
        }
    }

    fn insert_page(inner: &mut Inner, id: &str, title: &str) {
        inner.pages.push(id.to_string());
        inner.page_meta.insert(
            id.to_string(),
            PageMeta {
                id: id.to_string(),
                title: title.to_string(),
                last_edited_time: String::new(),
                created_time: "2024-01-01T00:00:00.000Z".to_string(),
                archived: false,
                url: None,
                properties: Value::Object(Default::default()),
            },
        );
        inner.children.insert(id.to_string(), Vec::new());
    }

    /// Seeds a page as if a human had written it in Notion.
    pub fn seed_page(&self, id: &str, title: &str, blocks: Vec<Value>) {
        let mut inner = self.inner.lock().unwrap();
        Self::insert_page(&mut inner, id, title);
        Self::append(&mut inner, id, blocks);
        Self::touch(&mut inner, id);
    }

    /// Replaces a page's body the way a Notion user would.
    pub fn edit_page(&self, id: &str, blocks: Vec<Value>) {
        let mut inner = self.inner.lock().unwrap();
        let existing = inner.children.get(id).cloned().unwrap_or_default();
        for b in existing {
            Self::remove(&mut inner, &b);
        }
        Self::append(&mut inner, id, blocks);
        Self::touch(&mut inner, id);
    }

    /// Bumps only the timestamp — models a property edit or Notion's own
    /// bookkeeping, which must not be mistaken for a content change.
    pub fn touch_only(&self, id: &str) {
        let mut inner = self.inner.lock().unwrap();
        Self::touch(&mut inner, id);
    }

    /// Archives a page the way a Notion user deleting it would.
    pub fn update_page_archived(&self, id: &str) {
        let mut inner = self.inner.lock().unwrap();
        if let Some(p) = inner.page_meta.get_mut(id) {
            p.archived = true;
        }
        Self::touch(&mut inner, id);
    }

    pub fn page_ids(&self) -> Vec<String> {
        self.inner.lock().unwrap().pages.clone()
    }

    pub fn block_types(&self, page_id: &str) -> Vec<String> {
        let inner = self.inner.lock().unwrap();
        inner
            .children
            .get(page_id)
            .map(|ids| {
                ids.iter()
                    .filter_map(|i| inner.blocks.get(i))
                    .map(|b| b["type"].as_str().unwrap_or("?").to_string())
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Plain text of each top-level block, for asserting a page's content
    /// survived (or didn't).
    pub fn block_texts(&self, page_id: &str) -> Vec<String> {
        let inner = self.inner.lock().unwrap();
        inner
            .children
            .get(page_id)
            .map(|ids| {
                ids.iter()
                    .filter_map(|i| inner.blocks.get(i))
                    .map(|b| {
                        let ty = b["type"].as_str().unwrap_or("");
                        crate::notion::model::rich_text_plain(&b[ty]["rich_text"])
                    })
                    .collect()
            })
            .unwrap_or_default()
    }

    pub fn block_ids(&self, page_id: &str) -> Vec<String> {
        self.inner
            .lock()
            .unwrap()
            .children
            .get(page_id)
            .cloned()
            .unwrap_or_default()
    }

    pub fn page_title(&self, page_id: &str) -> Option<String> {
        self.inner
            .lock()
            .unwrap()
            .page_meta
            .get(page_id)
            .map(|p| p.title.clone())
    }

    pub fn is_archived(&self, page_id: &str) -> bool {
        self.inner
            .lock()
            .unwrap()
            .page_meta
            .get(page_id)
            .is_some_and(|p| p.archived)
    }

    fn append(inner: &mut Inner, parent: &str, blocks: Vec<Value>) -> Vec<Value> {
        let mut created = Vec::new();
        for mut b in blocks {
            inner.next_id += 1;
            let id = format!("blk-{}", inner.next_id);
            let ty = b["type"].as_str().unwrap_or("paragraph").to_string();
            // Nested children arrive inline in the payload; store them as real
            // children so `list_children` walks the same shape Notion returns.
            let kids = b
                .get_mut(&ty)
                .and_then(|v| v.as_object_mut())
                .and_then(|o| o.remove("children"))
                .and_then(|v| match v {
                    Value::Array(a) => Some(a),
                    _ => None,
                })
                .unwrap_or_default();
            b["id"] = json!(id);
            b["object"] = json!("block");
            b["has_children"] = json!(!kids.is_empty());
            inner.blocks.insert(id.clone(), b.clone());
            inner.children.entry(id.clone()).or_default();
            inner.parent.insert(id.clone(), parent.to_string());
            inner.children.entry(parent.to_string()).or_default().push(id.clone());
            if !kids.is_empty() {
                Self::append(inner, &id, kids);
            }
            created.push(inner.blocks[&id].clone());
        }
        created
    }

    fn remove(inner: &mut Inner, block_id: &str) {
        let kids = inner.children.remove(block_id).unwrap_or_default();
        for k in kids {
            Self::remove(inner, &k);
        }
        inner.blocks.remove(block_id);
        if let Some(p) = inner.parent.remove(block_id) {
            if let Some(list) = inner.children.get_mut(&p) {
                list.retain(|c| c != block_id);
            }
        }
    }
}

#[async_trait]
impl NotionApi for FakeNotion {
    async fn me(&self) -> AppResult<BotInfo> {
        Ok(BotInfo {
            name: "Fake".into(),
            workspace_name: Some("Test".into()),
        })
    }

    async fn search_databases(&self) -> AppResult<Vec<DbSummary>> {
        Ok(vec![DbSummary {
            id: self.database_id.clone(),
            title: "Notes".into(),
            url: None,
        }])
    }

    async fn retrieve_database(&self, db: &str) -> AppResult<DbInfo> {
        if db != self.database_id {
            return Err(AppError::Notion {
                status: 404,
                message: "no such database".into(),
            });
        }
        Ok(DbInfo {
            id: db.to_string(),
            title: "Notes".into(),
            title_prop: self.title_prop.clone(),
            properties: self.schema(),
        })
    }

    async fn query_database(&self, _db: &str, _cursor: Option<String>) -> AppResult<PageList> {
        let inner = self.inner.lock().unwrap();
        Ok(PageList {
            // Notion's query omits archived pages, and the executor relies on
            // that absence to notice a remote deletion.
            pages: inner
                .pages
                .iter()
                .filter_map(|id| inner.page_meta.get(id))
                .filter(|p| !p.archived)
                .cloned()
                .collect(),
            next_cursor: None,
        })
    }

    async fn retrieve_page(&self, page: &str) -> AppResult<PageMeta> {
        self.inner
            .lock()
            .unwrap()
            .page_meta
            .get(page)
            .cloned()
            .ok_or_else(|| AppError::Notion {
                status: 404,
                message: "no such page".into(),
            })
    }

    async fn list_children(&self, block: &str) -> AppResult<Vec<Value>> {
        if let Some(hook) = self.on_list_children.lock().unwrap().take() {
            hook();
        }
        let inner = self.inner.lock().unwrap();
        Ok(inner
            .children
            .get(block)
            .map(|ids| ids.iter().filter_map(|i| inner.blocks.get(i)).cloned().collect())
            .unwrap_or_default())
    }

    async fn append_children(&self, block: &str, children: Vec<Value>) -> AppResult<Vec<Value>> {
        {
            let mut calls = self.append_calls.lock().unwrap();
            *calls += 1;
            if *self.fail_append_at.lock().unwrap() == Some(*calls) {
                return Err(AppError::Notion {
                    status: 400,
                    message: "validation_error: body.children[0] is not valid".into(),
                });
            }
        }
        let mut inner = self.inner.lock().unwrap();
        let created = Self::append(&mut inner, block, children);
        let page = inner.parent.get(block).cloned().unwrap_or(block.to_string());
        Self::touch(&mut inner, &page);
        Ok(created)
    }

    async fn delete_block(&self, block: &str) -> AppResult<()> {
        let mut inner = self.inner.lock().unwrap();
        let page = inner.parent.get(block).cloned().unwrap_or_default();
        Self::remove(&mut inner, block);
        Self::touch(&mut inner, &page);
        Ok(())
    }

    async fn create_page(
        &self,
        db: &str,
        properties: Value,
        children: Vec<Value>,
    ) -> AppResult<PageMeta> {
        if db != self.database_id {
            return Err(AppError::Notion {
                status: 404,
                message: "no such database".into(),
            });
        }
        self.reject_unknown_properties(&properties)?;
        let title = self.title_from(&properties);
        let mut inner = self.inner.lock().unwrap();
        inner.next_id += 1;
        let id = format!("page-{}", inner.next_id);
        Self::insert_page(&mut inner, &id, &title);
        Self::store_props(&mut inner, &id, &properties);
        Self::sync_meta_props(&mut inner, &id);
        Self::append(&mut inner, &id, children);
        Self::touch(&mut inner, &id);
        Ok(inner.page_meta[&id].clone())
    }

    async fn update_page(
        &self,
        page: &str,
        properties: Option<Value>,
        archived: Option<bool>,
    ) -> AppResult<PageMeta> {
        if let Some(p) = &properties {
            self.reject_unknown_properties(p)?;
        }
        let title = properties.as_ref().map(|p| self.title_from(p));
        let mut inner = self.inner.lock().unwrap();
        {
            let meta = inner.page_meta.get_mut(page).ok_or_else(|| AppError::Notion {
                status: 404,
                message: "no such page".into(),
            })?;
            if let Some(t) = &title {
                meta.title = t.clone();
            }
            if let Some(a) = archived {
                meta.archived = a;
            }
        }
        if let Some(p) = &properties {
            Self::store_props(&mut inner, page, p);
        }
        Self::sync_meta_props(&mut inner, page);
        Self::touch(&mut inner, page);
        Ok(inner.page_meta[page].clone())
    }

    async fn add_database_properties(&self, db: &str, properties: Value) -> AppResult<DbInfo> {
        if db != self.database_id {
            return Err(AppError::Notion {
                status: 404,
                message: "no such database".into(),
            });
        }
        if let Value::Object(props) = &properties {
            let mut schema = self.schema.lock().unwrap();
            for (name, spec) in props {
                let ty = spec
                    .as_object()
                    .and_then(|o| o.keys().next().cloned())
                    .unwrap_or_default();
                schema.insert(name.clone(), ty);
            }
        }
        self.retrieve_database(db).await
    }
}

impl FakeNotion {
    /// Notion 400s on a property that isn't in the schema; the real failure
    /// mode we care about is writing to a column that was never created.
    fn reject_unknown_properties(&self, properties: &Value) -> AppResult<()> {
        let schema = self.schema.lock().unwrap();
        if let Value::Object(props) = properties {
            for name in props.keys() {
                if !schema.contains_key(name) {
                    return Err(AppError::Notion {
                        status: 400,
                        message: format!("{} is not a property that exists", name),
                    });
                }
            }
        }
        Ok(())
    }

    fn title_from(&self, properties: &Value) -> String {
        properties
            .get(&self.title_prop)
            .and_then(|p| p.get("title"))
            .map(crate::notion::model::rich_text_plain)
            .unwrap_or_default()
    }

    /// Mirrors the stored properties onto the page metadata, so `PageMeta`
    /// carries them exactly as a real API response would.
    fn sync_meta_props(inner: &mut Inner, page: &str) {
        let props = inner.page_props.get(page).cloned().unwrap_or_default();
        if let Some(meta) = inner.page_meta.get_mut(page) {
            meta.properties = Value::Object(props);
        }
    }

    fn store_props(inner: &mut Inner, page: &str, properties: &Value) {
        if let Value::Object(props) = properties {
            let slot = inner.page_props.entry(page.to_string()).or_default();
            for (k, v) in props {
                // Notion echoes properties back with a `type` discriminator
                // that write payloads don't carry. Add it, or readers that
                // rely on it would work against the fake but not for real.
                let mut stored = v.clone();
                if let (Value::Object(o), None) = (&mut stored, v.get("type")) {
                    if let Some(kind) = o.keys().next().cloned() {
                        o.insert("type".to_string(), Value::String(kind));
                    }
                }
                slot.insert(k.clone(), stored);
            }
        }
    }
}
