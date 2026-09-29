# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.PersonIdentities do
  @moduledoc """
  A person's identity at this home (`Arca.Schemas.PersonIdentity`): one
  row beside each person row, carrying the identifier once they are
  enrolled or admitted, their provenance, and for a local person the live
  and operational key pairs, the private halves sealed under the person's
  own frame.

  ## Provenance

  `local` rows hold the key set this home minted at the person's first
  admitted sign-in, and no identifier until enrollment is accepted
  (`Arca.IdentityAttempts`). `remote` rows hold the identifier and the
  directory another home enrolled the person at, and no key. Provenance is
  written once and never changes, whatever door the person later uses.

  ## Who reads

  Every function takes the actor first. A person reads their own row (an
  actor whose `user_id` is theirs); the platform's own actor reads any.
  `lookup_identifier/2` is the door's read of an identifier before any
  session exists, which only the platform's actor makes. Refusals are
  `:not_found`, `:cross_tenant`, `:conflict` (a person already has a row,
  or the identifier is another person's), `{:invalid, errors}`,
  `:not_owner` (a member that no longer owns its slot) and
  `:database_error`. Rows are plain maps (`Arca.Data`), sealed bytes
  included: only the caller that sealed them can open them.
  """

  import Ecto.Query

  alias Arca.Schemas.PersonIdentity

  @key_bytes 32

  @typedoc "A person's identity row, as a plain map."
  @type row :: map()

  @doc """
  Write a person's identity row. `attrs` names the `:user_id` and the
  `:provenance`:

    * `"local"` — `:live_public_key`, `:operational_public_key` (distinct
      32-byte Ed25519 keys) and their sealed private halves
      `:live_key_sealed` and `:operational_key_sealed`. Unenrolled, with
      no identifier, at a first sign-in; enrolled when a restore mints the
      person, with the `:identifier`, the `:head_hash` its keys belong to,
      the `:directory_url` and optionally the `:genesis_hash`.
    * `"remote"` — the `:identifier`, the `:directory_url` of its genesis
      and optionally its `:genesis_hash` and `:head_hash`; no key.

  Written once per person: a second row is `{:error, :conflict}`. Runs in
  its own locking transaction, nested in a caller's (the `also:` closure a
  first sign-in passes `Arca.Users.mint/4`), and proves this member still
  owns its slot first.
  """
  @spec create(Prima.Actor.t(), map()) ::
          {:ok, row()}
          | {:error, :conflict | :cross_tenant | :not_owner | :database_error | {:invalid, map()}}
  def create(%Prima.Actor{scope: :platform}, attrs) when is_map(attrs) do
    with {:ok, row} <- build(Map.new(attrs)) do
      Arca.Repo.Errors.with_db_rescue("Arca.PersonIdentities.create", fn ->
        fenced(fn -> insert(row) end)
      end)
      |> Arca.Data.project()
    end
  end

  def create(%Prima.Actor{}, _attrs), do: {:error, :cross_tenant}

  @doc "The identity row of the person `user_id`: their own, or any for the platform's actor."
  @spec get(Prima.Actor.t(), String.t()) ::
          {:ok, row()} | {:error, :not_found | :cross_tenant | :database_error}
  def get(%Prima.Actor{} = actor, user_id) when is_binary(user_id) and user_id != "" do
    if reads?(actor, user_id) do
      Arca.Repo.Errors.with_db_rescue("Arca.PersonIdentities.get", fn ->
        found(Arca.Repo.one(from(p in PersonIdentity, where: p.user_id == ^user_id)))
      end)
      |> Arca.Data.project()
    else
      {:error, :cross_tenant}
    end
  end

  def get(%Prima.Actor{}, _user_id), do: {:error, :not_found}

  @doc """
  The identity row an identifier names, for the door before any person or
  session exists: only the platform's own actor asks.
  """
  @spec lookup_identifier(Prima.Actor.t(), String.t()) ::
          {:ok, row()} | {:error, :not_found | :cross_tenant | :database_error}
  # arca:unscoped-ok the door resolves an identifier to its person before any
  # session exists: the identifier is the only key there is, and the platform's
  # actor matched in the head is the only one that asks.
  def lookup_identifier(%Prima.Actor{scope: :platform}, identifier) when is_binary(identifier) do
    Arca.Repo.Errors.with_db_rescue("Arca.PersonIdentities.lookup_identifier", fn ->
      found(Arca.Repo.one(from(p in PersonIdentity, where: p.identifier == ^identifier)))
    end)
    |> Arca.Data.project()
  end

  def lookup_identifier(%Prima.Actor{}, _identifier), do: {:error, :cross_tenant}

  # ---- steps inside another store's transaction --------------------------------

  @doc false
  @spec enrolling!(String.t()) :: non_neg_integer()
  # A local person's enrollment opens: `none` → `pending`, in the caller's
  # transaction (`Arca.IdentityAttempts`). Answers the count it moved.
  # arca:db-raise-ok a transaction step: its caller rescues around the transaction.
  def enrolling!(user_id) do
    step(
      from(p in PersonIdentity,
        where:
          p.user_id == ^user_id and p.provenance == "local" and p.enrollment == "none" and
            is_nil(p.identifier)
      ),
      enrollment: "pending"
    )
  end

  @doc false
  @spec unenrolled!(String.t()) :: non_neg_integer()
  # A refused enrollment returns the person to `none`.
  # arca:db-raise-ok a transaction step: its caller rescues around the transaction.
  def unenrolled!(user_id) do
    step(
      from(p in PersonIdentity,
        where: p.user_id == ^user_id and p.enrollment == "pending" and is_nil(p.identifier)
      ),
      enrollment: "none"
    )
  end

  @doc false
  @spec enrolled!(String.t(), map()) :: non_neg_integer()
  # An accepted enrollment writes the identifier, the genesis and head it
  # names and the directory it is registered at: `pending` → `enrolled`.
  # arca:db-raise-ok a transaction step: its caller rescues around the transaction.
  def enrolled!(user_id, %{identifier: identifier} = facts) do
    step(
      from(p in PersonIdentity,
        where:
          p.user_id == ^user_id and p.provenance == "local" and p.enrollment == "pending" and
            is_nil(p.identifier)
      ),
      enrollment: "enrolled",
      identifier: identifier,
      genesis_hash: facts.genesis_hash,
      head_hash: facts.head_hash,
      directory_url: facts.directory_url
    )
  end

  @doc false
  @spec activate_keys!(String.t(), String.t(), keyword()) :: non_neg_integer()
  # A rotation or recovery activates staged keys: the live key (and, for a
  # recovery, the operational key) replaced and the head moved, only while
  # the row still reads the head the attempt extended.
  # arca:db-raise-ok a transaction step: its caller rescues around the transaction.
  def activate_keys!(user_id, expected_head, set) when is_list(set) do
    step(
      from(p in PersonIdentity,
        where: p.user_id == ^user_id and p.provenance == "local" and p.head_hash == ^expected_head
      ),
      set
    )
  end

  @doc false
  @spec first_method!(String.t()) :: :marked | :already | :no_identity
  # Record, once and for good, that a fresh confirmation method exists for
  # the person: nothing clears the mark, so revoking every method never
  # reopens a first-method exception. Answers `:marked` when this call set
  # it, `:already` when a method existed before, and `:no_identity` for a
  # person with no row.
  # arca:db-raise-ok a transaction step: its caller rescues around the transaction.
  def first_method!(user_id) do
    now = Arca.ServerMetaStorage.now!()
    unset = from(p in PersonIdentity, where: p.user_id == ^user_id and is_nil(p.first_method_at))

    cond do
      step(unset, first_method_at: now) == 1 -> :marked
      Arca.Repo.exists?(from(p in PersonIdentity, where: p.user_id == ^user_id)) -> :already
      true -> :no_identity
    end
  end

  # ---- internals -------------------------------------------------------------

  defp reads?(%Prima.Actor{scope: :platform}, _user_id), do: true
  defp reads?(%Prima.Actor{user_id: user_id}, user_id), do: true
  defp reads?(%Prima.Actor{}, _user_id), do: false

  defp insert(row) do
    case Arca.Repo.insert_all(PersonIdentity, [row], on_conflict: :nothing) do
      {1, _} -> {:ok, Arca.Repo.get!(PersonIdentity, row.id)}
      {0, _} -> {:error, :conflict}
    end
  end

  # One conditional statement over the row it names, raising the row's
  # revision; the count is its evidence.
  defp step(query, set) do
    now = Arca.ServerMetaStorage.now!()

    {count, _} =
      Arca.Repo.update_all(query, set: Keyword.put(set, :updated_at, now), inc: [revision: 1])

    count
  end

  defp build(%{provenance: "local"} = attrs) do
    errors =
      []
      |> required(attrs, :user_id, &(is_binary(&1) and &1 != ""))
      |> required(attrs, :live_public_key, &key?/1)
      |> required(attrs, :operational_public_key, &key?/1)
      |> required(attrs, :live_key_sealed, &sealed?/1)
      |> required(attrs, :operational_key_sealed, &sealed?/1)
      |> distinct_keys(attrs)
      |> local_identity(attrs)

    enrolled? = not is_nil(attrs[:identifier])

    row(errors, attrs, %{
      provenance: "local",
      enrollment: if(enrolled?, do: "enrolled", else: "none"),
      live_public_key: attrs[:live_public_key],
      operational_public_key: attrs[:operational_public_key],
      live_key_sealed: attrs[:live_key_sealed],
      operational_key_sealed: attrs[:operational_key_sealed],
      identifier: attrs[:identifier],
      genesis_hash: if(enrolled?, do: attrs[:genesis_hash]),
      head_hash: if(enrolled?, do: attrs[:head_hash]),
      directory_url: if(enrolled?, do: attrs[:directory_url])
    })
  end

  defp build(%{provenance: "remote"} = attrs) do
    errors =
      []
      |> required(attrs, :user_id, &(is_binary(&1) and &1 != ""))
      |> required(attrs, :identifier, &Prima.Identity.Encoding.identifier?/1)
      |> required(attrs, :directory_url, &Prima.Identity.Encoding.directory_url?/1)
      |> optional(attrs, :genesis_hash, &Prima.Identity.Encoding.digest?/1)
      |> optional(attrs, :head_hash, &Prima.Identity.Encoding.digest?/1)
      |> absent(attrs, [
        :live_public_key,
        :operational_public_key,
        :live_key_sealed,
        :operational_key_sealed
      ])

    row(errors, attrs, %{
      provenance: "remote",
      enrollment: "enrolled",
      identifier: attrs[:identifier],
      directory_url: attrs[:directory_url],
      genesis_hash: attrs[:genesis_hash],
      head_hash: attrs[:head_hash]
    })
  end

  defp build(_attrs), do: {:error, {:invalid, %{provenance: ["is local or remote"]}}}

  defp row([], attrs, fields) do
    now = DateTime.utc_now()

    {:ok,
     Map.merge(
       %{
         id: Prima.UUID7.generate_id("pid"),
         user_id: attrs.user_id,
         identifier: nil,
         genesis_hash: nil,
         head_hash: nil,
         first_method_at: nil,
         revision: 1,
         inserted_at: now,
         updated_at: now
       },
       fields
     )}
  end

  defp row(errors, _attrs, _fields), do: {:error, {:invalid, Map.new(errors)}}

  defp required(errors, attrs, field, valid?) do
    if valid?.(Map.get(attrs, field)), do: errors, else: [{field, ["is required"]} | errors]
  end

  defp optional(errors, attrs, field, valid?) do
    case Map.get(attrs, field) do
      nil -> errors
      value -> if valid?.(value), do: errors, else: [{field, ["is malformed"]} | errors]
    end
  end

  defp absent(errors, attrs, fields) do
    Enum.reduce(fields, errors, fn field, acc ->
      if is_nil(Map.get(attrs, field)),
        do: acc,
        else: [{field, ["is not this provenance's"]} | acc]
    end)
  end

  # A local person is written unenrolled at their first sign-in, or already
  # enrolled when a restore mints them: then with the identifier, the head
  # the restored keys belong to and the directory, and never one without
  # the others.
  defp local_identity(errors, %{identifier: identifier} = attrs) when not is_nil(identifier) do
    errors
    |> required(attrs, :identifier, &Prima.Identity.Encoding.identifier?/1)
    |> required(attrs, :head_hash, &Prima.Identity.Encoding.digest?/1)
    |> required(attrs, :directory_url, &Prima.Identity.Encoding.directory_url?/1)
    |> optional(attrs, :genesis_hash, &Prima.Identity.Encoding.digest?/1)
  end

  defp local_identity(errors, attrs),
    do: absent(errors, attrs, [:genesis_hash, :head_hash, :directory_url])

  defp distinct_keys(errors, %{live_public_key: live, operational_public_key: live})
       when is_binary(live),
       do: [{:operational_public_key, ["must differ from the live key"]} | errors]

  defp distinct_keys(errors, _attrs), do: errors

  defp key?(value), do: is_binary(value) and byte_size(value) == @key_bytes
  defp sealed?(value), do: is_binary(value) and value != ""

  defp found(nil), do: {:error, :not_found}
  defp found(%PersonIdentity{} = row), do: {:ok, row}

  # A write that widens what a person may sign: its transaction first proves
  # this member still owns its slot on the database's clock
  # (`Arca.ControlPlane.verify_held/1`), so a stale owner writes nothing.
  defp fenced(write) do
    with {:ok, slot} <- Arca.ControlPlane.member_slot() do
      Arca.Repo.locking_transaction(fn ->
        case Arca.ControlPlane.verify_held(slot) do
          :ok -> committed(write.())
          :lost -> Arca.Repo.rollback(:not_owner)
        end
      end)
    end
  end

  defp committed({:ok, value}), do: value
  defp committed({:error, reason}), do: Arca.Repo.rollback(reason)
end
