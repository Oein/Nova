use std::fs::Metadata;
use std::time::SystemTime;

pub fn mtime_ms(meta: &Metadata) -> i64 {
    meta.modified()
        .ok()
        .and_then(|t| system_time_to_ms(t))
        .unwrap_or(0)
}

pub fn system_time_to_ms(t: SystemTime) -> Option<i64> {
    match t.duration_since(SystemTime::UNIX_EPOCH) {
        Ok(d) => i64::try_from(d.as_millis()).ok(),
        Err(e) => {
            let d = e.duration();
            i64::try_from(d.as_millis()).ok().map(|v| -v)
        }
    }
}
