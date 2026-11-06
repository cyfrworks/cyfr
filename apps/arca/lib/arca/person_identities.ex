# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.PersonIdentities do
  @moduledoc """
  A person's identity at this home (`Arca.Schemas.PersonIdentity`): one
  row beside each person row, the account they were admitted by: its
  identifier, the directory that orders it and the head this home last
  read (`ARCHITECTURE.md` §9.1). This home holds no key of theirs. The
  head moves with the cached head's advance (`Arca.DirectoryHeads`), in
  its transaction.

  ## Who reads

  Every function takes the actor first. A person reads their own row (an
  actor whose `user_id` is theirs); the platform's own actor reads any.
  `lookup_identifier/2` is the door's read of an identifier before any
  session exists, which only the platform's actor makes. Refusals are
  `:not_found`, `:cross_tenant`, `:conflict` (a person already has a row,
  or the identifier is another person's), `{:invalid, errors}`,
  `:not_owner` (a member that no longer owns its slot) and
  `:database_error`. Rows are plain maps (`Arca.Data`).
  """

  import Ecto.Query

  alias Arca.Schemas.PersonIdentity

  # A write that widens what a person may sign: its transaction first proves
  # this member still owns its slot on the database's clock
  # (`Arca.Repo.owned/2`), so a stale owner writes nothing.

  @typedoc "A person's identity row, as a plain map."
  @type row :: map()

  @doc """
  Write a person's identity row: `attrs` names the `:user_id`, the
  `:provenance` `"remote"`, the account's `:identifier`, the
  `:directory_url` of its genesis and the `:head_hash` this home read.

  Written once per person: a second row is `{:error, :conflict}`. Runs in
  its own locking transaction, nested in a caller's (the `also:` closure
  an admission passes `Arca.Users.mint/4`), and proves this member still
  owns its slot first.
  """
  @spec create(Prima.Actor.t(), map()) ::
          {:ok, row()}
          | {:error, :conflict | :cross_tenant | :not_owner | :database_error | {:invalid, map()}}
  def create(%Prima.Actor{scope: :platform}, attrs) when is_map(attrs) do
    with {:ok, row} <- build(Map.new(attrs)) do
      Arca.Repo.owned("Arca.PersonIdentities.create", fn -> insert(row) end)
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
  Whether the first-method latch of the person `user_id` is still open: no
  fresh confirmation method, a passkey or a paired device, has ever
  existed for them, and the mark `first_method!/1` writes once and for
  good is unset. The person's row is locked first, as every write that
  sets the mark holds it, so inside a caller's transaction the answer
  stands until that transaction ends. A person with no identity row holds
  no method and reads open. The actor reads as `get/2` does.
  """
  @spec first_method_open?(Prima.Actor.t(), String.t()) ::
          {:ok, boolean()} | {:error, :cross_tenant | :database_error}
  def first_method_open?(%Prima.Actor{} = actor, user_id)
      when is_binary(user_id) and user_id != "" do
    if reads?(actor, user_id) do
      Arca.Repo.Errors.with_db_rescue("Arca.PersonIdentities.first_method_open?", fn ->
        Arca.Repo.locking_transaction(fn ->
          _locked = Arca.DirectoryHeads.lock_person!(user_id)

          not Arca.Repo.exists?(
            from(p in PersonIdentity,
              where: p.user_id == ^user_id and not is_nil(p.first_method_at)
            )
          )
        end)
      end)
    else
      {:error, :cross_tenant}
    end
  end

  def first_method_open?(%Prima.Actor{}, _user_id), do: {:error, :cross_tenant}

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

  defp build(%{provenance: "remote"} = attrs) do
    errors =
      []
      |> required(attrs, :user_id, &(is_binary(&1) and &1 != ""))
      |> required(attrs, :identifier, &Prima.Identity.Encoding.identifier?/1)
      |> required(attrs, :directory_url, &Prima.Identity.Encoding.directory_url?/1)
      |> required(attrs, :head_hash, &Prima.Identity.Encoding.digest?/1)

    row(errors, attrs, %{
      provenance: "remote",
      enrollment: "enrolled",
      identifier: attrs[:identifier],
      directory_url: attrs[:directory_url],
      head_hash: attrs[:head_hash]
    })
  end

  defp build(_attrs), do: {:error, {:invalid, %{provenance: ["is remote"]}}}

  defp row([], attrs, fields) do
    now = DateTime.utc_now()

    {:ok,
     Map.merge(
       %{
         id: Prima.UUID7.generate_id("pid"),
         user_id: attrs.user_id,
         identifier: nil,
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

  defp found(nil), do: {:error, :not_found}
  defp found(%PersonIdentity{} = row), do: {:ok, row}
end
