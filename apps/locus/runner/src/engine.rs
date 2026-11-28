// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//! The engine and its bounds (section 5.2 of the plan).
//!
//! **Configuration.** The component model, epoch interruption and wide
//! arithmetic are on. The component-model async family, GC and exception
//! handling are not built in: without Wasmtime's `component-model-async`
//! and `gc` features its engine leaves those features off
//! (`Config::features`), and has no switch for most of them. GC is also
//! turned off by name, with the component model's error context and
//! memory64; fuel is off, since epochs bound the wall clock the contract
//! states. Cranelift compiles at `OptLevel::None`, as the engine before it
//! did, on one thread of the runner's own (`Compiler`), with no parallel
//! compilation. Backtraces are off, so no error carries a guest's own
//! function names.
//!
//! **A component's bytes** are compiled in memory, on the compile thread,
//! only after they hash to their digest. The engine's configuration is
//! what refuses each refused feature; a compile it refuses is classified
//! there, after it, in `Prima.ComponentFeatures`'s order (`classify`):
//! valid with the nine refused features off, the failure is the engine's
//! own, "Component compilation failed: ..."; otherwise valid with the
//! validator's defaults it uses a refused feature, and invalid it is no
//! WebAssembly, each in Prima's sentence
//! (`tests/fixtures/component_features.json`). Nothing validates on the
//! runner's own thread, so an attempt's budget, its lease and both
//! channels run on whatever the compile thread is doing. A compile is
//! kept for 15 minutes by digest, and leaves when they pass.
//!
//! **A run** has one store, its limits the one authority over its memory,
//! tables and instances (`crate::imports::Guest`): a refused growth answers
//! the guest -1, and an instantiation the store refuses reads
//! "Component instantiation failed: " and the engine's words, as any other
//! instantiation failure does. The call yields at every epoch tick (10
//! ms), so whoever awaits it may stop waiting and drop it, its store with
//! it. A trap reads "Component call failed for <export>: " and the trap's
//! own text.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use sha2::Digest as _;
use wasmtime::component::{Component, HasSelf, Linker};
use wasmtime::wasmparser::{Validator, WasmFeatures};
use wasmtime::{Config, OptLevel, Store, Trap};

use crate::imports::{Ended, Guest, Run, catalyst, formula_world, reagent};
use crate::wire::STACK_BYTES;
use crate::words;

/// How often the engine's epoch ticks: a running call yields at each.
pub const EPOCH_TICK: Duration = Duration::from_millis(10);

/// How long a compile is kept, from its compile.
pub const KEPT_FOR: Duration = Duration::from_secs(15 * 60);

/// The stack of the compile thread.
const COMPILE_STACK_BYTES: usize = 8 * 1024 * 1024;

/// The features a component may not use, by wasmparser's names
/// (`Prima.ComponentFeatures.refused/0`).
pub const REFUSED: [(&str, WasmFeatures); 9] = [
    ("cm-async", WasmFeatures::CM_ASYNC),
    ("cm-async-stackful", WasmFeatures::CM_ASYNC_STACKFUL),
    (
        "cm-more-async-builtins",
        WasmFeatures::CM_MORE_ASYNC_BUILTINS,
    ),
    ("cm-error-context", WasmFeatures::CM_ERROR_CONTEXT),
    ("cm-threading", WasmFeatures::CM_THREADING),
    ("gc", WasmFeatures::GC),
    ("gc-types", WasmFeatures::GC_TYPES),
    ("exceptions", WasmFeatures::EXCEPTIONS),
    ("legacy-exceptions", WasmFeatures::LEGACY_EXCEPTIONS),
];

/// A component's type, as its assignment names it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Reagent,
    Catalyst,
    Formula,
}

impl Kind {
    /// The kind of `name`, or none for a type this runner does not run.
    pub fn named(name: &str) -> Option<Kind> {
        match name {
            "reagent" => Some(Kind::Reagent),
            "catalyst" => Some(Kind::Catalyst),
            "formula" => Some(Kind::Formula),
            _ => None,
        }
    }

    /// The interface its call is exported from.
    pub fn export(self) -> &'static str {
        match self {
            Kind::Reagent => "cyfr:reagent/compute@0.1.0",
            Kind::Catalyst => "cyfr:catalyst/run@0.1.0",
            Kind::Formula => "cyfr:formula/run@0.1.0",
        }
    }
}

/// Why a run gave no output.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Failure {
    /// The engine refused it: its instantiation or its call, in a sentence.
    Refused(String),
    /// One of its imports ended it, in this sentence.
    Ended(String),
}

/// The classifier's refusal of a component's bytes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Unadmitted {
    /// Valid only with a feature the runtime refuses.
    FeatureRefused,
    /// Not valid WebAssembly with any feature the validator knows.
    Invalid,
}

/// Classify `bytes` in Prima's order: admitted, or why not.
pub fn classify(bytes: &[u8]) -> Result<(), Unadmitted> {
    let refused = REFUSED
        .iter()
        .fold(WasmFeatures::empty(), |all, (_name, feature)| {
            all | *feature
        });
    if Validator::new_with_features(WasmFeatures::default() - refused)
        .validate_all(bytes)
        .is_ok()
    {
        return Ok(());
    }
    if Validator::new_with_features(WasmFeatures::default())
        .validate_all(bytes)
        .is_ok()
    {
        Err(Unadmitted::FeatureRefused)
    } else {
        Err(Unadmitted::Invalid)
    }
}

/// The sentence of a refusal of the component of `digest`
/// (`Prima.Refusal`'s, held to `tests/fixtures/component_features.json`).
pub fn unadmitted(refusal: Unadmitted, digest: &str) -> String {
    match refusal {
        Unadmitted::FeatureRefused => format!(
            "The component {digest} uses a WebAssembly feature this runtime does not admit: \
             component-model async, GC or exception handling."
        ),
        Unadmitted::Invalid => format!("The component {digest} is not valid WebAssembly."),
    }
}

/// `bytes`' digest as an assignment names one: `sha256:` and 64 lowercase
/// hexadecimal digits.
pub fn digest(bytes: &[u8]) -> String {
    format!("sha256:{}", crate::wire::hex(&sha2::Sha256::digest(bytes)))
}

/// The engine every run of a runner shares: its configuration, its two
/// linkers, its compile thread and the compiles it keeps.
pub struct Engine {
    engine: wasmtime::Engine,
    catalyst: Linker<Guest>,
    formula: Linker<Guest>,
    reagent: Linker<Guest>,
    compiler: Compiler,
    kept: Arc<Mutex<HashMap<String, (Component, u64)>>>,
    compiles: std::sync::atomic::AtomicU64,
    /// Each digest whose bytes are being fetched or compiled, by the one
    /// attempt doing so; the others wait for its compile.
    fetching: Mutex<HashMap<String, std::sync::Weak<tokio::sync::Mutex<()>>>>,
}

impl Engine {
    /// The engine, with its epoch ticking on a thread of its own from now
    /// on.
    pub fn new() -> wasmtime::Result<Arc<Engine>> {
        let engine = wasmtime::Engine::new(&config())?;
        let mut reagent = Linker::new(&engine);
        wasmtime_wasi::p2::add_to_linker_async(&mut reagent)?;
        let mut catalyst = Linker::new(&engine);
        wasmtime_wasi::p2::add_to_linker_async(&mut catalyst)?;
        catalyst::Catalyst::add_to_linker::<_, HasSelf<_>>(&mut catalyst, |guest| guest)?;
        let mut formula = Linker::new(&engine);
        wasmtime_wasi::p2::add_to_linker_async(&mut formula)?;
        formula_world::Formula::add_to_linker::<_, HasSelf<_>>(&mut formula, |guest| guest)?;
        let ticker = engine.clone();
        std::thread::Builder::new()
            .name("epoch".to_owned())
            .spawn(move || {
                loop {
                    std::thread::sleep(EPOCH_TICK);
                    ticker.increment_epoch();
                }
            })?;
        let compiler = Compiler::start(engine.clone())?;
        Ok(Arc::new(Engine {
            engine,
            catalyst,
            formula,
            reagent,
            compiler,
            kept: Arc::new(Mutex::new(HashMap::new())),
            compiles: std::sync::atomic::AtomicU64::new(0),
            fetching: Mutex::new(HashMap::new()),
        }))
    }

    /// How many compiles the engine holds.
    pub fn kept_count(&self) -> usize {
        self.kept.lock().expect("the kept compiles").len()
    }

    /// Wait until no other attempt fetches or compiles `digest`, and hold
    /// that turn until the guard is dropped: N attempts of one new digest
    /// make one fetch and one compile, the rest finding it kept. An attempt
    /// stopped while it holds the turn gives it up as it is dropped.
    pub async fn turn(&self, digest: &str) -> tokio::sync::OwnedMutexGuard<()> {
        let turn = {
            let mut fetching = self.fetching.lock().expect("the digests fetched");
            fetching.retain(|_digest, turn| turn.strong_count() > 0);
            match fetching.get(digest).and_then(std::sync::Weak::upgrade) {
                Some(turn) => turn,
                None => {
                    let turn = Arc::new(tokio::sync::Mutex::new(()));
                    fetching.insert(digest.to_owned(), Arc::downgrade(&turn));
                    turn
                }
            }
        };
        turn.lock_owned().await
    }

    /// The compile kept for `digest`, if one is.
    pub fn kept(&self, digest: &str) -> Option<Component> {
        let kept = self.kept.lock().expect("the kept compiles");
        kept.get(digest)
            .map(|(component, _compile)| component.clone())
    }

    /// Compile `bytes`, which hash to `digest`, on the compile thread, and
    /// keep the compile; or the sentence why not, a refused compile
    /// classified there. A caller that stops waiting leaves the compile to
    /// run out on its thread.
    pub async fn compile(&self, digest: &str, bytes: Vec<u8>) -> Result<Component, String> {
        let component = self.compiler.compile(digest, bytes).await?;
        // Each compile is one entry, and its own timer removes it when its
        // time passes, whether or not the runner looks it up again: a
        // compile of the same digest after it is another entry and timer.
        let compile = self
            .compiles
            .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        self.kept
            .lock()
            .expect("the kept compiles")
            .insert(digest.to_owned(), (component.clone(), compile));
        let kept = Arc::downgrade(&self.kept);
        let digest = digest.to_owned();
        let until = tokio::time::Instant::now() + KEPT_FOR;
        tokio::spawn(async move {
            tokio::time::sleep_until(until).await;
            if let Some(kept) = kept.upgrade() {
                let mut kept = kept.lock().expect("the kept compiles");
                if kept
                    .get(&digest)
                    .is_some_and(|(_component, at)| *at == compile)
                {
                    kept.remove(&digest);
                }
            }
        });
        Ok(component)
    }

    /// Run `component` as `kind` under `run`, with `input`: its output, or
    /// why it gave none.
    pub async fn run(
        &self,
        kind: Kind,
        component: &Component,
        run: Arc<Run>,
        input: &str,
    ) -> Result<String, Failure> {
        let mut store = Store::new(&self.engine, Guest::new(run));
        store.limiter(|guest| guest.limiter());
        store.set_epoch_deadline(1);
        store.epoch_deadline_async_yield_and_update(1);
        let export = kind.export();
        let called = match kind {
            Kind::Reagent => {
                let instance =
                    reagent::Reagent::instantiate_async(&mut store, component, &self.reagent)
                        .await
                        .map_err(not_instantiated)?;
                instance
                    .cyfr_reagent_compute()
                    .call_compute(&mut store, input)
                    .await
            }
            Kind::Catalyst => {
                let instance =
                    catalyst::Catalyst::instantiate_async(&mut store, component, &self.catalyst)
                        .await
                        .map_err(not_instantiated)?;
                instance
                    .cyfr_catalyst_run()
                    .call_run(&mut store, input)
                    .await
            }
            Kind::Formula => {
                let instance =
                    formula_world::Formula::instantiate_async(&mut store, component, &self.formula)
                        .await
                        .map_err(not_instantiated)?;
                instance
                    .cyfr_formula_run()
                    .call_run(&mut store, input)
                    .await
            }
        };
        called.map_err(|error| failed(export, &error))
    }
}

/// The engine's configuration: what compiles and what the engine itself
/// refuses.
pub fn config() -> Config {
    let mut config = Config::new();
    config
        .wasm_component_model(true)
        .epoch_interruption(true)
        .wasm_wide_arithmetic(true)
        .wasm_component_model_error_context(false)
        .wasm_gc(false)
        .wasm_memory64(false)
        .consume_fuel(false)
        .cranelift_opt_level(OptLevel::None)
        .wasm_backtrace_max_frames(None)
        .async_stack_size(STACK_BYTES);
    config
}

fn not_instantiated(error: wasmtime::Error) -> Failure {
    Failure::Refused(words::not_instantiated(&format!("{error:#}")))
}

fn failed(export: &str, error: &wasmtime::Error) -> Failure {
    if let Some(ended) = error.downcast_ref::<Ended>() {
        return Failure::Ended(ended.0.clone());
    }
    if let Some(trap) = error.downcast_ref::<Trap>() {
        return Failure::Refused(words::call_failed(export, &trap.to_string()));
    }
    Failure::Refused(words::call_failed(export, &format!("{error:#}")))
}

/// The runner's one compile thread.
struct Compiler {
    jobs: std::sync::mpsc::Sender<Job>,
}

/// One compile: the component's digest and bytes, and where its compile
/// or sentence goes.
type Job = (
    String,
    Vec<u8>,
    tokio::sync::oneshot::Sender<Result<Component, String>>,
);

impl Compiler {
    fn start(engine: wasmtime::Engine) -> std::io::Result<Compiler> {
        let (jobs, queue) = std::sync::mpsc::channel::<Job>();
        std::thread::Builder::new()
            .name("compile".to_owned())
            .stack_size(COMPILE_STACK_BYTES)
            .spawn(move || {
                for (digest, bytes, reply) in queue {
                    let compiled = Component::new(&engine, &bytes).map_err(|error| {
                        // The engine refuses every refused feature itself;
                        // the classifier chooses the refusal's sentence.
                        match classify(&bytes) {
                            Ok(()) => words::not_compiled(&format!("{error:#}")),
                            Err(refusal) => {
                                eprintln!(
                                    "cyfr-runner: the component {digest} is refused ({refusal:?})"
                                );
                                unadmitted(refusal, &digest)
                            }
                        }
                    });
                    let _ = reply.send(compiled);
                }
            })?;
        Ok(Compiler { jobs })
    }

    async fn compile(&self, digest: &str, bytes: Vec<u8>) -> Result<Component, String> {
        let (reply, compiled) = tokio::sync::oneshot::channel();
        self.jobs
            .send((digest.to_owned(), bytes, reply))
            .map_err(|_| words::not_compiled("the compile thread has ended"))?;
        compiled
            .await
            .unwrap_or_else(|_| Err(words::not_compiled("the compile thread has ended")))
    }
}
