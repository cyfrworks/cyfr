# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Keeper do
  @moduledoc """
  How the worker service's runner pool starts, reaches and ends the OS
  processes its runners are, behind one behaviour with two
  implementations chosen by `config :opus, :keeper` (`Opus.Settings`):

    * `Opus.Keeper.Channel` — the client of `cyfr-keeper` (`apps/keeper`),
      the keeper the image starts the service under: each runner is
      spawned in the keeper's `runner` uid pool with an explicit
      environment, and its control channel (`Prima.RunnerControl`) is the
      socket on its file descriptor 3, relayed over the attach connection
      as stream 4. Refused where no channel was inherited.
    * `Opus.Keeper.Direct` — a launcher for a machine without a keeper (a
      development boot, the umbrella test environment): each runner is a
      plain child process of this VM with the same argv and explicit
      environment, no uid of its own, and its control channel on its
      standard input and output. Refused where a channel was inherited,
      so a misconfigured image never falls back to it.

  A `Opus.RunnerProcess` calls `c:spawn/1` in its own process and keeps
  the `t:channel/0` it answers; every message the keeper then sends that
  process is read with `c:handle_message/2`, which answers the events it
  carries (`t:event/0`): the runner's OS pid once spawned, the channel
  attached, control bytes as the runner wrote them (lines are the
  caller's to split), the runner's log output, the channel closed, the
  process exited, its uid or process group retired, the spawn refused
  (no process of it ever ran, as when `c:spawn/1` refuses), or a failure.
  `c:refusal/1` says what a refusal means for an operator. Control bytes go back with `c:send/2`;
  `c:release/2` ends the runner: a term signal, a grace to report what it
  holds, then the group kill. `c:memory_bytes/1` is the bound every
  runner runs under, nil for a keeper that applies none.

  The keeper's own process, one per pool (`c:child_spec/1`), holds the
  keeper channel and the attach listener (Channel) or watches the runners'
  owners and reaps a runner whose owner is gone (Direct); the pool
  starts it as a sibling and is restarted with it.
  """

  @typedoc "What a runner is started with: its id, its argv and the environment beside the keeper's own."
  @type spec :: %{runner: String.t(), argv: [String.t()], env: %{String.t() => String.t()}}

  @typedoc "A keeper's handle on one runner, kept by the process that spawned it."
  @type channel :: term()

  @typedoc "How a runner's process ended."
  @type exit :: {:status, integer()} | {:signal, String.t()}

  @typedoc "What the keeper reports about a runner."
  @type event ::
          {:spawned, non_neg_integer() | nil}
          | :attached
          | {:control, binary()}
          | {:log, binary()}
          | :control_closed
          | {:exited, exit()}
          | :released
          | {:refused, term()}
          | {:error, term()}

  @doc "The keeper's process for a pool, from the pool's options (`:attach_dir`, `:channel`, `:name`)."
  @callback child_spec(keyword()) :: Supervisor.child_spec()

  @doc "Whether this keeper may run in `env` (the process environment) with `opts` (the pool's keeper options)."
  @callback available(%{optional(String.t()) => String.t()}, keyword()) :: :ok | {:error, term()}

  @doc "Start a runner for `spec` from the calling process, answering its channel and the events already known."
  @callback spawn(spec()) :: {:ok, channel(), [event()]} | {:error, term()}

  @doc "The events `message` (received by the spawning process) carries for `channel`, or `:unknown`."
  @callback handle_message(channel(), term()) :: {:events, [event()], channel()} | :unknown

  @doc "Write `data` to the runner's control channel."
  @callback send(channel(), iodata()) :: :ok | {:error, term()}

  @doc "End the runner: a term signal, `grace_ms` to report, then the kill of everything it started."
  @callback release(channel(), non_neg_integer()) :: :ok

  @doc """
  The memory bound, in bytes, every runner this keeper starts with the
  pool's keeper options runs under, or nil when it applies none.
  """
  @callback memory_bytes(keyword()) :: pos_integer() | nil

  @doc """
  What `reason`, the reason a spawn was refused before any runner process
  started (`t:event/0`'s `{:refused, reason}`, or `c:spawn/1`'s error),
  means for an operator: a code and a sentence, as
  `t:Prima.WorkerAPI.refusal/0` spells them.
  """
  @callback refusal(term()) :: Prima.WorkerAPI.refusal()

  @doc "The keeper's own view of its runner pool, when it has one."
  @callback stats() ::
              {:ok,
               %{size: non_neg_integer(), free: non_neg_integer(), quarantined: non_neg_integer()}}
              | :unknown

  @doc "The module for the keeper `config :opus, :keeper` names."
  @spec module(:channel | :direct) :: module()
  def module(:channel), do: Opus.Keeper.Channel
  def module(:direct), do: Opus.Keeper.Direct

  @doc "`keeper.available/2` under the process environment, raising with the reason when it refuses."
  @spec check!(module(), keyword()) :: :ok
  def check!(keeper, opts) when is_atom(keeper) and is_list(opts) do
    case keeper.available(System.get_env(), opts) do
      :ok ->
        :ok

      {:error, reason} ->
        raise ArgumentError, "[Opus.Keeper] #{inspect(keeper)} cannot run here: #{reason}"
    end
  end
end
