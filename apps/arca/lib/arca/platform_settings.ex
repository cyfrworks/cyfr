# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.PlatformSettings do
  @moduledoc """
  The platform settings: their rows, their environment pins, and
  `effective/1`, the one accessor every reader in every layer uses.

  The host declares the settings (their keys, defaults, stale policies and
  validators); this module stores values and answers them, and names no
  setting. The host hands it the declaration's plain data once at boot,
  `install_defaults!/1`, as it installs a port. Until then `effective/1`
  answers `{:error, :uninstalled}`, so no Arca or Sanctum child can read a
  setting at its own start.

  ## The store

  `platform_settings` holds one row per setting a person has set, and one
  reserved row, `"$revision"`, whose `revision` is the store revision: a
  counter every `put/4` and `delete/2` raises by one and nothing lowers.
  Both are compare-and-set on it, so two writers on two members serialize
  through that row, and a key deleted and set again cannot make an old
  revision current. Each row records the revision that last wrote it. A
  key with no row is its default.

  `settings_pins` holds each member's environment pins: the value a
  member's environment set for a key, under the member's name and the
  generation of its slot, retired by whoever next takes or expires that
  slot (`retire_pins/2`).

  Both tables are node facts: no athanor owns them, and every member of a
  cell reads the same rows.

  ## Values

  A value is stored as JSON text and answered as JSON decodes it, so an
  atom comes back as its string and a keyword list cannot be stored. A
  default is answered in that same shape: `install_defaults!/1` passes each
  one through the encoding, so a default and a row holding it read alike.

  ## The accessor

  `effective/1` answers from a `:persistent_term` cache that lives thirty
  seconds (`ttl_ms/0`, the bound within which a member that missed an
  invalidation converges), then asks the store again. When the store
  cannot answer, the key's stale policy decides: `:refuse` answers
  `{:error, :unavailable}`, and `:serve` answers the last value it read (the
  default when it never read one) and emits
  `[:cyfr, :platform_settings, :stale_served]`.
  """

  import Ecto.Query

  require Logger

  alias Arca.PlatformSettings.{Pin, Row}

  defmodule Row do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:key, :string, autogenerate: false}

    schema "platform_settings" do
      field :value, :string
      field :revision, :integer
      field :set_by, :string
      field :set_at, :utc_datetime_usec
    end
  end

  defmodule Pin do
    @moduledoc false
    use Ecto.Schema

    @primary_key false

    schema "settings_pins" do
      field :key, :string, primary_key: true
      field :member, :string, primary_key: true
      field :generation, :integer
      field :value, :string
    end
  end

  @revision_key "$revision"
  @ttl_ms 30_000
  @stale_event [:cyfr, :platform_settings, :stale_served]
  @installed {__MODULE__, :installed}

  @typedoc "A setting's key, as the host's declaration names it."
  @type key :: String.t()

  @typedoc "A value as JSON answers it."
  @type value :: nil | boolean() | number() | String.t() | [value()] | %{String.t() => value()}

  @typedoc "One stored setting."
  @type row :: %{
          key: key(),
          value: value(),
          revision: non_neg_integer(),
          set_by: String.t() | nil,
          set_at: DateTime.t()
        }

  @typedoc "One member's environment pin."
  @type pin :: %{key: key(), member: String.t(), generation: non_neg_integer(), value: value()}

  @typedoc "The installed data: each key's default and stale policy."
  @type installed :: %{key() => %{default: term(), stale: :refuse | :serve}}

  @doc "The row reserved for the store revision, which no setting may use."
  @spec revision_key() :: String.t()
  def revision_key, do: @revision_key

  @doc "How long a cached value is answered before the store is asked again, in milliseconds."
  @spec ttl_ms() :: pos_integer()
  def ttl_ms, do: @ttl_ms

  @doc "The telemetry event a `:serve` key emits when it answers a stale value."
  @spec stale_event() :: [atom(), ...]
  def stale_event, do: @stale_event

  # ---------------------------------------------------------------------------
  # The accessor
  # ---------------------------------------------------------------------------

  @doc """
  The value `key` takes now: its row, else its default.

  `{:error, :uninstalled}` before the host installed the defaults,
  `{:error, :unknown_key}` for a key they do not name, and
  `{:error, :unavailable}` for a `:refuse` key whose cached value has
  expired while the store cannot answer.
  """
  @spec effective(key()) :: {:ok, value()} | {:error, :uninstalled | :unavailable | :unknown_key}
  def effective(key) when is_binary(key) do
    with {:ok, installed} <- installed_map(),
         {:ok, %{default: default, stale: stale}} <- declared(installed, key) do
      now = System.monotonic_time(:millisecond)

      case :persistent_term.get(cache_key(key), nil) do
        {value, read_at} when now - read_at < @ttl_ms -> {:ok, value}
        cached -> refresh(key, default, stale, cached, now)
      end
    end
  end

  defp installed_map do
    case :persistent_term.get(@installed, nil) do
      nil -> {:error, :uninstalled}
      installed -> {:ok, installed}
    end
  end

  defp declared(installed, key) do
    case Map.fetch(installed, key) do
      {:ok, declared} -> {:ok, declared}
      :error -> {:error, :unknown_key}
    end
  end

  defp refresh(key, default, stale, cached, now) do
    case get(key) do
      {:ok, %{value: value}} ->
        remember(key, value, now)

      {:error, :not_found} ->
        remember(key, default, now)

      {:error, _unavailable} when stale == :refuse ->
        {:error, :unavailable}

      {:error, _unavailable} ->
        # The read time is left as it was, so the next read asks the store
        # again rather than trusting this answer for another interval.
        last =
          case cached do
            {value, _read_at} -> value
            nil -> default
          end

        :telemetry.execute(@stale_event, %{count: 1}, %{key: key})
        {:ok, last}
    end
  end

  defp remember(key, value, now) do
    :persistent_term.put(cache_key(key), {value, now})
    {:ok, value}
  end

  defp cache_key(key), do: {__MODULE__, :value, key}

  @doc """
  Install the host's declaration: `%{key => %{default: term, stale: :refuse
  | :serve}}`, plain values. Replaces any earlier installation and drops
  every cached value. Raises on a malformed declaration or a default JSON
  cannot hold.
  """
  @spec install_defaults!(installed()) :: :ok
  def install_defaults!(defaults) when is_map(defaults) do
    installed =
      Map.new(defaults, fn
        {key, %{default: default, stale: stale}}
        when is_binary(key) and key != @revision_key and stale in [:refuse, :serve] ->
          {key, %{default: default |> Jason.encode!() |> Jason.decode!(), stale: stale}}

        _entry ->
          raise ArgumentError,
                "[Arca.PlatformSettings] a declaration maps each setting's name, a string " <>
                  "other than the reserved revision key, to %{default: value, stale: " <>
                  ":refuse | :serve}"
      end)

    # The earlier installation's cached values go with it, and so do the
    # ones cached under this one's keys.
    invalidate(:all)
    :persistent_term.put(@installed, installed)
    invalidate(:all)
  end

  @doc "The installed declaration, or `nil` before `install_defaults!/1`."
  @spec installed() :: installed() | nil
  def installed, do: :persistent_term.get(@installed, nil)

  @doc """
  Forget the installed declaration and every cached value, so
  `effective/1` answers `{:error, :uninstalled}` again: the suite's way
  back to the state before a boot installed it.
  """
  @spec uninstall() :: :ok
  def uninstall do
    invalidate(:all)
    :persistent_term.erase(@installed)
    :ok
  end

  @doc "Drop the cached value of `key`, or of every key, so the next read asks the store."
  @spec invalidate(key() | :all) :: :ok
  def invalidate(:all) do
    for key <- Map.keys(installed() || %{}), do: :persistent_term.erase(cache_key(key))
    :ok
  end

  def invalidate(key) when is_binary(key) do
    :persistent_term.erase(cache_key(key))
    :ok
  end

  # ---------------------------------------------------------------------------
  # The rows
  # ---------------------------------------------------------------------------

  @doc "The row of `key`: `{:error, :not_found}` when none is stored, which is its default."
  @spec get(key()) :: {:ok, row()} | {:error, :not_found | :reserved | :database_error}
  def get(@revision_key), do: {:error, :reserved}

  def get(key) when is_binary(key) do
    Arca.Repo.Errors.with_db_rescue("Arca.PlatformSettings.get", fn ->
      case Arca.Repo.get(Row, key) do
        nil -> {:error, :not_found}
        %Row{} = row -> project(row)
      end
    end)
  end

  @doc """
  Every stored setting and the store revision, read in one statement so
  the two agree.
  """
  @spec all() ::
          {:ok, %{revision: non_neg_integer(), settings: [row()]}} | {:error, :database_error}
  def all do
    Arca.Repo.Errors.with_db_rescue("Arca.PlatformSettings.all", fn ->
      rows = Arca.Repo.all(from(r in Row, order_by: r.key))
      {[reserved], settings} = Enum.split_with(rows, &(&1.key == @revision_key))

      settings
      |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
        case project(row) do
          {:ok, projected} -> {:cont, {:ok, [projected | acc]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, projected} ->
          {:ok, %{revision: reserved.revision, settings: Enum.reverse(projected)}}

        error ->
          error
      end
    end)
  end

  @doc """
  Store `value` under `key` if the store revision still reads `revision`,
  raising it by one; answers the new store revision, which the row
  records. `{:error, :stale}` when another write raised it first.
  """
  @spec put(key(), term(), non_neg_integer(), String.t() | nil) ::
          {:ok, pos_integer()} | {:error, :stale | :reserved | :unencodable | :database_error}
  def put(@revision_key, _value, _revision, _set_by), do: {:error, :reserved}

  # arca:db-raise-ok the insert runs inside `write/4`, which rescues.
  def put(key, value, revision, set_by)
      when is_binary(key) and is_integer(revision) and revision >= 0 and
             (is_binary(set_by) or is_nil(set_by)) do
    case Jason.encode(value) do
      {:ok, encoded} ->
        write(key, revision, "Arca.PlatformSettings.put", fn next, now ->
          Arca.Repo.insert_all(
            Row,
            [%{key: key, value: encoded, revision: next, set_by: set_by, set_at: now}],
            on_conflict: {:replace, [:value, :revision, :set_by, :set_at]},
            conflict_target: :key
          )
        end)

      {:error, _reason} ->
        {:error, :unencodable}
    end
  end

  @doc """
  Remove `key`'s row, so it reads its default again, if the store revision
  still reads `revision`, raising it by one whether or not a row was there.
  """
  @spec delete(key(), non_neg_integer()) ::
          {:ok, pos_integer()} | {:error, :stale | :reserved | :database_error}
  def delete(@revision_key, _revision), do: {:error, :reserved}

  # arca:db-raise-ok the delete runs inside `write/4`, which rescues.
  def delete(key, revision) when is_binary(key) and is_integer(revision) and revision >= 0 do
    write(key, revision, "Arca.PlatformSettings.delete", fn _next, _now ->
      Arca.Repo.delete_all(from(r in Row, where: r.key == ^key))
    end)
  end

  # The store revision is raised by a conditional update of its row, so a
  # writer that read an older revision changes nothing: on PostgreSQL the
  # update waits for a concurrent writer's row lock and then finds the
  # revision moved; on SQLite the transaction holds the one write lock.
  defp write(key, revision, tag, change) do
    result =
      Arca.Repo.Errors.with_db_rescue(tag, fn ->
        Arca.Repo.locking_transaction(fn ->
          next = revision + 1
          now = DateTime.utc_now()

          {raised, _} =
            from(r in Row, where: r.key == ^@revision_key and r.revision == ^revision)
            |> Arca.Repo.update_all(set: [revision: next, set_at: now])

          if raised != 1, do: Arca.Repo.rollback(:stale)

          change.(next, now)
          next
        end)
      end)

    # This member reads its own write at once; the others on their
    # invalidation or within the cache's lifetime.
    if match?({:ok, _}, result), do: invalidate(key)
    result
  end

  # ---------------------------------------------------------------------------
  # The pins
  # ---------------------------------------------------------------------------

  @doc "Every member's recorded environment pins, by key and member."
  @spec pins() :: {:ok, [pin()]} | {:error, :database_error}
  def pins do
    Arca.Repo.Errors.with_db_rescue("Arca.PlatformSettings.pins", fn ->
      from(p in Pin, order_by: [p.key, p.member])
      |> Arca.Repo.all()
      |> Enum.reduce_while({:ok, []}, fn pin, {:ok, acc} ->
        case Jason.decode(pin.value) do
          {:ok, value} ->
            {:cont,
             {:ok,
              [
                %{key: pin.key, member: pin.member, generation: pin.generation, value: value}
                | acc
              ]}}

          {:error, _reason} ->
            {:halt, undecodable(pin.key)}
        end
      end)
      |> case do
        {:ok, pins} -> {:ok, Enum.reverse(pins)}
        error -> error
      end
    end)
  end

  @doc """
  Record that `member`'s environment, at the slot generation `generation`,
  pins `key` to `value`, replacing what that member recorded for it before.
  """
  @spec record_pin(key(), String.t(), non_neg_integer(), term()) ::
          :ok | {:error, :unencodable | :database_error}
  def record_pin(key, member, generation, value)
      when is_binary(key) and is_binary(member) and is_integer(generation) and generation >= 0 do
    case Jason.encode(value) do
      {:ok, encoded} ->
        Arca.Repo.Errors.with_db_rescue("Arca.PlatformSettings.record_pin", fn ->
          Arca.Repo.insert_all(
            Pin,
            [%{key: key, member: member, generation: generation, value: encoded}],
            on_conflict: {:replace, [:generation, :value]},
            conflict_target: [:key, :member]
          )

          :ok
        end)

      {:error, _reason} ->
        {:error, :unencodable}
    end
  end

  @doc """
  Retire every pin `member` recorded at `generation` or before: the step
  whoever next takes or expires that member's slot runs. A pin the member
  recorded under a later generation stays. Answers how many went.
  """
  @spec retire_pins(String.t(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, :database_error}
  def retire_pins(member, generation)
      when is_binary(member) and is_integer(generation) and generation >= 0 do
    Arca.Repo.Errors.with_db_rescue("Arca.PlatformSettings.retire_pins", fn ->
      {count, _} =
        from(p in Pin, where: p.member == ^member and p.generation <= ^generation)
        |> Arca.Repo.delete_all()

      {:ok, count}
    end)
  end

  defp project(%Row{} = row) do
    case Jason.decode(row.value) do
      {:ok, value} ->
        {:ok,
         %{
           key: row.key,
           value: value,
           revision: row.revision,
           set_by: row.set_by,
           set_at: row.set_at
         }}

      {:error, _reason} ->
        undecodable(row.key)
    end
  end

  # A value this module did not write reads as a store that cannot answer:
  # a refuse key refuses and a serve key serves its last value, never the
  # text itself.
  defp undecodable(key) do
    Logger.error("[Arca.PlatformSettings] the stored value of #{inspect(key)} is not JSON")
    {:error, :database_error}
  end
end
