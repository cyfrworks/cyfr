# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Keeper do
  @moduledoc """
  How the worker service's runner pool starts, reaches and ends the OS
  processes its runners are, behind one behaviour chosen by
  `config :opus, :keeper` (`Opus.Settings`):

    * `:channel`, `Opus.Keeper.Channel` — the client of `cyfr-keeper`
      (`apps/keeper`), the keeper the image starts the service under and
      the one keeper every build runs: each runner is spawned in the
      keeper's `runner` uid pool with an explicit environment, and its
      control channel (`Prima.RunnerControl`) is the socket on its file
      descriptor 3, relayed over the attach connection as stream 4.
      Refused where no channel was inherited, which refuses the boot.
    * `:direct` — the test build's launcher for a machine without a keeper
      (`direct_keeper/0`), compiled from its test support alone: each
      runner is a plain child process of this VM, with no uid of its own.
      No other build compiles it, so no other build can name it.

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
  owners and reaps a runner whose owner is gone (`:direct`); the pool
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

  @doc """
  The test build's launcher of runners as plain child processes, or `nil`.

  It isolates and bounds nothing, so it is named by the application
  environment of the test build alone (`apps/opus/mix.exs`,
  `:direct_keeper`) and compiled from its test support: every other build
  compiles no such module, so a name that reaches this key from anywhere
  else resolves to nothing.
  """
  @spec direct_keeper() :: module() | nil
  def direct_keeper do
    case Application.get_env(:opus, :direct_keeper) do
      keeper when is_atom(keeper) and not is_nil(keeper) ->
        if Code.ensure_loaded?(keeper), do: keeper

      _ ->
        nil
    end
  end

  @doc """
  The module for the keeper `config :opus, :keeper` names: `:channel` in
  every build, `:direct` only where `direct_keeper/0` has one.
  """
  @spec module(:channel | :direct) :: module()
  def module(:channel), do: Opus.Keeper.Channel

  def module(:direct) do
    direct_keeper() ||
      raise ArgumentError,
            "[Opus.Keeper] this build has no direct keeper: runners start only through cyfr-keeper"
  end

  @doc """
  `keeper.available/2` under `env` (the process environment by default),
  raising with the reason when it refuses. The refusal of the channel
  keeper names `cyfr-keeper`, the one process that can start the service
  with the channel it needs.
  """
  @spec check!(module(), keyword(), %{optional(String.t()) => String.t()}) :: :ok
  def check!(keeper, opts, env \\ System.get_env())
      when is_atom(keeper) and is_list(opts) and is_map(env) do
    case keeper.available(env, opts) do
      :ok ->
        :ok

      {:error, reason} ->
        raise ArgumentError,
              "[Opus.Keeper] #{inspect(keeper)} cannot run here: #{reason}" <> remedy(keeper)
    end
  end

  defp remedy(Opus.Keeper.Channel) do
    ". The worker service starts its runners only through cyfr-keeper, which " <>
      "starts it with the keeper channel on fd 3 (#{Opus.Settings.channel_env()}): start " <>
      "the release through `cyfr-keeper serve --pool runner:… -- /app/bin/opus start` " <>
      "(the image's entrypoint)."
  end

  defp remedy(_keeper), do: ""
end
