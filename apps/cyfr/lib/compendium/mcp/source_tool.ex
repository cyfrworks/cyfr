# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.MCP.SourceTool do
  @moduledoc """
  The `source` tool: an agent's hands on the source of a `local` component.

  Paths are `components/{type}s/local/{name}/{version}/…`. The tool reads,
  searches and edits the files inside a version directory, through
  `Cyfr.Files`, so the tier rules, the storage cap and the component's
  re-registration are the ones the Files page applies. It refuses:

    * another publisher's component — a pulled component is forked, not
      rewritten;
    * writing, editing or deleting the version directory itself — a
      component version is made and removed whole by the component verbs
      (`tree` lists it);
    * writing, editing or deleting `cyfr-manifest.json` — it declares what
      the component may reach and depend on, and a person changes it on
      the Files page (`read`, `grep` and `tree` show it);
    * the compiled artifact (`{type}.wasm`) and a tincture's `dist/`, which
      a build writes.

  `scoped/2` is the one decision. It validates the segments with
  `Cyfr.PathSafety` and compares names after Unicode compatibility
  normalisation and case folding, so no spelling a case-insensitive
  filesystem resolves to a refused file reaches `Cyfr.Files`.

  The tool is in-chain only; a person edits through Files. Its actions are
  their own policy keys, so a grant for `files.write` on `data/` never
  covers component code. Every call carries `path`, so
  `Aqua.Loop.Policy.touched_refs/1` counts the component as touched and a
  run of it later in the turn asks for a card.
  """

  @behaviour Cyfr.Ops.Provider

  alias Cyfr.Files
  alias Sanctum.Context

  @max_grep_matches 200
  @max_tree_entries 500
  @mutations ~w(write edit delete)
  @manifest Compendium.ComponentPath.manifest_name()
  @dist "dist"

  @impl true
  def service, do: "source"

  @impl true
  def tools, do: [definition()]

  @doc false
  def definition do
    %{
      name: "source",
      title: "Component source",
      description:
        "The source of a component you are authoring, under " <>
          "components/{type}s/local/{name}/{version}/. Read, search and edit it; " <>
          "the compiled artifact is written by a build, not here.",
      annotations: %{
        readOnlyHint: false,
        destructiveHint: true,
        actions: %{
          "tree" => %{
            kind: :read,
            planes: [:in_chain],
            permission: :storage_read,
            recovery: :replay_safe
          },
          "read" => %{
            kind: :read,
            planes: [:in_chain],
            permission: :storage_read,
            recovery: :replay_safe
          },
          "grep" => %{
            kind: :read,
            planes: [:in_chain],
            permission: :storage_read,
            recovery: :replay_safe
          },
          "write" => %{
            kind: :write,
            planes: [:in_chain],
            permission: :storage_write
          },
          "edit" => %{
            kind: :write,
            planes: [:in_chain],
            permission: :storage_write
          },
          "delete" => %{
            kind: :destructive,
            planes: [:in_chain],
            permission: :storage_write
          }
        }
      },
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => ["tree", "read", "grep", "write", "edit", "delete"]
          },
          "path" => %{
            "type" => "string",
            "description" =>
              "components/{type}s/local/{name}/{version}/… — a file, or a folder for tree"
          },
          "content" => %{"type" => "string", "description" => "write: the file's new content"},
          "pattern" => %{"type" => "string", "description" => "grep: a regular expression"},
          "include" => %{
            "type" => "string",
            "description" => "grep: only files whose name ends with this, e.g. .rs"
          },
          "edits" => %{
            "type" => "array",
            "description" =>
              "edit: line operations applied together, highest line first; " <>
                "each is {action: replace|insert|delete, start, end, content}",
            "items" => %{"type" => "object"}
          }
        },
        "required" => ["action", "path"]
      }
    }
  end

  @impl true
  def handle("source", %Context{} = ctx, %{"action" => action} = args) do
    with {:ok, path} <- scoped(Map.get(args, "path"), action) do
      dispatch(action, ctx, path, args)
    end
  end

  def handle(_name, _ctx, _args), do: {:error, :unknown_tool}

  # ---------------------------------------------------------------------------
  # Scope
  # ---------------------------------------------------------------------------

  # Refusals are worded, so an agent is told what it may edit rather than
  # being handed a storage error.
  defp scoped(path, action) when is_binary(path) do
    segments = String.split(path, "/", trim: true)

    with :ok <- safe(segments) do
      case segments do
        ["components", plural, publisher, _name, _version | rest] ->
          with :ok <- local_publisher(publisher),
               :ok <- source_file(plural, Enum.map(rest, &fold/1), action) do
            {:ok, Enum.join(segments, "/")}
          end

        ["components", _plural, publisher, _name] when action == "tree" ->
          with :ok <- local_publisher(publisher), do: {:ok, Enum.join(segments, "/")}

        _ ->
          {:error,
           {:invalid_argument,
            "source works inside components/{type}s/local/{name}/{version}/ — " <>
              "'#{path}' is not a component version's own source"}}
      end
    end
  end

  defp scoped(_path, _action),
    do: {:error, {:invalid_argument, "source needs a path"}}

  # `.`, `..`, empty and encoded segments never reach a name comparison.
  defp safe(segments) do
    case Cyfr.PathSafety.validate_segments(segments) do
      :ok -> :ok
      {:error, {_refusal, message}} -> {:error, {:invalid_argument, message}}
    end
  end

  # The spelling a comparison sees: `CYFR-Manifest.JSON` and its fullwidth
  # forms are the manifest to a case-insensitive filesystem.
  defp fold(name) do
    case :unicode.characters_to_nfkc_binary(name) do
      normalized when is_binary(normalized) -> String.downcase(normalized)
      _invalid -> name
    end
  end

  defp local_publisher(publisher) do
    if Compendium.ComponentPath.local_publisher?(publisher),
      do: :ok,
      else:
        {:error,
         {:invalid_argument,
          "'#{publisher}' is another publisher's component — its source is not yours to edit"}}
  end

  # `rest` is folded (`fold/1`): every name below compares folded.
  defp source_file(_plural, [], action) when action in @mutations,
    do:
      {:error,
       {:invalid_argument,
        "a component version is created and deleted whole, not through its source — " <>
          "name a file inside it"}}

  defp source_file(plural, rest, action) do
    artifact =
      plural |> fold() |> String.trim_trailing("s") |> Compendium.ComponentPath.wasm_name()

    cond do
      rest == [artifact] ->
        {:error,
         {:invalid_argument,
          "#{artifact} is written by a build, not by hand — edit the source and compile"}}

      match?([@dist | _], rest) ->
        {:error,
         {:invalid_argument, "dist/ holds a build's output — edit the source it is built from"}}

      rest == [@manifest] and action in @mutations ->
        {:error,
         {:invalid_argument,
          "#{@manifest} declares what this component may reach and depend on, so a person " <>
            "changes it on the Files page — read it here, and ask for the change it needs"}}

      true ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Actions
  # ---------------------------------------------------------------------------

  defp dispatch("read", ctx, path, _args), do: Files.read(ctx, path)

  defp dispatch("write", ctx, path, args) do
    case Map.get(args, "content") do
      content when is_binary(content) -> Files.write(ctx, path, content)
      _ -> {:error, {:invalid_argument, "write needs content"}}
    end
  end

  defp dispatch("delete", ctx, path, _args), do: Files.delete(ctx, path)

  defp dispatch("tree", ctx, path, _args) do
    case walk(ctx, path, "", @max_tree_entries) do
      {:ok, files} ->
        {shown, rest} = Enum.split(Enum.sort(files), @max_tree_entries)
        {:ok, %{path: path, files: shown, truncated: rest != []}}

      error ->
        error
    end
  end

  defp dispatch("grep", ctx, path, args) do
    with {:ok, pattern} <- compile_pattern(Map.get(args, "pattern")),
         {:ok, %{files: files}} <- dispatch("tree", ctx, path, args) do
      include = Map.get(args, "include")

      matches =
        files
        |> Enum.filter(&included?(&1, include))
        |> Enum.flat_map(&grep_file(ctx, path, &1, pattern))
        |> Enum.take(@max_grep_matches)

      {:ok, %{path: path, matches: matches, count: length(matches)}}
    end
  end

  defp dispatch("edit", ctx, path, args) do
    with {:ok, edits} <- edit_list(Map.get(args, "edits")) do
      Files.update(ctx, path, fn content ->
        with {:ok, edited} <- apply_edits(String.split(content, "\n"), edits) do
          {:ok, Enum.join(edited, "\n")}
        end
      end)
    end
  end

  defp dispatch(action, _ctx, _path, _args),
    do: {:error, {:invalid_argument, "unknown source action: #{action}"}}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Recursion through the domain's own listing, so a folder this tool may
  # not see stays unseen here too.
  defp walk(_ctx, _base, _prefix, budget) when budget <= 0, do: {:ok, []}

  defp walk(ctx, base, prefix, budget) do
    path = if prefix == "", do: base, else: base <> "/" <> prefix

    case Files.list(ctx, path) do
      {:ok, %{entries: entries}} ->
        Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
          rel = if prefix == "", do: entry.name, else: prefix <> "/" <> entry.name

          case entry.kind do
            :dir ->
              case walk(ctx, base, rel, budget - length(acc)) do
                {:ok, nested} -> {:cont, {:ok, acc ++ nested}}
                error -> {:halt, error}
              end

            _ ->
              {:cont, {:ok, acc ++ [rel]}}
          end
        end)

      error ->
        error
    end
  end

  defp compile_pattern(pattern) when is_binary(pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} -> {:ok, regex}
      {:error, _} -> {:error, {:invalid_argument, "'#{pattern}' is not a regular expression"}}
    end
  end

  defp compile_pattern(_), do: {:error, {:invalid_argument, "grep needs a pattern"}}

  defp included?(_file, nil), do: true
  defp included?(file, suffix) when is_binary(suffix), do: String.ends_with?(file, suffix)

  defp grep_file(ctx, base, relative, pattern) do
    case Files.read(ctx, base <> "/" <> relative) do
      {:ok, %{content: content, encoding: "utf8"}} ->
        content
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _n} -> Regex.match?(pattern, line) end)
        |> Enum.map(fn {line, n} -> %{file: relative, line: n, text: line} end)

      _ ->
        []
    end
  end

  defp edit_list(edits) when is_list(edits) and edits != [], do: {:ok, edits}
  defp edit_list(_), do: {:error, {:invalid_argument, "edit needs a non-empty edits list"}}

  # Applied highest line first, so an earlier edit cannot move the lines a
  # later one names.
  defp apply_edits(lines, edits) do
    edits
    |> Enum.sort_by(&(-start_of(&1)))
    |> Enum.reduce_while({:ok, lines}, fn edit, {:ok, acc} ->
      case apply_edit(acc, edit) do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  defp start_of(%{"start" => start}) when is_integer(start), do: start
  defp start_of(_), do: 0

  defp apply_edit(lines, %{"action" => "insert", "start" => start} = edit)
       when is_integer(start) do
    {before, rest} = Enum.split(lines, max(start - 1, 0))
    {:ok, before ++ String.split(content_of(edit), "\n") ++ rest}
  end

  defp apply_edit(lines, %{"action" => action, "start" => start, "end" => stop} = edit)
       when action in ["replace", "delete"] and is_integer(start) and is_integer(stop) and
              start >= 1 and stop >= start do
    if stop > length(lines) do
      {:error,
       {:invalid_argument, "line #{stop} is past the end of the file (#{length(lines)} lines)"}}
    else
      {before, rest} = Enum.split(lines, start - 1)
      kept = Enum.drop(rest, stop - start + 1)

      replacement =
        if action == "replace", do: String.split(content_of(edit), "\n"), else: []

      {:ok, before ++ replacement ++ kept}
    end
  end

  defp apply_edit(_lines, edit),
    do:
      {:error,
       {:invalid_argument,
        "each edit is {action: replace|insert|delete, start, end, content}: #{inspect(edit)}"}}

  defp content_of(%{"content" => content}) when is_binary(content), do: content
  defp content_of(_), do: ""
end
