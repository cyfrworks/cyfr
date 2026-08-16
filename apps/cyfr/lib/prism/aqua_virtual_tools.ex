# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

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
      description: "Athanor file ops. Wraps catalyst:local.files.",
      actions: %{
        "read" => %{kind: :read, planes: [:in_chain]},
        "list" => %{kind: :read, planes: [:in_chain]},
        "search" => %{kind: :read, planes: [:in_chain]},
        "grep" => %{kind: :read, planes: [:in_chain]},
        "tree" => %{kind: :read, planes: [:in_chain]},
        "write" => %{kind: :write, planes: [:in_chain]},
        "edit" => %{kind: :write, planes: [:in_chain]},
        "delete" => %{kind: :destructive, planes: [:in_chain]}
      }
    },
    "storage" => %{
      title: "Storage",
      description: "Persistent k/v under data/storage/. Wraps catalyst:local.files.",
      actions: %{
        "read" => %{kind: :read, planes: [:in_chain]},
        "list" => %{kind: :read, planes: [:in_chain]},
        "write" => %{kind: :write, planes: [:in_chain]},
        "delete" => %{kind: :destructive, planes: [:in_chain]}
      }
    },
    "http" => %{
      title: "HTTP",
      description: "Outbound HTTP. Wraps catalyst:local.http.",
      actions: %{
        "read" => %{kind: :read, planes: [:in_chain]},
        "get" => %{kind: :read, planes: [:in_chain]},
        "head" => %{kind: :read, planes: [:in_chain]},
        "options" => %{kind: :read, planes: [:in_chain]},
        "put" => %{kind: :write, planes: [:in_chain]},
        "patch" => %{kind: :write, planes: [:in_chain]},
        "post" => %{kind: :execute, planes: [:in_chain]},
        "delete" => %{kind: :destructive, planes: [:in_chain]}
      }
    },
    "request_setup" => %{
      title: "Setup form",
      description: "Open the inline setup form for a component needing credentials.",
      actions: %{"open" => %{kind: :write, planes: [:in_chain]}}
    }
  }

  @doc "Full catalog map. Source of truth for virtual-tool schema on the harness side."
  @spec catalog() :: %{
          String.t() => %{
            title: String.t(),
            description: String.t(),
            actions: %{String.t() => %{kind: atom(), planes: [atom(), ...]}}
          }
        }
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

  @doc """
  The second arm of the plane taxonomy audit.

  Virtual tools are dispatched inside the formula and never reach
  `Emissary.MCP.ToolRegistry`, so `audit_action_kinds/0` structurally
  cannot see them. Without this arm the taxonomy has a silent hole exactly
  where the agent surface is.

  Every virtual action is `:in_chain` and only `:in_chain` — there is no
  ingress that could reach one from outside a running formula.
  """
  @spec audit_planes() :: :ok | {:error, [map()]}
  def audit_planes do
    missing =
      Enum.flat_map(@catalog, fn {tool, %{actions: actions}} ->
        Enum.flat_map(actions, fn {action, annotation} ->
          case annotation do
            %{kind: kind, planes: [:in_chain]} when is_atom(kind) and not is_nil(kind) ->
              []

            other ->
              [%{tool: tool, action: action, annotation: other}]
          end
        end)
      end)

    case missing do
      [] -> :ok
      _ -> {:error, missing}
    end
  end

  @doc """
  Every `tool.action` pair in the catalog, sorted — the surface the Rust
  dispatch list must agree with.
  """
  @spec action_pairs() :: [String.t()]
  def action_pairs do
    @catalog
    |> Enum.flat_map(fn {tool, %{actions: actions}} ->
      Enum.map(Map.keys(actions), &"#{tool}.#{&1}")
    end)
    |> Enum.sort()
  end
end
