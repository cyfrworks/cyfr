# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.VaultStorage do
  @moduledoc """
  Persistence mechanics for vault entries. Sealing, binding-digest
  derivation and every consent semantic live in the `Sanctum.*` layer —
  `sealed_payload` arrives encrypted and leaves encrypted.

  Every id-keyed row filter carries the owning athanor, so an entry id
  learned in one athanor cannot resolve, mutate, or decrypt in another.
  """

  import Ecto.Query

  require Arca.Repo.Errors
  require Logger

  alias Arca.Schemas.VaultEntry

  @spec put(map()) :: {:ok, VaultEntry.t()} | {:error, term()}
  def put(attrs) when is_map(attrs) do
    _ = Map.fetch!(attrs, :athanor_id)
    row = Map.put_new(attrs, :id, Emissary.UUID7.generate_id("vlt"))

    struct(VaultEntry, row)
    |> Arca.Repo.insert()
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.VaultStorage] put failed: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @spec get(String.t(), String.t()) :: {:ok, VaultEntry.t()} | {:error, :not_found}
  def get(athanor_id, id) do

    case Arca.Repo.get_by(VaultEntry, id: id, athanor_id: athanor_id) do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.VaultStorage] get failed: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc "The living entry with this name in an athanor, if any."
  @spec get_by_name(String.t(), String.t()) :: {:ok, VaultEntry.t()} | {:error, :not_found}
  def get_by_name(athanor_id, name) do

    row =
      Arca.Repo.one(
        from v in VaultEntry,
          where: v.athanor_id == ^athanor_id and v.name == ^name and v.status != "tombstoned"
      )

    case row do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.VaultStorage] get_by_name failed: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc "Living entries in an athanor. `include_tombstoned: true` widens to all."
  @spec list(String.t(), keyword()) :: {:ok, [VaultEntry.t()]} | {:error, term()}
  def list(athanor_id, opts \\ []) do

    query =
      from v in VaultEntry,
        where: v.athanor_id == ^athanor_id,
        order_by: v.name

    query =
      if Keyword.get(opts, :include_tombstoned, false),
        do: query,
        else: where(query, [v], v.status != "tombstoned")

    {:ok, Arca.Repo.all(query)}
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.VaultStorage] list failed: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc "Update the mutable label. Everything else has its own verb."
  @spec update_meta(String.t(), String.t(), %{name: String.t()}) :: :ok | {:error, term()}
  def update_meta(athanor_id, id, %{name: name}) when is_binary(name) and name != "" do

    case Arca.Repo.update_all(
           from(v in VaultEntry, where: v.id == ^id and v.athanor_id == ^athanor_id),
           set: [name: name, updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)]
         ) do
      {1, _} -> :ok
      {0, _} -> {:error, :not_found}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.VaultStorage] update_meta failed: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @spec set_status(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def set_status(athanor_id, id, status) when is_binary(status) do

    case Arca.Repo.update_all(
           from(v in VaultEntry, where: v.id == ^id and v.athanor_id == ^athanor_id),
           set: [
             status: status,
             updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
           ]
         ) do
      {1, _} -> :ok
      {0, _} -> {:error, :not_found}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.VaultStorage] set_status failed: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  Tombstone an entry: status flip and material erasure in one update.
  The partial unique index ignores tombstoned rows, so the name is
  immediately reusable.
  """
  @spec tombstone(String.t(), String.t()) :: :ok | {:error, term()}
  def tombstone(athanor_id, id) do

    case Arca.Repo.update_all(
           from(v in VaultEntry, where: v.id == ^id and v.athanor_id == ^athanor_id),
           set: [
             status: "tombstoned",
             sealed_payload: nil,
             updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
           ]
         ) do
      {1, _} -> :ok
      {0, _} -> {:error, :not_found}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.VaultStorage] tombstone failed: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  Update the binding fields (`field_names`, `oauth_endpoints`,
  `oauth_scopes`) plus the cached `binding_digest`. `provider_hint` is
  absent by design — it sits in the AEAD AAD and is immutable per row.
  """
  @spec update_binding(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def update_binding(athanor_id, id, changes) when is_map(changes) do

    set =
      changes
      |> Map.take([:field_names, :oauth_endpoints, :oauth_scopes, :binding_digest, :status])
      |> Map.to_list()
      |> Keyword.put(:updated_at, DateTime.utc_now() |> DateTime.truncate(:microsecond))

    case Arca.Repo.update_all(
           from(v in VaultEntry, where: v.id == ^id and v.athanor_id == ^athanor_id),
           set: set
         ) do
      {1, _} -> :ok
      {0, _} -> {:error, :not_found}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.VaultStorage] update_binding failed: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  Replace the sealed payload iff `payload_rev` still equals `expected_rev`
  (compare-and-swap). The winning writer bumps the revision; a loser gets
  `{:error, :payload_conflict}` and must re-read.
  """
  @spec rotate_payload(String.t(), String.t(), non_neg_integer(), binary()) ::
          :ok | {:error, :payload_conflict}
  def rotate_payload(athanor_id, id, expected_rev, sealed)
      when is_integer(expected_rev) and is_binary(sealed) do

    result =
      Arca.Repo.update_all(
        from(v in VaultEntry,
          where: v.id == ^id and v.athanor_id == ^athanor_id and v.payload_rev == ^expected_rev
        ),
        set: [
          sealed_payload: sealed,
          payload_rev: expected_rev + 1,
          updated_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
        ]
      )

    case result do
      {1, _} -> :ok
      {0, _} -> {:error, :payload_conflict}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.VaultStorage] rotate_payload failed: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @spec touch_last_used(String.t(), String.t()) :: :ok
  def touch_last_used(athanor_id, id) do

    Arca.Repo.update_all(
      from(v in VaultEntry, where: v.id == ^id and v.athanor_id == ^athanor_id),
      set: [last_used_at: DateTime.utc_now()]
    )

    :ok
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[Arca.VaultStorage] touch_last_used failed: #{Exception.message(e)}")
      :ok
  end
end
