# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Grimoire.VirtualTools do
  @moduledoc """
  The one declaration of the assistant's virtual tools — `files`,
  `storage`, `http` and `request_setup` — and of the kinds an action may
  have to run without a card.

  A virtual tool is dispatched inside the formula, not through the
  operation table, so its declaration lives here rather than in a
  provider. Per family: its title, its description and the catalyst it
  runs on (`nil` for `request_setup`, a UI event). Per action:

    * **kind** — `:read`, `:write`, `:execute` or `:destructive`;
    * **planes** — always `[:in_chain]`: no ingress reaches a virtual
      action from outside a running formula;
    * **recovery** — `:replay_safe` on a read reviewed as safe to
      re-dispatch after an uncertain recovery;
    * **auto_only** — `true` on an action that may only ever be `auto`, a
      UI event no card could run;
    * **resource** — on a `files` action, the argument naming the path it
      touches, relative to the athanor root, as `Prima.Operation`'s
      `resource:` declares one: what a standing approval's constraint is
      checked against (`Sanctum.ToolGrants.admits?/2`). `search` names its
      folder by `base_path`, as the hand builds it; `storage` names a key
      and `http` a URL, so neither declares one and neither takes a
      constraint.

  Every function is a pure read of the table.
  """

  @typedoc "An action's kind."
  @type kind :: :read | :write | :execute | :destructive

  @typedoc "One action's declaration."
  @type action :: %{
          required(:kind) => kind(),
          required(:planes) => [atom()],
          optional(:recovery) => :replay_safe,
          optional(:auto_only) => true,
          optional(:resource) => {String.t(), Prima.Operation.resource_kind()}
        }

  @typedoc "One virtual tool family's declaration."
  @type family :: %{
          title: String.t(),
          description: String.t(),
          catalyst: String.t() | nil,
          actions: %{String.t() => action()}
        }

  @files_catalyst "catalyst:local.files"
  @http_catalyst "catalyst:local.http"
  @files_path {"path", :storage_path}

  @table %{
    "files" => %{
      title: "Files",
      description: "Athanor file ops. Wraps catalyst:local.files.",
      catalyst: @files_catalyst,
      actions: %{
        "read" => %{
          kind: :read,
          planes: [:in_chain],
          recovery: :replay_safe,
          resource: @files_path
        },
        "list" => %{
          kind: :read,
          planes: [:in_chain],
          recovery: :replay_safe,
          resource: @files_path
        },
        "search" => %{
          kind: :read,
          planes: [:in_chain],
          recovery: :replay_safe,
          resource: {"base_path", :storage_path}
        },
        "grep" => %{
          kind: :read,
          planes: [:in_chain],
          recovery: :replay_safe,
          resource: @files_path
        },
        "tree" => %{
          kind: :read,
          planes: [:in_chain],
          recovery: :replay_safe,
          resource: @files_path
        },
        "write" => %{kind: :write, planes: [:in_chain], resource: @files_path},
        "edit" => %{kind: :write, planes: [:in_chain], resource: @files_path},
        "delete" => %{kind: :destructive, planes: [:in_chain], resource: @files_path}
      }
    },
    "storage" => %{
      title: "Storage",
      description: "Persistent k/v under data/storage/. Wraps catalyst:local.files.",
      catalyst: @files_catalyst,
      actions: %{
        "read" => %{kind: :read, planes: [:in_chain], recovery: :replay_safe},
        "list" => %{kind: :read, planes: [:in_chain], recovery: :replay_safe},
        "write" => %{kind: :write, planes: [:in_chain]},
        "delete" => %{kind: :destructive, planes: [:in_chain]}
      }
    },
    "http" => %{
      title: "HTTP",
      description: "Outbound HTTP. Wraps catalyst:local.http.",
      catalyst: @http_catalyst,
      actions: %{
        "read" => %{kind: :read, planes: [:in_chain]},
        "links" => %{kind: :read, planes: [:in_chain]},
        "metadata" => %{kind: :read, planes: [:in_chain]},
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
      catalyst: nil,
      actions: %{"open" => %{kind: :write, planes: [:in_chain], auto_only: true}}
    }
  }

  # The kinds an action may have to run without a card. Destructive and
  # external actions always ask, and so does an action of unknown kind.
  @auto_kinds [:read, :write, :execute]

  @doc "The whole table: family name to its declaration."
  @spec table() :: %{String.t() => family()}
  def table, do: @table

  @doc "The virtual tool families, sorted."
  @spec tools() :: [String.t()]
  def tools, do: @table |> Map.keys() |> Enum.sort()

  @doc "Whether `tool` is a virtual tool family."
  @spec tool?(term()) :: boolean()
  def tool?(tool) when is_binary(tool), do: Map.has_key?(@table, tool)
  def tool?(_tool), do: false

  @doc """
  The catalyst a virtual tool family runs on (`"files"` and `"storage"`
  on the files catalyst, `"http"` on the http catalyst), or nil for a
  family that is not a virtual tool or runs on none.
  """
  @spec catalyst_for(term()) :: String.t() | nil
  def catalyst_for(tool) when is_binary(tool) do
    case Map.get(@table, tool) do
      %{catalyst: catalyst} -> catalyst
      nil -> nil
    end
  end

  def catalyst_for(_tool), do: nil

  @doc "Every catalyst a virtual tool family runs on, name-level, sorted and once each."
  @spec catalysts() :: [String.t()]
  def catalysts do
    @table
    |> Enum.flat_map(fn {_tool, %{catalyst: catalyst}} -> List.wrap(catalyst) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "The actions a virtual tool has, sorted, or `[]` for a tool the table does not hold."
  @spec actions_of(term()) :: [String.t()]
  def actions_of(tool) do
    case family(tool) do
      %{actions: actions} -> actions |> Map.keys() |> Enum.sort()
      nil -> []
    end
  end

  @doc "One action's declaration, or nil for a pair the table does not hold."
  @spec action(term(), term()) :: action() | nil
  def action(tool, action) when is_binary(action) do
    case family(tool) do
      %{actions: actions} -> Map.get(actions, action)
      nil -> nil
    end
  end

  def action(_tool, _action), do: nil

  @doc "The kind of a virtual `tool.action`, or nil when it is not one."
  @spec kind_for(term(), term()) :: kind() | nil
  def kind_for(tool, action) do
    case action(tool, action) do
      %{kind: kind} -> kind
      nil -> nil
    end
  end

  @doc "The planes of a virtual `tool.action`; `[]` when it is not one."
  @spec planes(term(), term()) :: [atom()]
  def planes(tool, action) do
    case action(tool, action) do
      %{planes: planes} -> planes
      nil -> []
    end
  end

  @doc """
  Whether `tool.action` may only ever be `auto`: a UI event the guest
  answers in place, never a catalyst call a card could run.
  """
  @spec auto_only?(term(), term()) :: boolean()
  def auto_only?(tool, action), do: match?(%{auto_only: true}, action(tool, action))

  @doc """
  `:replay_safe` for a virtual read reviewed as safe to re-dispatch after
  an uncertain recovery, nil for every other action — a write so marked
  included.
  """
  @spec recovery(term(), term()) :: :replay_safe | nil
  def recovery(tool, action) do
    case action(tool, action) do
      %{kind: :read, recovery: :replay_safe} -> :replay_safe
      _ -> nil
    end
  end

  @doc """
  The families with each action's kind, `[{tool, [{action, kind}]}]`,
  both levels sorted — the shape the operation table's enumeration takes.
  """
  @spec action_kinds() :: [{String.t(), [{String.t(), kind()}]}]
  def action_kinds do
    for tool <- tools() do
      {tool, for(action <- actions_of(tool), do: {action, kind_for(tool, action)})}
    end
  end

  @doc "Every `tool.action` pair in the table, sorted."
  @spec action_pairs() :: [String.t()]
  def action_pairs do
    Enum.sort(for tool <- tools(), action <- actions_of(tool), do: "#{tool}.#{action}")
  end

  @doc "The kinds an action may have to run without a card."
  @spec auto_permitted_kinds() :: [kind()]
  def auto_permitted_kinds, do: @auto_kinds

  @doc """
  Whether an action of `kind` may run without a card: a read, write or
  execute. A destructive, external or unknown (`nil`) kind always asks.
  """
  @spec auto_permitted_kind?(term()) :: boolean()
  def auto_permitted_kind?(kind), do: kind in @auto_kinds

  defp family(tool) when is_binary(tool), do: Map.get(@table, tool)
  defp family(_tool), do: nil
end
