defmodule PrismWeb.DisplayHelpers do
  @moduledoc """
  Shared display formatting helpers for Prism LiveViews.
  """

  @doc """
  Format an execution reference for display.

  Handles both legacy JSON-decoded map references and new canonical string references.
  """
  def format_ref(nil), do: "-"
  def format_ref(ref) when is_binary(ref), do: ref

  def format_ref(%{"local" => path}) when is_binary(path) do
    case Sanctum.ComponentRef.from_path(path) do
      {:ok, parsed} -> Sanctum.ComponentRef.to_string(parsed)
      {:error, _} -> path
    end
  end

  def format_ref(%{"arca" => path}) when is_binary(path) do
    case Sanctum.ComponentRef.from_path(path) do
      {:ok, parsed} -> Sanctum.ComponentRef.to_string(parsed)
      {:error, _} -> path
    end
  end

  def format_ref(%{"oci" => ref}) when is_binary(ref) do
    case Sanctum.ComponentRef.normalize(ref) do
      {:ok, normalized} -> normalized
      {:error, _} -> ref
    end
  end

  def format_ref(%{"registry" => ref}) when is_binary(ref), do: ref
  def format_ref(ref) when is_map(ref), do: inspect(ref)
  def format_ref(ref), do: inspect(ref)
end
