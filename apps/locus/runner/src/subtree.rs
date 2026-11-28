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
//! **A subtree** is its root's attempt and every child a formula of it
//! starts (`Tree::start_child`), each an attempt of its own run on a task
//! of its own, its own store with it. A child runs only once its `child`
//! frame is written to the service; one whose frame is not written runs
//! nothing and is given back. The subtree holds an attempt only while it
//! runs: an attempt that ends leaves it, and a child's leaves the relay
//! once nothing of it is outstanding there, so a thousand children one
//! after another hold what one holds. At most `crate::control::MAX_OPEN`
//! run at once, as many as one `exit` can name; a child past them is not
//! started, and is given back. An execution the subtree runs already,
//! admitted again, is not started again, and the running child is left as
//! it is. A `cancel_child` naming a running child stops it: its
//! component's call is dropped and it closes `abandoned`. So does a child
//! whose waiter is gone (its formula's call, task or store), which is how
//! nothing of a formula's children outlives it. A cancel naming the root,
//! or nothing running in the subtree, is ignored.
//!
//! **The subtree completes** once every attempt of it has ended with its
//! close recorded, a cancelled child's close excepted, whose cancel fences
//! it: the runner sends `complete`, `clean` only when no attempt was
//! stopped or ended a call lost or uncertain, no child was cancelled, and
//! nothing is outstanding on its relay. An attempt left open, other than a
//! cancelled child's, ends the subtree: the rest are stopped where they
//! stand, and the runner sends `exit` naming every attempt still open and
//! ends with 1. So does the relay's end, which leaves the runner no way to
//! CYFR.
//!
//! **Reuse.** After a clean `complete` the runner takes the service's next
//! `assign`: the service decides reuse (`docs/plans/native-locus.md`, D1
//! (c)). What a subtree held went with its attempts: their tasks, stores,
//! streams, children's trackers and keys. Only the engine's compiles stay,
//! each for its fifteen minutes (`crate::engine`). The runner's own last
//! line is that it runs nothing for anyone it should not, whatever its
//! service sends: an `assign` after an unclean `complete`, or one naming
//! another athanor than its first subtree's, runs nothing, and the runner
//! sends `exit` with nothing open and ends with 1.
//!
//! A frame of another kind, an `assign` while a subtree runs, or a line
//! that is not a frame is ignored; a line past the channel's bound ends
//! the runner with 1. When the channel ends the runner ends with 0 once no
//! subtree runs.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use tokio::sync::mpsc;

use crate::assignment;
use crate::attempt::{self, Answer, Ended, Start};
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

/// A signal that stops one attempt: once given it stays given, and every
/// copy of it gives the same one.
#[derive(Clone)]
pub struct Stop(Arc<tokio::sync::watch::Sender<bool>>);

impl Stop {
    pub fn new() -> Stop {
        Stop(Arc::new(tokio::sync::watch::channel(false).0))
    }

    /// Give the signal.
    pub fn stop(&self) {
        self.0.send_replace(true);
    }

    /// Wait until the signal is given.
    pub async fn stopped(&self) {
        let mut given = self.0.subscribe();
        let _ = given.wait_for(|given| *given).await;
    }
}

impl Default for Stop {
    fn default() -> Stop {
        Stop::new()
    }
}

/// A `Stop` given when it is dropped, unless disarmed first: what a waiter
/// holds of the child it waits for, so a waiter that goes stops it.
pub struct StopOnDrop(Option<Stop>);

impl StopOnDrop {
    pub fn new(stop: Stop) -> StopOnDrop {
        StopOnDrop(Some(stop))
    }

    /// Drop it without giving the signal: the child has answered.
    pub fn disarm(mut self) {
        self.0 = None;
    }
}

impl Drop for StopOnDrop {
    fn drop(&mut self) {
        if let Some(stop) = &self.0 {
            stop.stop();
        }
    }
}

/// Why a child was not started: nothing of it ran, and its admission is
/// to be given back.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Unstarted {
    /// The subtree runs its execution already: the running child is left
    /// as it is.
    Known,
    /// The subtree runs as many attempts as one `exit` can name
    /// (`crate::control::MAX_OPEN`).
    Full,
    /// Its `child` frame was not written: the service would not know of
    /// it.
    Unannounced,
    /// The subtree is ending.
    Ending,
}

/// The attempts of the subtree a runner runs.
pub struct Tree {
    athanor_id: String,
    root: String,
    state: Mutex<State>,
    finished: mpsc::UnboundedSender<Finished>,
    launches: mpsc::UnboundedSender<Launch>,
}

/// A child for the loop to run, on the runner's thread.
struct Launch {
    start: Start,
    runner: attempt::Runner,
    stop: Stop,
    waiter: Option<tokio::sync::oneshot::Sender<Answer>>,
}

#[derive(Default)]
struct State {
    /// The subtree's attempts still running, or reserved and not yet
    /// started, by execution: each leaves when it ends.
    entries: BTreeMap<String, Entry>,
    /// A child was cancelled, or an attempt ended what the runner does not
    /// know: the subtree completes not clean.
    unclean: bool,
    /// The subtree is ending: no child starts.
    ending: bool,
}

/// One attempt of the subtree, by its execution.
struct Entry {
    attempt: String,
    stop: Stop,
    task: Option<tokio::task::AbortHandle>,
    cancelled: bool,
}

impl Entry {
    fn new(attempt: &str, stop: Stop) -> Entry {
        Entry {
            attempt: attempt.to_owned(),
            stop,
            task: None,
            cancelled: false,
        }
    }
}

/// An attempt's end, as its task reports it.
struct Finished {
    execution_id: String,
    ended: Ended,
}

impl Tree {
    fn new(
        athanor_id: &str,
        root: &str,
        finished: mpsc::UnboundedSender<Finished>,
        launches: mpsc::UnboundedSender<Launch>,
    ) -> Arc<Tree> {
        Arc::new(Tree {
            athanor_id: athanor_id.to_owned(),
            root: root.to_owned(),
            state: Mutex::new(State::default()),
            finished,
            launches,
        })
    }

    /// A subtree of the root `root` for `athanor_id` that no loop serves,
    /// for a run outside one (the crate's import tests): its attempts' ends
    /// are reported to nobody.
    pub fn unserved(athanor_id: &str, root: &str) -> Arc<Tree> {
        Tree::new(
            athanor_id,
            root,
            mpsc::unbounded_channel().0,
            mpsc::unbounded_channel().0,
        )
    }

    /// The athanor the subtree runs for.
    pub fn athanor_id(&self) -> &str {
        &self.athanor_id
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().expect("the subtree's state")
    }

    /// Start the child `start` on `runner`, once its `child` frame is
    /// written to the service; `waiter` is answered its close, and `stop`
    /// stops it, as its waiter's going and a `cancel_child` do. A child not
    /// started is handed back, with why: nothing of it ran.
    pub async fn start_child(
        self: &Arc<Tree>,
        start: Start,
        runner: attempt::Runner,
        stop: Stop,
        waiter: Option<tokio::sync::oneshot::Sender<Answer>>,
    ) -> Result<(), (Unstarted, Box<Start>)> {
        let execution_id = start.assignment.execution_id.clone();
        let attempt = start.assignment.attempt.clone();
        {
            let mut state = self.lock();
            if state.ending {
                return Err((Unstarted::Ending, Box::new(start)));
            }
            if execution_id == self.root || state.entries.contains_key(&execution_id) {
                return Err((Unstarted::Known, Box::new(start)));
            }
            if state.entries.len() >= crate::control::MAX_OPEN {
                return Err((Unstarted::Full, Box::new(start)));
            }
            state
                .entries
                .insert(execution_id.clone(), Entry::new(&attempt, stop.clone()));
        }
        // Until it is handed to the loop, a child whose formula stopped
        // while its frame was being written is reported left open: whether
        // the service has it is not known, so the subtree ends naming it,
        // and never waits for it.
        let reserved = Reserved {
            tree: self,
            execution_id: Some(execution_id.clone()),
        };
        let child = Message::Child {
            execution_id: execution_id.clone(),
            attempt,
        };
        // The child runs only once its frame is written: a write that
        // failed runs nothing of it.
        if runner.control.send_flushed(&child).await.is_err() {
            reserved.handed();
            self.lock().entries.remove(&execution_id);
            return Err((Unstarted::Unannounced, Box::new(start)));
        }
        let launch = Launch {
            start,
            runner,
            stop,
            waiter,
        };
        if let Err(unsent) = self.launches.send(launch) {
            return Err((Unstarted::Ending, Box::new(unsent.0.start)));
        }
        reserved.handed();
        Ok(())
    }

    // Run `launch` on the runner's thread, as a task of its own; its end
    // is reported to the loop once its waiter has been answered. A subtree
    // that began to end meanwhile starts nothing: the entry, still open, is
    // named in its `exit`.
    fn launch(self: &Arc<Tree>, launch: Launch) {
        let Launch {
            start,
            runner,
            stop,
            waiter,
        } = launch;
        let execution_id = start.assignment.execution_id.clone();
        let tree = self.clone();
        let mut state = self.lock();
        if state.ending {
            return;
        }
        let reported = execution_id.clone();
        let task = tokio::task::spawn_local(async move {
            let (ended, answer) = attempt::run(start, runner, stop).await;
            if let Some(waiter) = waiter {
                let _ = waiter.send(answer);
            }
            tree.report(&reported, ended);
        });
        if let Some(entry) = state.entries.get_mut(&execution_id) {
            entry.task = Some(task.abort_handle());
        }
    }

    /// Record a doubt about the subtree that no attempt's end carries (a
    /// child's admission not given back, or given back unconfirmed; a
    /// formula's task stopped while its call was out): it completes not
    /// clean.
    pub fn doubt(&self) {
        self.lock().unclean = true;
    }

    fn report(&self, execution_id: &str, ended: Ended) {
        let _ = self.finished.send(Finished {
            execution_id: execution_id.to_owned(),
            ended,
        });
    }

    /// Stop the child `execution_id` for its service's `cancel_child`: the
    /// subtree completes not clean, however the child then ends (a cancel
    /// racing its close included), and a close CYFR does not record for it
    /// ends nothing: the cancel fences it. Whether it is a running child of
    /// this subtree; one that ended is no longer.
    fn cancel(&self, execution_id: &str) -> bool {
        let mut state = self.lock();
        let Some(entry) = state.entries.get_mut(execution_id) else {
            return false;
        };
        entry.cancelled = true;
        entry.stop.stop();
        state.unclean = true;
        true
    }

    // Record the end of `execution_id`'s attempt: what the subtree comes
    // to, or none while any attempt of it still runs.
    // Record the end of `execution_id`'s attempt, which the subtree holds
    // no more: the attempt, and what the subtree comes to, or none while
    // any attempt of it still runs.
    fn ended(&self, execution_id: &str, ended: Ended) -> (String, Option<Settled>) {
        let mut state = self.lock();
        let entry = state
            .entries
            .remove(execution_id)
            .expect("an attempt the subtree holds");
        if !ended.closed && !entry.cancelled {
            let mut open = self.end(&mut state);
            open.push(entry.attempt.clone());
            return (entry.attempt, Some(Settled::Open(open)));
        }
        state.unclean |= ended.unclean || !ended.closed;
        if state.entries.is_empty() {
            state.ending = true;
            let unclean = state.unclean;
            return (entry.attempt, Some(Settled::Closed { unclean }));
        }
        (entry.attempt, None)
    }

    /// How many attempt records the subtree holds.
    fn held(&self) -> usize {
        self.lock().entries.len()
    }

    /// End the subtree where it stands: no child starts, every attempt
    /// still running is stopped where it stands, and the attempts left
    /// open are answered, a cancelled child's excepted.
    fn end_now(&self) -> Vec<String> {
        let mut state = self.lock();
        self.end(&mut state)
    }

    fn end(&self, state: &mut State) -> Vec<String> {
        state.ending = true;
        let mut open = Vec::new();
        for entry in state.entries.values_mut() {
            if let Some(task) = &entry.task {
                task.abort();
            }
            if !entry.cancelled {
                open.push(entry.attempt.clone());
            }
        }
        open
    }
}

/// A child reserved in its subtree and not yet handed to the loop.
struct Reserved<'a> {
    tree: &'a Tree,
    execution_id: Option<String>,
}

impl Reserved<'_> {
    fn handed(mut self) {
        self.execution_id = None;
    }
}

impl Drop for Reserved<'_> {
    fn drop(&mut self) {
        if let Some(execution_id) = &self.execution_id {
            self.tree.report(
                execution_id,
                Ended {
                    closed: false,
                    unclean: true,
                },
            );
        }
    }
}

/// What a subtree came to.
enum Settled {
    /// Every attempt ended with its close recorded, or was cancelled.
    Closed { unclean: bool },
    /// An attempt was left open: these attempts are.
    Open(Vec<String>),
}

/// The subtree a runner is running.
struct Running {
    execution_id: String,
    tree: Arc<Tree>,
}

/// What the runner has run.
#[derive(Default)]
struct Ran {
    /// The athanor of its first subtree.
    athanor_id: Option<String>,
    /// A subtree of it completed not clean.
    unclean: bool,
}

/// Serve subtrees from `lines` and `control` until the runner ends,
/// answering its exit status.
///
/// The loop and every attempt's watch (its budget, lease, stop and close)
/// run on the thread that awaits this, in a `LocalSet` of its own; each
/// attempt's component work is a task on the runtime's workers.
pub async fn serve<R>(
    environment: Environment,
    engine: Arc<Engine>,
    lines: Lines<R>,
    control: Writer,
    relay_at: Option<RelayAt>,
) -> u8
where
    R: tokio::io::AsyncRead + Unpin,
{
    tokio::task::LocalSet::new()
        .run_until(serving(environment, engine, lines, control, relay_at))
        .await
}

async fn serving<R>(
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
    let mut ran = Ran::default();
    let mut closed = false;
    let (finished_tx, mut finished) = mpsc::unbounded_channel::<Finished>();
    let (launch_tx, mut launches) = mpsc::unbounded_channel::<Launch>();
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
                    if ran.unclean {
                        eprintln!(
                            "cyfr-runner: assigned {} after a subtree completed not clean; ending",
                            assignment.execution_id
                        );
                        exit(&control, &environment, Vec::new()).await;
                        return 1;
                    }
                    if ran.athanor_id.as_ref().is_some_and(|athanor| *athanor != assignment.athanor_id) {
                        eprintln!(
                            "cyfr-runner: assigned {} for another athanor than its first subtree's; ending",
                            assignment.execution_id
                        );
                        exit(&control, &environment, Vec::new()).await;
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
                    ran.athanor_id = Some(assignment.athanor_id.clone());
                    let execution_id = assignment.execution_id.clone();
                    let tree = Tree::new(
                        &assignment.athanor_id,
                        &execution_id,
                        finished_tx.clone(),
                        launch_tx.clone(),
                    );
                    let stop = Stop::new();
                    tree.lock().entries.insert(
                        execution_id.clone(),
                        Entry::new(&assignment.attempt, stop.clone()),
                    );
                    let start = Start { token, assignment, input, keys, admitted: None };
                    let runner = attempt::Runner {
                        engine: engine.clone(),
                        relay: relay.clone(),
                        control: control.clone(),
                        runner_id: environment.runner_id.clone(),
                        boot: environment.boot.clone(),
                        tree: tree.clone(),
                    };
                    tree.launch(Launch { start, runner, stop, waiter: None });
                    running = Some(Running { execution_id, tree });
                }
                Received::Message(Message::CancelChild { execution_id }) => {
                    match &running {
                        Some(running) if running.execution_id == execution_id => {
                            eprintln!("cyfr-runner: cancel_child names the subtree's root {execution_id}; ignored");
                        }
                        Some(running) if running.tree.cancel(&execution_id) => {
                            eprintln!("cyfr-runner: cancelled the child {execution_id}");
                        }
                        _ => {
                            eprintln!("cyfr-runner: cancel_child names no child here ({execution_id}); ignored");
                        }
                    }
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
            Some(launch) = launches.recv() => {
                // A child of a subtree no longer running is no child of
                // this one: its subtree ended with it named open.
                let execution_id = &launch.start.assignment.execution_id;
                match &running {
                    Some(current) if current.tree.lock().entries.contains_key(execution_id) => {
                        current.tree.launch(launch);
                    }
                    _ => {}
                }
            }
            Some(Finished { execution_id, ended }) = finished.recv() => {
                let Some(current) = &running else { continue };
                // An end reported by a task of an earlier subtree, which
                // ended with it, is no attempt of this one.
                if !current.tree.lock().entries.contains_key(&execution_id) {
                    continue;
                }
                let (attempt, settled) = current.tree.ended(&execution_id, ended);
                // A child that ended leaves the relay once nothing of it is
                // outstanding; the root's attempt stays until the next bind.
                if execution_id != current.execution_id
                    && let Some(relay) = &relay
                {
                    relay.retire(&attempt);
                }
                match settled {
                    None => {}
                    Some(Settled::Open(open)) => {
                        exit(&control, &environment, open).await;
                        return 1;
                    }
                    Some(Settled::Closed { unclean }) => {
                        let Running { execution_id, tree } =
                            running.take().expect("a running subtree");
                        let (idle, carried) = match &relay {
                            Some(relay) => (relay.idle().await, relay.carried().await),
                            None => (true, 0),
                        };
                        eprintln!(
                            "cyfr-runner: {execution_id} completed, holding {} attempt records, \
                             its relay carrying {carried} attempts",
                            tree.held()
                        );
                        let clean = !unclean && idle;
                        ran.unclean |= !clean;
                        let complete = Message::Complete { execution_id, clean };
                        if control.send_flushed(&complete).await.is_err() {
                            return 1;
                        }
                        if closed {
                            return 0;
                        }
                    }
                }
            }
            () = async {
                match &relay {
                    Some(relay) => relay.closed().await,
                    None => std::future::pending().await,
                }
            } => {
                eprintln!("cyfr-runner: the relay is closed; ending");
                let open = running.take().map(|running| running.tree.end_now()).unwrap_or_default();
                exit(&control, &environment, open).await;
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
