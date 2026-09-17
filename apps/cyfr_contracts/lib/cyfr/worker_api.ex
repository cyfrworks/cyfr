# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.WorkerAPI do
  @moduledoc """
  What CYFR asks of a worker service. A worker service implements this
  behaviour; CYFR is its client.

  A worker service runs no guest code: it starts runners, kills them and
  reports on them. Every request is addressed to one worker service and
  signed with that worker service's dispatch key
  (`Cyfr.WorkerAuth.request_header/3`); the worker service verifies it
  (`Cyfr.WorkerAuth.verify_request/4`), refuses a request addressed to
  another worker service and refuses a nonce it has already seen. It reports each runner's exit to CYFR itself
  (`c:Cyfr.HostAPI.runner_exited/3`).

  A request whose answer is lost is retried as `retry/1` says: `kill` and
  `status` again, `start` never — its assignment's claim window bounds it,
  and CYFR reconciles against the attempt's claim. `request_timeout_ms/1`
  bounds each wait.
  """

  @typedoc "What CYFR may do when a request's answer is lost (`Cyfr.HostAPI.retry/0`)."
  @type retry :: :idempotent | :never

  @retries %{start: :never, kill: :idempotent, status: :idempotent}
  @timeouts %{start: Cyfr.Assignment.claim_window_ms(), kill: 5_000, status: 5_000}

  @doc "The callbacks, as `retry/1` and `request_timeout_ms/1` name them."
  @spec callbacks() :: [atom()]
  def callbacks, do: Map.keys(@retries)

  @doc "What CYFR may do when `callback`'s answer is lost."
  @spec retry(atom()) :: retry()
  def retry(callback) when is_map_key(@retries, callback), do: Map.fetch!(@retries, callback)

  @doc """
  How long CYFR waits for `callback`'s answer, in milliseconds: the
  assignment's claim window for `start`, five seconds for `kill` and
  `status`.
  """
  @spec request_timeout_ms(atom()) :: pos_integer()
  def request_timeout_ms(callback) when is_map_key(@timeouts, callback),
    do: Map.fetch!(@timeouts, callback)

  @typedoc """
  A worker service's state: its configured service id; its boot id, which
  changes on every start; its runners, by whether they are fresh, idle or
  busy; and the attempts its runners have claimed.
  """
  @type status :: %{
          service: String.t(),
          boot: String.t(),
          runners: %{
            fresh: non_neg_integer(),
            idle: non_neg_integer(),
            busy: non_neg_integer()
          },
          attempts: [String.t()]
        }

  @doc """
  Start an assignment on a runner. `input` is the execution's input bytes,
  bound by the assignment's `input_digest`, and `sealed_keys` are the
  attempt's keys sealed with the worker service's dispatch seal key
  (`Cyfr.WorkerAuth.seal_attempt_keys/3`). The runner attaches
  (`c:Cyfr.HostAPI.attach/2`) before it runs anything. `:malformed` means
  the assignment cannot be read or is addressed to another worker service
  or another boot of this one, the input does not match its digest or the
  keys do not open as its attempt on this worker service.
  """
  @callback start(Cyfr.Assignment.token(), input :: binary(), sealed_keys :: String.t()) ::
              :ok | {:error, :malformed}

  @doc """
  Stop an execution. For a subtree root, the worker service releases the
  runner; for a child, it sends the runner a cancel and taints it. The
  execution's durable cancel request remains the fence. `:not_found` means
  no runner of this worker service runs it.
  """
  @callback kill(execution_id :: String.t()) :: :ok | {:error, :not_found}

  @doc "The worker service's state."
  @callback status() :: {:ok, status()}
end
