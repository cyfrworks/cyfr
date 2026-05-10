defmodule Prism.AquaVirtualTools do
  @moduledoc """
  Catalog for AQUA virtual tools — `files`, `storage`, `http`, `request_setup`.

  Virtual tools are defined and dispatched inside the AQUA formula
  (`components/formulas/local/aqua/<version>/src/src/tools.rs`); they don't
  appear in `Emissary.MCP.ToolRegistry`. This module mirrors the formula's
  virtual-tool schema in Elixir so the agents-panel matrix can render them
  alongside MCP tools and the harness can validate `ui.request_approval`
  proposals against them.

  The catalog follows the same shape as MCP tool annotations: each tool has an
  `actions` map keyed by canonical verb, value `%{kind: kind}`. Kind drives
  default risk and UI color.

  Two-source-in-sync trade-off: this module and `tools.rs` are both updated
  together when the AQUA formula version is bumped.
  """

  @catalog %{
    "files" => %{
      title: "Files",
      description: "Workspace file ops. Wraps catalyst:local.files.",
      actions: %{
        "read" => %{kind: :read},
        "list" => %{kind: :read},
        "search" => %{kind: :read},
        "grep" => %{kind: :read},
        "tree" => %{kind: :read},
        "write" => %{kind: :write},
        "edit" => %{kind: :write},
        "delete" => %{kind: :destructive}
      }
    },
    "storage" => %{
      title: "Storage",
      description: "Persistent k/v under data/storage/. Wraps catalyst:local.files.",
      actions: %{
        "read" => %{kind: :read},
        "list" => %{kind: :read},
        "write" => %{kind: :write},
        "delete" => %{kind: :destructive}
      }
    },
    "http" => %{
      title: "HTTP",
      description: "Outbound HTTP. Wraps catalyst:local.http.",
      actions: %{
        "get" => %{kind: :read},
        "head" => %{kind: :read},
        "options" => %{kind: :read},
        "put" => %{kind: :write},
        "patch" => %{kind: :write},
        "post" => %{kind: :execute},
        "delete" => %{kind: :destructive}
      }
    },
    "request_setup" => %{
      title: "Setup form",
      description: "Open the inline setup form for a component needing credentials.",
      actions: %{"open" => %{kind: :write}}
    }
  }

  @doc "Full catalog map. Source of truth for virtual-tool schema on the harness side."
  @spec catalog() :: %{String.t() => %{title: String.t(), description: String.t(), actions: %{String.t() => %{kind: atom()}}}}
  def catalog, do: @catalog

  @doc "Lookup the kind of a virtual `tool.action`. Returns `nil` if not a virtual tool/action."
  @spec kind_for(String.t(), String.t()) :: atom() | nil
  def kind_for(tool, action) do
    case @catalog[tool] do
      %{actions: actions} ->
        case actions[action] do
          %{kind: kind} -> kind
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Return `[{tool, [{action, kind}]}]` shaped like the MCP path's enumeration,
  so the AQUA harness can merge MCP + virtual + external surfaces into one
  uniform list.
  """
  @spec list_for_panel() :: [{String.t(), [{String.t(), atom()}]}]
  def list_for_panel do
    @catalog
    |> Enum.map(fn {tool, %{actions: actions}} ->
      pairs =
        actions
        |> Enum.map(fn {action, %{kind: kind}} -> {action, kind} end)
        |> Enum.sort()

      {tool, pairs}
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc "Whether `tool` is a virtual tool managed by AQUA."
  @spec virtual_tool?(String.t()) :: boolean()
  def virtual_tool?(tool) when is_binary(tool), do: Map.has_key?(@catalog, tool)
  def virtual_tool?(_), do: false
end
