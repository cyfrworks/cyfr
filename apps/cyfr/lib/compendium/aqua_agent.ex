# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.AquaAgent do
  @moduledoc """
  The AQUA agent file format and the tree's roster: the soul at
  `aqua/aqua.md` and one frontmatter-markdown file per role under
  `aqua/roles/`, served through the seed overlay like every other aqua
  path, so an unedited file tracks the shipped seed and an edited one
  shadows only itself.

  The format is deliberately portable — the shape Claude Code speaks for
  its subagents (`.claude/agents/*.md`): YAML frontmatter carrying the
  metadata, the system prompt as the markdown body. CYFR's additions are
  `catalyst_ref` (which LLM catalyst executes the agent — defaultable),
  `tool_policy` (the per-action allowlist, richer than a flat tools list)
  and `disabled: true` (how a shipped role is taken out of the roster —
  shipped files revert, they don't delete). Which file is the soul and
  which are roles is the tree's to say (`Compendium.AquaPath`), never the
  frontmatter's.

      ---
      title: Arcade
      description: Spawn an Arcade specialist …
      catalyst_ref: catalyst:moonmoon69.claude
      model: claude-sonnet-4-6
      tool_policy:
        files.read: auto
        build.compile: ask
      ---
      You are the Arcade specialist …

  The frontmatter grammar is restricted on purpose: string and boolean
  scalars plus the one flat string→string map (`tool_policy`) — enough for
  portability, small enough that `serialize/1` can emit it byte-stably.
  `parse_frontmatter/1` is shared with the scrolls (`SKILL.md` files under
  `aqua/skills/` follow the open Agent Skills convention: `name` +
  `description` frontmatter, instructions as the body).
  """

  alias Compendium.AquaPath
  alias Sanctum.Context

  @type t :: %{
          name: String.t(),
          title: String.t(),
          description: String.t(),
          disabled: boolean(),
          catalyst_ref: String.t() | nil,
          model: String.t() | nil,
          tool_policy: %{String.t() => String.t()},
          prompt: String.t()
        }

  # ---------------------------------------------------------------------------
  # Format
  # ---------------------------------------------------------------------------

  @doc """
  Parse one agent file. The name comes from the filename (`<name>.md`),
  never from the frontmatter — the tree is the roster.
  """
  @spec parse(String.t(), binary()) :: {:ok, t()} | {:error, term()}
  def parse(name, binary) when is_binary(name) and is_binary(binary) do
    with {:ok, meta, body} <- parse_frontmatter(binary),
         {:ok, policy} <- checked_tool_policy(meta["tool_policy"]) do
      {:ok,
       %{
         name: name,
         title: string_or(meta["title"], name),
         description: string_or(meta["description"], ""),
         disabled: meta["disabled"] == true,
         catalyst_ref: blank_to_nil(meta["catalyst_ref"]),
         model: blank_to_nil(meta["model"]),
         tool_policy: policy,
         prompt: body
       }}
    end
  end

  @doc "Serialize an agent back to its file — the inverse of `parse/2`."
  @spec serialize(t()) :: binary()
  def serialize(%{name: _} = agent) do
    fields =
      [
        {"title", agent.title},
        {"description", blank_to_nil(agent.description)},
        {"catalyst_ref", agent.catalyst_ref},
        {"model", agent.model},
        {"disabled", if(agent.disabled, do: true)}
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.map(fn {k, v} -> "#{k}: #{scalar(v)}\n" end)

    policy =
      case Enum.sort(agent.tool_policy || %{}) do
        [] ->
          []

        pairs ->
          ["tool_policy:\n" | Enum.map(pairs, fn {k, v} -> "  #{key(k)}: #{v}\n" end)]
      end

    IO.iodata_to_binary([
      "---\n",
      fields,
      policy,
      "---\n\n",
      String.trim_trailing(agent.prompt || ""),
      "\n"
    ])
  end

  @doc """
  Split a frontmatter-markdown binary into `{:ok, meta, body}`. Shared by
  agent files and `SKILL.md` — any file that opens with a `---` fence.
  """
  @spec parse_frontmatter(binary()) :: {:ok, map(), String.t()} | {:error, term()}
  def parse_frontmatter("---\n" <> rest) do
    case String.split(rest, "\n---\n", parts: 2) do
      [yaml, body] ->
        # Leading/trailing newlines are framing, not content — normalizing
        # them keeps parse/serialize a stable round-trip.
        body = body |> String.trim_leading("\n") |> String.trim_trailing("\n")

        case YamlElixir.read_from_string(yaml) do
          {:ok, meta} when is_map(meta) -> {:ok, meta, body}
          {:ok, nil} -> {:ok, %{}, body}
          {:ok, _other} -> {:error, :frontmatter_not_a_map}
          {:error, reason} -> {:error, {:frontmatter_invalid, reason}}
        end

      _ ->
        {:error, :frontmatter_unterminated}
    end
  end

  def parse_frontmatter(_binary), do: {:error, :frontmatter_missing}

  # ---------------------------------------------------------------------------
  # Roster
  # ---------------------------------------------------------------------------

  @doc """
  The soul and every role under `aqua/` — the overlay union, so shipped and
  member-created roles list alike. Disabled agents are included (flagged);
  the callers that build a surface drop them. A file that fails to parse
  is skipped with its error in the second element — one broken role must
  not take the roster down. The soul comes first when the tree has one,
  then the roles by name.
  """
  @spec list(Context.t()) :: {:ok, [t()], [{String.t(), term()}]} | {:error, term()}
  def list(%Context{} = ctx) do
    case Arca.list_typed(ctx, AquaPath.roles_root()) do
      {:ok, entries} ->
        {roles, errors} =
          entries
          |> Enum.filter(fn {file, kind} -> kind == :file and String.ends_with?(file, ".md") end)
          |> Enum.map(fn {file, _kind} -> String.trim_trailing(file, ".md") end)
          |> Enum.reject(&AquaPath.soul?/1)
          |> Enum.reduce({[], []}, fn name, {ok, errs} ->
            case get(ctx, name) do
              {:ok, agent} -> {[agent | ok], errs}
              {:error, reason} -> {ok, [{name, reason} | errs]}
            end
          end)

        {soul, errors} =
          case get(ctx, AquaPath.soul_name()) do
            {:ok, agent} -> {[agent], errors}
            {:error, :not_found} -> {[], errors}
            {:error, reason} -> {[], [{AquaPath.soul_name(), reason} | errors]}
          end

        {:ok, soul ++ Enum.sort_by(roles, & &1.name), Enum.reverse(errors)}

      {:error, :not_found} ->
        {:ok, [], []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Whether this agent is the estate's soul, by the one reserved name."
  @spec soul?(t()) :: boolean()
  def soul?(%{name: name}), do: AquaPath.soul?(name)

  @doc "One agent by name — the soul or a role, whichever the name is — through the overlay union."
  @spec get(Context.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def get(%Context{} = ctx, name) when is_binary(name) do
    with {:ok, binary} <- Arca.get(ctx, AquaPath.agent_file(name)) do
      parse(name, binary)
    end
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp string_or(value, _fallback) when is_binary(value) and value != "", do: value
  defp string_or(_value, fallback), do: fallback

  defp blank_to_nil(value) when is_binary(value) and value != "", do: value
  defp blank_to_nil(_), do: nil

  defp checked_tool_policy(nil), do: {:ok, %{}}

  defp checked_tool_policy(policy) when is_map(policy) do
    if Enum.all?(policy, fn {k, v} -> is_binary(k) and is_binary(v) end),
      do: {:ok, policy},
      else: {:error, :tool_policy_not_a_string_map}
  end

  defp checked_tool_policy(_), do: {:error, :tool_policy_not_a_map}

  # The restricted emission grammar: booleans bare; strings plain when they
  # cannot be misread by a YAML parser, double-quoted (JSON-escaped, which
  # YAML accepts) otherwise.
  defp scalar(true), do: "true"
  defp scalar(false), do: "false"

  defp scalar(value) when is_binary(value) do
    if value =~ ~r/\A[A-Za-z0-9][A-Za-z0-9 _.,:\/\-()]*\z/ and
         not String.contains?(value, ": ") and
         not String.ends_with?(value, " ") do
      value
    else
      inspect(value)
    end
  end

  defp key(k) do
    if k =~ ~r/\A[A-Za-z0-9_.\-]+(\.\*)?\z/ or k =~ ~r/\A[A-Za-z0-9_\-]+\z/,
      do: k,
      else: inspect(k)
  end
end
