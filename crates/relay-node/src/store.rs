//! SQLite storage: key bindings, cards, queued envelopes, directory, blob index.
//!
//! Blob bytes live as files in `<data>/blobs/`; only their index is in SQLite.

use std::path::Path;
use std::sync::Mutex;

use rusqlite::{Connection, OptionalExtension, params};

/// Mailbox binding created on first successful auth (trust on first use).
#[derive(Debug, Clone)]
pub struct Binding {
    pub pubkey: [u8; 32],
    pub card: Option<Vec<u8>>,
}

/// One envelope waiting in a mailbox.
#[derive(Debug, Clone)]
pub struct Queued {
    pub id: [u8; 16],
    pub env: Vec<u8>,
}

/// Outcome of queueing an envelope.
#[derive(Debug, PartialEq, Eq)]
pub enum Enqueue {
    Stored,
    Duplicate,
    QuotaExceeded,
}

/// Push registration of a mailbox (`push` frame). `kind` is `apns` (with `token`, `env`) or
/// `webpush` (with `sub_json`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PushReg {
    pub kind: String,
    pub token: Option<String>,
    pub env: Option<String>,
    pub sub_json: Option<String>,
}

/// Outcome of a directory claim.
#[derive(Debug, PartialEq, Eq)]
pub enum Claim {
    Created,
    Updated,
    Taken,
    TooMany,
}

pub struct Store {
    conn: Mutex<Connection>,
}

/// A mailbox may hold at most this many handles.
pub const MAX_HANDLES_PER_MAILBOX: i64 = 5;

impl Store {
    pub fn open(path: &Path) -> rusqlite::Result<Self> {
        let conn = Connection::open(path)?;
        Self::init(conn)
    }

    pub fn open_in_memory() -> rusqlite::Result<Self> {
        Self::init(Connection::open_in_memory()?)
    }

    fn init(conn: Connection) -> rusqlite::Result<Self> {
        conn.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA synchronous = NORMAL;
             PRAGMA foreign_keys = ON;
             CREATE TABLE IF NOT EXISTS bindings (
                 mailbox BLOB PRIMARY KEY,
                 pubkey BLOB NOT NULL,
                 card BLOB,
                 created_at INTEGER NOT NULL,
                 updated_at INTEGER NOT NULL
             );
             CREATE TABLE IF NOT EXISTS envelopes (
                 seq INTEGER PRIMARY KEY AUTOINCREMENT,
                 mailbox BLOB NOT NULL,
                 env_id BLOB NOT NULL,
                 env BLOB NOT NULL,
                 size INTEGER NOT NULL,
                 expires_at INTEGER NOT NULL,
                 UNIQUE (mailbox, env_id)
             );
             CREATE INDEX IF NOT EXISTS envelopes_mailbox ON envelopes (mailbox, seq);
             CREATE INDEX IF NOT EXISTS envelopes_expiry ON envelopes (expires_at);
             CREATE TABLE IF NOT EXISTS directory (
                 handle TEXT PRIMARY KEY,
                 mailbox BLOB NOT NULL,
                 card BLOB NOT NULL,
                 updated_at INTEGER NOT NULL
             );
             CREATE INDEX IF NOT EXISTS directory_mailbox ON directory (mailbox);
             CREATE TABLE IF NOT EXISTS blobs (
                 sha TEXT PRIMARY KEY,
                 size INTEGER NOT NULL,
                 expires_at INTEGER NOT NULL
             );
             CREATE INDEX IF NOT EXISTS blobs_expiry ON blobs (expires_at);
             CREATE TABLE IF NOT EXISTS push (
                 mailbox BLOB PRIMARY KEY,
                 kind TEXT NOT NULL,
                 token TEXT,
                 env TEXT,
                 sub_json TEXT,
                 updated_at INTEGER NOT NULL
             );",
        )?;
        Ok(Self { conn: Mutex::new(conn) })
    }

    fn c(&self) -> std::sync::MutexGuard<'_, Connection> {
        self.conn.lock().unwrap_or_else(|e| e.into_inner())
    }

    // Bindings and cards.

    pub fn binding(&self, mailbox: &[u8; 16]) -> rusqlite::Result<Option<Binding>> {
        self.c()
            .query_row("SELECT pubkey, card FROM bindings WHERE mailbox = ?1", [&mailbox[..]], |r| {
                let pk: Vec<u8> = r.get(0)?;
                let card: Option<Vec<u8>> = r.get(1)?;
                Ok((pk, card))
            })
            .optional()
            .map(|o| {
                o.and_then(|(pk, card)| {
                    let pubkey: [u8; 32] = pk.try_into().ok()?;
                    Some(Binding { pubkey, card })
                })
            })
    }

    /// Binds `mailbox` to `pubkey` if it is unbound. Returns the key the mailbox is bound to
    /// after the call (the existing one when it was already bound).
    pub fn bind(&self, mailbox: &[u8; 16], pubkey: &[u8; 32], now: i64) -> rusqlite::Result<[u8; 32]> {
        let c = self.c();
        c.execute(
            "INSERT OR IGNORE INTO bindings (mailbox, pubkey, created_at, updated_at) VALUES (?1, ?2, ?3, ?3)",
            params![&mailbox[..], &pubkey[..], now],
        )?;
        let pk: Vec<u8> = c.query_row("SELECT pubkey FROM bindings WHERE mailbox = ?1", [&mailbox[..]], |r| r.get(0))?;
        Ok(pk.try_into().unwrap_or([0u8; 32]))
    }

    pub fn set_card(&self, mailbox: &[u8; 16], card: &[u8], now: i64) -> rusqlite::Result<()> {
        self.c().execute(
            "UPDATE bindings SET card = ?2, updated_at = ?3 WHERE mailbox = ?1",
            params![&mailbox[..], card, now],
        )?;
        Ok(())
    }

    // Envelopes.

    pub fn mailbox_usage(&self, mailbox: &[u8; 16]) -> rusqlite::Result<i64> {
        self.c().query_row(
            "SELECT COALESCE(SUM(size), 0) FROM envelopes WHERE mailbox = ?1",
            [&mailbox[..]],
            |r| r.get(0),
        )
    }

    pub fn enqueue(
        &self,
        mailbox: &[u8; 16],
        id: &[u8; 16],
        env: &[u8],
        expires_at: i64,
        quota: i64,
    ) -> rusqlite::Result<Enqueue> {
        let mut c = self.c();
        let tx = c.transaction()?;
        let exists: bool = tx.query_row(
            "SELECT EXISTS (SELECT 1 FROM envelopes WHERE mailbox = ?1 AND env_id = ?2)",
            params![&mailbox[..], &id[..]],
            |r| r.get(0),
        )?;
        if exists {
            return Ok(Enqueue::Duplicate);
        }
        let used: i64 = tx.query_row(
            "SELECT COALESCE(SUM(size), 0) FROM envelopes WHERE mailbox = ?1",
            [&mailbox[..]],
            |r| r.get(0),
        )?;
        if used + env.len() as i64 > quota {
            return Ok(Enqueue::QuotaExceeded);
        }
        tx.execute(
            "INSERT INTO envelopes (mailbox, env_id, env, size, expires_at) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![&mailbox[..], &id[..], env, env.len() as i64, expires_at],
        )?;
        tx.commit()?;
        Ok(Enqueue::Stored)
    }

    /// Pending envelopes of a mailbox, oldest first, skipping expired ones.
    pub fn pending(&self, mailbox: &[u8; 16], now: i64) -> rusqlite::Result<Vec<Queued>> {
        let c = self.c();
        let mut st = c.prepare(
            "SELECT env_id, env FROM envelopes WHERE mailbox = ?1 AND expires_at > ?2 ORDER BY seq",
        )?;
        let rows = st.query_map(params![&mailbox[..], now], |r| {
            let id: Vec<u8> = r.get(0)?;
            let env: Vec<u8> = r.get(1)?;
            Ok((id, env))
        })?;
        let mut out = Vec::new();
        for row in rows {
            let (id, env) = row?;
            if let Ok(id) = <[u8; 16]>::try_from(id) {
                out.push(Queued { id, env });
            }
        }
        Ok(out)
    }

    /// Deletes an acknowledged envelope. Returns whether a row was removed.
    pub fn ack(&self, mailbox: &[u8; 16], id: &[u8; 16]) -> rusqlite::Result<bool> {
        let n = self.c().execute(
            "DELETE FROM envelopes WHERE mailbox = ?1 AND env_id = ?2",
            params![&mailbox[..], &id[..]],
        )?;
        Ok(n > 0)
    }

    // Directory.

    pub fn claim_handle(&self, handle: &str, mailbox: &[u8; 16], card: &[u8], now: i64) -> rusqlite::Result<Claim> {
        let mut c = self.c();
        let tx = c.transaction()?;
        let owner: Option<Vec<u8>> = tx
            .query_row("SELECT mailbox FROM directory WHERE handle = ?1", [handle], |r| r.get(0))
            .optional()?;
        let res = match owner {
            Some(o) if o.as_slice() == &mailbox[..] => {
                tx.execute(
                    "UPDATE directory SET card = ?2, updated_at = ?3 WHERE handle = ?1",
                    params![handle, card, now],
                )?;
                Claim::Updated
            }
            Some(_) => Claim::Taken,
            None => {
                let count: i64 = tx.query_row(
                    "SELECT COUNT(*) FROM directory WHERE mailbox = ?1",
                    [&mailbox[..]],
                    |r| r.get(0),
                )?;
                if count >= MAX_HANDLES_PER_MAILBOX {
                    Claim::TooMany
                } else {
                    tx.execute(
                        "INSERT INTO directory (handle, mailbox, card, updated_at) VALUES (?1, ?2, ?3, ?4)",
                        params![handle, &mailbox[..], card, now],
                    )?;
                    Claim::Created
                }
            }
        };
        tx.commit()?;
        Ok(res)
    }

    pub fn lookup_handle(&self, handle: &str) -> rusqlite::Result<Option<([u8; 16], Vec<u8>)>> {
        self.c()
            .query_row("SELECT mailbox, card FROM directory WHERE handle = ?1", [handle], |r| {
                let m: Vec<u8> = r.get(0)?;
                let card: Vec<u8> = r.get(1)?;
                Ok((m, card))
            })
            .optional()
            .map(|o| o.and_then(|(m, card)| Some((<[u8; 16]>::try_from(m).ok()?, card))))
    }

    // Blobs.

    pub fn blob_exists(&self, sha: &str, now: i64) -> rusqlite::Result<bool> {
        self.c().query_row(
            "SELECT EXISTS (SELECT 1 FROM blobs WHERE sha = ?1 AND expires_at > ?2)",
            params![sha, now],
            |r| r.get(0),
        )
    }

    pub fn put_blob(&self, sha: &str, size: i64, expires_at: i64) -> rusqlite::Result<()> {
        self.c().execute(
            "INSERT INTO blobs (sha, size, expires_at) VALUES (?1, ?2, ?3)
             ON CONFLICT (sha) DO UPDATE SET expires_at = excluded.expires_at",
            params![sha, size, expires_at],
        )?;
        Ok(())
    }

    // Push registrations.

    /// Registers (or replaces) the push target of a mailbox.
    pub fn set_push(&self, mailbox: &[u8; 16], reg: &PushReg, now: i64) -> rusqlite::Result<()> {
        self.c().execute(
            "INSERT INTO push (mailbox, kind, token, env, sub_json, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
             ON CONFLICT (mailbox) DO UPDATE SET kind = excluded.kind, token = excluded.token,
                 env = excluded.env, sub_json = excluded.sub_json, updated_at = excluded.updated_at",
            params![&mailbox[..], reg.kind, reg.token, reg.env, reg.sub_json, now],
        )?;
        Ok(())
    }

    pub fn delete_push(&self, mailbox: &[u8; 16]) -> rusqlite::Result<()> {
        self.c().execute("DELETE FROM push WHERE mailbox = ?1", [&mailbox[..]])?;
        Ok(())
    }

    /// Deletes the registration only if it is still `reg` (a newer one is kept).
    pub fn delete_push_if(&self, mailbox: &[u8; 16], reg: &PushReg) -> rusqlite::Result<bool> {
        let n = self.c().execute(
            "DELETE FROM push WHERE mailbox = ?1 AND kind = ?2 AND token IS ?3 AND sub_json IS ?4",
            params![&mailbox[..], reg.kind, reg.token, reg.sub_json],
        )?;
        Ok(n > 0)
    }

    pub fn get_push(&self, mailbox: &[u8; 16]) -> rusqlite::Result<Option<PushReg>> {
        self.c()
            .query_row("SELECT kind, token, env, sub_json FROM push WHERE mailbox = ?1", [&mailbox[..]], |r| {
                Ok(PushReg { kind: r.get(0)?, token: r.get(1)?, env: r.get(2)?, sub_json: r.get(3)? })
            })
            .optional()
    }

    // Expiry.

    /// Deletes expired envelopes and blob rows. Returns the expired blob hashes so the caller
    /// can delete their files.
    pub fn sweep(&self, now: i64) -> rusqlite::Result<(usize, Vec<String>)> {
        let mut c = self.c();
        let tx = c.transaction()?;
        let envs = tx.execute("DELETE FROM envelopes WHERE expires_at <= ?1", [now])?;
        let shas: Vec<String> = {
            let mut st = tx.prepare("SELECT sha FROM blobs WHERE expires_at <= ?1")?;
            st.query_map([now], |r| r.get(0))?.collect::<Result<_, _>>()?
        };
        tx.execute("DELETE FROM blobs WHERE expires_at <= ?1", [now])?;
        tx.commit()?;
        Ok((envs, shas))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn queue_quota_ack() {
        let s = Store::open_in_memory().unwrap();
        let mb = [1u8; 16];
        assert_eq!(s.enqueue(&mb, &[1; 16], &[0; 60], 100, 100).unwrap(), Enqueue::Stored);
        assert_eq!(s.enqueue(&mb, &[1; 16], &[0; 60], 100, 100).unwrap(), Enqueue::Duplicate);
        assert_eq!(s.enqueue(&mb, &[2; 16], &[0; 60], 100, 100).unwrap(), Enqueue::QuotaExceeded);
        assert_eq!(s.pending(&mb, 0).unwrap().len(), 1);
        assert!(s.ack(&mb, &[1; 16]).unwrap());
        assert!(s.pending(&mb, 0).unwrap().is_empty());
    }

    #[test]
    fn expiry() {
        let s = Store::open_in_memory().unwrap();
        let mb = [1u8; 16];
        s.enqueue(&mb, &[1; 16], b"x", 10, 100).unwrap();
        s.put_blob("ab", 1, 10).unwrap();
        assert!(s.pending(&mb, 11).unwrap().is_empty());
        let (n, shas) = s.sweep(11).unwrap();
        assert_eq!((n, shas), (1, vec!["ab".to_string()]));
    }

    #[test]
    fn push_registrations() {
        let s = Store::open_in_memory().unwrap();
        let mb = [4u8; 16];
        let a = PushReg { kind: "apns".into(), token: Some("aa".into()), env: Some("prod".into()), sub_json: None };
        let b = PushReg { kind: "webpush".into(), token: None, env: None, sub_json: Some("{}".into()) };
        assert_eq!(s.get_push(&mb).unwrap(), None);
        s.set_push(&mb, &a, 1).unwrap();
        assert_eq!(s.get_push(&mb).unwrap(), Some(a.clone()));
        s.set_push(&mb, &b, 2).unwrap();
        assert!(!s.delete_push_if(&mb, &a).unwrap(), "stale delete keeps the newer registration");
        assert_eq!(s.get_push(&mb).unwrap(), Some(b.clone()));
        assert!(s.delete_push_if(&mb, &b).unwrap());
        s.set_push(&mb, &a, 3).unwrap();
        s.delete_push(&mb).unwrap();
        assert_eq!(s.get_push(&mb).unwrap(), None);
    }

    /// A database created before the push table existed gains it on open.
    #[test]
    fn migrates_old_database() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("old.sqlite3");
        Connection::open(&path)
            .unwrap()
            .execute_batch("CREATE TABLE bindings (mailbox BLOB PRIMARY KEY, pubkey BLOB NOT NULL, card BLOB, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);")
            .unwrap();
        let s = Store::open(&path).unwrap();
        let reg = PushReg { kind: "apns".into(), token: Some("aa".into()), env: Some("prod".into()), sub_json: None };
        s.set_push(&[1; 16], &reg, 1).unwrap();
        drop(s);
        assert_eq!(Store::open(&path).unwrap().get_push(&[1; 16]).unwrap(), Some(reg));
    }

    #[test]
    fn tofu_binding() {
        let s = Store::open_in_memory().unwrap();
        let mb = [3u8; 16];
        assert_eq!(s.bind(&mb, &[1; 32], 0).unwrap(), [1; 32]);
        assert_eq!(s.bind(&mb, &[2; 32], 0).unwrap(), [1; 32]);
    }
}
