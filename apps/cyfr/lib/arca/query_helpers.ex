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
  Scope a query to the tenant identified by the given context.

  Applies both `org_id` and `project_id` filters by default.
  Pass `skip_project: true` to filter by org_id only.
  """
  @spec where_tenant(Ecto.Queryable.t(), Sanctum.Context.t(), keyword()) :: Ecto.Query.t()
  def where_tenant(query, %Sanctum.Context{} = ctx, opts \\ []) do
    query = where_org_id(query, ctx.org_id)

    if Keyword.get(opts, :skip_project, false) do
      query
    else
      where_project_id(query, ctx.project_id)
    end
  end

  @doc """
  Add project_id filter to an Ecto query, using "default" sentinel for nil.
  """
  @spec where_project_id(Ecto.Queryable.t(), String.t() | nil) :: Ecto.Query.t()
  def where_project_id(query, nil) do
    from(q in query, where: q.project_id == "default")
  end

  def where_project_id(query, project_id) do
    from(q in query, where: q.project_id == ^project_id)
  end

  @doc """
  Conditionally add a key-value pair to a keyword list.
  Returns the keyword list unchanged if the value is nil.
  """
  @spec maybe_put(keyword(), atom(), any()) :: keyword()
  def maybe_put(opts, _key, nil), do: opts
  def maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
