# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.VaultStorage do
  @moduledoc """
  Persistence mechanics for vault entries. Sealing, binding-digest
  derivation and every consent semantic live in the `Sanctum.*` layer —
  `sealed_payload` arrives encrypted and leaves encrypted.

  Every function takes the actor first and works on the actor's athanor;
  an actor whose athanor is not a resolved id is refused
  (`{:error, :no_athanor}`) before any query, and a `%Sanctum.Context{}` or
  a bare athanor id matches no clause at all.

  `nil` and `""` are both unresolved and both refused. An empty athanor is
  not a narrower tenant: it would filter on `athanor_id == ""`, match
  nothing and answer an ordinary empty result, which is how "no tenant was
  resolved" turns into "there is no such credential" — the two answers this
  module exists to keep apart.

  ## The tenant is the actor's, never the row's

  What comes back is a plain map (`t:entry/0`) that carries no
  `athanor_id`. The column exists and every filter here uses it, but it is
  not readable back out, so a caller cannot take the tenant from a row it
  holds and hand it to the next call: an entry id learned in one athanor
  resolves to nothing in another, and nothing on the answer would let a
  caller widen itself back to the row's own athanor. `put/2` refuses an
  `:athanor_id` in its attributes for the same reason — the tenant is the
  actor's to supply.

  ## What crosses the boundary

  Ciphertext, and no Ecto struct or changeset. `sealed_payload` is opaque
  bytes on the way in and on the way out; no argument or result here has
  ever held a decrypted credential, and keeping it that way is what stops
  one reaching a log line, a crash report or a retained payload through a
  module below the security boundary.

  ## Transactions

  Two functions own every indivisible write, so no caller assembles one
  out of a sequence. `move_binding/5` is the binding compare-and-set with
  the invalidation of every profile that depended on it.
  `commit_payload/3` is a material write with the status flip and the
  binding move that belong to it, which is the shape of an operator
  rotation and of an OAuth grant commit alike.

  The decisions those transactions carry out — which digest, which status,
  which ciphertext, which word a blocked profile takes — are all made by
  the caller before the transaction opens, so nothing inside one waits on
  an answer from above and no caller needs a way to abort one. What is
  left inside is a precondition expressed as data: a digest or a revision
  the row must still read. Arca checks it and rolls its own transaction
  back when the row has moved on.
  """

  import Ecto.Query

  alias Arca.Schemas.VaultEntry

  @typedoc """
  A vault entry as callers see it: the metadata, the binding columns and
  the sealed bytes. Deliberately no `athanor_id` — see the module doc.
  """
  @type entry :: %{
          id: String.t(),
          name: String.t(),
          kind: String.t(),
          provider_hint: String.t(),
          provenance: String.t(),
          field_names: String.t(),
          binding_digest: String.t() | nil,
          oauth_endpoints: String.t() | nil,
          oauth_scopes: String.t() | nil,
          status: String.t(),
          payload_rev: non_neg_integer(),
          sealed_payload: binary() | nil,
          last_used_at: DateTime.t() | nil
        }

  @typedoc "The binding move and the profiles it blocks, or nothing to move."
  @type rebind :: %{
          from_digest: String.t() | nil,
          changes: map(),
          blocked_status: String.t()
        }

  @typedoc "What `commit_payload/3` is asked to write, all of it decided by the caller."
  @type payload_plan :: %{
          expected_rev: non_neg_integer(),
          sealed_payload: binary(),
          status: String.t() | nil,
          rebind: rebind() | nil
        }

  @type refusal :: {:error, :no_athanor | :database_error}

  @binding_keys [:field_names, :oauth_endpoints, :oauth_scopes, :binding_digest]

  # A tenant this module will act for. Written once so no head can drift
  # into accepting `""`, which reads as a tenant, filters as a tenant and
  # answers like an empty athanor rather than like the refusal it is.
  defguardp resolved(athanor_id) when is_binary(athanor_id) and athanor_id != ""

  @doc """
  Insert an entry for the actor's athanor.

  `attrs` carries the row's own fields; the tenant is the actor's and an
  `:athanor_id` among the attributes is an `ArgumentError`, not a quiet
  override — a caller that thought it was choosing the tenant must find
  out here rather than write someone else's row.
  """
  @spec put(Cyfr.Actor.t(), map()) ::
          {:ok, entry()} | {:error, :name_taken} | refusal()
  def put(%Cyfr.Actor{athanor_id: athanor_id}, attrs)
      when resolved(athanor_id) and is_map(attrs) do
    if Map.has_key?(attrs, :athanor_id) or Map.has_key?(attrs, "athanor_id") do
      raise ArgumentError,
            "Arca.VaultStorage.put/2: the tenant comes from the actor; " <>
              "drop :athanor_id from the attributes"
    end

    Arca.Repo.Errors.with_db_rescue("Arca.VaultStorage.put", fn ->
      row =
        attrs
        |> Map.put(:athanor_id, athanor_id)
        |> Map.put_new(:id, Cyfr.UUID7.generate_id("vlt"))

      # Through a changeset carrying the living-name index, so a race on
      # the name answers `{:error, :name_taken}` like the pre-check does.
      # A bare `struct |> insert` declares no constraint, so a violation
      # raised `Ecto.ConstraintError` — which `db_errors()` deliberately
      # does not rescue — straight past this wrapper.
      #
      # Both spellings are declared because the two adapters name the
      # violated constraint differently: Postgres reports the index's own
      # name, while ecto_sqlite3 derives one from the columns SQLite names
      # in its error text. Declaring only the first left SQLite raising
      # `Ecto.ConstraintError` on the race the changeset exists to catch.
      %VaultEntry{}
      |> Ecto.Changeset.change(row)
      |> Ecto.Changeset.unique_constraint([:athanor_id, :name],
        name: :vault_entries_active_name_index
      )
      |> Ecto.Changeset.unique_constraint([:athanor_id, :name],
        name: :vault_entries_athanor_id_name_index
      )
      |> Arca.Repo.insert()
      |> case do
        {:ok, inserted} -> {:ok, view(inserted)}
        # The changeset never leaves: a caller below the security boundary
        # answering with an Ecto struct would put the sealed payload into
        # every inspect of the refusal.
        {:error, %Ecto.Changeset{}} -> {:error, :name_taken}
      end
    end)
  end

  def put(%Cyfr.Actor{}, attrs) when is_map(attrs), do: {:error, :no_athanor}

  @doc "The entry with this id in the actor's athanor."
  @spec get(Cyfr.Actor.t(), String.t()) ::
          {:ok, entry()} | {:error, :not_found} | refusal()
  def get(%Cyfr.Actor{athanor_id: athanor_id}, id) when resolved(athanor_id) and is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("Arca.VaultStorage.get", fn ->
      # Not found and belongs-to-another-athanor are deliberately the same
      # answer: a distinct error would tell a caller that an id it guessed
      # exists somewhere else.
      case Arca.Repo.get_by(VaultEntry, id: id, athanor_id: athanor_id) do
        nil -> {:error, :not_found}
        row -> {:ok, view(row)}
      end
    end)
  end

  def get(%Cyfr.Actor{}, id) when is_binary(id), do: {:error, :no_athanor}

  @doc "The living entry with this name in the actor's athanor, if any."
  @spec get_by_name(Cyfr.Actor.t(), String.t()) ::
          {:ok, entry()} | {:error, :not_found} | refusal()
  def get_by_name(%Cyfr.Actor{athanor_id: athanor_id}, name)
      when resolved(athanor_id) and is_binary(name) do
    Arca.Repo.Errors.with_db_rescue("Arca.VaultStorage.get_by_name", fn ->
      row =
        from(v in VaultEntry, where: v.name == ^name and v.status != "tombstoned")
        |> Arca.QueryHelpers.where_athanor(athanor_id)
        |> Arca.Repo.one()

      case row do
        nil -> {:error, :not_found}
        entry -> {:ok, view(entry)}
      end
    end)
  end

  def get_by_name(%Cyfr.Actor{}, name) when is_binary(name),
    do: {:error, :no_athanor}

  @doc "Living entries in the actor's athanor. `include_tombstoned: true` widens to all."
  @spec list(Cyfr.Actor.t(), keyword()) :: {:ok, [entry()]} | refusal()
  def list(actor, opts \\ [])

  def list(%Cyfr.Actor{athanor_id: athanor_id}, opts)
      when resolved(athanor_id) and is_list(opts) do
    Arca.Repo.Errors.with_db_rescue("Arca.VaultStorage.list", fn ->
      query =
        from(v in VaultEntry, order_by: v.name)
        |> Arca.QueryHelpers.where_athanor(athanor_id)

      query =
        if Keyword.get(opts, :include_tombstoned, false),
          do: query,
          else: where(query, [v], v.status != "tombstoned")

      {:ok, Enum.map(Arca.Repo.all(query), &view/1)}
    end)
  end

  def list(%Cyfr.Actor{}, opts) when is_list(opts), do: {:error, :no_athanor}

  @doc "Update the mutable label. Everything else has its own verb."
  @spec update_meta(Cyfr.Actor.t(), String.t(), %{name: String.t()}) ::
          :ok | {:error, :not_found} | refusal()
  def update_meta(%Cyfr.Actor{athanor_id: athanor_id}, id, %{name: name})
      when resolved(athanor_id) and is_binary(id) and is_binary(name) and name != "" do
    Arca.Repo.Errors.with_db_rescue("Arca.VaultStorage.update_meta", fn ->
      write(athanor_id, id, name: name, updated_at: now())
    end)
  end

  def update_meta(%Cyfr.Actor{}, id, %{name: name})
      when is_binary(id) and is_binary(name) and name != "",
      do: {:error, :no_athanor}

  @doc "Set the entry's status."
  @spec set_status(Cyfr.Actor.t(), String.t(), String.t()) ::
          :ok | {:error, :not_found} | refusal()
  def set_status(%Cyfr.Actor{athanor_id: athanor_id}, id, status)
      when resolved(athanor_id) and is_binary(id) and is_binary(status) do
    Arca.Repo.Errors.with_db_rescue("Arca.VaultStorage.set_status", fn ->
      write(athanor_id, id, status: status, updated_at: now())
    end)
  end

  def set_status(%Cyfr.Actor{}, id, status)
      when is_binary(id) and is_binary(status),
      do: {:error, :no_athanor}

  @doc """
  Tombstone an entry: status flip and material erasure in one update.
  The partial unique index ignores tombstoned rows, so the name is
  immediately reusable.
  """
  @spec tombstone(Cyfr.Actor.t(), String.t()) :: :ok | {:error, :not_found} | refusal()
  def tombstone(%Cyfr.Actor{athanor_id: athanor_id}, id)
      when resolved(athanor_id) and is_binary(id) do
    Arca.Repo.Errors.with_db_rescue("Arca.VaultStorage.tombstone", fn ->
      write(athanor_id, id, status: "tombstoned", sealed_payload: nil, updated_at: now())
    end)
  end

  def tombstone(%Cyfr.Actor{}, id) when is_binary(id), do: {:error, :no_athanor}

  @doc """
  Move a living entry's binding from the digest it was read at, and block
  every profile that depended on it, as ONE transaction.

  `changes` carries the binding columns (`field_names`, `oauth_endpoints`,
  `oauth_scopes`) and the recomputed `binding_digest`; `provider_hint` is
  absent by design — it sits in the AEAD AAD and is immutable per row. The
  write lands only while the row's `binding_digest` still reads
  `from_digest`, and every profile whose head consent references the entry
  takes `blocked_status` with it, so no consent is ever left covering a
  binding it did not approve.

  `{:error, :binding_moved}` when another change landed first or the entry
  is gone; the caller re-reads and recomputes. The answer on success is
  the profiles blocked.
  """
  @spec move_binding(Cyfr.Actor.t(), String.t(), String.t() | nil, map(), String.t()) ::
          {:ok, [String.t()]} | {:error, :binding_moved} | refusal()
  def move_binding(%Cyfr.Actor{athanor_id: athanor_id}, id, from_digest, changes, blocked_status)
      when resolved(athanor_id) and is_binary(id) and is_map(changes) and
             (is_binary(from_digest) or is_nil(from_digest)) and is_binary(blocked_status) do
    Arca.Repo.Errors.with_db_rescue("Arca.VaultStorage.move_binding", fn ->
      transact(fn ->
        rebind(athanor_id, id, %{
          from_digest: from_digest,
          changes: changes,
          blocked_status: blocked_status
        })
      end)
    end)
  end

  def move_binding(%Cyfr.Actor{}, id, from_digest, changes, blocked_status)
      when is_binary(id) and is_map(changes) and
             (is_binary(from_digest) or is_nil(from_digest)) and is_binary(blocked_status),
      do: {:error, :no_athanor}

  @doc """
  Replace the sealed payload iff `payload_rev` still equals `expected_rev`
  (compare-and-swap). The winning writer bumps the revision; a loser gets
  `{:error, :payload_conflict}` and must re-read.

  This is the bare compare-and-set, for the OAuth refresh write-back,
  which holds no other write and must hold no transaction across the
  provider's HTTP call. A material write that carries a status flip or a
  binding move with it goes through `commit_payload/3`.
  """
  @spec rotate_payload(Cyfr.Actor.t(), String.t(), non_neg_integer(), binary()) ::
          :ok | {:error, :payload_conflict} | refusal()
  def rotate_payload(%Cyfr.Actor{athanor_id: athanor_id}, id, expected_rev, sealed)
      when resolved(athanor_id) and is_binary(id) and is_integer(expected_rev) and
             expected_rev >= 0 and is_binary(sealed) do
    Arca.Repo.Errors.with_db_rescue("Arca.VaultStorage.rotate_payload", fn ->
      cas_payload(athanor_id, id, expected_rev, sealed)
    end)
  end

  def rotate_payload(%Cyfr.Actor{}, id, expected_rev, sealed)
      when is_binary(id) and is_integer(expected_rev) and expected_rev >= 0 and is_binary(sealed),
      do: {:error, :no_athanor}

  @doc """
  Write a new sealed payload, with the status flip and the binding move
  that belong to it, as ONE transaction.

  Both classes of material write come through here — an operator rotation,
  which replaces the material and may clear `needs_reauth`, and an OAuth
  grant commit, which may also move the binding the grant was issued
  against. They are one function because they are one guarantee: an entry
  is at its previous version or at its next one, never between. A rotate
  that fails part-way leaves nothing behind it.

  `plan`:

    * `:expected_rev` — the `payload_rev` the caller read; the write lands
      only while the row still reads it.
    * `:sealed_payload` — the ciphertext to store.
    * `:status` — a status to set with the write, or `nil`.
    * `:rebind` — `nil`, or `move_binding/5`'s three arguments as a map.

  The payload compare-and-set goes LAST. Inside one transaction the order
  of the writes is invisible to every other reader; what it decides is
  which writes a failure has to undo. The payload CAS is the step that
  loses a race, so putting it last means a lost race undoes the status
  flip and the binding move with it, and never the reverse.
  """
  @spec commit_payload(Cyfr.Actor.t(), String.t(), payload_plan()) ::
          {:ok, %{payload_rev: non_neg_integer(), affected: [String.t()]}}
          | {:error, :payload_conflict | :binding_moved}
          | refusal()
  def commit_payload(%Cyfr.Actor{athanor_id: athanor_id}, id, %{
        expected_rev: expected_rev,
        sealed_payload: sealed,
        status: status,
        rebind: rebind
      })
      when resolved(athanor_id) and is_binary(id) and is_integer(expected_rev) and
             expected_rev >= 0 and is_binary(sealed) and
             (is_binary(status) or is_nil(status)) and (is_map(rebind) or is_nil(rebind)) do
    Arca.Repo.Errors.with_db_rescue("Arca.VaultStorage.commit_payload", fn ->
      transact(fn ->
        with :ok <- maybe_status(athanor_id, id, status),
             {:ok, affected} <- maybe_rebind(athanor_id, id, rebind),
             :ok <- cas_payload(athanor_id, id, expected_rev, sealed) do
          {:ok, %{payload_rev: expected_rev + 1, affected: affected}}
        end
      end)
    end)
  end

  def commit_payload(%Cyfr.Actor{}, id, %{
        expected_rev: expected_rev,
        sealed_payload: sealed,
        status: status,
        rebind: rebind
      })
      when is_binary(id) and is_integer(expected_rev) and expected_rev >= 0 and
             is_binary(sealed) and (is_binary(status) or is_nil(status)) and
             (is_map(rebind) or is_nil(rebind)),
      do: {:error, :no_athanor}

  @doc "Mark an entry read now — bookkeeping, written behind by `Arca.RecordSink`."
  @spec touch_last_used(Cyfr.Actor.t(), String.t()) :: :ok | {:error, :no_athanor}
  def touch_last_used(%Cyfr.Actor{athanor_id: athanor_id}, id)
      when resolved(athanor_id) and is_binary(id) do
    Arca.RecordSink.enqueue({:vault_touch, athanor_id, id})
  end

  def touch_last_used(%Cyfr.Actor{}, id) when is_binary(id),
    do: {:error, :no_athanor}

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  # The row minus its tenant. The column is what every query filters on and
  # what the AEAD binds; it is not an answer, because a caller that read it
  # back could use a row it already holds to name the tenant of its next
  # call — which is the one thing the actor is here to decide.
  defp view(%VaultEntry{} = row) do
    %{
      id: row.id,
      name: row.name,
      kind: row.kind,
      provider_hint: row.provider_hint,
      provenance: row.provenance,
      field_names: row.field_names,
      binding_digest: row.binding_digest,
      oauth_endpoints: row.oauth_endpoints,
      oauth_scopes: row.oauth_scopes,
      status: row.status,
      payload_rev: row.payload_rev,
      sealed_payload: row.sealed_payload,
      last_used_at: row.last_used_at
    }
  end

  # `Arca.Repo.transaction/1` answers `{:ok, value}`; the statements here
  # answer `:ok`/`{:ok, value}`/`{:error, reason}` already, so a refusal is
  # rolled back and handed straight back to the caller with its own word.
  defp transact(fun) do
    case Arca.Repo.transaction(fn ->
           case fun.() do
             {:error, reason} -> Arca.Repo.rollback(reason)
             other -> other
           end
         end) do
      {:ok, {:ok, value}} -> {:ok, value}
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_status(_athanor_id, _id, nil), do: :ok

  defp maybe_status(athanor_id, id, status) when is_binary(status),
    do: write(athanor_id, id, status: status, updated_at: now())

  defp maybe_rebind(_athanor_id, _id, nil), do: {:ok, []}

  defp maybe_rebind(athanor_id, id, %{} = rebind), do: rebind(athanor_id, id, rebind)

  # The compare-and-set and the invalidation it implies. Callers reach it
  # through `move_binding/5` or `commit_payload/3`, both of which are
  # already inside a transaction — the two writes are never separable.
  defp rebind(athanor_id, id, %{
         from_digest: from_digest,
         changes: changes,
         blocked_status: blocked_status
       }) do
    with :ok <- cas_binding(athanor_id, id, from_digest, changes),
         {:ok, affected} <-
           Arca.ConsentStorage.head_profiles_referencing(
             Cyfr.Actor.in_athanor(athanor_id),
             id
           ),
         :ok <- block_profiles(athanor_id, affected, blocked_status) do
      {:ok, Enum.sort(affected)}
    end
  end

  defp block_profiles(athanor_id, profile_ids, blocked_status) do
    Enum.reduce_while(profile_ids, :ok, fn profile_id, :ok ->
      case Arca.ProfileStorage.set_status(
             Cyfr.Actor.in_athanor(athanor_id),
             profile_id,
             blocked_status
           ) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp cas_binding(athanor_id, id, from_digest, changes) do
    set =
      changes
      |> Map.take(@binding_keys)
      |> Map.to_list()
      |> Keyword.put(:updated_at, now())

    query =
      from(v in VaultEntry, where: v.id == ^id and v.status != "tombstoned")
      |> Arca.QueryHelpers.where_athanor(athanor_id)

    query =
      if is_nil(from_digest),
        do: from(v in query, where: is_nil(v.binding_digest)),
        else: from(v in query, where: v.binding_digest == ^from_digest)

    case Arca.Repo.update_all(query, set: set) do
      {1, _} -> :ok
      {0, _} -> {:error, :binding_moved}
    end
  end

  defp cas_payload(athanor_id, id, expected_rev, sealed) do
    query =
      from(v in VaultEntry, where: v.id == ^id and v.payload_rev == ^expected_rev)
      |> Arca.QueryHelpers.where_athanor(athanor_id)

    case Arca.Repo.update_all(query,
           set: [sealed_payload: sealed, payload_rev: expected_rev + 1, updated_at: now()]
         ) do
      {1, _} -> :ok
      {0, _} -> {:error, :payload_conflict}
    end
  end

  defp write(athanor_id, id, set) do
    query =
      from(v in VaultEntry, where: v.id == ^id)
      |> Arca.QueryHelpers.where_athanor(athanor_id)

    case Arca.Repo.update_all(query, set: set) do
      {1, _} -> :ok
      {0, _} -> {:error, :not_found}
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
