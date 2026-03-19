defmodule Prism.AgentPreferences do
  @moduledoc """
  Persists agent preferences for headless/scheduled runs.

  Stores the user's preferred provider, model, and catalyst ref so that
  scheduled agent tasks can run without interactive model selection.
  Uses the storage MCP tool for persistence.
  """

  alias Sanctum.Context

  @storage_key "agent_preferences"

  @doc """
  Save agent preferences for the given context.
  """
  def save(%Context{} = ctx, provider, model, catalyst_ref) do
    prefs = %{
      "provider" => provider,
      "model" => model,
      "catalyst_ref" => catalyst_ref,
      "updated_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    Emissary.MCP.ToolRegistry.call("storage", ctx, %{
      "action" => "write",
      "key" => @storage_key,
      "value" => prefs
    })
  end

  @doc """
  Get saved agent preferences for the given context.

  Returns `{:ok, prefs_map}` or `{:error, reason}`.
  """
  def get(%Context{} = ctx) do
    case Emissary.MCP.ToolRegistry.call("storage", ctx, %{
           "action" => "read",
           "key" => @storage_key
         }) do
      {:ok, prefs} when is_map(prefs) -> {:ok, prefs}
      {:ok, _} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end
end
