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
}

impl Job {
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
        }
    }

    pub fn digest(&self) -> String {
        cyfr_runner::engine::digest(&self.component)
    }

    pub fn attempt(&self) -> Attempt {
        Attempt {
            athanor_id: ATHANOR.to_owned(),
            execution_id: self.execution_id.clone(),
            attempt: self.attempt.clone(),
            fence: 2,
            generation: 7,
            service: SERVICE.to_owned(),
        }
    }

    pub fn keys(&self) -> AttemptKeys {
        AttemptKeys {
            attempt: self.attempt(),
            call: self.call_key.into(),
            seal: self.seal_key.into(),
        }
    }

    /// The assignment token: its payload, and a MAC the runner does not
    /// verify (CYFR does, at attach).
    pub fn token(&self) -> String {
        let now = now_ms();
        let payload = json!({
            "v": 1, "generation": 7, "service": SERVICE, "boot": BOOT, "member": MEMBER,
            "issued_at": now, "claim_by": now + 30_000,
            "execution_id": self.execution_id, "attempt": self.attempt, "fence": 2,
            "root_execution_id": self.execution_id, "athanor_id": ATHANOR,
            "actor": {"authenticated": true, "user_id": "usr_test"},
            "authority": self.authority,
            "component": {"ref": self.reference, "type": self.kind, "digest": self.digest(),
                          "declared_needs": []},
            "input_digest": format!("sha256:{}", auth::sha256_hex(&self.input)),
            "timeout_ms": self.timeout_ms, "deadline": now + self.timeout_ms + 60_000,
            "lease_until": now + 180_000, "intercepted": [],
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
}

pub type Script = Box<dyn FnMut(&Call, &Job) -> Reply + Send>;

/// The answers CYFR gives a job that runs and closes as asked.
pub fn standard(call: &Call, job: &Job) -> Reply {
    match call.op.as_str() {
        "attach" => Reply::Ok(json!({})),
        "fetch_artifact" => Reply::Ok(Value::String(wire::encode_base64(&job.component))),
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
    pub stderr: Arc<Mutex<String>>,
    dir: PathBuf,
    listener: Option<UnixListener>,
    pub calls: Arc<Mutex<Vec<Call>>>,
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

    pub fn start_on(control: Control, variables: &[(&str, &str)]) -> Service {
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
        let (mut command, ours) = match control {
            Control::Stdio => {
                let mut command = Command::new(runner);
                command.stdin(Stdio::piped()).stdout(Stdio::piped());
                (command, None)
            }
            Control::Descriptor3 => {
                let (ours, theirs) = UnixStream::pair().expect("a socket pair");
                let mut command = Command::new("/bin/sh");
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
        let stderr = Arc::new(Mutex::new(String::new()));
        let collected = stderr.clone();
        let mut errors = child.stderr.take().expect("its errors");
        std::thread::spawn(move || {
            let mut text = String::new();
            let _ = errors.read_to_string(&mut text);
            collected.lock().expect("stderr").push_str(&text);
        });
        Service {
            stdin: Some(stdin),
            child,
            lines,
            stderr,
            dir,
            listener: Some(listener),
            calls: Arc::new(Mutex::new(Vec::new())),
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

    /// Accept the relay and answer its calls by `script`, on a thread.
    pub fn serve(&mut self, job: Job, script: Script) {
        let listener = self.listener.take().expect("the relay is not yet served");
        let calls = self.calls.clone();
        let relay_end = std::thread::Builder::new().stack_size(STACK_BYTES);
        let _ = relay_end.spawn(move || {
            listener
                .set_nonblocking(false)
                .expect("a blocking listener");
            let Ok((stream, _)) = listener.accept() else {
                return;
            };
            relay(stream, job, script, calls);
        });
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

    /// The runner's exit status, within `within`.
    pub fn exit(&mut self, within: Duration) -> ExitStatus {
        let until = Instant::now() + within;
        loop {
            if let Some(status) = self.child.try_wait().expect("the runner's status") {
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

    pub fn errors(&self) -> String {
        self.stderr.lock().expect("stderr").clone()
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
/// answered by `script`.
pub fn relay(mut stream: UnixStream, job: Job, mut script: Script, calls: Arc<Mutex<Vec<Call>>>) {
    let keys = job.keys();
    let mut seq = 0u64;
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
        if frame["kind"] != "host_call" {
            continue;
        }
        let header = frame["header"].as_str().expect("a header");
        let fields = call_fields(header);
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
            Reply::Close => {
                let close = json!({"v": 1, "attempt": call.attempt, "seq": seq, "kind": "close",
                                   "reason": "malformed"});
                let _ = write_frame(&mut stream, &close);
                return;
            }
            Reply::Frame(json) => {
                let _ = write_raw(&mut stream, &json);
                continue;
            }
            Reply::Dropped => (Value::Null, Vec::new()),
            Reply::OkThenEnd(value) => {
                let body = seal(
                    &keys,
                    &fields,
                    json!({"v": 3, "ok": value}).to_string().into_bytes(),
                );
                let answer = json!({"v": 1, "attempt": call.attempt, "seq": seq, "kind": "host_answer",
                                    "re": re, "status": 200, "body": wire::encode_base64(&body)});
                let _ = write_frame(&mut stream, &answer);
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
        let answer = json!({"v": 1, "attempt": call.attempt, "seq": seq, "kind": "host_answer",
                            "re": re, "status": status, "body": wire::encode_base64(&body)});
        seq += 1;
        if write_frame(&mut stream, &answer).is_err() {
            return;
        }
    }
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
    fn post(
        &mut self,
        _op: cyfr_runner::host::Op,
        header: String,
        body: Vec<u8>,
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
