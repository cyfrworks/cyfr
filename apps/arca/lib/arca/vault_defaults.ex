# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.VaultDefaults do
  @moduledoc """
  An athanor's default entry per provider: the one a consent suggests
  when several entries of that provider would satisfy a need.

  One row per `(athanor_id, provider_hint)` (`vault_defaults`), naming
  one of the athanor's own vault entries (`vault_entry_id`, kept the
  athanor's by the composite key). Two athanors choose their defaults
  independently. Moving a default moves no existing consent.

  Every function takes the actor first and works on the actor's athanor;
  an actor whose athanor is not a resolved id is refused
  (`{:error, :no_athanor}`) before any query.

  `set/3` is one upsert on the unique key, so a provider never has two
  defaults: the entry it names is read under a lock in the same
  transaction, so a tombstone of that entry either lands first (and the
  set is refused `:not_found`) or waits and then removes the row it
  wrote. `Arca.VaultStorage.put/3` makes an athanor's first entry of a
  provider its default (`put_new!/3`, inside its transaction), and its
  `tombstone/2` removes every default naming the entry
  (`drop_entry!/2`).
  """

  import Ecto.Query

  alias Arca.Schemas.VaultDefault
  alias Arca.Schemas.VaultEntry

  @typedoc "One default as callers see it: the provider and the entry it names."
  @type default :: %{provider_hint: String.t(), vault_entry_id: String.t()}

  @typedoc "What a default names: one of the athanor's entries."
  @type target :: %{vault_entry_id: String.t()}

  @type refusal :: {:error, :no_athanor | :database_error}

  defguardp resolved(athanor_id) when is_binary(athanor_id) and athanor_id != ""
  defguardp provider(hint) when is_binary(hint) and hint != ""

  @doc "The actor's athanor's default for `provider_hint`."
  @spec get(Prima.Actor.t(), String.t()) :: {:ok, default()} | {:error, :not_found} | refusal()
  def get(%Prima.Actor{athanor_id: athanor_id}, provider_hint)
      when resolved(athanor_id) and provider(provider_hint) do
    Arca.Repo.Errors.with_db_rescue("Arca.VaultDefaults.get", fn ->
      case Arca.Repo.get_by(VaultDefault, athanor_id: athanor_id, provider_hint: provider_hint) do
        nil -> {:error, :not_found}
        row -> {:ok, view(row)}
      end
    end)
  end

  def get(%Prima.Actor{}, provider_hint) when provider(provider_hint), do: {:error, :no_athanor}

  @doc "Every default of the actor's athanor, by provider."
  @spec list(Prima.Actor.t()) :: {:ok, [default()]} | refusal()
  def list(%Prima.Actor{athanor_id: athanor_id}) when resolved(athanor_id) do
    Arca.Repo.Errors.with_db_rescue("Arca.VaultDefaults.list", fn ->
      rows =
        from(d in VaultDefault, order_by: d.provider_hint)
        |> Arca.QueryHelpers.where_athanor(athanor_id)
        |> Arca.Repo.all()

      {:ok, Enum.map(rows, &view/1)}
    end)
  end

  def list(%Prima.Actor{}), do: {:error, :no_athanor}

  @doc """
  Make `target` the actor's athanor's default for `provider_hint`, moving
  any default the provider had, in one upsert.

  `target` names `vault_entry_id`, a living entry of the actor's athanor,
  and nothing else; any other target is `{:error, :invalid_target}`, and
  an entry that is not living there `{:error, :not_found}`.
  """
  @spec set(Prima.Actor.t(), String.t(), target()) ::
          {:ok, default()} | {:error, :invalid_target | :not_found} | refusal()
  def set(%Prima.Actor{athanor_id: athanor_id}, provider_hint, target)
      when resolved(athanor_id) and provider(provider_hint) and is_map(target) do
    with {:ok, columns} <- target_columns(target) do
      Arca.Repo.Errors.with_db_rescue("Arca.VaultDefaults.set", fn ->
        Arca.Repo.locking_transaction(fn ->
          with :ok <- living(athanor_id, columns) do
            upsert!(athanor_id, provider_hint, columns)
          else
            {:error, reason} -> Arca.Repo.rollback(reason)
          end
        end)
      end)
    end
  end

  def set(%Prima.Actor{}, provider_hint, target) when provider(provider_hint) and is_map(target),
    do: {:error, :no_athanor}

  @doc "Remove the actor's athanor's default for `provider_hint`; `:ok` when it had none."
  @spec clear(Prima.Actor.t(), String.t()) :: :ok | refusal()
  def clear(%Prima.Actor{athanor_id: athanor_id}, provider_hint)
      when resolved(athanor_id) and provider(provider_hint) do
    Arca.Repo.Errors.with_db_rescue("Arca.VaultDefaults.clear", fn ->
      {_count, _} =
        from(d in VaultDefault, where: d.provider_hint == ^provider_hint)
        |> Arca.QueryHelpers.where_athanor(athanor_id)
        |> Arca.Repo.delete_all()

      :ok
    end)
  end

  def clear(%Prima.Actor{}, provider_hint) when provider(provider_hint), do: {:error, :no_athanor}

  @doc false
  # Inside `Arca.VaultStorage.put/3`'s transaction: the entry becomes its
  # provider's default unless the athanor already names one. One insert
  # that does nothing on the key; an entry naming no provider sets none.
  @spec put_new!(Prima.Actor.t(), String.t(), String.t()) :: :ok
  # arca:db-raise-ok a step inside the caller's transaction; a raise rolls it back.
  def put_new!(%Prima.Actor{athanor_id: athanor_id}, "", _entry_id) when resolved(athanor_id),
    do: :ok

  # arca:db-raise-ok a step inside the caller's transaction; a raise rolls it back.
  def put_new!(%Prima.Actor{athanor_id: athanor_id}, provider_hint, entry_id)
      when resolved(athanor_id) and provider(provider_hint) and is_binary(entry_id) do
    now = now()

    Arca.Repo.insert_all(
      VaultDefault,
      [
        %{
          id: Prima.UUID7.generate_id("vdf"),
          athanor_id: athanor_id,
          provider_hint: provider_hint,
          vault_entry_id: entry_id,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:athanor_id, :provider_hint]
    )

    :ok
  end

  @doc false
  # Inside `Arca.VaultStorage.tombstone/2`'s transaction: no default of the
  # athanor names an entry that is gone.
  @spec drop_entry!(Prima.Actor.t(), String.t()) :: :ok
  # arca:db-raise-ok a step inside the caller's transaction; a raise rolls it back.
  def drop_entry!(%Prima.Actor{athanor_id: athanor_id}, entry_id)
      when resolved(athanor_id) and is_binary(entry_id) do
    {_count, _} =
      from(d in VaultDefault, where: d.vault_entry_id == ^entry_id)
      |> Arca.QueryHelpers.where_athanor(athanor_id)
      |> Arca.Repo.delete_all()

    :ok
  end

  # ---------------------------------------------------------------------------

  defp target_columns(%{vault_entry_id: id} = target)
       when is_binary(id) and id != "" and map_size(target) == 1,
       do: {:ok, %{vault_entry_id: id}}

  defp target_columns(_target), do: {:error, :invalid_target}

  # The entry named is read under a lock, so a tombstone of it serializes
  # with this write: one that committed first is seen here, and one that
  # starts later waits and then removes the row written.
  defp living(athanor_id, %{vault_entry_id: id}) when is_binary(id) do
    from(v in VaultEntry, where: v.id == ^id and v.status != "tombstoned", select: v.id)
    |> Arca.QueryHelpers.where_athanor(athanor_id)
    |> Arca.QueryHelpers.for_update()
    |> Arca.Repo.one()
    |> found()
  end

  defp found(nil), do: {:error, :not_found}
  defp found(_id), do: :ok

  # One statement: insert, or move the provider's existing default.
  defp upsert!(athanor_id, provider_hint, columns) do
    now = now()

    row =
      Map.merge(columns, %{
        id: Prima.UUID7.generate_id("vdf"),
        athanor_id: athanor_id,
        provider_hint: provider_hint,
        inserted_at: now,
        updated_at: now
      })

    {1, _} =
      Arca.Repo.insert_all(VaultDefault, [row],
        on_conflict: {:replace, [:vault_entry_id, :updated_at]},
        conflict_target: [:athanor_id, :provider_hint]
      )

    %{provider_hint: provider_hint, vault_entry_id: columns.vault_entry_id}
  end

  defp view(%VaultDefault{} = row),
    do: %{provider_hint: row.provider_hint, vault_entry_id: row.vault_entry_id}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
