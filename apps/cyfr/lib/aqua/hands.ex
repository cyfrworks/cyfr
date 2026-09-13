# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Hands do
  @moduledoc """
  The one table of AQUA's hands — `files`, `storage`, `http`,
  `request_setup`: the model-visible operations that run a local catalyst
  under the pinned authority, and the UI event that is none.

  Every question about a hand is answered from these rows:

    * **kind** — what `Aqua.Kinds.kind_for/2` and the AQUA page classify
      a `tool.action` as, and which reads are reviewed as safe to
      re-dispatch after an uncertain recovery (`recovery: :replay_safe`);
    * **child call** — the catalyst and the input a `tool.action` becomes
      (`child_call/3`), which `Aqua.Loop.Binding` dispatches;
    * **canonical operation** — what an `execution.run` of one of those
      catalysts, or a `files` call whose path lands in the storage
      boundary, IS (`canonical/2`, `canonical_files/2`): wrappers are
      aliases of canonical operations, and every policy decision — a
      card, an approval — is made on the canonical one;
    * **`auto_only`** — `request_setup.open` is a UI event, not a catalyst;
      an `ask` on it would be a card nothing can execute.

  The resource boundary is `data/storage/`: a file operation inside it is
  the storage operation of the same effect, whichever tool spelled it.
  `files.list` and `files.tree` are one catalyst request (`tree`), so the
  reverse mapping answers both and the caller decides what an ambiguous
  request may do.
  """

  @files_catalyst "catalyst:local.files"
  @http_catalyst "catalyst:local.http"
  @storage_prefix "data/storage/"
  @storage_root "data/storage"
  @components_prefix "components/"
  @components_root "components"

  @catalog %{
    "files" => %{
      title: "Files",
      description: "Athanor file ops. Wraps catalyst:local.files.",
      catalyst: @files_catalyst,
      actions: %{
        "read" => %{kind: :read, planes: [:in_chain], recovery: :replay_safe},
        "list" => %{kind: :read, planes: [:in_chain], recovery: :replay_safe},
        "search" => %{kind: :read, planes: [:in_chain], recovery: :replay_safe},
        "grep" => %{kind: :read, planes: [:in_chain], recovery: :replay_safe},
        "tree" => %{kind: :read, planes: [:in_chain], recovery: :replay_safe},
        "write" => %{kind: :write, planes: [:in_chain]},
        "edit" => %{kind: :write, planes: [:in_chain]},
        "delete" => %{kind: :destructive, planes: [:in_chain]}
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

  @doc """
  The catalyst a virtual tool family runs on (`"files"` and `"storage"`
  on the files catalyst, `"http"` on the http catalyst), or nil for a
  family that is not a virtual tool or runs on none.
  """
  @spec catalyst_for(String.t()) :: String.t() | nil
  def catalyst_for(tool) when is_binary(tool) do
    case Map.get(@catalog, tool) do
      %{catalyst: catalyst} -> catalyst
      nil -> nil
    end
  end

  @http_page_ops ~w(read links metadata head)
  @http_methods ~w(get options post put patch delete)

  @type canonical :: %{tool: String.t(), action: String.t(), args: map()}

  @doc "Full catalog map. Source of truth for virtual-tool schema on the harness side."
  @spec catalog() :: %{
          String.t() => %{
            title: String.t(),
            description: String.t(),
            catalyst: String.t() | nil,
            actions: %{String.t() => map()}
          }
        }
  def catalog, do: @catalog

  @doc "Lookup the kind of a virtual `tool.action`. Returns `nil` if not a virtual tool/action."
  @spec kind_for(String.t(), String.t()) :: atom() | nil
  def kind_for(tool, action) do
    case annotation(tool, action) do
      %{kind: kind} -> kind
      _ -> nil
    end
  end

  @doc """
  Whether `tool.action` may only ever be `auto`: a UI event the guest
  answers in place, never a catalyst call a card could run.
  """
  @spec auto_only?(String.t(), String.t()) :: boolean()
  def auto_only?(tool, action) do
    case annotation(tool, action) do
      %{auto_only: true} -> true
      _ -> false
    end
  end

  defp annotation(tool, action) when is_binary(tool) and is_binary(action) do
    case @catalog[tool] do
      %{actions: actions} -> actions[action]
      _ -> nil
    end
  end

  defp annotation(_tool, _action), do: nil

  @doc "The actions a virtual tool has, or `[]` for a tool the catalog does not hold."
  @spec actions_of(String.t()) :: [String.t()]
  def actions_of(tool) do
    case @catalog[tool] do
      %{actions: actions} -> actions |> Map.keys() |> Enum.sort()
      _ -> []
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
  @spec hand?(String.t()) :: boolean()
  def hand?(tool) when is_binary(tool), do: Map.has_key?(@catalog, tool)
  def hand?(_), do: false

  @doc """
  The second arm of the plane taxonomy audit.

  Virtual tools are dispatched inside the formula and never reach
  `Cyfr.Ops.Catalog`, so `audit_action_kinds/0` structurally
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

  # ---------------------------------------------------------------------------
  # References
  # ---------------------------------------------------------------------------

  @doc """
  A component reference at name level — `type:ns.name`, the version (and
  anything after it) dropped — so `catalyst:local.files:0.5.2` and
  `catalyst:local.files` are the same catalyst here as they are for the
  chain.
  """
  @spec name_level(String.t()) :: String.t()
  def name_level(reference) when is_binary(reference) do
    reference |> String.split(":", parts: 3) |> Enum.take(2) |> Enum.join(":")
  end

  @doc "Whether a reference names a catalyst a hand runs on, at any version."
  @spec hand_catalyst?(String.t()) :: boolean()
  def hand_catalyst?(reference) when is_binary(reference) do
    name = name_level(reference)
    Enum.any?(@catalog, fn {_tool, %{catalyst: catalyst}} -> catalyst == name end)
  end

  def hand_catalyst?(_), do: false

  # ---------------------------------------------------------------------------
  # Child call — the catalyst request the guest builds for one virtual call
  # ---------------------------------------------------------------------------

  @doc """
  The catalyst and the input one virtual `tool.action` becomes — what the
  guest's dispatch table builds, so a card approved on the host runs the
  very same request. `request_setup` builds nothing: it is a UI event.
  """
  @spec child_call(String.t(), String.t(), map()) ::
          {:ok, %{catalyst: String.t(), input: map()}} | {:error, String.t()}
  def child_call("files", action, args) when is_map(args) do
    with {:ok, input} <- files_input(action, args),
         do: {:ok, %{catalyst: @files_catalyst, input: input}}
  end

  def child_call("storage", action, args) when is_map(args) do
    with {:ok, input} <- storage_input(action, args),
         do: {:ok, %{catalyst: @files_catalyst, input: input}}
  end

  def child_call("http", action, args) when is_map(args) do
    with {:ok, input} <- http_input(action, args),
         do: {:ok, %{catalyst: @http_catalyst, input: input}}
  end

  def child_call("request_setup", _action, _args),
    do: {:error, "request_setup is a UI event, not a catalyst call"}

  def child_call(tool, _action, _args), do: {:error, "#{tool} is not a virtual tool"}

  defp files_input("read", args) do
    {:ok,
     %{"action" => "read_lines", "path" => str(args, "path")}
     |> copy_arg(args, "start_line")
     |> copy_arg(args, "end_line")}
  end

  defp files_input("write", args),
    do:
      {:ok,
       %{"action" => "write_text", "path" => str(args, "path"), "content" => str(args, "content")}}

  defp files_input("edit", args),
    do:
      {:ok,
       %{"action" => "edit", "path" => str(args, "path"), "edits" => Map.get(args, "edits", [])}}

  defp files_input("search", args),
    do:
      {:ok,
       %{
         "action" => "search",
         "base_path" => str(args, "base_path", "."),
         "pattern" => str(args, "pattern", "*")
       }}

  defp files_input("grep", args) do
    input = %{
      "action" => "grep",
      "path" => str(args, "path", "."),
      "pattern" => str(args, "pattern")
    }

    input =
      case Map.get(args, "include") do
        include when is_binary(include) -> Map.put(input, "include", include)
        _ -> input
      end

    {:ok, input}
  end

  defp files_input(list_or_tree, args) when list_or_tree in ["tree", "list"] do
    {:ok, %{"action" => "tree", "path" => str(args, "path", ".")} |> copy_arg(args, "depth")}
  end

  defp files_input("delete", args),
    do: {:ok, %{"action" => "delete", "path" => str(args, "path")}}

  defp files_input(other, _args), do: {:error, "Unknown files action: #{other}"}

  defp storage_input(action, args) do
    key = str(args, "key")
    path = @storage_prefix <> key <> ".json"

    case action do
      "write" ->
        content = Jason.encode!(Map.get(args, "value"), pretty: true)
        {:ok, %{"action" => "write_text", "path" => path, "content" => content}}

      "read" ->
        {:ok, %{"action" => "read_lines", "path" => path}}

      "list" ->
        list_path = if key == "", do: @storage_root, else: @storage_prefix <> key
        {:ok, %{"action" => "tree", "path" => list_path, "depth" => 2}}

      "delete" ->
        {:ok, %{"action" => "delete", "path" => path}}

      other ->
        {:error, "Unknown storage action: #{other}"}
    end
  end

  # The model's `action` is the wrapper's, not the catalyst's: params carry
  # everything else the model said.
  defp http_input(action, args) when action in @http_page_ops,
    do: {:ok, %{"operation" => action, "params" => Map.delete(args, "action")}}

  defp http_input(action, args) when action in @http_methods do
    params = args |> Map.delete("action") |> Map.put("method", String.upcase(action))
    {:ok, %{"operation" => "fetch", "params" => params}}
  end

  defp http_input(other, _args), do: {:error, "Unknown http action: #{other}"}

  defp str(args, key, default \\ "") do
    case Map.get(args, key) do
      value when is_binary(value) -> value
      _ -> default
    end
  end

  defp copy_arg(input, args, key) do
    case Map.fetch(args, key) do
      {:ok, value} -> Map.put(input, key, value)
      :error -> input
    end
  end

  # ---------------------------------------------------------------------------
  # Canonical operations — what a request IS, whichever tool spelled it
  # ---------------------------------------------------------------------------

  @doc """
  The canonical virtual operations an `execution.run` of `reference` with
  `input` denotes: `{:ok, candidates}` with the canonical one first — more
  than one only for a request two virtual actions build identically
  (`files.tree` and `files.list`) — `{:error, :not_virtual}` for a
  reference that is not one of the wrapped catalysts, and
  `{:error, :unknown_operation}` for an input no virtual action builds.
  Each candidate carries the virtual tool's own `args`, so a card can be
  stored for it and `child_call/3` can run it again.
  """
  @spec canonical(String.t(), map()) ::
          {:ok, [canonical()]} | {:error, :not_virtual | :unknown_operation}
  def canonical(reference, input) when is_binary(reference) and is_map(input) do
    case name_level(reference) do
      @files_catalyst -> files_canonical(input)
      @http_catalyst -> http_canonical(input)
      _ -> {:error, :not_virtual}
    end
  end

  def canonical(_reference, _input), do: {:error, :not_virtual}

  @doc """
  The canonical operation of a direct `files` call: the storage operation
  of the same effect when its path lands in `data/storage/`, itself
  otherwise. A files action with no storage equivalent (edit, search,
  grep) inside the boundary is `{:error, :not_a_storage_operation}`.
  """
  @spec canonical_files(String.t(), map()) ::
          {:ok, canonical()} | {:error, :not_a_storage_operation | :unknown_operation}
  def canonical_files(action, args) when is_binary(action) and is_map(args) do
    path = str(args, if(action == "search", do: "base_path", else: "path"))

    cond do
      not Map.has_key?(@catalog["files"].actions, action) ->
        {:error, :unknown_operation}

      component_source_path?(path) ->
        # A component's source is not the files catalyst's to write: its
        # grant is `data/`. The host-side `source` tool owns this, with its
        # own policy keys, so `files.write: auto` for `data/` cannot
        # auto-approve a rewrite of component code.
        {:ok, %{tool: "source", action: action, args: args}}

      not storage_path?(path) ->
        {:ok, %{tool: "files", action: action, args: args}}

      action in ["read", "write", "delete", "tree", "list"] ->
        {:ok, storage_op(files_to_storage(action), path, args)}

      true ->
        {:error, :not_a_storage_operation}
    end
  end

  defp files_to_storage("read"), do: "read"
  defp files_to_storage("write"), do: "write"
  defp files_to_storage("delete"), do: "delete"
  defp files_to_storage(_tree_or_list), do: "list"

  defp files_canonical(%{"action" => action} = input) when is_binary(action) do
    path = str(input, if(action == "search", do: "base_path", else: "path"))

    cond do
      storage_path?(path) -> storage_canonical(action, path, input)
      true -> files_op(action, input)
    end
  end

  defp files_canonical(_input), do: {:error, :unknown_operation}

  defp files_op("read_lines", input) do
    {:ok,
     [%{tool: "files", action: "read", args: take(input, ["path", "start_line", "end_line"])}]}
  end

  defp files_op("write_text", input),
    do: {:ok, [%{tool: "files", action: "write", args: take(input, ["path", "content"])}]}

  defp files_op("edit", input),
    do: {:ok, [%{tool: "files", action: "edit", args: take(input, ["path", "edits"])}]}

  defp files_op("search", input),
    do: {:ok, [%{tool: "files", action: "search", args: take(input, ["base_path", "pattern"])}]}

  defp files_op("grep", input),
    do:
      {:ok, [%{tool: "files", action: "grep", args: take(input, ["path", "pattern", "include"])}]}

  defp files_op("tree", input) do
    args = take(input, ["path", "depth"])

    {:ok,
     [%{tool: "files", action: "tree", args: args}, %{tool: "files", action: "list", args: args}]}
  end

  defp files_op("delete", input),
    do: {:ok, [%{tool: "files", action: "delete", args: take(input, ["path"])}]}

  defp files_op(_other, _input), do: {:error, :unknown_operation}

  defp storage_canonical("read_lines", path, _input), do: {:ok, [storage_op("read", path, %{})]}

  defp storage_canonical("write_text", path, input) do
    value =
      case Jason.decode(str(input, "content")) do
        {:ok, decoded} -> decoded
        _ -> str(input, "content")
      end

    {:ok, [storage_op("write", path, %{"value" => value})]}
  end

  defp storage_canonical("tree", path, _input), do: {:ok, [storage_op("list", path, %{})]}
  defp storage_canonical("delete", path, _input), do: {:ok, [storage_op("delete", path, %{})]}
  defp storage_canonical(_other, _path, _input), do: {:error, :unknown_operation}

  defp storage_op(action, path, extra) do
    %{tool: "storage", action: action, args: Map.put(extra, "key", storage_key(path))}
  end

  defp storage_key(path) do
    path
    |> String.replace_prefix(@storage_root, "")
    |> String.trim_leading("/")
    |> String.replace_suffix(".json", "")
  end

  defp component_source_path?(path) when is_binary(path),
    do: path == @components_root or String.starts_with?(path, @components_prefix)

  defp component_source_path?(_), do: false

  defp storage_path?(path) when is_binary(path),
    do: path == @storage_root or String.starts_with?(path, @storage_prefix)

  defp http_canonical(%{"operation" => op} = input) when op in @http_page_ops do
    {:ok, [%{tool: "http", action: op, args: params(input)}]}
  end

  defp http_canonical(%{"operation" => "fetch"} = input) do
    params = params(input)
    method = params |> Map.get("method", "get") |> to_string() |> String.downcase()

    if method in @http_methods,
      do: {:ok, [%{tool: "http", action: method, args: Map.delete(params, "method")}]},
      else: {:error, :unknown_operation}
  end

  defp http_canonical(_input), do: {:error, :unknown_operation}

  defp params(input) do
    case Map.get(input, "params") do
      %{} = params -> params
      _ -> %{}
    end
  end

  defp take(input, keys) do
    Map.new(
      Enum.flat_map(keys, fn key ->
        if(Map.has_key?(input, key), do: [{key, input[key]}], else: [])
      end)
    )
  end
end
