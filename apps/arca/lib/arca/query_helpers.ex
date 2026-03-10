defmodule Arca.QueryHelpers do
  @moduledoc """
  Shared Ecto query helpers for Arca storage modules.
  """

  import Ecto.Query

  @doc """
  Normalize nil org_id to empty string sentinel.

  SQLite treats NULL != NULL in unique indexes, so we use "" as sentinel
  for nil org_id to ensure conflict detection works correctly.
  """
  @spec normalize_org_id(String.t() | nil) :: String.t()
  def normalize_org_id(nil), do: ""
  def normalize_org_id(org_id), do: org_id

  @doc """
  Add org_id filter to an Ecto query, using the empty string sentinel for nil.
  """
  @spec where_org_id(Ecto.Queryable.t(), String.t() | nil) :: Ecto.Query.t()
  def where_org_id(query, nil) do
    from(q in query, where: q.org_id == "")
  end

  def where_org_id(query, org_id) do
    from(q in query, where: q.org_id == ^org_id)
  end

  @doc """
  Conditionally add a key-value pair to a keyword list.
  Returns the keyword list unchanged if the value is nil.
  """
  @spec maybe_put(keyword(), atom(), any()) :: keyword()
  def maybe_put(opts, _key, nil), do: opts
  def maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
