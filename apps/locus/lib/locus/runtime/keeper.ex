# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.Keeper do
  @moduledoc """
  How the worker service's runner pool starts, reaches and ends the OS
  processes its runners are, behind one behaviour chosen by the
  `:keeper` of `config :locus, :runtime` (`Locus.Runtime.Settings`):

    * `:channel`, `Locus.Runtime.Keeper.Channel` — the adapter to
      `Locus.Keeper`, the node's one client of `cyfr-locus`
      (`apps/locus/keeper`), the keeper the image starts every role under:
      each runner is spawned in the
      keeper's `runner` uid pool with an explicit environment, and its
      control channel (`Prima.RunnerControl`) is the socket on its file
      descriptor 3, relayed over the attach connection as stream 4, and its
      relay (`Prima.RunnerRelay`) the socket on its file descriptor 4,
      relayed as stream 5, in a network namespace of its own with no other
      way out.
      Refused where no channel was inherited, which refuses the boot.
    * `:direct` — the test build's launcher for a machine without a keeper
      (`direct_keeper/0`), compiled from its test support alone: each
      runner is a plain child process of this VM, with no uid of its own,
      whose relay is a unix socket in its home.
      No other build compiles it, so no other build can name it.

  A `Locus.Runtime.RunnerProcess` calls `c:spawn/1` in its own process and keeps
  the `t:channel/0` it answers; every message the keeper then sends that
  process is read with `c:handle_message/2`, which answers the events it
  carries (`t:event/0`): the runner's OS pid once spawned, the channel
  attached, control bytes as the runner wrote them (lines are the
  caller's to split), relay bytes as the runner wrote them (frames are
  the caller's to split), the relay's end, the runner's log output, the
  channel closed, the
  process exited, its uid or process group retired, the spawn refused
  (no process of it ever ran, as when `c:spawn/1` refuses), or a failure.
  Both keepers spawn through a `Locus.Launcher` that tells a runner's
  owner its events in its own words (`t:Locus.Launcher.control_event/0`),
  and both read them through `event/1`.
  `c:refusal/1` says what a refusal means for an operator. Control bytes go back with `c:send/2`,
  relay bytes with `c:send_relay/2`, callable from any process once the
  runner attached, and `c:close_relay/1` ends the relay;
  `c:release/2` ends the runner: a term signal, a grace to report what it
  holds, then the group kill. `c:memory_bytes/1` is the bound every
  runner runs under, nil for a keeper that applies none.

  The keeper's own process, one per pool (`c:child_spec/1`), holds what
  its runners share: the client they spawn through and their bound
  (Channel), or the janitor that ends every runner it started when the
  pool goes down (`:direct`); the pool starts it as a sibling and is
  restarted with it.
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
          | {:relay, binary()}
          | :relay_closed
          | {:log, binary()}
          | :control_closed
          | {:exited, exit()}
          | :released
          | {:refused, term()}
          | {:error, term()}

  @doc """
  The keeper's process for a pool, from the pool's options: the adapter's
  `:client`, `:memory_bytes` and `:name` (Channel), the janitor's `:name`
  (`:direct`).
  """
  @callback child_spec(keyword()) :: Supervisor.child_spec()

  @doc """
  Whether this keeper may run where `inherited?` says whether cyfr-locus's
  channel was inherited (`Locus.Keeper.channel_inherited?/0`), with `opts`
  (the pool's keeper options).
  """
  @callback available(inherited? :: boolean(), keyword()) :: :ok | {:error, term()}

  @doc "Start a runner for `spec` from the calling process, answering its channel and the events already known."
  @callback spawn(spec()) :: {:ok, channel(), [event()]} | {:error, term()}

  @doc "The events `message` (received by the spawning process) carries for `channel`, or `:unknown`."
  @callback handle_message(channel(), term()) :: {:events, [event()], channel()} | :unknown

  @doc "Write `data` to the runner's control channel."
  @callback send(channel(), iodata()) :: :ok | {:error, term()}

  @doc "Write `data` to the runner's relay, from any process, once the runner attached."
  @callback send_relay(channel(), iodata()) :: :ok | {:error, term()}

  @doc "End the runner's relay: nothing more is written to it."
  @callback close_relay(channel()) :: :ok

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

  @doc """
  The test build's launcher of runners as plain child processes, or `nil`.

  It isolates and bounds nothing, so it is named by the test
  configuration alone (the `:direct_keeper` of `config :locus, :runtime`
  in `config/test.exs` and `apps/locus/config/config.exs`) and compiled
  from its test support: every other build compiles no such module, so a
  name that reaches this key from anywhere else resolves to nothing.
  """
  @spec direct_keeper() :: module() | nil
  def direct_keeper do
    case Keyword.get(Locus.Runtime.Settings.env(), :direct_keeper) do
      keeper when is_atom(keeper) and not is_nil(keeper) ->
        if Code.ensure_loaded?(keeper), do: keeper

      _ ->
        nil
    end
  end

  @doc """
  The module for the keeper the `:keeper` of `config :locus, :runtime` names: `:channel` in
  every build, `:direct` only where `direct_keeper/0` has one.
  """
  @spec module(:channel | :direct) :: module()
  def module(:channel), do: Locus.Runtime.Keeper.Channel

  def module(:direct) do
    direct_keeper() ||
      raise ArgumentError,
            "[Locus.Runtime.Keeper] this build has no direct keeper: runners start only through cyfr-locus"
  end

  @doc """
  The runtime's event for `event`, an event a runner's launcher told its
  owner (`t:Locus.Launcher.control_event/0`): the OS pid once spawned, a
  refusal at the memory bound as `:memory_unavailable` and any other as
  its code, stdout and stderr as the runner's log, an exit without its
  memory report (the keeper logs an end at the bound itself), and every
  other event as it is.
  """
  @spec event(Locus.Launcher.control_event()) :: event()
  def event({:spawned, _spawn_id, _uid, pid}), do: {:spawned, pid}
  def event({:refused, "memory_unavailable"}), do: {:refused, :memory_unavailable}
  def event({:refused, code}), do: {:refused, code}
  def event({:stdout, bytes}), do: {:log, bytes}
  def event({:stderr, bytes}), do: {:log, bytes}
  def event({:exited, exit, _memory_exceeded}), do: {:exited, exit}
  def event(:attached), do: :attached
  def event({:control, bytes}), do: {:control, bytes}
  def event(:control_closed), do: :control_closed
  def event({:relay, bytes}), do: {:relay, bytes}
  def event(:relay_closed), do: :relay_closed
  def event({:error, reason}), do: {:error, reason}
  def event(:released), do: :released

  @doc """
  `keeper.available/2` where `inherited?` says whether cyfr-locus's
  channel was inherited (`Locus.Keeper.channel_inherited?/0` by default),
  raising with the reason when it refuses. The refusal of the channel
  keeper names `cyfr-locus`, the one process that can start the service
  with the channel it needs.
  """
  @spec check!(module(), keyword(), boolean()) :: :ok
  def check!(keeper, opts, inherited? \\ Locus.Keeper.channel_inherited?())
      when is_atom(keeper) and is_list(opts) and is_boolean(inherited?) do
    case keeper.available(inherited?, opts) do
      :ok ->
        :ok

      {:error, reason} ->
        raise ArgumentError,
              "[Locus.Runtime.Keeper] #{inspect(keeper)} cannot run here: #{reason}" <>
                remedy(keeper)
    end
  end

  defp remedy(Locus.Runtime.Keeper.Channel) do
    ". The worker service starts its runners only through cyfr-locus, which " <>
      "starts it with the keeper channel on fd 3 (#{Locus.Keeper.channel_env()}): start " <>
      "the release through `cyfr-locus serve --pool runner:… -- /app/bin/locus start` " <>
      "(the locus-runtime service's entrypoint)."
  end

  defp remedy(_keeper), do: ""
end
