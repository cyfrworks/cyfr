# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Platform.Settings do
  @moduledoc """
  The platform settings as the host runs them: installed and applied at
  boot, listed, set and reset, and one settings process per member that
  hears every committed change.

  `Cyfr.Platform.Settings.Roster` declares the settings and
  `Arca.PlatformSettings` stores them and answers `effective/1`. This
  module is what joins the two, and it validates every value it writes
  with the roster's validator: Arca never sees one.

  ## Boot

  Three steps, in `Cyfr.Application.start/2`, before the supervision tree
  is built and so before any consumer reads a setting, whether or not the
  boot migrated:

    1. `install!/0` hands the roster's defaults and stale policies to
       Arca, so `effective/1` answers.
    2. `check_pins!/0` refuses the boot when this member's environment
       pins a key to one value and a live member's recorded pin holds
       another, naming the key and both members. A pinned value changes
       cell-wide by stopping every member that holds the old pin before
       the first one starts with the new.
    3. `apply/0` reads the store once (an unreadable store refuses the
       boot) and applies each restart-scoped row and the log level's row
       through the entry's apply function. What it applied, or the value
       this member was configured with, is the setting's **active** value
       until the next boot; `list/0` alone shows the desired one.

  A member's pins are recorded under its `(node, generation)` by the
  claim that wins its slot (`claimed/1`, called by `Cyfr.Cell`), which
  also retires the pins of the slot's earlier generations and of every
  member whose slot is no longer held. Once the member holds its slot,
  its settings process writes each pinned value to the store as the
  deployment's row, so every member, pinned or not, reads the pinned
  value through `effective/1`, and removes a deployment's row that no
  live pin holds any longer.

  ## Writes

  `set/4` and `reset/3` are compare-and-set on the store revision
  (`Arca.PlatformSettings.put/4`, `delete/2`): two operators on two
  members serialize through that row, the second refused `:stale`, and a
  write carrying a revision read before another write is refused the
  same way. A key a deployment pins is refused `:pinned`. A committed
  write is announced on `Cyfr.Bus.settings_changed/0`; a store that
  cannot write refuses and leaves the running value as it was.

  ## The settings process

  One per member, started after the bus and before every consumer. It
  drops a key's cached value on every change it hears, and applies the
  log level, the one live apply, in store-revision order: a change older
  than the one it last applied is never applied over it, whether it
  arrives late or out of order. Where a claimant runs it also asks the
  store every `Arca.PlatformSettings.ttl_ms/0`, so a member that missed a
  message converges within that bound, and publishes the revision it has
  observed, which `list/0` reports per member.

  ## A headless node

  `reset/3` and `set/4` are public functions, so an operator without the
  console reaches them on a running node through the release's remote
  shell:

      bin/cyfr rpc 'Cyfr.Platform.Settings.reset(Sanctum.system_context(), "log_level")'

  With no node running, the same call works under `bin/cyfr eval` once
  the store's application is started (`Application.ensure_all_started(:arca)`);
  nothing is announced there, and the next boot reads the store.
  """

  use GenServer

  require Logger

  alias Arca.PlatformSettings, as: Store
  alias Cyfr.Bus.SettingsChanged
  alias Cyfr.Platform.Settings.Roster
  alias Cyfr.Platform.Settings.Roster.Entry

  # The writer a deployment's pinned value is stored under.
  @deployment "deployment"

  # What `apply/0` left behind: each applied key's active value, the store
  # revision it read, and whether the level it runs at came from a row.
  @active {__MODULE__, :active}
  @boot_revision {__MODULE__, :boot_revision}
  @level_from_row {__MODULE__, :level_from_row}

  # A boot-time write that loses its compare-and-set reads the revision
  # again; past this many rounds the store is too busy to settle a pin.
  @write_rounds 3

  @typedoc "Why a write is refused."
  @type refusal ::
          :unknown_key
          | :pinned
          | :stale
          | :unavailable
          | {:invalid, String.t(), String.t()}

  @typedoc "One member's environment pin, as `Arca.PlatformSettings.pins/0` answers it."
  @type pin :: Store.pin()

  @typedoc "A live member's slot as `Arca.ControlPlane.roster/0` answers it, or any map naming both."
  @type slot_row :: %{
          required(:node) => String.t(),
          required(:generation) => pos_integer(),
          optional(atom()) => term()
        }

  @typedoc "One rostered setting as `list/0` describes it."
  @type setting :: %{
          key: String.t(),
          group: String.t(),
          scope: String.t(),
          stale: String.t(),
          variable: String.t() | nil,
          value: Store.value(),
          default: Store.value(),
          desired: Store.value(),
          source: String.t(),
          pending: boolean(),
          revision: non_neg_integer() | nil,
          set_by: String.t() | nil,
          set_at: DateTime.t() | nil,
          pins: [%{member: String.t(), value: Store.value()}],
          divergent: boolean(),
          inherit: boolean()
        }

  @typedoc "What `list/0` answers."
  @type listing :: %{
          revision: non_neg_integer(),
          ttl_ms: pos_integer(),
          members: [%{member: String.t(), revision: non_neg_integer() | nil}],
          settings: [setting()]
        }

  # ---------------------------------------------------------------------------
  # Boot
  # ---------------------------------------------------------------------------

  @doc "Install the roster's defaults and stale policies into Arca, plain values."
  @spec install!() :: :ok
  def install!, do: Store.install_defaults!(Roster.defaults())

  @doc """
  Refuse the boot when this member's environment pins a key to a value
  other than the one a live member recorded for it, naming the key and
  both members. A pin on one member and none on another is a divergence
  `list/0` shows, not a refusal. Without a claimant there is no cell and
  nothing to check.
  """
  @spec check_pins!() :: :ok
  def check_pins! do
    mine = pinned()

    with true <- mine != [] and Arca.ControlPlane.claimed?(),
         {:ok, live} <- live_pins(),
         [_ | _] = found <- conflicts(mine, node_name(), live) do
      raise pin_refusal(found)
    else
      {:error, :unavailable} ->
        raise "[Cyfr] FATAL: the platform settings' pins could not be read, so this " <>
                "member cannot tell whether its environment agrees with the cell's."

      _nothing_to_refuse ->
        :ok
    end
  end

  @doc """
  Each of `mine` (this member's pins, `{key, value}`) that a live pin of
  another member holds at a different value: `{key, value, member,
  their_value}`. `me` is this member's node, whose own earlier pins are
  never a conflict.
  """
  @spec conflicts([{String.t(), Store.value()}], String.t(), [pin()]) ::
          [{String.t(), Store.value(), String.t(), Store.value()}]
  def conflicts(mine, me, live) when is_list(mine) and is_binary(me) and is_list(live) do
    for {key, value} <- mine,
        %{key: ^key, member: member, value: theirs} <- live,
        member != me,
        theirs != value,
        do: {key, value, member, theirs}
  end

  @doc """
  The pins in `pins` recorded by the boot that holds its slot now: the
  member's slot is live in `members` (`Arca.ControlPlane.roster/0`) at the
  generation the pin was recorded under.
  """
  @spec live([pin()], [slot_row()]) :: [pin()]
  def live(pins, members) when is_list(pins) and is_list(members) do
    held = Map.new(members, &{&1.node, &1.generation})
    Enum.filter(pins, &(Map.get(held, &1.member) == &1.generation))
  end

  defp pin_refusal(found) do
    lines =
      Enum.map_join(found, "\n", fn {key, value, member, theirs} ->
        variable = variable(key)

        "  * #{variable} pins #{key} to #{inspect(value)} on this member " <>
          "(#{node_name()}) and to #{inspect(theirs)} on the live member #{member}."
      end)

    "[Cyfr] FATAL: this member's environment disagrees with a live member's on a " <>
      "pinned setting.\n\n" <>
      lines <>
      "\n\nA pinned value changes cell-wide by stopping every member that holds the " <>
      "old pin before starting the first one with the new."
  end

  @doc """
  Apply the stored value of every restart-scoped setting and of the log
  level through its entry's apply function, once, before any consumer
  starts. A key this member's environment pins keeps the pinned value; a
  key with no row keeps the value this member was configured with; a row
  whose value the roster's validator refuses is logged and left
  unapplied. Raises when the store cannot be read.
  """
  @spec apply() :: :ok
  def apply do
    snapshot =
      case Store.all() do
        {:ok, snapshot} ->
          snapshot

        {:error, _reason} ->
          raise "[Cyfr] FATAL: the platform settings could not be read. The table is " <>
                  "created by the schema; check that the database answers and is migrated."
      end

    rows = Map.new(snapshot.settings, &{&1.key, &1})
    pinned = Map.new(Roster.pinned())

    decided =
      for %Entry{apply: {_, _, 1}} = entry <- Roster.entries(),
          do: {entry, boot_value(entry, rows, pinned)}

    decided
    |> Enum.flat_map(fn
      {entry, {:row, value}} -> [{entry.apply, {entry.key, value}}]
      _kept -> []
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.each(fn {{module, function, 1}, values} ->
      Kernel.apply(module, function, [Map.new(values)])
    end)

    active =
      Map.new(decided, fn
        {entry, {:row, value}} -> {entry.key, value}
        {entry, {:pinned, value}} -> {entry.key, value}
        {entry, :configured} -> {entry.key, configured(entry)}
      end)

    level_from_row? = Enum.any?(decided, &match?({%Entry{key: "log_level"}, {:row, _}}, &1))

    :persistent_term.put(@active, active)
    :persistent_term.put(@boot_revision, snapshot.revision)
    :persistent_term.put(@level_from_row, level_from_row?)
    :ok
  end

  defp boot_value(%Entry{key: key} = entry, rows, pinned) do
    cond do
      Map.has_key?(pinned, key) ->
        {:pinned, Map.fetch!(pinned, key)}

      Map.has_key?(rows, key) ->
        case entry.validator.(rows[key].value) do
          {:ok, value} ->
            {:row, value}

          {:error, form} ->
            Logger.error(
              "[Cyfr.Platform.Settings] the stored #{key} #{form}; " <>
                "keeping the configured value"
            )

            :configured
        end

      true ->
        :configured
    end
  end

  # The value this member runs a key at without a row: where the reader
  # takes it today, else the roster's default.
  defp configured(%Entry{key: "log_level"}), do: Logger.level()

  defp configured(%Entry{app: app, config: [name], default: default}),
    do: Application.get_env(app, name, default)

  defp configured(%Entry{app: app, config: [name, sub], default: default}),
    do: app |> Application.get_env(name, []) |> Keyword.get(sub, default)

  defp configured(%Entry{default: default}), do: default

  @doc """
  The apply of the two execution-slot caps (`values`, key to validated
  value): written where the slots read them at boot, before the
  execution subtree starts.
  """
  @spec apply_execution_slots(%{String.t() => pos_integer()}) :: :ok
  def apply_execution_slots(values) when is_map(values) do
    for {key, value} <- values do
      {:ok, %Entry{app: app, config: [name]}} = Roster.fetch(key)
      Application.put_env(app, name, value)
    end

    :ok
  end

  @doc "The log level's apply (`values` holds `\"log_level\"`, a validated level)."
  @spec apply_log_level(%{String.t() => Logger.level()}) :: :ok
  def apply_log_level(%{"log_level" => level}) when is_atom(level) do
    Logger.configure(level: level)
  end

  # ---------------------------------------------------------------------------
  # The claim's pins
  # ---------------------------------------------------------------------------

  @doc """
  The claim step `Cyfr.Cell` runs each time it wins `slot`: retire the
  pins the slot's earlier generations recorded and those of every member
  whose slot is no longer held, then record this member's environment
  pins under `(node, generation)`.
  """
  @spec claimed(Arca.ControlPlane.slot()) :: :ok | {:error, :unavailable}
  def claimed(%{node: node, generation: generation})
      when is_binary(node) and is_integer(generation) and generation > 0 do
    with {:ok, _retired} <- Store.retire_pins(node, generation - 1),
         {:ok, pins} <- Store.pins(),
         {:ok, members} <- Arca.ControlPlane.roster(),
         :ok <- retire_stale(pins, members, node),
         :ok <- record_pins(node, generation) do
      :ok
    else
      _unavailable -> {:error, :unavailable}
    end
  end

  defp retire_stale(pins, members, me) do
    live = live(pins, members)

    pins
    |> Enum.reject(&(&1.member == me or &1 in live))
    |> Enum.uniq_by(&{&1.member, &1.generation})
    |> Enum.reduce_while(:ok, fn pin, :ok ->
      case Store.retire_pins(pin.member, pin.generation) do
        {:ok, _count} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp record_pins(node, generation) do
    Enum.reduce_while(Roster.pinned(), :ok, fn {key, value}, :ok ->
      case Store.record_pin(key, node, generation, value) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # List, set and reset
  # ---------------------------------------------------------------------------

  @doc """
  Every rostered setting: its active `value` on this member (for a
  restart-scoped key, the one applied at this member's boot), `default`,
  `desired` (what the store and the pins ask for), `source`
  (`deployment | operator | default`), `pending` (a restart-scoped key
  whose desired value differs from its active one), the row's revision,
  writer and time, the live members' pins and whether they diverge (a pin
  on some members and not on others). With them, the desired store
  revision, the cache's bound and, per member, the revision it last
  observed (`nil` when it has not said).
  """
  @spec list() :: {:ok, listing()} | {:error, :unavailable}
  def list do
    with {:ok, %{revision: revision, settings: rows}} <- Store.all(),
         {:ok, live} <- live_pins() do
      me = node_name()
      rows = Map.new(rows, &{&1.key, &1})
      mine = Map.new(pinned())
      active = :persistent_term.get(@active, %{})
      members = members(me)
      names = Enum.map(members, & &1.member)

      settings =
        for entry <- Roster.entries(),
            do: describe(entry, rows, mine, live, active, me, names)

      {:ok, %{revision: revision, ttl_ms: Store.ttl_ms(), members: members, settings: settings}}
    else
      _unavailable -> {:error, :unavailable}
    end
  end

  defp describe(%Entry{key: key} = entry, rows, mine, live, active, me, names) do
    row = Map.get(rows, key)
    pins = pins_of(key, mine, live, me)
    desired = desired(entry, row, mine)
    value = active_value(entry, active, desired)
    pinned_members = MapSet.new(pins, &elem(&1, 0))

    %{
      key: key,
      group: Atom.to_string(entry.group),
      scope: Atom.to_string(entry.scope),
      stale: Atom.to_string(entry.stale),
      variable: entry.variable,
      value: value,
      default: plain(entry.default),
      desired: desired,
      source: source(pins, row),
      pending: entry.scope == :restart and value != desired,
      revision: row && row.revision,
      set_by: row && row.set_by,
      set_at: row && row.set_at,
      pins: Enum.map(pins, fn {member, pinned} -> %{member: member, value: pinned} end),
      divergent: pins != [] and Enum.any?(names, &(not MapSet.member?(pinned_members, &1))),
      inherit: entry.inherit
    }
  end

  # This member's own pin first, then every live member's recorded one.
  defp pins_of(key, mine, live, me) do
    recorded = for %{key: ^key, member: member, value: value} <- live, do: {member, value}

    case Map.fetch(mine, key) do
      {:ok, value} -> Enum.uniq_by([{me, value} | recorded], &elem(&1, 0))
      :error -> recorded
    end
  end

  # What this member's environment and the store ask for.
  defp desired(%Entry{key: key, default: default}, row, mine) do
    case Map.fetch(mine, key) do
      {:ok, value} -> value
      :error -> if row, do: row.value, else: plain(default)
    end
  end

  # What this member runs at: the level it logs at, the value a restart
  # setting was applied with at boot, and a live setting's desired value.
  defp active_value(%Entry{key: "log_level"}, _active, _desired), do: plain(Logger.level())

  defp active_value(%Entry{key: key, scope: :restart}, active, desired),
    do: plain(Map.get(active, key, desired))

  defp active_value(_entry, _active, desired), do: desired

  defp source([_ | _], _row), do: "deployment"
  defp source([], nil), do: "default"
  defp source([], _row), do: "operator"

  # The members `list/0` reports: the live roster this member last read,
  # or this member alone where no claimant runs, each with the revision
  # its settings process last said it observed.
  defp members(me) do
    observed =
      case Process.whereis(__MODULE__) do
        nil -> %{}
        pid -> GenServer.call(pid, :observed)
      end

    names =
      case Cyfr.Cell.roster() do
        [] -> [me]
        roster -> roster
      end

    for name <- Enum.sort(names), do: %{member: name, revision: Map.get(observed, name)}
  end

  @doc """
  Set `key` to `raw` (the environment's text or a typed value) for the
  caller `ctx`, recording who and when.

  The value passes the roster's validator first, `{:error, {:invalid,
  key, form}}` naming the form and range it must take. A key a deployment
  pins is `{:error, :pinned}`. `opts[:revision]` is the store revision the
  change was made against, as `list/0` answered it; without it, the
  revision is read now. A write since that revision is `{:error,
  :stale}`, and a store that cannot write is `{:error, :unavailable}`:
  either way nothing changed. A live setting reaches new and refreshed
  work on every member within the cache's bound; a restart-scoped one is
  answered `pending: true` and applied at each member's next boot.
  """
  @spec set(Sanctum.Context.t(), String.t(), term(), keyword()) ::
          {:ok,
           %{key: String.t(), value: Store.value(), revision: pos_integer(), pending: boolean()}}
          | {:error, refusal()}
  def set(%Sanctum.Context{} = ctx, key, raw, opts \\ []) when is_binary(key) and is_list(opts) do
    with {:ok, entry} <- fetch(key),
         :ok <- unpinned(key),
         {:ok, value} <- validate(entry, raw),
         {:ok, revision} <- base_revision(opts),
         {:ok, next} <- written(Store.put(key, value, revision, writer(ctx))) do
      Logger.info("[Cyfr.Platform.Settings] #{key} set by #{writer(ctx)} at revision #{next}")

      announce(
        SettingsChanged.new(:changed, setting: key, revision: next, op: :put, value: plain(value))
      )

      {:ok, %{key: key, value: plain(value), revision: next, pending: entry.scope == :restart}}
    end
  end

  @doc """
  Remove `key`'s row so it reads its default again, raising the store
  revision. A key whose absence inherits another's value (the API
  rate-limit pair) is deleted, never written with the value it inherits.
  Refusals and `opts[:revision]` as `set/4`.
  """
  @spec reset(Sanctum.Context.t(), String.t(), keyword()) ::
          {:ok,
           %{key: String.t(), value: Store.value(), revision: pos_integer(), pending: boolean()}}
          | {:error, refusal()}
  def reset(%Sanctum.Context{} = ctx, key, opts \\ []) when is_binary(key) and is_list(opts) do
    with {:ok, entry} <- fetch(key),
         :ok <- unpinned(key),
         {:ok, revision} <- base_revision(opts),
         {:ok, next} <- written(Store.delete(key, revision)) do
      Logger.info("[Cyfr.Platform.Settings] #{key} reset by #{writer(ctx)} at revision #{next}")
      announce(SettingsChanged.new(:changed, setting: key, revision: next, op: :delete))

      {:ok,
       %{key: key, value: plain(entry.default), revision: next, pending: entry.scope == :restart}}
    end
  end

  defp fetch(key) do
    case Roster.fetch(key) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, :unknown_key}
    end
  end

  # Pinned here, or by any live member: the deployment's value, which no
  # operator write may replace.
  defp unpinned(key) do
    with false <- List.keymember?(pinned(), key, 0),
         {:ok, live} <- live_pins(),
         false <- Enum.any?(live, &(&1.key == key)) do
      :ok
    else
      true -> {:error, :pinned}
      {:error, :unavailable} -> {:error, :unavailable}
    end
  end

  defp validate(%Entry{key: key, validator: validator}, raw) do
    case validator.(raw) do
      {:ok, value} -> {:ok, value}
      {:error, form} -> {:error, {:invalid, key, form}}
    end
  end

  defp base_revision(opts) do
    case Keyword.get(opts, :revision) do
      revision when is_integer(revision) and revision >= 0 ->
        {:ok, revision}

      nil ->
        case Store.all() do
          {:ok, %{revision: revision}} -> {:ok, revision}
          {:error, _reason} -> {:error, :unavailable}
        end
    end
  end

  defp written({:ok, revision}), do: {:ok, revision}
  defp written({:error, :stale}), do: {:error, :stale}
  defp written({:error, _unavailable}), do: {:error, :unavailable}

  defp writer(%Sanctum.Context{user_id: user_id}) when is_binary(user_id), do: user_id
  defp writer(_ctx), do: "system"

  # The committed write, to every member and first to this one's settings
  # process, so the caller hears back only once its own member has applied
  # it. Where no settings process runs (a release `eval` with only the
  # store started) there is no bus either, and each member converges on
  # its own poll.
  defp announce(%SettingsChanged{} = change) do
    case Process.whereis(__MODULE__) do
      nil ->
        :ok

      pid ->
        :ok = GenServer.call(pid, {:observe, change})
        Cyfr.Bus.broadcast_global(Cyfr.Bus.settings_changed(), change)
    end
  end

  # ---------------------------------------------------------------------------
  # Pins
  # ---------------------------------------------------------------------------

  # This member's environment pins, as the store holds values.
  defp pinned, do: for({key, value} <- Roster.pinned(), do: {key, plain(value)})

  # The pins recorded by live members; none where no claimant runs.
  defp live_pins do
    if Arca.ControlPlane.claimed?() do
      with {:ok, pins} <- Store.pins(),
           {:ok, members} <- Arca.ControlPlane.roster() do
        {:ok, live(pins, members)}
      else
        _unavailable -> {:error, :unavailable}
      end
    else
      {:ok, []}
    end
  end

  defp variable(key) do
    case Roster.fetch(key) do
      {:ok, %Entry{variable: variable}} when is_binary(variable) -> variable
      _other -> key
    end
  end

  # A value as the store answers it: JSON's.
  defp plain(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp node_name, do: Atom.to_string(node())

  # ---------------------------------------------------------------------------
  # The settings process
  # ---------------------------------------------------------------------------

  @doc """
  Start this member's settings process. `:name` (default this module),
  `:member` (default this node's name), `:claimed` (default
  `Arca.ControlPlane.claimed?/0`: whether it settles pins and polls) and
  `:poll_ms` (default the cache's bound).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    :ok = Cyfr.Bus.subscribe_global(Cyfr.Bus.settings_changed())

    boot_revision = :persistent_term.get(@boot_revision, 0)

    state = %{
      member: Keyword.get(opts, :member, node_name()),
      claimed?: Keyword.get(opts, :claimed, Arca.ControlPlane.claimed?()),
      poll_ms: Keyword.get(opts, :poll_ms, Store.ttl_ms()),
      observed: boot_revision,
      level_revision: boot_revision,
      level_from_row?: :persistent_term.get(@level_from_row, false),
      members: %{}
    }

    state =
      if state.claimed? do
        state = settle_pins(state)
        Process.send_after(self(), :poll, state.poll_ms)
        state
      else
        state
      end

    {:ok, publish(state)}
  end

  @impl true
  def handle_call({:observe, %SettingsChanged{kind: :changed} = change}, _from, state),
    do: {:reply, :ok, observe(change, state)}

  def handle_call(:observed, _from, state),
    do: {:reply, Map.put(state.members, state.member, state.observed), state}

  @impl true
  def handle_info(%SettingsChanged{kind: :changed} = change, state),
    do: {:noreply, observe(change, state)}

  def handle_info(%SettingsChanged{kind: :observed, member: member, revision: revision}, state) do
    {:noreply,
     %{state | members: Map.update(state.members, member, revision, &max(&1, revision))}}
  end

  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, state.poll_ms)
    {:noreply, state |> poll() |> publish()}
  end

  def handle_info(msg, state) do
    Prima.LoggerContext.unexpected(__MODULE__, msg)
    {:noreply, state}
  end

  # A committed write: the key's cached value goes whatever its revision,
  # since the cache only ever re-reads the store; the log level is applied
  # only from a change newer than the one it runs at.
  defp observe(%SettingsChanged{setting: key, revision: revision, op: op, value: value}, state) do
    Store.invalidate(key)

    state =
      if key == "log_level" and revision > state.level_revision,
        do: level(op, value, revision, state),
        else: state

    advance(state, revision)
  end

  # What the store holds now, for a member that missed a message: every
  # cached value goes, and the log level follows its row.
  defp poll(state) do
    case Store.all() do
      {:ok, %{revision: revision, settings: rows}} when revision > state.observed ->
        Store.invalidate(:all)

        state =
          case Enum.find(rows, &(&1.key == "log_level")) do
            %{revision: at, value: value} when at > state.level_revision ->
              level(:put, value, at, state)

            nil when state.level_from_row? ->
              level(:delete, nil, revision, state)

            _unchanged ->
              state
          end

        advance(state, revision)

      _current_or_unavailable ->
        state
    end
  end

  defp level(op, value, revision, state) do
    if List.keymember?(Roster.pinned(), "log_level", 0) do
      # The environment's level stands on this member.
      %{state | level_revision: revision}
    else
      level_change(op, value, %{state | level_revision: revision})
    end
  end

  defp level_change(:put, value, state) do
    {:ok, %Entry{validator: validator}} = Roster.fetch("log_level")

    case validator.(value) do
      {:ok, level} ->
        apply_log_level(%{"log_level" => level})
        %{state | level_from_row?: true}

      {:error, form} ->
        Logger.error("[Cyfr.Platform.Settings] the stored log_level #{form}")
        state
    end
  end

  # A reset applies what `effective/1` answers once the row is gone, the
  # roster's default, on every member alike: the level a member booted
  # with is that boot's first write and never a fallback. A pinned key is
  # never reset, and a pin's row is its own, so no pin can be what the
  # delete leaves.
  defp level_change(:delete, _value, state) do
    {:ok, %Entry{default: default, validator: validator}} = Roster.fetch("log_level")
    {:ok, level} = validator.(default)
    apply_log_level(%{"log_level" => level})
    %{state | level_from_row?: false}
  end

  defp advance(%{observed: observed} = state, revision) when revision > observed,
    do: publish(%{state | observed: revision})

  defp advance(state, _revision), do: state

  defp publish(state) do
    Cyfr.Bus.broadcast_global(
      Cyfr.Bus.settings_changed(),
      SettingsChanged.new(:observed, member: state.member, revision: state.observed)
    )

    state
  end

  # Once this member holds its slot (its pins were recorded by the claim):
  # each value its environment pins is written as the deployment's row, so
  # every member reads it, and a deployment's row that no live pin holds
  # any more is removed, so the key reads its default again. A store that
  # cannot settle them refuses the boot.
  defp settle_pins(state) do
    mine = pinned()

    with {:ok, %{settings: rows}} <- Store.all(),
         {:ok, live} <- live_pins() do
      rows = Map.new(rows, &{&1.key, &1})
      held = MapSet.new(Enum.map(mine, &elem(&1, 0)) ++ Enum.map(live, & &1.key))

      puts =
        for {key, value} <- mine, not match?(%{value: ^value}, rows[key]), do: {key, value}

      deletes =
        for {key, %{set_by: @deployment}} <- rows, not MapSet.member?(held, key), do: key

      state = Enum.reduce(puts, state, fn {key, value}, acc -> settle(acc, key, value) end)
      Enum.reduce(deletes, state, fn key, acc -> settle(acc, key, :delete) end)
    else
      _unavailable ->
        raise "[Cyfr] FATAL: the platform settings could not be read to settle this " <>
                "member's pinned values."
    end
  end

  defp settle(state, key, value), do: settle(state, key, value, @write_rounds)

  defp settle(_state, key, _value, 0) do
    raise "[Cyfr] FATAL: the platform settings kept moving while this member wrote " <>
            "its pinned #{key}."
  end

  defp settle(state, key, value, rounds) do
    result =
      with {:ok, %{revision: revision}} <- Store.all() do
        if value == :delete,
          do: Store.delete(key, revision),
          else: Store.put(key, value, revision, @deployment)
      end

    case result do
      {:ok, next} ->
        change =
          if value == :delete,
            do: SettingsChanged.new(:changed, setting: key, revision: next, op: :delete),
            else:
              SettingsChanged.new(:changed, setting: key, revision: next, op: :put, value: value)

        Cyfr.Bus.broadcast_global(Cyfr.Bus.settings_changed(), change)
        observe(change, state)

      {:error, :stale} ->
        settle(state, key, value, rounds - 1)

      {:error, _unavailable} ->
        raise "[Cyfr] FATAL: the platform settings could not be written to settle " <>
                "this member's pinned #{key}."
    end
  end
end
