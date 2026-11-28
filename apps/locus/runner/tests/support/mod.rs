// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//! A scripted service end for the real binary: it starts `cyfr-runner`
//! with its control channel on standard input and output and its relay on
//! a unix socket it listens on (the two transport names the test build's
//! direct launcher uses), assigns it a job, and answers each host call the
//! runner makes as a script says, recording every call it was sent.

#![allow(dead_code)]

use std::io::{BufRead as _, BufReader, Read as _, Write as _};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use zeroize::Zeroizing;

use cyfr_runner::auth::{self, Attempt, AttemptKeys, CallFields, Direction};
use cyfr_runner::control::{self, Message};
use cyfr_runner::wire;

pub const RUNNER: &str = "run_test-runner";
pub const SERVICE: &str = "wrk_testservice";
pub const BOOT: &str = "boot_test-boot";
pub const MEMBER: &str = "cyfr@127.0.0.1#boot_test-member";
pub const ATHANOR: &str = "ath_test-athanor";

/// 32 bytes from the system's random source: no key or IV of the tests is
/// a literal.
pub fn random_key() -> [u8; 32] {
    std::array::from_fn(|_| {
        let byte = getrandom::u32().expect("the operating system's random source answers");
        byte.to_le_bytes()[0]
    })
}

/// The repository's root.
pub fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

/// The bytes of a repository file.
pub fn bytes(path: &str) -> Vec<u8> {
    let path = root().join(path);
    std::fs::read(&path).unwrap_or_else(|error| panic!("{}: {error}", path.display()))
}

/// A vector file under `tests/fixtures`.
pub fn fixture(name: &str) -> Value {
    serde_json::from_slice(&bytes(&format!("tests/fixtures/{name}"))).expect("a vector file")
}

/// The test WASM of Locus's suite and the seed's components.
pub const HOSTILE: &str = "apps/locus/test/support/runtime/test_wasm/hostile";
pub const TEST_WASM: &str = "apps/locus/test/support/runtime/test_wasm";

/// The time, in Unix milliseconds.
pub fn now_ms() -> u64 {
    u64::try_from(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("after the epoch")
            .as_millis(),
    )
    .expect("a time in range")
}

/// The first `count` processors this process may run on, as `taskset -c`
/// names them.
pub fn allowed_cpus(count: usize) -> String {
    let status = std::fs::read_to_string("/proc/self/status").expect("the process's status");
    let list = status
        .lines()
        .find_map(|line| line.strip_prefix("Cpus_allowed_list:"))
        .expect("the allowed processors")
        .trim()
        .to_owned();
    let mut cpus = Vec::new();
    for part in list.split(',') {
        match part.split_once('-') {
            Some((from, to)) => {
                let (from, to): (u32, u32) = (
                    from.parse().expect("a processor"),
                    to.parse().expect("a processor"),
                );
                cpus.extend((from..=to).map(|cpu| cpu.to_string()));
            }
            None => cpus.push(part.to_owned()),
        }
    }
    assert!(cpus.len() >= count, "{count} processors of {list}");
    cpus[..count].join(",")
}

/// The runner's peak resident memory, in KiB.
pub fn peak_kib(pid: u32) -> u64 {
    std::fs::read_to_string(format!("/proc/{pid}/status"))
        .unwrap_or_default()
        .lines()
        .find_map(|line| line.strip_prefix("VmHWM:"))
        .and_then(|rest| rest.split_whitespace().next())
        .and_then(|kib| kib.parse().ok())
        .unwrap_or(0)
}

/// One job: what its assignment says, its input and its component.
#[derive(Clone)]
pub struct Job {
    pub execution_id: String,
    pub attempt: String,
    pub kind: &'static str,
    pub reference: String,
    pub component: Vec<u8>,
    pub input: Vec<u8>,
    pub timeout_ms: u64,
    pub authority: Value,
    /// The attempt's keys, drawn for the job, which a scan of the runner's
    /// memory looks for.
    pub call_key: [u8; 32],
    pub seal_key: [u8; 32],
    /// What its assignment names beside the attempt: its athanor, service,
    /// boot and member, and the actions its host intercepts.
    pub athanor: String,
    pub service: String,
    pub boot: String,
    pub member: String,
    pub intercepted: Vec<String>,
    /// The attempt its keys name, when it is not its assignment's.
    pub keys_attempt: Option<Attempt>,
    /// The jobs of its subtree the service admitted as children, shared by
    /// every copy: the service end opens each one's calls under its keys.
    pub family: Arc<Mutex<Vec<Job>>>,
    /// The vault fields CYFR admits it with, as a child.
    pub secrets: Value,
    /// The executions of its subtree the service cancelled, shared by every
    /// copy: CYFR refuses each one's `fail`, the cancel having fenced it.
    pub cancelled: Arc<Mutex<Vec<String>>>,
}

impl Job {
    /// The job bound to a node of its own whose limits are the zero
    /// limits with `limits` in their place.
    pub fn bound(mut self, limits: Value) -> Job {
        let mut node = json!({"batch_timeout": "30s", "max_concurrent_tasks": 1,
                              "max_memory_bytes": 67_108_864, "max_request_size": 1_048_576,
                              "max_response_size": 5_242_880,
                              "rate_limit": {"requests": 100, "window": "1m"}, "timeout": "30s"});
        node.as_object_mut()
            .expect("limits")
            .extend(limits.as_object().expect("limits").clone());
        self.authority = json!({"cursor": {"bound": self.reference}, "depth": 0,
            "invoke_mode": "open_inert", "activation": {}, "budget": {"id": "bgt_test"},
            "chain": [self.reference],
            "policy": {"canonical": "jcs-1",
                       "nodes": {self.reference.clone(): {"edges": {}, "limits": node}}}});
        self
    }

    /// A job running the component at `path` as `kind` on `input`.
    pub fn new(kind: &'static str, path: &str, input: &str) -> Job {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let n = NEXT.fetch_add(1, Ordering::Relaxed);
        Job {
            execution_id: format!("exec_test-{n}"),
            attempt: format!("att_test-{n}"),
            kind,
            reference: format!("{kind}:local.test:0.1.0"),
            component: bytes(path),
            input: input.as_bytes().to_vec(),
            timeout_ms: 30_000,
            authority: json!({"cursor": "unbound", "depth": 0, "invoke_mode": "open_inert",
                              "activation": {}, "budget": {"id": "bgt_test"}, "chain": []}),
            call_key: random_key(),
            seal_key: random_key(),
            athanor: ATHANOR.to_owned(),
            service: SERVICE.to_owned(),
            boot: BOOT.to_owned(),
            member: MEMBER.to_owned(),
            intercepted: Vec::new(),
            keys_attempt: None,
            family: Arc::new(Mutex::new(Vec::new())),
            secrets: json!({}),
            cancelled: Arc::new(Mutex::new(Vec::new())),
        }
    }

    /// A child of this job's subtree, running the component at `path` as
    /// `kind` on `input`: of the same athanor and member, sharing its
    /// family.
    pub fn child(&self, kind: &'static str, path: &str, input: &str) -> Job {
        let mut child = Job::new(kind, path, input);
        child.athanor.clone_from(&self.athanor);
        child.family = self.family.clone();
        child.cancelled = self.cancelled.clone();
        child
    }

    /// The job whose attempt is `attempt`: this one or a child admitted.
    pub fn of(&self, attempt: &str) -> Job {
        if attempt == self.attempt {
            return self.clone();
        }
        self.family
            .lock()
            .expect("the family")
            .iter()
            .find(|child| child.attempt == attempt)
            .cloned()
            .unwrap_or_else(|| self.clone())
    }

    /// CYFR's answer to an `admit_child` of this job's for `child`: its
    /// assignment, its keys sealed under this job's seal key, its input
    /// and its vault fields. The child joins the family.
    pub fn admitted(&self, child: &Job) -> Value {
        self.family.lock().expect("the family").push(child.clone());
        json!({"assignment": child.token(), "attempt_keys": self.sealed_keys(child),
               "input": String::from_utf8(child.input.clone()).expect("a text input"),
               "secrets": child.secrets})
    }

    /// The `cancel_child` line for `child`, which CYFR then holds fenced.
    pub fn cancel(&self, child: &Job) -> Vec<u8> {
        self.cancelled
            .lock()
            .expect("the cancelled")
            .push(child.execution_id.clone());
        control::encode(&Message::CancelChild {
            execution_id: child.execution_id.clone(),
        })
        .expect("a cancel_child frame")
    }

    /// `child`'s keys sealed for this job's runner under its seal key, as
    /// `Prima.WorkerAuth.seal_attempt_keys/3` seals them.
    pub fn sealed_keys(&self, child: &Job) -> String {
        sealed_attempt_keys(&self.seal_key, &child.keys())
    }

    pub fn digest(&self) -> String {
        cyfr_runner::engine::digest(&self.component)
    }

    pub fn attempt(&self) -> Attempt {
        Attempt {
            athanor_id: self.athanor.clone(),
            execution_id: self.execution_id.clone(),
            attempt: self.attempt.clone(),
            fence: 2,
            generation: 7,
            service: self.service.clone(),
        }
    }

    pub fn keys(&self) -> AttemptKeys {
        AttemptKeys {
            attempt: self.keys_attempt.clone().unwrap_or_else(|| self.attempt()),
            call: self.call_key.into(),
            seal: self.seal_key.into(),
        }
    }

    /// The assignment token: its payload, and a MAC the runner does not
    /// verify (CYFR does, at attach).
    pub fn token(&self) -> String {
        let now = now_ms();
        let payload = json!({
            "v": 1, "generation": 7, "service": self.service, "boot": self.boot,
            "member": self.member,
            "issued_at": now, "claim_by": now + 30_000,
            "execution_id": self.execution_id, "attempt": self.attempt, "fence": 2,
            "root_execution_id": self.execution_id, "athanor_id": self.athanor,
            "actor": {"authenticated": true, "user_id": "usr_test"},
            "authority": self.authority,
            "component": {"ref": self.reference, "type": self.kind, "digest": self.digest(),
                          "declared_needs": []},
            "input_digest": format!("sha256:{}", auth::sha256_hex(&self.input)),
            "timeout_ms": self.timeout_ms, "deadline": now + self.timeout_ms + 60_000,
            "lease_until": now + 180_000, "intercepted": self.intercepted,
        });
        format!(
            "{}.{}",
            wire::encode_base64url(payload.to_string().as_bytes()),
            wire::encode_base64url(&[1u8; 32])
        )
    }

    pub fn assign(&self) -> Message {
        Message::Assign {
            assignment: Zeroizing::new(self.token()),
            input: Zeroizing::new(self.input.clone()),
            keys: self.keys(),
        }
    }
}

/// A host call as the service end opened it.
#[derive(Debug, Clone)]
pub struct Call {
    pub op: String,
    pub args: Value,
    pub attempt: String,
    /// The call's signed header, as posted.
    pub header: String,
}

/// How the script answers a call.
pub enum Reply {
    /// `{"v": 3, "ok": value}`.
    Ok(Value),
    /// `{"v": 3, "error": name, ...fields}`.
    Error(&'static str, Value),
    /// This plain answer, sealed as given.
    Plain(Vec<u8>),
    /// A `host_answer` with no status: no answer reached the service.
    Dropped,
    /// No `host_answer` at all.
    Silent,
    /// The service's `close`, then its end of the stream closed.
    Close,
    /// This frame's JSON, as given, in place of an answer.
    Frame(Vec<u8>),
    /// `{"v": 3, "ok": value}`, then the service's end of the stream closed.
    OkThenEnd(Value),
    /// `{"v": 3, "ok": value}` after this long, written from a thread of its
    /// own while the service reads on; its writing is logged, just before
    /// it is written, as a call of op `answered:<op>`.
    Later(Duration, Value),
    /// `{"v": 3, "ok": value}` once the condition holds, written from a
    /// thread of its own, and logged as `Later`'s is once it is written.
    When(Box<dyn Fn() -> bool + Send>, Value),
}

pub type Script = Box<dyn FnMut(&Call, &Job) -> Reply + Send>;

/// What the service end sends a fetch, in order, as its upstream answers.
pub enum Upstream {
    /// The first chunk: the answer's status and headers, and a body.
    Head(u16, Vec<(&'static str, String)>, Vec<u8>),
    /// The next bytes of the body.
    Chunk(Vec<u8>),
    /// One of an attached fetch's sealed answer frames, its kind byte and
    /// sealed value.
    Frame(Vec<u8>),
    /// CYFR's refusal of an attached fetch: its signed header and sealed
    /// answer.
    Refusal(String, Vec<u8>),
    /// The fetch's end, naming a code or none.
    End(Option<&'static str>),
    /// The service's `close`, then its end of the stream closed.
    Close,
    /// What came before written, then what follows written once the runner
    /// has granted this many bytes of the fetch back in all, as the
    /// service sends only what the runner's credit covers.
    AfterCredit(u64),
    /// What came before written, then this long before what follows.
    Pause(Duration),
}

/// How the service end answers each fetch the runner sends: the fetch's
/// frame, and what is sent back for it at once. A fetch given no `End`
/// stays open, its upstream slow.
pub type Fetches = Box<dyn FnMut(&Value, &Job) -> Vec<Upstream> + Send>;

/// A fetch script that answers nothing: every fetch stays open.
pub fn silent_fetches() -> Fetches {
    Box::new(|_fetch, _job| Vec::new())
}

/// The answers CYFR gives a job that runs and closes as asked.
pub fn standard(call: &Call, job: &Job) -> Reply {
    let of = job.of(&call.attempt);
    if call.op == "fail"
        && of.attempt != job.attempt
        && job
            .cancelled
            .lock()
            .expect("the cancelled")
            .contains(&of.execution_id)
    {
        // The cancel fenced the attempt: CYFR no longer takes its close.
        return Reply::Error("lost", json!({}));
    }
    match call.op.as_str() {
        "attach" => Reply::Ok(json!({})),
        "fetch_artifact" => Reply::Ok(Value::String(wire::encode_base64(
            &job.of(&call.attempt).component,
        ))),
        "complete" => Reply::Ok(call.args["outcome"]["output"].clone()),
        "fail" => Reply::Ok(call.args["outcome"]["error"].clone()),
        "renew" => Reply::Ok(json!({ call.attempt.clone(): {"lease_until": now_ms() + 180_000} })),
        "record_denial" => Reply::Ok(Value::Bool(true)),
        _ => Reply::Error("not_found", json!({})),
    }
}

/// A runner under test and the service end it talks to.
pub struct Service {
    child: Child,
    stdin: Option<Box<dyn std::io::Write + Send>>,
    lines: mpsc::Receiver<String>,
    stderr: Arc<Mutex<Vec<u8>>>,
    stderr_reader: Option<std::thread::JoinHandle<()>>,
    dir: PathBuf,
    listener: Option<UnixListener>,
    pub calls: Arc<Mutex<Vec<Call>>>,
    /// Every frame the runner sent on its relay, in order.
    pub frames: Arc<Mutex<Vec<Value>>>,
    /// Whether the service's end of the relay has read its last frame.
    pub relay_ended: Arc<std::sync::atomic::AtomicBool>,
    socket: Option<UnixStream>,
}

/// Where the runner's control channel is.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Control {
    /// Standard input and output (`RUNTIME_CONTROL_FD=0`).
    Stdio,
    /// Descriptor 3, a socket, as the keeper hands it: a shell moves the
    /// socket from its standard input there and runs the runner on it.
    Descriptor3,
}

impl Service {
    /// Start the binary with `variables` beside its identity and channels.
    pub fn start() -> Service {
        Service::start_with(&[])
    }

    pub fn start_with(variables: &[(&str, &str)]) -> Service {
        Service::start_on(Control::Stdio, variables)
    }

    /// Start the binary held to the first `cpus` processors this test may
    /// use, as a runner's quota holds it.
    pub fn start_held(cpus: usize) -> Service {
        Service::start_held_on(Control::Stdio, &[], Some(cpus))
    }

    /// Start the binary on `control` with `variables`, held to as many
    /// processors as `CYFR_TEST_RUNNER_CPUS` names when it names any (the
    /// crate's check runs the formula suite so, at a runner's default of
    /// one).
    pub fn start_on(control: Control, variables: &[(&str, &str)]) -> Service {
        let held = std::env::var("CYFR_TEST_RUNNER_CPUS")
            .ok()
            .map(|cpus| cpus.parse().expect("CYFR_TEST_RUNNER_CPUS is a count"));
        Service::start_held_on(control, variables, held)
    }

    fn start_held_on(control: Control, variables: &[(&str, &str)], held: Option<usize>) -> Service {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let dir = std::env::temp_dir().join(format!(
            "cyfr-runner-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&dir).expect("a test folder");
        let socket = dir.join("relay.sock");
        let listener = UnixListener::bind(&socket).expect("the relay socket");
        let runner = env!("CARGO_BIN_EXE_cyfr-runner");
        // Held, the runner runs under `taskset` on the processors named.
        let program = |program: &str| match held {
            Some(cpus) => {
                let mut command = Command::new("taskset");
                command.arg("-c").arg(allowed_cpus(cpus)).arg(program);
                command
            }
            None => Command::new(program),
        };
        let (mut command, ours) = match control {
            Control::Stdio => {
                let mut command = program(runner);
                command.stdin(Stdio::piped()).stdout(Stdio::piped());
                (command, None)
            }
            Control::Descriptor3 => {
                let (ours, theirs) = UnixStream::pair().expect("a socket pair");
                let mut command = program("/bin/sh");
                command
                    .arg("-c")
                    .arg(r#"exec "$0" 3<&0 0</dev/null"#)
                    .arg(runner)
                    .stdin(Stdio::from(std::os::fd::OwnedFd::from(theirs)))
                    .stdout(Stdio::null());
                (command, Some(ours))
            }
        };
        command
            .env_clear()
            .env("RUNTIME_RUNNER_ID", RUNNER)
            .env("RUNTIME_SERVICE_ID", SERVICE)
            .env("RUNTIME_BOOT_ID", BOOT)
            .env("RUNTIME_RELAY_SOCKET", &socket)
            .stderr(Stdio::piped());
        if control == Control::Stdio {
            command.env("RUNTIME_CONTROL_FD", "0");
        }
        for (name, value) in variables {
            command.env(name, value);
        }
        let mut child = command.spawn().expect("the runner starts");
        let socket = ours
            .as_ref()
            .map(|ours| ours.try_clone().expect("the socket"));
        let (stdin, output): (
            Box<dyn std::io::Write + Send>,
            Box<dyn std::io::Read + Send>,
        ) = match ours {
            None => (
                Box::new(child.stdin.take().expect("its input")),
                Box::new(child.stdout.take().expect("its output")),
            ),
            Some(ours) => (
                Box::new(ours.try_clone().expect("the socket")),
                Box::new(ours),
            ),
        };
        let (send, lines) = mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(output).lines() {
                let Ok(line) = line else { return };
                if send.send(line).is_err() {
                    return;
                }
            }
        });
        let stderr = Arc::new(Mutex::new(Vec::new()));
        let collected = stderr.clone();
        let mut errors = child.stderr.take().expect("its errors");
        let stderr_reader = std::thread::spawn(move || {
            let mut bytes = Vec::new();
            errors.read_to_end(&mut bytes).expect("read runner stderr");
            *collected.lock().expect("stderr") = bytes;
        });
        Service {
            stdin: Some(stdin),
            child,
            lines,
            stderr,
            stderr_reader: Some(stderr_reader),
            dir,
            listener: Some(listener),
            calls: Arc::new(Mutex::new(Vec::new())),
            frames: Arc::new(Mutex::new(Vec::new())),
            relay_ended: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            socket,
        }
    }

    /// The runner's process id.
    pub fn pid(&self) -> u32 {
        self.child.id()
    }

    /// Send one control line, as given, answering whether it was written
    /// whole.
    pub fn try_send_line(&mut self, line: &[u8]) -> std::io::Result<()> {
        let stdin = self.stdin.as_mut().expect("the control channel is open");
        stdin.write_all(line)?;
        stdin.flush()
    }

    /// Send one control line, as given.
    pub fn send_line(&mut self, line: &[u8]) {
        let stdin = self.stdin.as_mut().expect("the control channel is open");
        stdin.write_all(line).expect("the runner reads");
        stdin.flush().expect("the runner reads");
    }

    /// Assign `job`, and answer its relay's calls by `script`.
    pub fn assign(&mut self, job: &Job, script: Script) {
        let line = control::encode(&job.assign()).expect("an assign frame");
        self.send_line(&line);
        self.serve(job.clone(), script);
    }

    /// Assign `job`, answer its relay's calls by `script` and its fetches
    /// by `fetches`.
    pub fn assign_fetching(&mut self, job: &Job, script: Script, fetches: Fetches) {
        let line = control::encode(&job.assign()).expect("an assign frame");
        self.send_line(&line);
        self.serve_fetching(job.clone(), script, fetches);
    }

    /// The frames of `kind` the runner sent on its relay so far.
    pub fn frames_of(&self, kind: &str) -> Vec<Value> {
        self.frames
            .lock()
            .expect("the frames")
            .iter()
            .filter(|frame| frame["kind"] == kind)
            .cloned()
            .collect()
    }

    /// Accept the relay and answer its calls by `script`, on a thread.
    pub fn serve(&mut self, job: Job, script: Script) {
        self.serve_fetching(job, script, silent_fetches());
    }

    /// Accept the relay and answer its calls by `script` and its fetches
    /// by `fetches`, on a thread.
    pub fn serve_fetching(&mut self, job: Job, script: Script, fetches: Fetches) {
        let listener = self.listener.take().expect("the relay is not yet served");
        let calls = self.calls.clone();
        let frames = self.frames.clone();
        let ended = self.relay_ended.clone();
        let relay_end = std::thread::Builder::new().stack_size(STACK_BYTES);
        let _ = relay_end.spawn(move || {
            listener
                .set_nonblocking(false)
                .expect("a blocking listener");
            if let Ok((stream, _)) = listener.accept() {
                relay_fetching(stream, job, script, fetches, calls, frames);
            }
            ended.store(true, Ordering::SeqCst);
        });
    }

    /// End the control channel, then wait up to `within` for the runner
    /// to exit, collecting its stderr.
    pub fn exit_after_close(&mut self, within: Duration) -> ExitStatus {
        self.close_control();
        self.exit(within)
    }

    /// End the control channel.
    pub fn close_control(&mut self) {
        self.stdin = None;
        if let Some(socket) = &self.socket {
            let _ = socket.shutdown(std::net::Shutdown::Write);
        }
    }

    /// The next control line the runner writes, read as JSON, within
    /// `within`.
    pub fn line(&self, within: Duration) -> Value {
        let line = self
            .lines
            .recv_timeout(within)
            .unwrap_or_else(|_| panic!("no line within {within:?}; stderr: {}", self.errors()));
        serde_json::from_str(&line).expect("a JSON line")
    }

    /// The next control line that is not an event.
    pub fn frame(&self, within: Duration) -> Value {
        let until = Instant::now() + within;
        loop {
            let line = self.line(until.saturating_duration_since(Instant::now()));
            if line["type"] != "event" {
                return line;
            }
        }
    }

    /// Every line until the runner's output ends.
    pub fn rest(&self, within: Duration) -> Vec<Value> {
        let until = Instant::now() + within;
        let mut lines = Vec::new();
        while let Ok(line) = self
            .lines
            .recv_timeout(until.saturating_duration_since(Instant::now()))
        {
            lines.push(serde_json::from_str(&line).expect("a JSON line"));
        }
        lines
    }

    /// Wait up to `within` for the runner to exit, then collect its stderr.
    pub fn exit(&mut self, within: Duration) -> ExitStatus {
        let until = Instant::now() + within;
        loop {
            if let Some(status) = self.child.try_wait().expect("the runner's status") {
                self.finish_stderr().expect("collect runner stderr");
                return status;
            }
            assert!(
                Instant::now() < until,
                "the runner did not exit; stderr: {}",
                self.errors()
            );
            std::thread::sleep(Duration::from_millis(20)); // sleep-ok: polls a child's exit, bounded by `within`
        }
    }

    fn finish_stderr(&mut self) -> std::thread::Result<()> {
        self.stderr_reader
            .take()
            .map_or(Ok(()), std::thread::JoinHandle::join)
    }

    pub fn errors(&self) -> String {
        String::from_utf8_lossy(&self.stderr.lock().expect("stderr")).into_owned()
    }

    /// The ops of the calls sent so far, in order.
    pub fn ops(&self) -> Vec<String> {
        self.calls
            .lock()
            .expect("the calls")
            .iter()
            .map(|call| call.op.clone())
            .collect()
    }

    pub fn calls_of(&self, op: &str) -> Vec<Call> {
        self.calls
            .lock()
            .expect("the calls")
            .iter()
            .filter(|call| call.op == op)
            .cloned()
            .collect()
    }
}

impl Drop for Service {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = self.finish_stderr();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// The stack of the service end's relay thread, which reads a request
/// body as CYFR does, at any depth.
const STACK_BYTES: usize = 64 * 1024 * 1024;

/// A request body as CYFR reads it: JSON nested to any depth.
pub fn deep(bytes: &[u8]) -> Value {
    use serde::Deserialize as _;
    let mut reader = serde_json::Deserializer::from_slice(bytes);
    reader.disable_recursion_limit();
    Value::deserialize(&mut reader).expect("a request body")
}

/// The service's end of the relay: each `host_call` opened, recorded and
/// answered by `script`, every fetch left open.
pub fn relay(stream: UnixStream, job: Job, script: Script, calls: Arc<Mutex<Vec<Call>>>) {
    relay_fetching(
        stream,
        job,
        script,
        silent_fetches(),
        calls,
        Arc::new(Mutex::new(Vec::new())),
    );
}

/// The service's end of the relay: every frame recorded, each `host_call`
/// opened, recorded and answered by `script`, and each `fetch` answered by
/// `fetches`.
pub fn relay_fetching(
    mut stream: UnixStream,
    job: Job,
    mut script: Script,
    mut fetches: Fetches,
    calls: Arc<Mutex<Vec<Call>>>,
    frames: Arc<Mutex<Vec<Value>>>,
) {
    // What the service writes, and the seq of its next frame, shared with
    // the threads that answer later.
    let out = Arc::new(Mutex::new((stream.try_clone().expect("the stream"), 0u64)));
    loop {
        let mut length = [0u8; 4];
        if stream.read_exact(&mut length).is_err() {
            return;
        }
        let mut frame = vec![0u8; u32::from_be_bytes(length) as usize];
        if stream.read_exact(&mut frame).is_err() {
            return;
        }
        let frame: Value = serde_json::from_slice(&frame).expect("a relay frame");
        frames.lock().expect("the frames").push(frame.clone());
        if frame["kind"] == "fetch" {
            let re = frame["seq"].as_u64().expect("a seq");
            let attempt = frame["attempt"].as_str().expect("an attempt").to_owned();
            if !answer_fetch(&out, &frames, &attempt, re, fetches(&frame, &job)) {
                return;
            }
            continue;
        }
        if frame["kind"] != "host_call" {
            continue;
        }
        let header = frame["header"].as_str().expect("a header");
        let fields = call_fields(header);
        let keys = job.of(&fields.attempt.attempt).keys();
        // As CYFR's listener does: a header that is not its attempt's own
        // call key's is refused, unopened.
        if auth::verify_call_header(&keys.call, header, now_ms()).is_err() {
            calls.lock().expect("the calls").push(Call {
                op: "bad_mac".to_owned(),
                args: Value::Null,
                attempt: fields.attempt.attempt.clone(),
                header: header.to_owned(),
            });
            let re = frame["seq"].as_u64().expect("a seq");
            let mut writing = out.lock().expect("the writer");
            let answer = json!({"v": 1, "attempt": fields.attempt.attempt, "seq": writing.1,
                "kind": "host_answer", "re": re, "status": 401,
                "body": wire::encode_base64(b"{\"v\":3,\"error\":\"bad_mac\"}")});
            writing.1 += 1;
            if write_frame(&mut writing.0, &answer).is_err() {
                return;
            }
            continue;
        }
        let sealed = wire::decode_base64(frame["body"].as_str().expect("a body")).expect("base64");
        let plain = auth::open_call(&keys.seal, Direction::Body, &fields, &sealed)
            .expect("a body sealed under the attempt's key");
        let request = deep(&plain);
        let call = Call {
            op: request["op"].as_str().expect("an op").to_owned(),
            args: request["args"].clone(),
            attempt: frame["attempt"].as_str().expect("an attempt").to_owned(),
            header: header.to_owned(),
        };
        calls.lock().expect("the calls").push(call.clone());
        let re = frame["seq"].as_u64().expect("a seq");
        let (status, body) = match script(&call, &job) {
            Reply::Silent => continue,
            Reply::When(holds, value) => {
                let body = seal(
                    &keys,
                    &fields,
                    json!({"v": 3, "ok": value}).to_string().into_bytes(),
                );
                let (out, calls, call) = (out.clone(), calls.clone(), call.clone());
                std::thread::spawn(move || {
                    eventually(holds);
                    let mut writing = out.lock().expect("the writer");
                    let answer = json!({"v": 1, "attempt": call.attempt, "seq": writing.1,
                        "kind": "host_answer", "re": re, "status": 200,
                        "body": wire::encode_base64(&body)});
                    writing.1 += 1;
                    let _ = write_frame(&mut writing.0, &answer);
                    // Logged once it is written: a test can wait for what
                    // the runner has been sent.
                    calls.lock().expect("the calls").push(Call {
                        op: format!("answered:{}", call.op),
                        ..call
                    });
                });
                continue;
            }
            Reply::Later(after, value) => {
                let body = seal(
                    &keys,
                    &fields,
                    json!({"v": 3, "ok": value}).to_string().into_bytes(),
                );
                let (out, calls, call) = (out.clone(), calls.clone(), call.clone());
                std::thread::spawn(move || {
                    std::thread::sleep(after); // sleep-ok: CYFR's answer comes this much later, as the test scripts it
                    let mut writing = out.lock().expect("the writer");
                    let answer = json!({"v": 1, "attempt": call.attempt, "seq": writing.1,
                        "kind": "host_answer", "re": re, "status": 200,
                        "body": wire::encode_base64(&body)});
                    writing.1 += 1;
                    // Logged before it is written: the runner's next call
                    // can arrive before this thread runs again.
                    calls.lock().expect("the calls").push(Call {
                        op: format!("answered:{}", call.op),
                        ..call
                    });
                    let _ = write_frame(&mut writing.0, &answer);
                });
                continue;
            }
            Reply::Close => {
                let mut writing = out.lock().expect("the writer");
                let close = json!({"v": 1, "attempt": call.attempt, "seq": writing.1, "kind": "close",
                                   "reason": "malformed"});
                let _ = write_frame(&mut writing.0, &close);
                return;
            }
            Reply::Frame(json) => {
                let mut writing = out.lock().expect("the writer");
                let _ = write_raw(&mut writing.0, &json);
                continue;
            }
            Reply::Dropped => (Value::Null, Vec::new()),
            Reply::OkThenEnd(value) => {
                let body = seal(
                    &keys,
                    &fields,
                    json!({"v": 3, "ok": value}).to_string().into_bytes(),
                );
                let mut writing = out.lock().expect("the writer");
                let answer = json!({"v": 1, "attempt": call.attempt, "seq": writing.1, "kind": "host_answer",
                                    "re": re, "status": 200, "body": wire::encode_base64(&body)});
                let _ = write_frame(&mut writing.0, &answer);
                return;
            }
            Reply::Ok(value) => (
                json!(200),
                seal(
                    &keys,
                    &fields,
                    json!({"v": 3, "ok": value}).to_string().into_bytes(),
                ),
            ),
            Reply::Error(name, extra) => {
                let mut answer = json!({"v": 3, "error": name});
                if let Value::Object(extra) = extra {
                    answer.as_object_mut().expect("an object").extend(extra);
                }
                (
                    json!(200),
                    seal(&keys, &fields, answer.to_string().into_bytes()),
                )
            }
            Reply::Plain(plain) => (json!(200), seal(&keys, &fields, plain)),
        };
        let mut writing = out.lock().expect("the writer");
        let answer = json!({"v": 1, "attempt": call.attempt, "seq": writing.1, "kind": "host_answer",
                            "re": re, "status": status, "body": wire::encode_base64(&body)});
        writing.1 += 1;
        if write_frame(&mut writing.0, &answer).is_err() {
            return;
        }
    }
}

/// What the service end writes, and the seq of its next frame.
type Out = Arc<Mutex<(UnixStream, u64)>>;

/// Write `upstream` for the fetch `re` of `attempt`: its frames in one write,
/// so its runner reads them together, up to an `AfterCredit` the runner has
/// not yet granted, whose rest a thread of its own writes once it has.
/// False once the service's end closed or its write failed.
fn answer_fetch(
    out: &Out,
    frames: &Arc<Mutex<Vec<Value>>>,
    attempt: &str,
    re: u64,
    upstream: Vec<Upstream>,
) -> bool {
    let mut written = Vec::new();
    let mut writing = out.lock().expect("the writer");
    let mut upstream = upstream.into_iter();
    while let Some(next) = upstream.next() {
        let members = match next {
            Upstream::Pause(pause) => {
                if writing.0.write_all(&written).is_err() {
                    return false;
                }
                written.clear();
                std::thread::sleep(pause); // sleep-ok: the upstream's pause, as the test scripts it
                continue;
            }
            Upstream::AfterCredit(bytes) => {
                if granted(frames, re) >= bytes {
                    continue;
                }
                if writing.0.write_all(&written).is_err() {
                    return false;
                }
                let rest: Vec<Upstream> = upstream.by_ref().collect();
                let (out, frames, attempt) = (out.clone(), frames.clone(), attempt.to_owned());
                std::thread::spawn(move || {
                    eventually(|| granted(&frames, re) >= bytes);
                    answer_fetch(&out, &frames, &attempt, re, rest);
                });
                return true;
            }
            Upstream::Head(status, headers, body) => json!({"kind": "fetch_chunk",
                "status": status,
                "headers": headers.iter().map(|(name, value)| json!([name, value]))
                                  .collect::<Vec<_>>(),
                "body": wire::encode_base64(&body)}),
            Upstream::Chunk(body) => json!({"kind": "fetch_chunk", "status": null,
                "headers": null, "body": wire::encode_base64(&body)}),
            Upstream::Frame(frame) => json!({"kind": "attached_frame",
                "frame": wire::encode_base64(&frame)}),
            Upstream::Refusal(header, body) => json!({"kind": "attached_refusal",
                "header": header, "body": wire::encode_base64(&body)}),
            Upstream::End(error) => json!({"kind": "fetch_end", "error": error}),
            Upstream::Close => json!({"kind": "close", "reason": "malformed"}),
        };
        let closing = members["kind"] == "close";
        let mut sent = json!({"v": 1, "attempt": attempt, "seq": writing.1, "re": re});
        sent.as_object_mut()
            .expect("an object")
            .extend(members.as_object().expect("an object").clone());
        writing.1 += 1;
        let json = sent.to_string();
        let length = u32::try_from(json.len()).expect("a frame under 4 GiB");
        written.extend_from_slice(&length.to_be_bytes());
        written.extend_from_slice(json.as_bytes());
        if closing {
            let _ = writing.0.write_all(&written);
            return false;
        }
    }
    writing.0.write_all(&written).is_ok()
}

/// The bytes the runner has granted back for the fetch `re` so far.
pub fn granted(frames: &Arc<Mutex<Vec<Value>>>, re: u64) -> u64 {
    frames
        .lock()
        .expect("the frames")
        .iter()
        .filter(|frame| frame["kind"] == "credit" && frame["re"] == re)
        .map(|frame| frame["bytes"].as_u64().expect("bytes"))
        .sum()
}

/// Wait until `holds` holds, within a minute: what it looks for is the
/// runner's, reached on its own time.
pub fn eventually(mut holds: impl FnMut() -> bool) {
    let until = Instant::now() + Duration::from_secs(60);
    while !holds() {
        assert!(
            Instant::now() < until,
            "the condition did not hold within a minute"
        );
        std::thread::sleep(Duration::from_millis(20)); // sleep-ok: polls a condition the runner reaches, bounded by a minute
    }
}

/// A pin CYFR answers for `host` on `scheme`'s default port.
pub fn pin(id: &str, scheme: &str, host: &str) -> Reply {
    let port = if scheme == "https" { 443 } else { 80 };
    Reply::Ok(
        json!({"id": id, "ip": "203.0.113.10", "family": 4, "scheme": scheme,
                     "port": port, "host": host, "expires_at": now_ms() + 30_000}),
    )
}

/// One frame of an attached request's answer as CYFR seals it: its kind
/// byte and its value sealed for `call_id` at `seq` under the attempt's
/// seal key (`Prima.WorkerAuth.seal_frame/7`).
pub fn seal_frame(job: &Job, call_id: &str, seq: u64, kind: &str, plain: &[u8]) -> Vec<u8> {
    use aes_gcm::aead::{Aead, KeyInit, Payload};
    let aad = format!("cyfr-locus/v1/runtime/frame-answer\n{call_id}\n{seq}\n{kind}");
    let iv = random_iv();
    let sealed = aes_gcm::Aes256Gcm::new((&job.seal_key).into())
        .encrypt(
            &aes_gcm::Nonce::from(iv),
            Payload {
                msg: plain,
                aad: aad.as_bytes(),
            },
        )
        .expect("a frame seals");
    let (ciphertext, tag) = sealed.split_at(sealed.len() - 16);
    let mut bytes = iv.to_vec();
    bytes.extend_from_slice(tag);
    bytes.extend_from_slice(ciphertext);
    let byte = match kind {
        "head" => b'h',
        "chunk" => b'c',
        "end" => b'e',
        _error => b'x',
    };
    let mut frame = vec![byte];
    frame.extend_from_slice(wire::encode_base64url(&bytes).as_bytes());
    frame
}

/// CYFR's refusal of the attached fetch `call_id` as its listener answers
/// it: the posted call's header, signed under the attempt's call key, and
/// the guest error naming the call id, sealed as that call's answer.
pub fn attached_refusal(job: &Job, call_id: &str, kind: &str, message: &str) -> Upstream {
    refusal_as(job, call_id, kind, message, &Signed::default())
}

/// How a scripted refusal's header is signed: its age, the key it is
/// signed under, and the attempt it names.
#[derive(Default)]
pub struct Signed {
    pub age_ms: u64,
    pub call_key: Option<[u8; 32]>,
    pub attempt: Option<Attempt>,
}

/// An attached refusal as `attached_refusal` writes one, signed as `signed`
/// says.
pub fn refusal_as(
    job: &Job,
    call_id: &str,
    kind: &str,
    message: &str,
    signed: &Signed,
) -> Upstream {
    let answer = json!({"v": 3, "error": "guest_error", "type": kind, "message": message,
                        "call_id": call_id});
    answered_refusal(job, &answer, signed)
}

/// CYFR's refusal of an attached fetch whose sealed answer is `answer`, as
/// given, its header signed as `signed` says.
pub fn answered_refusal(job: &Job, answer: &Value, signed: &Signed) -> Upstream {
    let fields = CallFields {
        attempt: signed.attempt.clone().unwrap_or_else(|| job.attempt()),
        boot: BOOT.to_owned(),
        runner: RUNNER.to_owned(),
        member: MEMBER.to_owned(),
        ts: now_ms() - signed.age_ms,
        nonce: "n_attached_refusal".to_owned(),
    };
    let posted = b"the posted body";
    let key = signed.call_key.unwrap_or(job.call_key);
    let header = auth::host_call_header(&key, &fields, posted).expect("a header");
    let body = seal(&job.keys(), &fields, answer.to_string().into_bytes());
    Upstream::Refusal(header, body)
}

/// `keys` sealed under `seal_key` for the runner of their attempt
/// (`Prima.WorkerAuth.seal_attempt_keys/3`): the attempt as base64url JSON,
/// `.`, and the two keys sealed under the attempt-keys label and the
/// attempt's values.
pub fn sealed_attempt_keys(seal_key: &[u8; 32], keys: &AttemptKeys) -> String {
    use aes_gcm::aead::{Aead, KeyInit, Payload};
    let a = &keys.attempt;
    let named = json!({"athanor_id": a.athanor_id, "execution_id": a.execution_id,
        "attempt": a.attempt, "fence": a.fence, "generation": a.generation,
        "service": a.service});
    let aad = [
        auth::ATTEMPT_KEYS_LABEL.to_owned(),
        a.athanor_id.clone(),
        a.execution_id.clone(),
        a.attempt.clone(),
        a.fence.to_string(),
        a.generation.to_string(),
        a.service.clone(),
    ]
    .join("\n");
    let mut plain = keys.call.to_vec();
    plain.extend_from_slice(&keys.seal[..]);
    let iv = random_iv();
    let sealed = aes_gcm::Aes256Gcm::new(seal_key.into())
        .encrypt(
            &aes_gcm::Nonce::from(iv),
            Payload {
                msg: &plain,
                aad: aad.as_bytes(),
            },
        )
        .expect("the keys seal");
    let (ciphertext, tag) = sealed.split_at(sealed.len() - 16);
    let mut bytes = iv.to_vec();
    bytes.extend_from_slice(tag);
    bytes.extend_from_slice(ciphertext);
    format!(
        "{}.{}",
        wire::encode_base64url(named.to_string().as_bytes()),
        wire::encode_base64url(&bytes)
    )
}

fn random_iv() -> [u8; 12] {
    let random = "the operating system's random source answers";
    let [a, b, c, d, e, f, g, h] = getrandom::u64().expect(random).to_le_bytes();
    let [i, j, k, l] = getrandom::u32().expect(random).to_le_bytes();
    [a, b, c, d, e, f, g, h, i, j, k, l]
}

pub fn seal(keys: &AttemptKeys, fields: &CallFields, plain: Vec<u8>) -> Vec<u8> {
    // A fresh IV from the system's random source for every answer.
    let random = "the operating system's random source answers";
    let [a, b, c, d, e, f, g, h] = getrandom::u64().expect(random).to_le_bytes();
    let [i, j, k, l] = getrandom::u32().expect(random).to_le_bytes();
    let iv = [a, b, c, d, e, f, g, h, i, j, k, l];
    auth::seal_call(&keys.seal, Direction::Answer, fields, &plain, &iv)
        .expect("an answer seals")
        .into_bytes()
}

pub fn write_frame(stream: &mut UnixStream, frame: &Value) -> std::io::Result<()> {
    write_raw(stream, frame.to_string().as_bytes())
}

pub fn write_raw(stream: &mut UnixStream, json: &[u8]) -> std::io::Result<()> {
    let length = u32::try_from(json.len()).expect("a frame under 4 GiB");
    stream.write_all(&length.to_be_bytes())?;
    stream.write_all(json)
}

/// The fields a host call's header names.
pub fn call_fields(header: &str) -> CallFields {
    let get = |name: &str| {
        header
            .split(' ')
            .find_map(|token| token.strip_prefix(&format!("{name}=")))
            .unwrap_or_else(|| panic!("the header names no {name}"))
            .to_owned()
    };
    CallFields {
        attempt: Attempt {
            athanor_id: get("athanor_id"),
            execution_id: get("execution_id"),
            attempt: get("attempt"),
            fence: get("fence").parse().expect("a fence"),
            generation: get("generation").parse().expect("a generation"),
            service: get("service"),
        },
        boot: get("boot"),
        runner: get("runner"),
        member: get("member"),
        ts: get("ts").parse().expect("a ts"),
        nonce: get("nonce"),
    }
}

/// A path within the test's folder.
pub fn within(dir: &Path, name: &str) -> PathBuf {
    dir.join(name)
}

/// A poster that answers in process, as a script says: the service end
/// without a relay, for what the attempt's host calls make of answers.
pub struct Scripted {
    pub job: Job,
    pub script: Script,
    pub calls: Vec<Call>,
}

impl cyfr_runner::host::Post for Scripted {
    async fn place(&mut self, _op: cyfr_runner::host::Op) -> Option<cyfr_runner::host::Place> {
        Some(cyfr_runner::host::Place::free())
    }

    fn post(
        &mut self,
        _op: cyfr_runner::host::Op,
        header: String,
        body: Vec<u8>,
        _place: cyfr_runner::host::Place,
    ) -> impl std::future::Future<Output = Option<cyfr_runner::host::Reached>> {
        let keys = self.job.keys();
        let fields = call_fields(&header);
        let plain = auth::open_call(&keys.seal, Direction::Body, &fields, &body)
            .expect("a body sealed under the attempt's key");
        let request = deep(&plain);
        let call = Call {
            op: request["op"].as_str().expect("an op").to_owned(),
            args: request["args"].clone(),
            attempt: fields.attempt.attempt.clone(),
            header: header.clone(),
        };
        self.calls.push(call.clone());
        let reached = match (self.script)(&call, &self.job) {
            Reply::Ok(value) => Some(seal(
                &keys,
                &fields,
                json!({"v": 3, "ok": value}).to_string().into_bytes(),
            )),
            Reply::Error(name, extra) => {
                let mut answer = json!({"v": 3, "error": name});
                if let Value::Object(extra) = extra {
                    answer.as_object_mut().expect("an object").extend(extra);
                }
                Some(seal(&keys, &fields, answer.to_string().into_bytes()))
            }
            Reply::Plain(plain) => Some(seal(&keys, &fields, plain)),
            _ => None,
        };
        std::future::ready(reached.map(|body| cyfr_runner::host::Reached { status: 200, body }))
    }
}

/// The caller presenting `job`'s attempt.
pub fn caller(job: &Job) -> cyfr_runner::host::Caller {
    cyfr_runner::host::Caller {
        keys: job.keys(),
        boot: BOOT.to_owned(),
        runner: RUNNER.to_owned(),
        member: MEMBER.to_owned(),
    }
}

/// `depth` nested arrays around nothing.
pub fn nested(depth: usize) -> String {
    format!("{}{}", "[".repeat(depth), "]".repeat(depth))
}

/// Run `test` on a thread of `STACK_BYTES`: a test that holds a document
/// nested as deep as the runner reads one, as CYFR's reader does.
pub fn deep_stack(test: fn()) {
    std::thread::Builder::new()
        .stack_size(STACK_BYTES)
        .spawn(test)
        .expect("a test thread")
        .join()
        .expect("the test passes");
}

/// The runner's resident memory, in KiB.
pub fn resident_kib(pid: u32) -> u64 {
    std::fs::read_to_string(format!("/proc/{pid}/status"))
        .unwrap_or_default()
        .lines()
        .find_map(|line| line.strip_prefix("VmRSS:"))
        .and_then(|rest| rest.split_whitespace().next())
        .and_then(|kib| kib.parse().ok())
        .unwrap_or(0)
}

/// How many times each needle is in the writable memory of process `pid`
/// (its heap, stacks and anonymous maps, its own binary's data included).
pub fn scan(pid: u32, needles: &[&[u8]]) -> Vec<usize> {
    use std::io::{Seek as _, SeekFrom};
    let maps = std::fs::read_to_string(format!("/proc/{pid}/maps")).expect("the maps");
    let mut memory = std::fs::File::open(format!("/proc/{pid}/mem")).expect("the memory");
    let mut found = vec![0; needles.len()];
    for line in maps.lines() {
        let mut parts = line.split_whitespace();
        let (Some(range), Some(perms)) = (parts.next(), parts.next()) else {
            continue;
        };
        if !perms.starts_with("rw") || line.contains("[vvar") || line.contains("[vsys") {
            continue;
        }
        let (start, end) = range.split_once('-').expect("a range");
        let start = u64::from_str_radix(start, 16).expect("hex");
        let end = u64::from_str_radix(end, 16).expect("hex");
        let mut region = vec![0u8; usize::try_from(end - start).expect("a size")];
        if memory.seek(SeekFrom::Start(start)).is_err() {
            continue;
        }
        let mut read = 0;
        while read < region.len() {
            match memory.read(&mut region[read..]) {
                Ok(0) | Err(_) => break,
                Ok(n) => read += n,
            }
        }
        region.truncate(read);
        for (count, needle) in found.iter_mut().zip(needles) {
            *count += region
                .windows(needle.len())
                .filter(|window| window == needle)
                .count();
        }
    }
    found
}
