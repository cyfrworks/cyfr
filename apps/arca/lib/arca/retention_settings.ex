# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.RetentionSettings do
  @moduledoc """
  The retention values an athanor has set: one `retention_settings` row
  per athanor (`Arca.Schemas.RetentionSettings`), apart from the
  security-owned settings document on the athanor row.

  The row holds only the keys the athanor chose, each a positive integer,
  as the RFC 8785 encoding of a string-keyed map. A key never set is
  absent from it; `Arca.Retention` fills the defaults on read. An athanor
  with no row has set nothing: `get/1` answers the empty patch at
  revision 0.

  ## Concurrent patches

  `patch/2` reads the row, merges its keys over the patch it read and
  writes the result only while the row still holds the revision it read
  (a first row is inserted only while none exists). A patch that finds
  the row moved on reads it again and merges again, so two patches of
  different keys both land, each raising the revision by one. After
  three such retries it answers `{:error, :settings_conflict}` rather
  than write over a patch it never read.

  ## Corruption

  Every value drives destructive cleanup, so a document that cannot be
  read as the athanor wrote it is `{:error, :corrupt}`, never the
  defaults: a stored document that is not a JSON object, or a roster key
  whose value is not a positive integer. A key outside the roster is
  ignored, and the next patch drops it.

  ## Tenancy

  Every function takes the `Prima.Actor` first and refuses one with no
  athanor as `{:error, :no_athanor}` before any query. A store that
  cannot answer is `{:error, :database_error}`.
  """

  import Ecto.Query, only: [from: 2]
  import Arca.QueryHelpers, only: [where_athanor: 2]

  alias Arca.Schemas.RetentionSettings, as: Row

  @retries 3

  @typedoc "The keys an athanor has set, and the revision of the row that holds them."
  @type stored :: %{patch: %{String.t() => pos_integer()}, revision: non_neg_integer()}

  @doc """
  The athanor's patch and the revision of its row: `%{patch: %{}, revision:
  0}` when it has none.
  """
  @spec get(Prima.Actor.t()) ::
          {:ok, stored()} | {:error, :no_athanor | :corrupt | :database_error}
  def get(%Prima.Actor{} = actor) do
    with {:ok, athanor} <- tenant(actor),
         {:ok, row} <- read(athanor) do
      decode(row)
    end
  end

  @doc """
  Merge `changes` — retention keys to positive integers, validated by the
  caller (`Arca.Retention.set_settings/2`) — over the athanor's patch,
  answering the merged patch and the revision it landed at.
  """
  @spec patch(Prima.Actor.t(), %{String.t() => pos_integer()}) ::
          {:ok, stored()}
          | {:error, :no_athanor | :corrupt | :database_error | :settings_conflict}
  def patch(%Prima.Actor{} = actor, changes) when is_map(changes) do
    with {:ok, athanor} <- tenant(actor) do
      merge(athanor, changes, @retries)
    end
  end

  defp merge(athanor, changes, retries) do
    with {:ok, row} <- read(athanor),
         {:ok, %{patch: current, revision: revision}} <- decode(row) do
      merged = Map.merge(current, changes)

      case write(athanor, merged, revision) do
        :written -> {:ok, %{patch: merged, revision: revision + 1}}
        :moved when retries > 0 -> merge(athanor, changes, retries - 1)
        :moved -> {:error, :settings_conflict}
        {:error, :database_error} = unavailable -> unavailable
      end
    end
  end

  defp read(athanor) do
    Arca.Repo.Errors.with_db_rescue("Arca.RetentionSettings.read", fn ->
      {:ok, Arca.Repo.one(from(r in where_athanor(Row, athanor), select: r))}
    end)
  end

  # A first row only while none exists, and a later one only while it
  # still holds the revision the merge read: either statement changes no
  # row when another patch landed first, and the merge is read again.
  defp write(athanor, merged, 0) do
    {:ok, settings} = Prima.JCS.encode(merged)
    now = DateTime.utc_now()

    Arca.Repo.Errors.with_db_rescue("Arca.RetentionSettings.write", fn ->
      row = %{
        athanor_id: athanor,
        settings: settings,
        revision: 1,
        inserted_at: now,
        updated_at: now
      }

      case Arca.Repo.insert_all(Row, [row], on_conflict: :nothing) do
        {1, _} -> :written
        {0, _} -> :moved
      end
    end)
  end

  defp write(athanor, merged, revision) do
    {:ok, settings} = Prima.JCS.encode(merged)

    Arca.Repo.Errors.with_db_rescue("Arca.RetentionSettings.write", fn ->
      from(r in where_athanor(Row, athanor), where: r.revision == ^revision)
      |> Arca.Repo.update_all(
        set: [settings: settings, revision: revision + 1, updated_at: DateTime.utc_now()]
      )
      |> case do
        {1, _} -> :written
        {0, _} -> :moved
      end
    end)
  end

  defp decode(nil), do: {:ok, %{patch: %{}, revision: 0}}

  defp decode(%Row{settings: settings, revision: revision}) do
    with {:ok, %{} = document} <- Jason.decode(settings),
         {:ok, patch} <- roster_values(document) do
      {:ok, %{patch: patch, revision: revision}}
    else
      _unreadable -> {:error, :corrupt}
    end
  end

  # The roster keys the document holds, each a positive integer; any other
  # key is ignored here and gone after the next patch.
  defp roster_values(document) do
    Enum.reduce_while(Arca.Retention.kinds(), {:ok, %{}}, fn kind, {:ok, patch} ->
      case Map.fetch(document, kind.key()) do
        {:ok, value} when is_integer(value) and value > 0 ->
          {:cont, {:ok, Map.put(patch, kind.key(), value)}}

        {:ok, _not_a_value} ->
          {:halt, :corrupt}

        :error ->
          {:cont, {:ok, patch}}
      end
    end)
  end

  defp tenant(%Prima.Actor{athanor_id: id}) when is_binary(id) and id != "", do: {:ok, id}
  defp tenant(%Prima.Actor{}), do: {:error, :no_athanor}
end
