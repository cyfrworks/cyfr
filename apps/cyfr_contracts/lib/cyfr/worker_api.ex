# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.WorkerAPI do
  @moduledoc """
  What CYFR asks of a worker service. A worker service implements this
  behaviour; CYFR is its client.

  A worker service runs no guest code: it starts runners (OS processes it
  talks to over `Cyfr.RunnerControl`), kills them and reports on them.
  Every request is addressed to one worker service and
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
  Where CYFR reaches one worker service: its configured service id and
  the base URL of its listener (`Cyfr.WorkerWire`), with the name-level
  component references it alone runs, or `nil` when it runs any. Every
  entry of CYFR's static worker list is one of these.
  """
  @type endpoint :: %{
          id: String.t(),
          url: String.t(),
          components: [String.t()] | nil
        }

  @typedoc """
  A worker service's state: its configured service id; its boot id, which
  changes on every start; its runners, counted by state
  (`runner_states/0`); and the attempts its runners have claimed. A
  runner is in exactly one state:

    * `fresh` — started and not yet assigned, so it belongs to no
      athanor;
    * `idle` — belongs to one athanor, whose subtrees it has run, and can
      take another assignment for that athanor only;
    * `busy` — running an assignment;
    * `tainted` — terminated or being terminated, after a kill or an
      unclean completion; it is never assigned again.
  """
  @type status :: %{
          service: String.t(),
          boot: String.t(),
          runners: %{
            fresh: non_neg_integer(),
            idle: non_neg_integer(),
            busy: non_neg_integer(),
            tainted: non_neg_integer()
          },
          attempts: [String.t()]
        }

  @runner_states [:fresh, :idle, :busy, :tainted]

  @doc "The runner states a status counts, each runner in exactly one."
  @spec runner_states() :: [atom()]
  def runner_states, do: @runner_states

  @doc """
  Whether `status` has the shape of `t:status/0`: its four members and no
  other, a string service and boot, a count for every runner state and
  no other, and a list of attempt id strings.
  """
  @spec valid_status?(term()) :: boolean()
  def valid_status?(
        %{service: service, boot: boot, runners: %{} = runners, attempts: attempts} = status
      )
      when map_size(status) == 4 and is_binary(service) and is_binary(boot) and
             is_list(attempts) and map_size(runners) == length(@runner_states) do
    Enum.all?(@runner_states, fn state ->
      match?(count when is_integer(count) and count >= 0, Map.get(runners, state))
    end) and Enum.all?(attempts, &is_binary/1)
  end

  def valid_status?(_status), do: false

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
  Stop an execution a runner of this worker service runs. For a subtree
  root, the kill ends the runner: the worker service terminates the
  runner's process and reports its exit
  (`c:Cyfr.HostAPI.runner_exited/3`). For a child, the kill ends the
  child's process inside the runner (`Cyfr.RunnerControl`'s
  `cancel_child`), and the runner keeps running the rest of its subtree.
  Either kill taints the runner: it is never assigned again, and is
  terminated once its subtree completes if not before. The execution's
  durable cancel request remains the fence.

  A kill is idempotent: `:ok` again for an execution a runner of this
  boot already ended, whether by a kill or on its own. `:not_found` means
  no runner of this boot of the worker service ever ran it.
  """
  @callback kill(execution_id :: String.t()) :: :ok | {:error, :not_found}

  @doc "The worker service's state."
  @callback status() :: {:ok, status()}
end
