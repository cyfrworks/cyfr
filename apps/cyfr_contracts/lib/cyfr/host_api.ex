# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.HostAPI do
  @moduledoc """
  What a runner asks of CYFR while it runs execution attempts, and what a
  worker service reports to CYFR. CYFR implements this behaviour; runners
  and worker services are its clients.

  ## A runner's calls

  Every callback but `c:runner_exited/2` answers a runner, for one attempt
  it runs. The call is signed with that attempt's call key
  (`Cyfr.WorkerAuth.host_call_header/3`), and its body and answer are
  sealed with the attempt's seal key (`Cyfr.WorkerAuth.seal_call/5`).
  Before a callback runs, CYFR verifies the header
  (`Cyfr.WorkerAuth.verify_host_call/5`), refuses a nonce already seen for
  the attempt on a call that is not idempotent, and, for every call but
  `c:attach/2`, checks that the attempt row is current, running, at the
  header's fence, on the header's boot and claimed by the header's runner.
  A call that fails any of those checks is answered `:lost`, and the
  runner stops the attempt's work.

  A callback receives the verified header as its `t:caller/0`. The tenant,
  execution, attempt and runner a call acts for come from the caller, never
  from its body.

  ## The worker service's report

  `c:runner_exited/2` answers a worker service. The report is signed with
  that worker service's own dispatch key (`Cyfr.WorkerAuth.report_header/3`)
  and verified with `Cyfr.WorkerAuth.verify_report/4`, so it speaks only
  for the runners of the worker service it names.
  """

  alias Cyfr.Assignment
  alias Cyfr.Delta
  alias Cyfr.Execution.Outcome
  alias Cyfr.WorkerAuth

  @typedoc "A call's verified header: the attempt it is made for and the runner presenting it."
  @type caller :: WorkerAuth.host_call()

  @typedoc """
  A refusal every runner call may answer. `:lost`: the attempt is not
  current, running, at the caller's fence and claimed by the caller's
  runner, and the runner stops its work. `:unavailable`: CYFR's store could
  not answer; the runner may retry, and keeps working only while the lease
  it last held still holds.
  """
  @type refusal :: :lost | :unavailable

  @typedoc """
  A refusal the runner hands its guest: the type and message of the WIT
  error envelope (`Cyfr.WitResponse.encode_error/2`), and for a
  `setup_required` refusal its remediation (`Cyfr.Remediation`).
  """
  @type guest_error ::
          {:guest_error, type :: String.t(), message :: String.t()}
          | {:guest_error, type :: String.t(), message :: String.t(), remediation :: map()}

  @typedoc "Vault field values by field name."
  @type secrets :: %{optional(String.t()) => String.t()}

  @typedoc "One attempt's lease renewal: its new expiry in Unix ms, a cancel asked of it, or its loss."
  @type renewal :: {:ok, lease_until :: non_neg_integer()} | :cancel | :lost

  @typedoc """
  An admitted child: its assignment, already claimed for the calling
  runner, its attempt's keys (sealed with the calling attempt's seal key on
  the wire, `Cyfr.WorkerAuth.seal_attempt_keys/3`), the input it was
  admitted with (its JSON on the wire, which the assignment's
  `input_digest` binds) and its secrets.
  """
  @type child :: %{
          assignment: Assignment.token(),
          attempt_keys: WorkerAuth.attempt_keys(),
          input: map(),
          secrets: secrets()
        }

  @type storage_op :: :read | :write | :append | :list | :delete | :exists

  @doc """
  Claim an assignment for the caller's runner, answering the secrets its
  consented vault edge projects (an empty map when the edge grants none).

  CYFR verifies the token (`Cyfr.Assignment.verify/3`), checks that it names
  the caller's attempt and generation and is addressed to the caller's
  worker service, and claims the attempt row: running, at the assignment's
  fence and unclaimed. An attach from the runner that
  already holds the claim answers as the first did; one from any other
  runner is `:replayed`. A vault edge that cannot produce its material is
  `{:setup_required, payload}`. On success CYFR keeps the verified
  assignment, its authority and the attempt's masking set until the
  attempt's terminal write.
  """
  @callback attach(caller(), Assignment.token()) ::
              {:ok, secrets()}
              | {:error, refusal() | Assignment.refusal() | :replayed | {:setup_required, map()}}

  @doc """
  Renew the leases of attempts the caller's runner holds (its own attempt
  and the children it runs), answering each attempt's renewal by attempt
  id. An attempt the runner does not hold is `:lost`.
  """
  @callback renew(caller(), attempts :: [String.t()]) ::
              {:ok, %{optional(String.t()) => renewal()}} | {:error, refusal()}

  @doc """
  Close the caller's attempt as completed. CYFR waits for the attempt's
  in-flight `c:push_deltas/2`, releases the deltas it holds back, masks the
  output, checks it against the node's response size, stages it and writes
  the terminal row. Answers the output as recorded, masked, which is what
  the runner hands onward (to a parent guest), or `{:failed, message}` when
  CYFR closed the attempt as failed instead: the output was too large or
  could not be retained.
  """
  @callback complete(caller(), Outcome.t()) ::
              {:ok, output :: term()} | {:error, refusal() | {:failed, String.t()}}

  @doc """
  Close the caller's attempt as failed with the outcome's error. CYFR waits
  for the attempt's in-flight `c:push_deltas/2` and releases the deltas it
  holds back, then writes the terminal row and fails the attempt's
  children. Answers the failure as recorded, masked, which is what the
  runner hands onward (to a parent guest).
  """
  @callback fail(caller(), Outcome.t()) :: {:ok, message :: String.t()} | {:error, refusal()}

  @doc """
  Deliver the caller's guest events, in the order they were emitted. A
  runner keeps one `push_deltas` in flight per attempt and batches the
  events that arrive meanwhile. Answers one reply per delta, in order: the
  JSON the guest's `emit` returns, naming the sequence CYFR assigned the
  last event that delta released, acknowledging an event held back whole,
  or refusing it.
  """
  @callback push_deltas(caller(), [Delta.t()]) :: {:ok, [String.t()]} | {:error, refusal()}

  @doc """
  Dispense an OAuth access token for `provider` from the caller's consented
  vault edge, charged to its `oauth:` rate. CYFR adds the token to the
  attempt's masking set.
  """
  @callback oauth_token(caller(), provider :: String.t()) ::
              {:ok, String.t()} | {:error, refusal() | guest_error()}

  @doc """
  Take one request from the caller's consented rate for `bucket` (such as
  `http:<component ref>`), before the runner makes the request it limits.
  """
  @callback take_rate(caller(), bucket :: String.t()) ::
              :ok | {:error, refusal() | guest_error()}

  @doc "The bytes of the component artifact with `digest`, for a runner whose cache lacks it."
  @callback fetch_artifact(caller(), digest :: String.t()) ::
              {:ok, binary()} | {:error, refusal() | :not_found}

  @doc """
  Run the caller's guest storage operation in the caller's athanor: `args`
  are the guest request's members other than `action`. CYFR checks the
  path, the consented storage scope and the athanor's usage. Answers the
  success response's members.
  """
  @callback storage(caller(), storage_op(), args :: map()) ::
              {:ok, map()} | {:error, refusal() | guest_error()}

  @doc """
  Admit a child the caller's guest starts with `guest_fn` on `ref`, through
  the edge named `need`, with `input`. CYFR steps the authority it holds
  for the caller's attempt, checks the delegation roster its admitted input
  carries, charges the root budget for a spawn, applies limits, rates,
  policy and attestation, writes the child's row under the caller's
  attempt, claims the child for the caller's runner and unseals its
  secrets. The child runs in the caller's runner, which closes its attempt;
  what the child holds goes back at its terminal write. The caller's
  attempt must be live: no cancel asked of it and its execution running.
  """
  @callback admit_child(
              caller(),
              ref :: String.t(),
              need :: String.t() | nil,
              input :: map(),
              guest_fn :: :call | :spawn
            ) :: {:ok, child()} | {:error, refusal() | guest_error()}

  @doc """
  Run the catalog tool `name` with `args` for the caller's guest, which
  made it with `guest_fn`, on the in-chain plane under the authority CYFR
  holds for the caller's attempt, with the caller's execution and attempt
  as its lineage. The caller's attempt must be live: no cancel asked of it
  and its execution running.
  """
  @callback tool_call(caller(), name :: String.t(), args :: map(), guest_fn :: :call | :spawn) ::
              {:ok, term()} | {:error, refusal() | guest_error()}

  @doc "Record a denial the runner's own egress checks made for the caller's component."
  @callback record_denial(caller(), attrs :: map()) :: :ok | {:error, refusal()}

  @doc """
  Report that the runner `runner` of the reporting worker service exited,
  with the attempts it was started with and had not closed. CYFR lapses
  each of them that was dispatched to the reporting service and boot, is
  claimed by that runner and is still running, and stops what it holds
  for each. A report speaks for its own boot only: another boot of the
  same service lapses nothing.
  """
  @callback runner_exited(
              report :: WorkerAuth.dispatch(),
              runner :: String.t(),
              attempts :: [String.t()]
            ) ::
              :ok | {:error, :unavailable}
end
