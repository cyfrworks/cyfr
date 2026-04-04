defmodule Sanctum.TinctureVisibility do
  @moduledoc """
  Manages tincture public/private visibility settings.

  Visibility is an operator decision stored in Sanctum, not in the
  component manifest. All tinctures default to private. Operators must
  explicitly set visibility via the `tincture_visibility` MCP action or
  by calling `set_public/4` directly.

  Manifests do not contain visibility fields — visibility is a deployment
  concern, not a component-definition concern.
  """

  alias Sanctum.{Context, ComponentRef}

  @doc """
  Check if a tincture is publicly visible.

  Accepts a `%Sanctum.Context{}` (authenticated or unauthenticated).
  Returns `true` only when an explicit visibility record exists with `is_public: true`.
  Missing records default to private (fail closed).
  """
  @spec public?(Context.t(), String.t(), String.t()) :: boolean()
  def public?(%Context{} = ctx, publisher, name) do
    case Arca.TinctureData.VisibilityStorage.get_visibility(ctx, publisher, name) do
      {:ok, %{is_public: val}} -> val == true
      _ -> false
    end
  rescue
    # Fail closed: if the DB is unavailable, default to private
    _ -> false
  end

  @doc """
  Set the public visibility of a tincture.

  Requires an authenticated context.
  """
  @spec set_public(Context.t(), String.t(), String.t(), boolean()) :: :ok | {:error, term()}
  def set_public(%Context{} = ctx, publisher, name, is_public)
      when is_boolean(is_public) do
    with :ok <- validate_refs(publisher, name) do
      Arca.TinctureData.VisibilityStorage.put(ctx, publisher, name, is_public)
    end
  end

  @doc """
  Get the current visibility state for a tincture.

  Requires an authenticated context.
  Returns `{:ok, %{is_public: boolean()}}` or `{:error, :not_found}`.
  """
  @spec get(Context.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get(%Context{} = ctx, publisher, name) do
    Arca.TinctureData.VisibilityStorage.get(ctx, publisher, name)
  end

  @doc """
  Delete the visibility record for a tincture (resets to default private).
  """
  @spec delete(Context.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def delete(%Context{} = ctx, publisher, name) do
    Arca.TinctureData.VisibilityStorage.delete(ctx, publisher, name)
  end

  defp validate_refs(publisher, name),
    do: ComponentRef.validate_ref_parts(publisher, name)
end
