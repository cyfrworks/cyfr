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
  def format_ref(ref), do: inspect(ref)
end
