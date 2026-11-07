# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.IdentityLog do
  @moduledoc """
  The directory's store (`Arca.Schemas.IdentityLogEntry`): one append-only
  log per identifier, each entry beside the verified state it leaves, and
  the operator's tombstone.

  Arca stores bytes and hashes and verifies no signature: the directory's
  decisions verify an entry against the state its head stores before they
  write here (`Sanctum.Directory`), so the next entry is checked against
  one row, never the whole log. What this module owns is the serialization
  rule a directory promises:

    * **Registration** (`register/3`) writes an identifier's genesis at
      position 0. Registering the same genesis again answers the existing
      registration as `:exists`, whatever the quota.
    * **Appending** (`append/4`) names the head it extends. An entry that
      is already the one after its `prev` answers that entry as `:exists`;
      a `prev` that is not the head is `:stale` and writes nothing.
    * **A tombstone** (`tombstone/2`) marks an identifier gone: every later
      read and write answers `:gone`.

  Order is the position and the `prev` link alone: the times a row
  records are never compared, so no clock decides which write lands.

  ## Quotas

  Every write is decided under one lock, the directory's usage row in
  `server_meta`, which also counts registered identifiers and stored log
  bytes; a quota is never checked by an unlocked count. `policy` is the
  deployment's (`:max_identities`, `:log_bytes`, `:recovery_reserve_bytes`,
  positive integers, the reserve below the total). A new genesis past
  `:max_identities` is refused; a genesis and an entry a listed key signed
  may not spend the recovery reserve, and an entry appended after the
  genesis that a recovery key signed may: each is
  `{:error, {:capacity, :identities | :log_bytes}}`, retryable and distinct
  from any refusal of the identity. An entry past
  `Prima.Identity.max_entry_bytes/0` is `:entry_too_large`.

  ## Who writes

  The platform's own actor, for the directory, and nothing else. Writes
  prove first that this member still owns its slot (`:not_owner`).
  """

  import Ecto.Query

  alias Arca.QueryHelpers
  alias Arca.Schemas.{IdentityLogEntry, ServerMeta}

  @usage_key "directory_usage"
  @max_page 100
  @kinds ~w(add_key remove_key recover add_recovery)

  @typedoc "The deployment's directory quotas."
  @type policy :: %{
          required(:max_identities) => pos_integer(),
          required(:log_bytes) => pos_integer(),
          required(:recovery_reserve_bytes) => pos_integer()
        }

  @typedoc "An entry, as a plain map."
  @type row :: map()

  @doc "The most entries one page of a log answers."
  @spec max_page() :: pos_integer()
  def max_page, do: @max_page

  @doc """
  Register an identifier's genesis: `attrs` names the `:identifier`, the
  genesis `:entry` bytes, its `:entry_hash` and the verified `:state` it
  leaves (text). Answers `{:ok, entry, :created}`, `{:ok, entry, :exists}`
  for the same genesis again, `{:error, :conflict}` for other bytes under
  the same identifier, `{:error, :gone}` for a tombstoned identifier, or a
  quota refusal.
  """
  @spec register(Prima.Actor.t(), map(), policy()) ::
          {:ok, row(), :created | :exists} | {:error, term()}
  def register(%Prima.Actor{scope: :platform, system: true}, attrs, policy) when is_map(attrs) do
    with {:ok, policy} <- policy(policy),
         {:ok, fields} <- fields(attrs, [:identifier, :entry, :entry_hash, :state]) do
      write("Arca.IdentityLog.register", fn -> register_in(fields, policy) end)
    end
  end

  def register(%Prima.Actor{}, _attrs, _policy), do: {:error, :cross_tenant}

  @doc """
  Append an entry to `identifier`'s log: `attrs` names the `:entry` bytes,
  its `:entry_hash`, the `:prev_hash` it extends, its `:kind`, the verified
  `:state` it leaves (text), and `:recovery`, whether a recovery key
  signed it, which lets it spend the recovery reserve. Answers
  `{:ok, entry, :accepted}`, `{:ok, entry, :exists}` when that exact entry
  is already the one after its `prev`, `{:error, :stale}` when `prev` is
  not the head, `{:error, :not_found}` for an unregistered identifier,
  `{:error, :gone}` for a tombstoned one, or a quota refusal.
  """
  @spec append(Prima.Actor.t(), String.t(), map(), policy()) ::
          {:ok, row(), :accepted | :exists} | {:error, term()}
  def append(%Prima.Actor{scope: :platform, system: true}, identifier, attrs, policy)
      when is_binary(identifier) and is_map(attrs) do
    with {:ok, policy} <- policy(policy),
         {:ok, fields} <-
           fields(attrs, [:entry, :entry_hash, :prev_hash, :kind, :state, :recovery]) do
      write("Arca.IdentityLog.append", fn -> append_in(identifier, fields, policy) end)
    end
  end

  def append(%Prima.Actor{}, _identifier, _attrs, _policy), do: {:error, :cross_tenant}

  @doc """
  Mark `identifier` gone, the operator's tombstone: every later read and
  write of it answers `:gone`, and its entries stay. Answers `:ok`, also
  for an identifier already gone, or `{:error, :not_found}`.
  """
  @spec tombstone(Prima.Actor.t(), String.t()) :: :ok | {:error, term()}
  def tombstone(%Prima.Actor{scope: :platform, system: true}, identifier)
      when is_binary(identifier) do
    case Arca.Repo.owned("Arca.IdentityLog.tombstone", fn -> tombstone_in(identifier) end) do
      {:ok, :gone} -> :ok
      {:error, _reason} = error -> error
    end
  end

  def tombstone(%Prima.Actor{}, _identifier), do: {:error, :cross_tenant}

  @doc """
  One page of `identifier`'s log in order: entries after position
  `after:` (-1, the default, starts at the genesis), at most `limit:`
  (default and ceiling `max_page/0`).
  """
  @spec entries(Prima.Actor.t(), String.t(), keyword()) ::
          {:ok, [row()]} | {:error, :cross_tenant | :database_error}
  def entries(actor, identifier, opts \\ [])

  def entries(%Prima.Actor{scope: :platform}, identifier, opts)
      when is_binary(identifier) and is_list(opts) do
    after_seq = Keyword.get(opts, :after, -1)
    limit = opts |> Keyword.get(:limit, @max_page) |> min(@max_page) |> max(1)

    Arca.Repo.Errors.with_db_rescue("Arca.IdentityLog.entries", fn ->
      {:ok,
       Arca.Repo.all(
         from(e in IdentityLogEntry,
           where: e.identifier == ^identifier and e.seq > ^after_seq,
           order_by: [asc: e.seq],
           limit: ^limit
         )
       )}
    end)
    |> Arca.Data.project()
  end

  def entries(%Prima.Actor{}, _identifier, _opts), do: {:error, :cross_tenant}

  @doc """
  The last entry of `identifier`'s log, with the verified state it left,
  or `{:error, :not_found}`, or `{:error, :gone}` for a tombstoned one.
  """
  @spec head(Prima.Actor.t(), String.t()) ::
          {:ok, row()} | {:error, :not_found | :gone | :cross_tenant | :database_error}
  def head(%Prima.Actor{scope: :platform}, identifier) when is_binary(identifier) do
    Arca.Repo.Errors.with_db_rescue("Arca.IdentityLog.head", fn ->
      with :ok <- present(identifier) do
        {:ok, head_of(identifier)}
      end
    end)
    |> Arca.Data.project()
  end

  def head(%Prima.Actor{}, _identifier), do: {:error, :cross_tenant}

  @doc """
  The position of the entry hashing to `entry_hash` in `identifier`'s log,
  or `{:error, :not_found}` for a hash the log does not hold, or
  `{:error, :gone}` for a tombstoned identifier.
  """
  @spec position(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, non_neg_integer()}
          | {:error, :not_found | :gone | :cross_tenant | :database_error}
  def position(%Prima.Actor{scope: :platform}, identifier, entry_hash)
      when is_binary(identifier) and is_binary(entry_hash) do
    Arca.Repo.Errors.with_db_rescue("Arca.IdentityLog.position", fn ->
      with :ok <- present(identifier) do
        from(e in IdentityLogEntry,
          where: e.identifier == ^identifier and e.entry_hash == ^entry_hash,
          select: e.seq
        )
        |> Arca.Repo.one()
        |> case do
          nil -> {:error, :not_found}
          seq -> {:ok, seq}
        end
      end
    end)
  end

  def position(%Prima.Actor{}, _identifier, _entry_hash), do: {:error, :cross_tenant}

  @doc "What the directory holds: registered identifiers and stored log bytes."
  @spec usage(Prima.Actor.t()) ::
          {:ok, %{identities: non_neg_integer(), log_bytes: non_neg_integer()}}
          | {:error, :cross_tenant | :database_error}
  def usage(%Prima.Actor{scope: :platform}) do
    Arca.Repo.Errors.with_db_rescue("Arca.IdentityLog.usage", fn ->
      case Arca.Repo.get(ServerMeta, @usage_key) do
        nil -> {:ok, %{identities: 0, log_bytes: 0}}
        %ServerMeta{value: value} -> {:ok, decode_usage(value)}
      end
    end)
  end

  def usage(%Prima.Actor{}), do: {:error, :cross_tenant}

  # ---- the writes ------------------------------------------------------------

  defp register_in(%{identifier: identifier, entry: entry} = fields, policy) do
    usage = lock_usage!()

    case genesis_of(identifier) do
      %IdentityLogEntry{gone_at: %DateTime{}} ->
        {:error, :gone}

      %IdentityLogEntry{entry: ^entry} = existing ->
        {:ok, {existing, :exists}}

      %IdentityLogEntry{} ->
        {:error, :conflict}

      nil ->
        size = byte_size(entry)

        cond do
          usage.identities >= policy.max_identities ->
            {:error, {:capacity, :identities}}

          usage.log_bytes + size > policy.log_bytes - policy.recovery_reserve_bytes ->
            {:error, {:capacity, :log_bytes}}

          true ->
            put_usage!(%{
              usage
              | identities: usage.identities + 1,
                log_bytes: usage.log_bytes + size
            })

            row = entry_row(identifier, 0, "genesis", fields, nil)
            {:ok, {insert!(row), :created}}
        end
    end
  end

  defp append_in(identifier, %{entry: entry, prev_hash: prev} = fields, policy) do
    usage = lock_usage!()

    with :ok <- present(identifier) do
      case after_of(identifier, prev) do
        %IdentityLogEntry{entry: ^entry} = existing ->
          {:ok, {existing, :exists}}

        %IdentityLogEntry{} ->
          {:error, :stale}

        nil ->
          append_at(identifier, head_of(identifier), fields, policy, usage)
      end
    end
  end

  defp append_at(identifier, %IdentityLogEntry{entry_hash: prev, seq: seq}, fields, policy, usage)
       when prev == fields.prev_hash do
    size = byte_size(fields.entry)
    # An entry a recovery key signed may spend the reserve, which is kept so
    # an account can always be recovered; nothing else may.
    budget =
      if fields.recovery,
        do: policy.log_bytes,
        else: policy.log_bytes - policy.recovery_reserve_bytes

    if usage.log_bytes + size > budget do
      {:error, {:capacity, :log_bytes}}
    else
      put_usage!(%{usage | log_bytes: usage.log_bytes + size})
      {:ok, {insert!(entry_row(identifier, seq + 1, fields.kind, fields, prev)), :accepted}}
    end
  end

  defp append_at(_identifier, _head, _fields, _policy, _usage), do: {:error, :stale}

  defp tombstone_in(identifier) do
    _usage = lock_usage!()

    case genesis_of(identifier) do
      nil ->
        {:error, :not_found}

      %IdentityLogEntry{gone_at: %DateTime{}} ->
        {:ok, :gone}

      %IdentityLogEntry{id: id} ->
        {1, _} =
          from(e in IdentityLogEntry, where: e.id == ^id)
          |> Arca.Repo.update_all(set: [gone_at: DateTime.utc_now()])

        {:ok, :gone}
    end
  end

  # ---- reads -----------------------------------------------------------------

  defp present(identifier) do
    case genesis_of(identifier) do
      nil -> {:error, :not_found}
      %IdentityLogEntry{gone_at: %DateTime{}} -> {:error, :gone}
      %IdentityLogEntry{} -> :ok
    end
  end

  defp genesis_of(identifier) do
    Arca.Repo.one(from(e in IdentityLogEntry, where: e.identifier == ^identifier and e.seq == 0))
  end

  defp head_of(identifier) do
    Arca.Repo.one(
      from(e in IdentityLogEntry,
        where: e.identifier == ^identifier,
        order_by: [desc: e.seq],
        limit: 1
      )
    )
  end

  defp after_of(identifier, prev) do
    Arca.Repo.one(
      from(e in IdentityLogEntry, where: e.identifier == ^identifier and e.prev_hash == ^prev)
    )
  end

  defp insert!(row) do
    Arca.Repo.insert_all(IdentityLogEntry, [row])
    Arca.Repo.get!(IdentityLogEntry, row.id)
  end

  defp entry_row(identifier, seq, kind, fields, prev) do
    %{
      id: Prima.UUID7.generate_id("ile"),
      identifier: identifier,
      seq: seq,
      kind: kind,
      entry_hash: fields.entry_hash,
      prev_hash: prev,
      entry: fields.entry,
      state: fields.state,
      bytes: byte_size(fields.entry),
      gone_at: nil,
      inserted_at: DateTime.utc_now()
    }
  end

  # ---- the usage row, which is also the lock ---------------------------------

  defp lock_usage! do
    Arca.Repo.insert_all(
      ServerMeta,
      [
        %{
          key: @usage_key,
          value: encode_usage(%{identities: 0, log_bytes: 0}),
          updated_at: DateTime.utc_now()
        }
      ],
      on_conflict: :nothing
    )

    from(m in ServerMeta, where: m.key == ^@usage_key, select: m.value)
    |> QueryHelpers.for_update()
    |> Arca.Repo.one!()
    |> decode_usage()
  end

  defp put_usage!(usage) do
    {1, _} =
      from(m in ServerMeta, where: m.key == ^@usage_key)
      |> Arca.Repo.update_all(set: [value: encode_usage(usage), updated_at: DateTime.utc_now()])

    :ok
  end

  defp encode_usage(%{identities: identities, log_bytes: bytes}),
    do: Jason.encode!(%{"identities" => identities, "log_bytes" => bytes})

  defp decode_usage(value) do
    %{"identities" => identities, "log_bytes" => bytes} = Jason.decode!(value)
    %{identities: identities, log_bytes: bytes}
  end

  # ---- inputs ----------------------------------------------------------------

  defp policy(%{max_identities: ids, log_bytes: bytes, recovery_reserve_bytes: reserve} = policy)
       when is_integer(ids) and ids > 0 and is_integer(bytes) and bytes > 0 and
              is_integer(reserve) and reserve > 0 and reserve < bytes,
       do: {:ok, policy}

  defp policy(_policy), do: {:error, :invalid_policy}

  defp fields(attrs, names) do
    attrs = Map.new(attrs)

    errors =
      for name <- names, not valid?(name, Map.get(attrs, name)), into: %{} do
        {name, ["is required"]}
      end

    cond do
      errors != %{} ->
        {:error, {:invalid, errors}}

      byte_size(attrs.entry) > Prima.Identity.max_entry_bytes() ->
        {:error, :entry_too_large}

      true ->
        {:ok, Map.take(attrs, names)}
    end
  end

  defp valid?(:identifier, value), do: Prima.Identity.Encoding.identifier?(value)
  defp valid?(:entry, value), do: is_binary(value) and value != ""
  defp valid?(:entry_hash, value), do: Prima.Identity.Encoding.digest?(value)
  defp valid?(:prev_hash, value), do: Prima.Identity.Encoding.digest?(value)
  defp valid?(:kind, value), do: value in @kinds
  defp valid?(:state, value), do: is_binary(value) and value != ""
  defp valid?(:recovery, value), do: is_boolean(value)

  # One write: fenced (`Arca.Repo.owned/2`), then decided under the usage
  # lock. A written entry answers with what it was: created, accepted or
  # an existing entry.
  defp write(tag, decide) do
    case Arca.Repo.owned(tag, decide) do
      {:ok, {row, result}} when is_atom(result) -> {:ok, row, result}
      {:error, _reason} = refusal -> refusal
    end
  end
end
