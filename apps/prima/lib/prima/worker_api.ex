# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.WorkerAPI do
  @moduledoc """
  What CYFR asks of a worker service. A worker service implements this
  behaviour; CYFR is its client.

  A worker service runs no guest code: it starts runners (OS processes it
  talks to over `Prima.RunnerControl`), kills them and reports on them.
  Every request is addressed to one worker service and
  signed with that worker service's dispatch key
  (`Prima.WorkerAuth.request_header/3`); the worker service verifies it
  (`Prima.WorkerAuth.verify_request/4`), refuses a request addressed to
  another worker service and refuses a nonce it has already seen. It reports each runner's exit to CYFR itself
  (`c:Prima.HostAPI.runner_exited/3`).

  A request whose answer is lost is retried as `retry/1` says: `kill` and
  `status` again, `start` never — its assignment's claim window bounds it,
  and CYFR reconciles against the attempt's claim. `request_timeout_ms/1`
  bounds each wait.
  """

  @typedoc "What CYFR may do when a request's answer is lost (`Prima.HostAPI.retry/0`)."
  @type retry :: :idempotent | :never

  @retries %{start: :never, kill: :idempotent, status: :idempotent}
  @timeouts %{start: Prima.Assignment.claim_window_ms(), kill: 5_000, status: 5_000}

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
  the base URL of its listener (`Prima.WorkerWire`), with the name-level
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
  (`runner_states/0`); the attempts its runners have claimed; the memory
  bound, in bytes, every runner it starts runs under, `nil` when its
  keeper applies none; and its `refusal`, `nil` while its keeper starts
  runners. A runner is in exactly one state:

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
          attempts: [String.t()],
          memory_bytes: pos_integer() | nil,
          refusal: refusal() | nil
        }

  @typedoc """
  Why a worker service's keeper refuses to start runners, from the last
  runner it refused until one starts again: `reason`, a code of lowercase
  letters, digits and underscores (`memory_unavailable` where the keeper
  cannot bound a runner's memory), and `message`, a sentence for the
  operator naming what the deployment lacks. While it refuses, a `start`
  no fresh or idle runner can take is refused `unavailable` with the same
  sentence.
  """
  @type refusal :: %{reason: String.t(), message: String.t()}

  @runner_states [:fresh, :idle, :busy, :tainted]
  @status_members ~w(service boot runners attempts memory_bytes refusal)
  @refusal_members ~w(reason message)
  @reason ~r/\A[a-z][a-z0-9_]{0,63}\z/
  @max_message_bytes 1024
  # 2^53 − 1: the largest integer every JSON reader holds exactly.
  @max_integer 9_007_199_254_740_991

  @doc "The runner states a status counts, each runner in exactly one."
  @spec runner_states() :: [atom()]
  def runner_states, do: @runner_states

  @doc """
  Whether `status` has the shape of `t:status/0`: its six members and no
  other, a string service and boot, a count for every runner state and
  no other, a list of attempt id strings, a memory bound of 1 to 2^53 − 1
  bytes or `nil`, and a `t:refusal/0` whose message
  `valid_refusal_message?/1` accepts, or `nil`.
  """
  @spec valid_status?(term()) :: boolean()
  def valid_status?(
        %{
          service: service,
          boot: boot,
          runners: %{} = runners,
          attempts: attempts,
          memory_bytes: memory_bytes,
          refusal: refusal
        } = status
      )
      when map_size(status) == 6 and is_binary(service) and is_binary(boot) and
             is_list(attempts) and map_size(runners) == length(@runner_states) do
    Enum.all?(@runner_states, fn state ->
      match?(count when is_integer(count) and count >= 0, Map.get(runners, state))
    end) and Enum.all?(attempts, &is_binary/1) and bound?(memory_bytes) and
      refusal?(refusal)
  end

  def valid_status?(_status), do: false

  defp bound?(nil), do: true
  defp bound?(bytes), do: is_integer(bytes) and bytes > 0 and bytes <= @max_integer

  defp refusal?(nil), do: true

  defp refusal?(%{reason: reason, message: message} = refusal) when map_size(refusal) == 2,
    do: is_binary(reason) and Regex.match?(@reason, reason) and valid_refusal_message?(message)

  defp refusal?(_refusal), do: false

  @doc """
  Whether `message` is a sentence a `t:refusal/0` may carry: 1 to
  #{@max_message_bytes} bytes of UTF-8 without a control character, which
  an operator's terminal shows as it reads. A worker service's status
  carries no other, and CYFR reads no other as the sentence of a start the
  worker service refused (`c:start/3`).
  """
  @spec valid_refusal_message?(term()) :: boolean()
  def valid_refusal_message?(message) when is_binary(message) do
    byte_size(message) in 1..@max_message_bytes and String.valid?(message) and
      not String.match?(message, ~r/[\x00-\x1F\x7F]/)
  end

  def valid_refusal_message?(_message), do: false

  @doc """
  The status a JSON answer spells, as `status_to_wire/1` writes it, or
  `:error` for anything else: a member missing or extra at any level, or
  a value `valid_status?/1` refuses. `tests/fixtures/worker_auth.json`
  holds the vectors (`status`).
  """
  @spec read_status(term()) :: {:ok, status()} | :error
  def read_status(%{"runners" => %{} = runners, "refusal" => refusal} = wire) do
    with true <- Enum.sort(Map.keys(wire)) == Enum.sort(@status_members),
         {:ok, runners} <- read_runners(runners),
         {:ok, refusal} <- read_refusal(refusal) do
      status = %{
        service: wire["service"],
        boot: wire["boot"],
        runners: runners,
        attempts: wire["attempts"],
        memory_bytes: wire["memory_bytes"],
        refusal: refusal
      }

      if valid_status?(status), do: {:ok, status}, else: :error
    else
      _refused -> :error
    end
  end

  def read_status(_wire), do: :error

  defp read_runners(runners) do
    names = Map.new(@runner_states, &{Atom.to_string(&1), &1})

    if Enum.sort(Map.keys(runners)) == Enum.sort(Map.keys(names)),
      do: {:ok, Map.new(names, fn {name, state} -> {state, Map.fetch!(runners, name)} end)},
      else: :error
  end

  defp read_refusal(nil), do: {:ok, nil}

  defp read_refusal(%{} = refusal) do
    if Enum.sort(Map.keys(refusal)) == Enum.sort(@refusal_members),
      do: {:ok, %{reason: refusal["reason"], message: refusal["message"]}},
      else: :error
  end

  defp read_refusal(_refusal), do: :error

  @doc """
  `status` as its JSON answer spells it, every member a string, which
  `read_status/1` reads back; raises `ArgumentError` for a status
  `valid_status?/1` refuses, since it is the caller's own.
  """
  @spec status_to_wire(status()) :: %{String.t() => term()}
  def status_to_wire(status) do
    unless valid_status?(status), do: raise(ArgumentError, "not a status: #{inspect(status)}")

    %{
      "service" => status.service,
      "boot" => status.boot,
      "runners" => Map.new(@runner_states, &{Atom.to_string(&1), Map.fetch!(status.runners, &1)}),
      "attempts" => status.attempts,
      "memory_bytes" => status.memory_bytes,
      "refusal" => refusal_to_wire(status.refusal)
    }
  end

  defp refusal_to_wire(nil), do: nil

  defp refusal_to_wire(%{reason: reason, message: message}),
    do: %{"reason" => reason, "message" => message}

  @doc """
  Start an assignment on a runner. `input` is the execution's input bytes,
  bound by the assignment's `input_digest`, and `sealed_keys` are the
  attempt's keys sealed with the worker service's dispatch seal key
  (`Prima.WorkerAuth.seal_attempt_keys/3`). The runner attaches
  (`c:Prima.HostAPI.attach/2`) before it runs anything. `:malformed` means
  the assignment cannot be read or is addressed to another worker service
  or another boot of this one, the input does not match its digest or the
  keys do not open as its attempt on this worker service. `:unavailable`
  means no runner could be given the assignment: none could be started,
  and with a sentence when the worker service knows why (its keeper
  refuses runners, `t:refusal/0`). Its listener refuses an unavailable
  start `503`, naming the sentence when there is one. CYFR reads a `503`
  naming a refusal's sentence (`valid_refusal_message?/1`) as this
  refusal, a definite one: the worker service started nothing, and the
  run is closed failed with the sentence. A `503` without one is a lost
  answer, reconciled against the attempt's claim, since the listener
  answers one too when its call into the worker service timed out, after
  which the run may still start.
  """
  @callback start(Prima.Assignment.token(), input :: binary(), sealed_keys :: String.t()) ::
              :ok | {:error, :malformed | :unavailable | {:unavailable, String.t()}}

  @doc """
  Stop an execution a runner of this worker service runs. For a subtree
  root, the kill ends the runner: the worker service terminates the
  runner's process and reports its exit
  (`c:Prima.HostAPI.runner_exited/3`). For a child, the kill ends the
  child's process inside the runner (`Prima.RunnerControl`'s
  `cancel_child`), and the runner keeps running the rest of its subtree.
  Either kill taints the runner: it is never assigned again, and is
  terminated once its subtree completes if not before. The execution's
  durable cancel request remains the fence.

  A kill is idempotent: `:ok` again for an execution a runner of this
  boot already ended, whether by a kill or on its own. `:not_found` means
  no runner of this boot of the worker service holds or held it, however
  busy its runners are: the kill reached nothing, and CYFR counts it as
  nothing whose native work may still run. `:ok` means a runner holding
  it was told.
  """
  @callback kill(execution_id :: String.t()) :: :ok | {:error, :not_found}

  @doc "The worker service's state."
  @callback status() :: {:ok, status()}
end
