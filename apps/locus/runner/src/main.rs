// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//! The runner's program. It reads its environment (`Environment`), takes
//! its two channels, builds its engine and serves subtrees on a
//! runtime of as many worker threads as its processors
//! (`cyfr_runner::subtree::serve`) until it ends:
//! 0 when its control channel ends with nothing running, 1 when it ends
//! otherwise (after an `exit` frame where it has one to write), 69 when its
//! engine cannot be built, and 78 when its environment is refused or names
//! a channel it was not given. A panic aborts it, and its keeper reports
//! the exit.
//!
//! Its control channel is descriptor 3, or standard input and output when
//! `RUNTIME_CONTROL_FD` is 0; its relay is descriptor 4, or the unix socket
//! `RUNTIME_RELAY_SOCKET` names, which it connects to with its first
//! assignment. The loop runs on a thread of `STACK_BYTES`, the stack the
//! JSON reader needs at its deepest (`cyfr_runner::wire`), and so does each
//! worker.

// The one place this crate takes up unsafe code: adopting the two
// descriptors the keeper hands over (`adopt`). The library forbids it.
#![deny(unsafe_code)]

use std::os::fd::{FromRawFd as _, OwnedFd};
use std::os::unix::net::UnixStream;
use std::process::ExitCode;

use cyfr_runner::control::{Environment, Lines, Relay, Writer};
use cyfr_runner::engine::Engine;
use cyfr_runner::subtree::{RelayAt, serve};
use cyfr_runner::wire::STACK_BYTES;

fn main() -> ExitCode {
    let environment = match Environment::read(std::env::vars_os()) {
        Ok(environment) => environment,
        Err(refusal) => {
            eprintln!("cyfr-runner: {refusal}");
            return ExitCode::from(78);
        }
    };
    // Each descriptor is adopted once: one named for both channels is no
    // pair the keeper hands, and is refused before either is adopted.
    if environment.relay == Relay::Fd(environment.control_fd) {
        eprintln!(
            "cyfr-runner: the control descriptor {} is the relay's",
            environment.control_fd
        );
        return ExitCode::from(78);
    }
    let control = match environment.control_fd {
        0 => None,
        fd => match adopt(fd) {
            Some(stream) => Some(stream),
            None => {
                eprintln!("cyfr-runner: the control descriptor {fd} is not open");
                return ExitCode::from(78);
            }
        },
    };
    let relay = match &environment.relay {
        Relay::Fd(fd) => match adopt(*fd) {
            Some(stream) => Some(Ok(stream)),
            None => {
                eprintln!("cyfr-runner: the relay descriptor {fd} is not open");
                return ExitCode::from(78);
            }
        },
        Relay::Socket(path) => Some(Err(path.clone())),
    };
    let engine = match Engine::new() {
        Ok(engine) => engine,
        Err(error) => {
            eprintln!("cyfr-runner: the engine cannot be built: {error}");
            return ExitCode::from(69);
        }
    };
    let runner = std::thread::Builder::new()
        .name("runner".to_owned())
        .stack_size(STACK_BYTES)
        .spawn(move || run(environment, engine, control, relay));
    match runner.map(|thread| thread.join()) {
        Ok(Ok(status)) => ExitCode::from(status),
        _ => ExitCode::from(1),
    }
}

fn run(
    environment: Environment,
    engine: std::sync::Arc<Engine>,
    control: Option<UnixStream>,
    relay: Option<Result<UnixStream, String>>,
) -> u8 {
    // As many workers as the runner's processors (`available_parallelism`
    // reads its quota), so a formula's children need not wait for each
    // other; the loop over the control channel runs on this thread.
    let workers = std::thread::available_parallelism().map_or(1, std::num::NonZero::get);
    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .worker_threads(workers)
        .thread_name("runner-worker")
        .thread_stack_size(STACK_BYTES)
        // A worker serves the timers and I/O after every task it polls, not
        // every 61st: with every worker computing a guest that yields each
        // epoch tick, a budget, a lease, a stop and the channels keep their
        // time within a tick of it.
        .event_interval(1)
        .enable_io()
        .enable_time()
        .build()
    {
        Ok(runtime) => runtime,
        Err(error) => {
            eprintln!("cyfr-runner: the runtime cannot be built: {error}");
            return 69;
        }
    };
    // Each attempt's budget, lease and close run on this thread with the
    // loop (`cyfr_runner::subtree::serve`); its component's work on the
    // workers.
    let status = runtime.block_on(async move {
        let relay_at = match relay {
            Some(Ok(stream)) => match nonblocking(stream) {
                Some(stream) => Some(RelayAt::Stream(stream)),
                None => return 78,
            },
            Some(Err(path)) => Some(RelayAt::Socket(path)),
            None => None,
        };
        match control {
            None => {
                let control = Writer::start(tokio::io::stdout());
                serve(
                    environment,
                    engine,
                    Lines::new(tokio::io::stdin()),
                    control,
                    relay_at,
                )
                .await
            }
            Some(stream) => {
                let Some(stream) = nonblocking(stream) else {
                    return 78;
                };
                let (reader, writer) = stream.into_split();
                let control = Writer::start(writer);
                serve(environment, engine, Lines::new(reader), control, relay_at).await
            }
        }
    });
    // Standard input is read on a blocking thread, which a shutdown would
    // wait on for a line that may never come.
    runtime.shutdown_background();
    status
}

fn nonblocking(stream: UnixStream) -> Option<tokio::net::UnixStream> {
    stream.set_nonblocking(true).ok()?;
    tokio::net::UnixStream::from_std(stream).ok()
}

/// The stream on descriptor `fd`, when one is open there.
fn adopt(fd: u32) -> Option<UnixStream> {
    let raw = i32::try_from(fd).ok()?;
    // A descriptor below 3 is standard input, output or error, never a
    // channel; one that is not open has no entry here.
    if raw < 3 || std::fs::symlink_metadata(format!("/proc/self/fd/{raw}")).is_err() {
        return None;
    }
    // SAFETY: the descriptor is open (above), and was given to this
    // process by the keeper that started it (descriptors 3 and 4, its
    // socketpairs' ends) or, for the control channel, named by the
    // environment it set. Nothing else in the process names it: `main`
    // adopts the control descriptor and the relay's once each, before any
    // other thread or file is opened, and refuses a control descriptor
    // equal to the relay's before adopting either, so the `OwnedFd` is its
    // one owner and closes it once.
    #[allow(unsafe_code)]
    let owned = unsafe { OwnedFd::from_raw_fd(raw) };
    Some(UnixStream::from(owned))
}
