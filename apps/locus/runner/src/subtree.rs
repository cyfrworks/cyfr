// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 CYFR Works Inc.

//! The runner's loop: one subtree at a time from its service, over the
//! control channel, each from its `assign` to its `complete`.
//!
//! An `assign` carries the signed assignment, the input its digest binds
//! and the attempt's opened keys. The runner reads the assignment, which
//! must name the service and boot its environment does, and the input,
//! which must be a JSON object; binds its relay to the attempt, opening
//! the relay with its first assignment; and runs the root's attempt
//! (`crate::attempt`). An assignment that does not read, or a relay that
//! cannot carry it, is not the service's to have sent: the runner ends
//! with 1 and the service reports what it assigned.
//!
//! When the attempt ends with its close recorded, the runner sends
//! `complete`, `clean` unless it stopped the component's call, a call of
//! the attempt ended lost or uncertain, or anything is still outstanding on
//! its relay, and waits for its next `assign`. An
//! attempt left open ends the runner: it sends `exit` naming the attempt
//! and ends with 1. So does the relay's end, which leaves the runner no
//! way to CYFR. A `cancel_child` names no child of a subtree with none,
//! and is ignored, as is a frame of another kind, an `assign` while a
//! subtree runs, or a line that is not a frame; a line past the channel's
//! bound ends the runner with 1. When the channel ends the runner ends with
//! 0 once no subtree runs.

use std::sync::Arc;

use tokio::task::JoinHandle;

use crate::assignment;
use crate::attempt::{self, Ended, Start};
use crate::control::{Environment, Lines, Message, Received, Writer};
use crate::engine::Engine;
use crate::relay::Relay;
use crate::wire::read;

/// Where the runner's relay is: the stream its keeper gave it, or the
/// unix socket the test build's direct launcher names.
pub enum RelayAt {
    Stream(tokio::net::UnixStream),
    Socket(String),
}

/// The subtree a runner is running.
struct Running {
    execution_id: String,
    attempt: String,
    task: JoinHandle<Ended>,
}

/// Serve subtrees from `lines` and `control` until the runner ends,
/// answering its exit status.
pub async fn serve<R>(
    environment: Environment,
    engine: Arc<Engine>,
    mut lines: Lines<R>,
    control: Writer,
    mut relay_at: Option<RelayAt>,
) -> u8
where
    R: tokio::io::AsyncRead + Unpin,
{
    let mut relay: Option<Relay> = None;
    let mut running: Option<Running> = None;
    let mut closed = false;
    loop {
        tokio::select! {
            received = lines.next(), if !closed => match received {
                Received::Message(Message::Assign { assignment: token, input, keys }) => {
                    if let Some(running) = &running {
                        eprintln!(
                            "cyfr-runner: assigned while running {}; ignored",
                            running.execution_id
                        );
                        continue;
                    }
                    let Ok(assignment) = assignment::read(&token) else {
                        eprintln!("cyfr-runner: the assignment cannot be read; ending");
                        return 1;
                    };
                    if assignment.service != environment.service_id
                        || assignment.boot != environment.boot
                    {
                        eprintln!("cyfr-runner: the assignment names another service or boot; ending");
                        return 1;
                    }
                    let input = match read(&input) {
                        Ok(input) if input.value().is_object() => input,
                        _ => {
                            eprintln!("cyfr-runner: the assignment's input is no JSON object; ending");
                            return 1;
                        }
                    };
                    if relay.is_none() {
                        match open(relay_at.take()).await {
                            Some(opened) => relay = Some(opened),
                            None => {
                                eprintln!("cyfr-runner: the relay cannot be opened; ending");
                                return 1;
                            }
                        }
                    }
                    let relay = relay.as_ref().expect("the relay is open");
                    if relay.bind(&assignment.attempt).await.is_err() {
                        eprintln!("cyfr-runner: the relay cannot carry the assignment; ending");
                        return 1;
                    }
                    let start = Start { token, assignment, input, keys };
                    let runner = attempt::Runner {
                        engine: engine.clone(),
                        relay: relay.clone(),
                        control: control.clone(),
                        runner_id: environment.runner_id.clone(),
                        boot: environment.boot.clone(),
                    };
                    running = Some(Running {
                        execution_id: start.assignment.execution_id.clone(),
                        attempt: start.assignment.attempt.clone(),
                        task: tokio::spawn(attempt::run(start, runner)),
                    });
                }
                Received::Message(Message::CancelChild { execution_id }) => {
                    eprintln!("cyfr-runner: cancel_child names no child here ({execution_id}); ignored");
                }
                Received::Message(other) => {
                    eprintln!("cyfr-runner: the service sent a {other:?} frame; ignored");
                }
                Received::Refused(refusal) => {
                    eprintln!("cyfr-runner: the service sent a line that is not a frame: {refusal:?}");
                }
                Received::Oversize => {
                    eprintln!("cyfr-runner: the service sent a line past the protocol's bound; ending");
                    return 1;
                }
                Received::Closed => {
                    closed = true;
                    if running.is_none() {
                        return 0;
                    }
                }
            },
            ended = async {
                match running.as_mut() {
                    Some(running) => (&mut running.task).await,
                    None => std::future::pending().await,
                }
            } => {
                let Running { execution_id, attempt, .. } =
                    running.take().expect("a running subtree");
                let ended = ended.unwrap_or(Ended { closed: false, unclean: true });
                if !ended.closed {
                    exit(&control, &environment, vec![attempt]).await;
                    return 1;
                }
                let idle = match &relay {
                    Some(relay) => relay.idle().await,
                    None => true,
                };
                let complete = Message::Complete {
                    execution_id,
                    clean: !ended.unclean && idle,
                };
                if control.send_flushed(&complete).await.is_err() {
                    return 1;
                }
                if closed {
                    return 0;
                }
            }
            () = async {
                match &relay {
                    Some(relay) => relay.closed().await,
                    None => std::future::pending().await,
                }
            } => {
                eprintln!("cyfr-runner: the relay is closed; ending");
                let open = running.take().map(|running| {
                    running.task.abort();
                    running.attempt
                });
                exit(&control, &environment, open.into_iter().collect()).await;
                return 1;
            }
        }
    }
}

async fn open(at: Option<RelayAt>) -> Option<Relay> {
    let stream = match at? {
        RelayAt::Stream(stream) => stream,
        RelayAt::Socket(path) => tokio::net::UnixStream::connect(path).await.ok()?,
    };
    let (reader, writer) = stream.into_split();
    Some(Relay::start(reader, writer))
}

async fn exit(control: &Writer, environment: &Environment, open: Vec<String>) {
    let exit = Message::Exit {
        runner: environment.runner_id.clone(),
        open,
    };
    let _ = control.send_flushed(&exit).await;
}
