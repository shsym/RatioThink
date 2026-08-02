//! Inferlet registry: scan a directory, validate it, swap it in atomically.
//!
//! Adding an inferlet is two files plus a `[ratio]` manifest table, with no
//! gateway rebuild. The honest scope of that claim: **no gateway code for an
//! inferlet implementing an already-supported protocol class**. A genuinely new
//! interaction shape is a new [`Protocol`], and that is gateway work.
//!
//! Two properties the naive version gets wrong:
//!
//! * **Install tracking keys on the artifact digest, not the route.** A
//!   `OnceCell` per route installs once and then never notices that the route's
//!   files changed — reload would appear to succeed while serving stale wasm.
//! * **Validation happens before the swap.** A scan that finds a duplicate
//!   route or a malformed manifest must leave the running registry untouched,
//!   not half-replace it.

use anyhow::{Context as _, Result, bail};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

/// How the gateway drives an inferlet: which event commits the HTTP response,
/// what terminates it, which renderer applies, and how the return value reads.
///
/// This exists because the chat driver commits on `Event::Ready`, and the
/// captured ToT/Best-of-N streams contain **no `Ready`** — they open on
/// `tree_start` and end on `tree_complete`/`awaiting_selection`. Without a
/// declared class, a tree inferlet hangs until `first_event_timeout`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Protocol {
    /// Ready → deltas → finish. Implemented.
    ChatV1,
    /// tree_start → node_* → tree_complete | awaiting_selection. Milestone B2.
    TreeV1,
    /// No stream; the return value is the whole response.
    JsonUnaryV1,
}

impl Protocol {
    fn parse(s: &str) -> Result<Self> {
        Ok(match s {
            "chat-v1" => Self::ChatV1,
            "tree-v1" => Self::TreeV1,
            "json-unary-v1" => Self::JsonUnaryV1,
            other => bail!(
                "unknown protocol {other:?} (known: chat-v1, tree-v1, json-unary-v1). \
                 A new interaction shape needs gateway support, not just a manifest entry."
            ),
        })
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::ChatV1 => "chat-v1",
            Self::TreeV1 => "tree-v1",
            Self::JsonUnaryV1 => "json-unary-v1",
        }
    }

    /// Whether the gateway can actually drive this today.
    pub fn implemented(self) -> bool {
        matches!(self, Self::ChatV1)
    }
}

#[derive(Debug, Clone)]
pub struct Entry {
    /// The name clients put in `inferlet`.
    pub route: String,
    /// pie program id, `name@version` from `[package]`.
    pub program: String,
    pub protocol: Protocol,
    pub wasm: PathBuf,
    pub manifest: PathBuf,
    /// Identity of THIS version of the artifacts. Changing either file changes
    /// this, which is what makes reload actually reload.
    pub digest: String,
    pub preload: bool,
    /// Additional names that resolve here — how `chat-apc` from the shipped app
    /// reaches the `chat` inferlet without the gateway hardcoding that string.
    pub aliases: Vec<String>,
    /// Durable namespaces this inferlet declares. Used for GC scoping and
    /// collision detection — NOT enforcement: pie authorizes snapshots by
    /// `(username, name)` with no program in the key, so a guest can touch any
    /// name regardless of what it declared. May legitimately be empty (`echo`).
    pub snapshot_prefixes: Vec<String>,
}

#[derive(Debug, Default)]
pub struct Registry {
    /// Includes aliases, so a lookup is one hash probe.
    by_route: HashMap<String, Arc<Entry>>,
    /// One per artifact pair — what preload and reload iterate, so an aliased
    /// inferlet is not installed twice.
    primary: Vec<Arc<Entry>>,
}

impl Registry {
    pub fn get(&self, route: &str) -> Option<&Arc<Entry>> {
        self.by_route.get(route)
    }

    /// Sorted, for a 404 that tells the caller what *is* available.
    pub fn routes(&self) -> Vec<String> {
        let mut v: Vec<String> = self.by_route.keys().cloned().collect();
        v.sort();
        v
    }

    pub fn entries(&self) -> impl Iterator<Item = &Arc<Entry>> {
        self.primary.iter()
    }

    /// Scan and fully validate. Returns `Err` without side effects, so a bad
    /// directory can never partially replace a good registry.
    pub fn scan(dir: &Path) -> Result<Self> {
        let mut by_route: HashMap<String, Arc<Entry>> = HashMap::new();
        let mut primary: Vec<Arc<Entry>> = Vec::new();
        let mut programs: HashSet<String> = HashSet::new();

        let rd = std::fs::read_dir(dir)
            .with_context(|| format!("cannot read inferlet dir {}", dir.display()))?;
        let mut wasms: Vec<PathBuf> = rd
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.extension().is_some_and(|x| x == "wasm"))
            .collect();
        wasms.sort();

        for wasm in wasms {
            let stem = wasm
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or_default()
                .to_string();
            // Staged layout is `{name}.wasm` + `{name}.Pie.toml`.
            let manifest = wasm.with_file_name(format!("{stem}.Pie.toml"));
            if !manifest.exists() {
                bail!(
                    "{} has no matching {}",
                    wasm.display(),
                    manifest.file_name().unwrap_or_default().to_string_lossy()
                );
            }

            let entry = Arc::new(parse_entry(&wasm, &manifest)?);

            if !programs.insert(entry.program.clone()) {
                bail!(
                    "duplicate program id {:?} (from {}). Two inferlets cannot share \
                     a name@version — pie would install one over the other.",
                    entry.program,
                    entry.wasm.display()
                );
            }
            // Aliases occupy the same namespace as routes: `chat-apc` colliding
            // with a real route must fail the scan, not silently shadow it.
            for name in std::iter::once(&entry.route).chain(entry.aliases.iter()) {
                if let Some(prev) = by_route.get(name) {
                    bail!(
                        "duplicate route {name:?}: {} and {}",
                        prev.wasm.display(),
                        entry.wasm.display()
                    );
                }
                by_route.insert(name.clone(), Arc::clone(&entry));
            }
            primary.push(entry);
        }

        if primary.is_empty() {
            bail!("no inferlets found in {}", dir.display());
        }
        Ok(Self { by_route, primary })
    }
}

fn parse_entry(wasm: &Path, manifest: &Path) -> Result<Entry> {
    let manifest_bytes = std::fs::read(manifest)
        .with_context(|| format!("cannot read {}", manifest.display()))?;
    let wasm_bytes =
        std::fs::read(wasm).with_context(|| format!("cannot read {}", wasm.display()))?;

    let doc: toml::Value = toml::from_str(
        std::str::from_utf8(&manifest_bytes)
            .with_context(|| format!("{} is not UTF-8", manifest.display()))?,
    )
    .with_context(|| format!("cannot parse {}", manifest.display()))?;

    let pkg = doc
        .get("package")
        .with_context(|| format!("{} has no [package]", manifest.display()))?;
    let name = pkg
        .get("name")
        .and_then(|v| v.as_str())
        .with_context(|| format!("{} has no [package].name", manifest.display()))?;
    let version = pkg
        .get("version")
        .and_then(|v| v.as_str())
        .with_context(|| format!("{} has no [package].version", manifest.display()))?;

    let ratio = doc.get("ratio");
    let route = ratio
        .and_then(|r| r.get("route"))
        .and_then(|v| v.as_str())
        .unwrap_or(name)
        .to_string();
    let protocol = Protocol::parse(
        ratio
            .and_then(|r| r.get("protocol"))
            .and_then(|v| v.as_str())
            .unwrap_or("chat-v1"),
    )
    .with_context(|| format!("in {}", manifest.display()))?;
    let preload = ratio
        .and_then(|r| r.get("preload"))
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    let aliases = ratio
        .and_then(|r| r.get("aliases"))
        .and_then(|v| v.as_array())
        .map(|a| {
            a.iter()
                .filter_map(|x| x.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default();
    let snapshot_prefixes = ratio
        .and_then(|r| r.get("snapshot_prefixes"))
        .and_then(|v| v.as_array())
        .map(|a| {
            a.iter()
                .filter_map(|x| x.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default();

    // Both artifacts, length-delimited: the digest must change if EITHER does.
    let mut h = Sha256::new();
    h.update((wasm_bytes.len() as u64).to_le_bytes());
    h.update(&wasm_bytes);
    h.update((manifest_bytes.len() as u64).to_le_bytes());
    h.update(&manifest_bytes);
    let digest = format!("{:x}", h.finalize());

    Ok(Entry {
        route,
        program: format!("{name}@{version}"),
        protocol,
        wasm: wasm.to_path_buf(),
        manifest: manifest.to_path_buf(),
        digest: digest[..16].to_string(),
        preload,
        aliases,
        snapshot_prefixes,
    })
}

/// Mirror of what the engine currently holds: `program id -> artifact digest`.
///
/// Two things this must NOT be:
///
/// * **Route-keyed.** A route whose files changed would report "already done"
///   forever, and reload would silently keep serving the old wasm.
/// * **A set of every digest ever seen.** `program::add` overwrites, so pie
///   holds exactly one artifact per program id. Remembering history means
///   reverting A → B → A skips the reinstall while the engine still holds B —
///   the reload appears to work and serves the wrong bytes. Found by the revert
///   leg of the B1 gate, which is why that leg exists.
#[derive(Default)]
pub struct Installed {
    current: Mutex<HashMap<String, String>>,
}

impl Installed {
    /// `true` if the engine does not currently hold this exact artifact.
    pub fn needs_install(&self, e: &Entry) -> bool {
        self.current.lock().unwrap().get(&e.program) != Some(&e.digest)
    }

    pub fn mark(&self, e: &Entry) {
        self.current
            .lock()
            .unwrap()
            .insert(e.program.clone(), e.digest.clone());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn write(dir: &Path, stem: &str, wasm: &[u8], manifest: &str) {
        std::fs::File::create(dir.join(format!("{stem}.wasm")))
            .unwrap()
            .write_all(wasm)
            .unwrap();
        std::fs::File::create(dir.join(format!("{stem}.Pie.toml")))
            .unwrap()
            .write_all(manifest.as_bytes())
            .unwrap();
    }

    /// A counter, not a timestamp: the clock is coarse enough that two tests
    /// running in parallel got the same directory and stomped each other's
    /// files, which showed up as two unrelated tests failing intermittently.
    fn tmp() -> PathBuf {
        static N: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
        let d = std::env::temp_dir().join(format!(
            "reg-test-{}-{}",
            std::process::id(),
            N.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    const ECHO: &str = r#"
[package]
name = "echo"
version = "0.1.0"
[ratio]
protocol = "chat-v1"
preload = true
"#;

    #[test]
    fn scans_and_defaults_route_to_package_name() {
        let d = tmp();
        write(&d, "echo", b"\0asm", ECHO);
        let r = Registry::scan(&d).unwrap();
        let e = r.get("echo").expect("route defaults to package name");
        assert_eq!(e.program, "echo@0.1.0");
        assert_eq!(e.protocol, Protocol::ChatV1);
        assert!(e.preload);
        assert!(e.snapshot_prefixes.is_empty(), "echo needs no persistence");
    }

    /// The property a per-route OnceCell cannot provide.
    #[test]
    fn digest_changes_when_the_wasm_changes() {
        let d = tmp();
        write(&d, "echo", b"\0asm-v1", ECHO);
        let a = Registry::scan(&d).unwrap().get("echo").unwrap().digest.clone();
        write(&d, "echo", b"\0asm-v2", ECHO);
        let b = Registry::scan(&d).unwrap().get("echo").unwrap().digest.clone();
        assert_ne!(a, b, "changed bytes must produce a new version identity");
    }

    #[test]
    fn digest_changes_when_only_the_manifest_changes() {
        let d = tmp();
        write(&d, "echo", b"\0asm", ECHO);
        let a = Registry::scan(&d).unwrap().get("echo").unwrap().digest.clone();
        write(&d, "echo", b"\0asm", &ECHO.replace("0.1.0", "0.1.1"));
        let b = Registry::scan(&d).unwrap().get("echo").unwrap().digest.clone();
        assert_ne!(a, b);
    }

    #[test]
    fn duplicate_route_is_rejected() {
        let d = tmp();
        write(&d, "a", b"\0asm", "[package]\nname=\"a\"\nversion=\"1\"\n[ratio]\nroute=\"same\"\n");
        write(&d, "b", b"\0asm", "[package]\nname=\"b\"\nversion=\"1\"\n[ratio]\nroute=\"same\"\n");
        let err = Registry::scan(&d).unwrap_err().to_string();
        assert!(err.contains("duplicate route"), "got: {err}");
    }

    #[test]
    fn duplicate_program_id_is_rejected() {
        let d = tmp();
        write(&d, "a", b"\0asm", "[package]\nname=\"x\"\nversion=\"1\"\n[ratio]\nroute=\"a\"\n");
        write(&d, "b", b"\0asm", "[package]\nname=\"x\"\nversion=\"1\"\n[ratio]\nroute=\"b\"\n");
        let err = Registry::scan(&d).unwrap_err().to_string();
        assert!(err.contains("duplicate program id"), "got: {err}");
    }

    #[test]
    fn missing_manifest_is_rejected() {
        let d = tmp();
        std::fs::File::create(d.join("lonely.wasm")).unwrap();
        assert!(Registry::scan(&d).unwrap_err().to_string().contains("no matching"));
    }

    #[test]
    fn unknown_protocol_is_rejected_rather_than_defaulted() {
        let d = tmp();
        write(&d, "x", b"\0asm", "[package]\nname=\"x\"\nversion=\"1\"\n[ratio]\nprotocol=\"telepathy-v9\"\n");
        // `{:#}` renders the whole context chain; the cause is one layer in, and
        // the message must name the offending file so the fix is obvious.
        let err = format!("{:#}", Registry::scan(&d).unwrap_err());
        assert!(err.contains("unknown protocol"), "got: {err}");
        assert!(err.contains("x.Pie.toml"), "got: {err}");
    }

    /// Validation must not partially apply — the caller keeps the old registry.
    #[test]
    fn a_bad_directory_yields_no_registry_at_all() {
        let d = tmp();
        write(&d, "good", b"\0asm", ECHO);
        write(&d, "bad", b"\0asm", "this is not toml [[[");
        assert!(Registry::scan(&d).is_err());
    }

    #[test]
    fn installed_tracks_versions_not_routes() {
        let d = tmp();
        write(&d, "echo", b"\0asm-v1", ECHO);
        let e1 = Registry::scan(&d).unwrap().get("echo").unwrap().clone();
        let inst = Installed::default();
        assert!(inst.needs_install(&e1));
        inst.mark(&e1);
        assert!(!inst.needs_install(&e1));

        write(&d, "echo", b"\0asm-v2", ECHO);
        let e2 = Registry::scan(&d).unwrap().get("echo").unwrap().clone();
        assert!(
            inst.needs_install(&e2),
            "changed artifacts must reinstall; this is what a per-route OnceCell gets wrong"
        );
        inst.mark(&e2);

        // Reverting to a previously installed version must reinstall: pie holds
        // one artifact per program id, so after v2 the engine no longer has v1.
        // A remembers-everything set fails here and serves v2 under v1's digest.
        assert!(
            inst.needs_install(&e1),
            "A → B → A must reinstall; the engine currently holds B"
        );
    }

    /// The shipped app sends `inferlet: "chat-apc"`. That mapping belongs in the
    /// manifest, not in a hardcoded gateway string.
    #[test]
    fn aliases_resolve_to_the_same_entry_without_duplicating_it() {
        let d = tmp();
        write(
            &d,
            "chat",
            b"\0asm",
            "[package]\nname=\"chat\"\nversion=\"0.1.0\"\n[ratio]\naliases=[\"chat-apc\"]\n",
        );
        let r = Registry::scan(&d).unwrap();
        assert_eq!(r.get("chat").unwrap().program, r.get("chat-apc").unwrap().program);
        assert_eq!(r.entries().count(), 1, "an alias must not preload twice");
        assert_eq!(r.routes(), vec!["chat".to_string(), "chat-apc".to_string()]);
    }

    #[test]
    fn an_alias_colliding_with_a_route_is_rejected() {
        let d = tmp();
        write(&d, "echo", b"\0asm", ECHO);
        write(
            &d,
            "chat",
            b"\0asm2",
            "[package]\nname=\"chat\"\nversion=\"1\"\n[ratio]\naliases=[\"echo\"]\n",
        );
        let err = Registry::scan(&d).unwrap_err().to_string();
        assert!(err.contains("duplicate route"), "got: {err}");
    }

    #[test]
    fn tree_v1_parses_but_is_not_yet_implemented() {
        assert!(Protocol::parse("tree-v1").unwrap() == Protocol::TreeV1);
        assert!(!Protocol::TreeV1.implemented());
        assert!(Protocol::ChatV1.implemented());
    }
}
