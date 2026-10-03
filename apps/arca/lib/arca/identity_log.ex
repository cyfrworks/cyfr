# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.IdentityLog do
  @moduledoc """
  The directory's store (`Arca.Schemas.IdentityLogEntry`): one append-only
  log per identifier, and the recorded outcome of every recovery request
  it answered.

  Arca stores bytes and hashes and verifies no signature: the directory's
  decisions verify a chain before they write here. What this module owns
  is the serialization rule a directory promises:

    * **Registration** (`register/3`) writes an identifier's genesis at
      position 0. Registering the same genesis again answers the existing
      registration, whatever the quota.
    * **Rotation** (`append/4`) names the head it extends; a head that moved
      is refused `:stale` and nothing is written.
    * **Recovery** (`recover/4`) names the recovery policy revision it
      expects. The revision is the number of accepted recoveries in the
      log, read under the lock; a request against a revision that is no
      longer current is recorded and refused `:stale_policy`. A request id
      is scoped to its identifier and its request digest: the same request
      again answers its recorded outcome, refusal included, whatever the
      state has become, and the same id with another digest is refused
      `:request_id_reused`. An accepted recovery is appended at the head.
      A head that moved while the revision still stands is `:stale` and
      recorded nothing: the caller rebuilds its entry on the new head.

  ## Quotas

  Every write is decided under one lock, the directory's usage row in
  `server_meta`, which also counts registered identifiers and stored log
  bytes; a quota is never checked by an unlocked count. `policy` is the
  deployment's (`:max_identities`, `:log_bytes`, `:recovery_reserve_bytes`,
  positive integers, the reserve below the total). A new genesis past
  `:max_identities` is refused, a genesis or a rotation may not spend the
  recovery reserve, and a recovery entry or its recorded refusal may: each
  is `{:error, {:capacity, :identities | :log_bytes}}`, retryable and
  distinct from any refusal of the identity. An entry past
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

  @typedoc "The deployment's directory quotas."
  @type policy :: %{
          required(:max_identities) => pos_integer(),
          required(:log_bytes) => pos_integer(),
          required(:recovery_reserve_bytes) => pos_integer()
        }

  @typedoc "An entry or a recorded outcome, as a plain map."
  @type row :: map()

  @doc "The most entries one page of a log answers."
  @spec max_page() :: pos_integer()
  def max_page, do: @max_page

  @doc """
  Register an identifier's genesis: `attrs` names the `:identifier`, the
  genesis `:entry` bytes and its `:entry_hash`. Answers `{:ok, entry}`,
  the existing genesis for an exact repeat, `{:error, :conflict}` for other
  bytes under the same identifier, or a quota refusal.
  """
  @spec register(Prima.Actor.t(), map(), policy()) :: {:ok, row()} | {:error, term()}
  def register(%Prima.Actor{scope: :platform, system: true}, attrs, policy) when is_map(attrs) do
    with {:ok, policy} <- policy(policy),
         {:ok, fields} <- fields(attrs, [:identifier, :entry, :entry_hash]) do
      write("Arca.IdentityLog.register", fn -> register_in(fields, policy) end)
    end
  end

  def register(%Prima.Actor{}, _attrs, _policy), do: {:error, :cross_tenant}

  @doc """
  Append a rotation to `identifier`'s log: `attrs` names the `:entry`
  bytes, its `:entry_hash` and the `:prev_hash` it extends. Answers
  `{:ok, entry}`, `{:error, :stale}` when the head moved,
  `{:error, :not_found}` for an unregistered identifier, or a quota
  refusal.
  """
  @spec append(Prima.Actor.t(), String.t(), map(), policy()) :: {:ok, row()} | {:error, term()}
  def append(%Prima.Actor{scope: :platform, system: true}, identifier, attrs, policy)
      when is_binary(identifier) and is_map(attrs) do
    with {:ok, policy} <- policy(policy),
         {:ok, fields} <- fields(attrs, [:entry, :entry_hash, :prev_hash]) do
      write("Arca.IdentityLog.append", fn -> append_in(identifier, fields, policy) end)
    end
  end

  def append(%Prima.Actor{}, _identifier, _attrs, _policy), do: {:error, :cross_tenant}

  @doc """
  Apply a recovery to `identifier`'s log: `attrs` names the `:entry` bytes,
  its `:entry_hash`, the `:prev_hash` it extends, the `:request_id`, the
  `:request_digest` and the `:expected_revision`. See the module doc for
  the rule. Answers `{:ok, entry}` for an accepted recovery (again for an
  exact retry), or `{:error, :stale_policy | :stale | :request_id_reused |
  :not_found}`, or a quota refusal.
  """
  @spec recover(Prima.Actor.t(), String.t(), map(), policy()) :: {:ok, row()} | {:error, term()}
  def recover(%Prima.Actor{scope: :platform, system: true}, identifier, attrs, policy)
      when is_binary(identifier) and is_map(attrs) do
    with {:ok, policy} <- policy(policy),
         {:ok, fields} <-
           fields(attrs, [
             :entry,
             :entry_hash,
             :prev_hash,
             :request_id,
             :request_digest,
             :expected_revision
           ]) do
      write("Arca.IdentityLog.recover", fn -> recover_in(identifier, fields, policy) end)
    end
  end

  def recover(%Prima.Actor{}, _identifier, _attrs, _policy), do: {:error, :cross_tenant}

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
           where: e.identifier == ^identifier and not is_nil(e.seq) and e.seq > ^after_seq,
           order_by: [asc: e.seq],
           limit: ^limit
         )
       )}
    end)
    |> Arca.Data.project()
  end

  def entries(%Prima.Actor{}, _identifier, _opts), do: {:error, :cross_tenant}

  @doc "The last entry of `identifier`'s log, or `{:error, :not_found}`."
  @spec head(Prima.Actor.t(), String.t()) ::
          {:ok, row()} | {:error, :not_found | :cross_tenant | :database_error}
  def head(%Prima.Actor{scope: :platform}, identifier) when is_binary(identifier) do
    Arca.Repo.Errors.with_db_rescue("Arca.IdentityLog.head", fn ->
      case head_of(identifier) do
        nil -> {:error, :not_found}
        entry -> {:ok, entry}
      end
    end)
    |> Arca.Data.project()
  end

  def head(%Prima.Actor{}, _identifier), do: {:error, :cross_tenant}

  @doc """
  The last entry of `identifier`'s log and its key-bearing entries: the
  genesis and every accepted recovery up to that head, in position order.
  Rotations name only a live key, so these alone carry the operational key
  and the recovery set in force at the head and at every earlier policy
  revision: what a directory checks a new entry's signature against before
  it reads the whole log. A read, through the identifier's index.
  """
  @spec keys(Prima.Actor.t(), String.t()) ::
          {:ok, %{head: row(), keyed: [row()]}}
          | {:error, :not_found | :cross_tenant | :database_error}
  def keys(%Prima.Actor{scope: :platform}, identifier) when is_binary(identifier) do
    Arca.Repo.Errors.with_db_rescue("Arca.IdentityLog.keys", fn ->
      case head_of(identifier) do
        nil ->
          {:error, :not_found}

        head ->
          # Bounded by the head read first, so an entry appended between
          # the two reads is not answered beside a head that predates it.
          keyed =
            Arca.Repo.all(
              from(e in IdentityLogEntry,
                where:
                  e.identifier == ^identifier and e.kind in ["genesis", "recover"] and
                    not is_nil(e.seq) and e.seq <= ^head.seq,
                order_by: [asc: e.seq]
              )
            )

          {:ok, %{head: head, keyed: keyed}}
      end
    end)
    |> Arca.Data.project()
  end

  def keys(%Prima.Actor{}, _identifier), do: {:error, :cross_tenant}

  @doc """
  The recorded outcome of `request_id` under `identifier`: the accepted
  entry, or the refusal's record (`outcome: "stale_policy"` with its
  `outcome_body`).
  """
  @spec outcome(Prima.Actor.t(), String.t(), String.t()) ::
          {:ok, row()} | {:error, :not_found | :cross_tenant | :database_error}
  def outcome(%Prima.Actor{scope: :platform}, identifier, request_id)
      when is_binary(identifier) and is_binary(request_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.IdentityLog.outcome", fn ->
      case request_of(identifier, request_id) do
        nil -> {:error, :not_found}
        record -> {:ok, record}
      end
    end)
    |> Arca.Data.project()
  end

  def outcome(%Prima.Actor{}, _identifier, _request_id), do: {:error, :cross_tenant}

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

  defp register_in(%{identifier: identifier, entry: entry, entry_hash: hash}, policy) do
    usage = lock_usage!()

    case genesis_of(identifier) do
      %IdentityLogEntry{entry: ^entry} = existing ->
        {:ok, existing}

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
            row =
              entry_row(identifier, 0, "genesis", entry, hash, nil)
              |> Map.put(:bytes, size)

            put_usage!(%{
              usage
              | identities: usage.identities + 1,
                log_bytes: usage.log_bytes + size
            })

            insert!(row)
        end
    end
  end

  defp append_in(identifier, %{entry: entry, entry_hash: hash, prev_hash: prev}, policy) do
    usage = lock_usage!()
    size = byte_size(entry)

    case head_of(identifier) do
      nil ->
        {:error, :not_found}

      %IdentityLogEntry{entry_hash: ^prev, seq: seq} ->
        if usage.log_bytes + size > policy.log_bytes - policy.recovery_reserve_bytes do
          {:error, {:capacity, :log_bytes}}
        else
          put_usage!(%{usage | log_bytes: usage.log_bytes + size})

          insert!(
            entry_row(identifier, seq + 1, "rotate", entry, hash, prev)
            |> Map.put(:bytes, size)
          )
        end

      %IdentityLogEntry{} ->
        {:error, :stale}
    end
  end

  defp recover_in(identifier, fields, policy) do
    usage = lock_usage!()

    case request_of(identifier, fields.request_id) do
      %IdentityLogEntry{request_digest: digest} = record when digest == fields.request_digest ->
        recorded(record)

      %IdentityLogEntry{} ->
        {:error, :request_id_reused}

      nil ->
        apply_recovery(identifier, fields, policy, usage)
    end
  end

  defp apply_recovery(identifier, fields, policy, usage) do
    case head_of(identifier) do
      nil ->
        {:error, :not_found}

      head ->
        revision = revision_of(identifier)

        cond do
          fields.expected_revision != revision ->
            refuse_stale_policy(identifier, fields, revision, policy, usage)

          head.entry_hash != fields.prev_hash ->
            {:error, :stale}

          true ->
            accept_recovery(identifier, head, fields, policy, usage)
        end
    end
  end

  defp accept_recovery(identifier, head, fields, policy, usage) do
    size = byte_size(fields.entry)

    if usage.log_bytes + size > policy.log_bytes do
      {:error, {:capacity, :log_bytes}}
    else
      put_usage!(%{usage | log_bytes: usage.log_bytes + size})

      entry_row(
        identifier,
        head.seq + 1,
        "recover",
        fields.entry,
        fields.entry_hash,
        head.entry_hash
      )
      |> Map.merge(%{
        request_id: fields.request_id,
        request_digest: fields.request_digest,
        bytes: size
      })
      |> insert!()
    end
  end

  # A request against a revision that is no longer current is recorded with
  # its body, so a retry answers the same refusal whatever the log does next.
  defp refuse_stale_policy(identifier, fields, revision, policy, usage) do
    body =
      Jason.encode!(%{
        "outcome" => "stale_policy",
        "expected_revision" => fields.expected_revision,
        "revision" => revision
      })

    size = byte_size(body)

    if usage.log_bytes + size > policy.log_bytes do
      {:error, {:capacity, :log_bytes}}
    else
      put_usage!(%{usage | log_bytes: usage.log_bytes + size})

      %{
        id: Prima.UUID7.generate_id("ile"),
        identifier: identifier,
        seq: nil,
        kind: "recover",
        entry_hash: nil,
        prev_hash: nil,
        entry: nil,
        request_id: fields.request_id,
        request_digest: fields.request_digest,
        outcome: "stale_policy",
        outcome_body: body,
        bytes: size,
        inserted_at: DateTime.utc_now()
      }
      |> insert!()

      {:refused, :stale_policy}
    end
  end

  defp recorded(%IdentityLogEntry{outcome: "accepted"} = record), do: {:ok, record}
  defp recorded(%IdentityLogEntry{outcome: "stale_policy"}), do: {:refused, :stale_policy}

  # ---- reads under the lock --------------------------------------------------

  defp genesis_of(identifier) do
    Arca.Repo.one(from(e in IdentityLogEntry, where: e.identifier == ^identifier and e.seq == 0))
  end

  defp head_of(identifier) do
    Arca.Repo.one(
      from(e in IdentityLogEntry,
        where: e.identifier == ^identifier and not is_nil(e.seq),
        order_by: [desc: e.seq],
        limit: 1
      )
    )
  end

  defp revision_of(identifier) do
    Arca.Repo.one(
      from(e in IdentityLogEntry,
        where: e.identifier == ^identifier and e.kind == "recover" and not is_nil(e.seq),
        select: count(e.id)
      )
    ) || 0
  end

  defp request_of(identifier, request_id) do
    Arca.Repo.one(
      from(e in IdentityLogEntry,
        where: e.identifier == ^identifier and e.request_id == ^request_id
      )
    )
  end

  defp insert!(row) do
    Arca.Repo.insert_all(IdentityLogEntry, [row])
    {:ok, Arca.Repo.get!(IdentityLogEntry, row.id)}
  end

  defp entry_row(identifier, seq, kind, entry, hash, prev) do
    %{
      id: Prima.UUID7.generate_id("ile"),
      identifier: identifier,
      seq: seq,
      kind: kind,
      entry_hash: hash,
      prev_hash: prev,
      entry: entry,
      request_id: nil,
      request_digest: nil,
      outcome: "accepted",
      outcome_body: nil,
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
  defp valid?(:request_id, value), do: Prima.Identity.Encoding.id?(value)
  defp valid?(:request_digest, value), do: Prima.Identity.Encoding.digest?(value)
  defp valid?(:expected_revision, value), do: is_integer(value) and value >= 0

  # One write: a locking transaction that proves this member still owns its
  # slot (`Arca.ControlPlane.verify_held/1`), then decides under the usage
  # lock. A recorded refusal commits and is answered as the refusal.
  defp write(tag, decide) do
    Arca.Repo.Errors.with_db_rescue(tag, fn ->
      with {:ok, slot} <- Arca.ControlPlane.member_slot() do
        Arca.Repo.locking_transaction(fn ->
          case Arca.ControlPlane.verify_held(slot) do
            :ok -> decided(decide.())
            :lost -> Arca.Repo.rollback(:not_owner)
          end
        end)
        |> case do
          {:ok, {:refused, reason}} -> {:error, reason}
          other -> other
        end
      end
    end)
    |> Arca.Data.project()
  end

  defp decided({:ok, value}), do: value
  defp decided({:refused, _reason} = refused), do: refused
  defp decided({:error, reason}), do: Arca.Repo.rollback(reason)
end
