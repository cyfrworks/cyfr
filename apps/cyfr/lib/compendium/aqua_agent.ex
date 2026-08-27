# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.AquaAgent do
  @moduledoc """
  The AQUA agent file format and roster: one frontmatter-markdown file per
  agent under `aqua/agents/` — the directory IS the roster, served through
  the seed overlay like every other aqua path, so an unedited agent tracks
  the shipped seed and an edited one shadows only itself.

  The format is deliberately portable — the shape Claude Code speaks for
  its subagents (`.claude/agents/*.md`): YAML frontmatter carrying the
  metadata, the system prompt as the markdown body. CYFR's additions are
  `catalyst_ref` (which LLM catalyst executes the agent — defaultable),
  `tool_policy` (the per-action allowlist, richer than a flat tools list),
  `role: orchestrator` / `parent:` (the orchestration relationship
  `agent.json` used to nest), `default: true` (the orchestrator a
  conversation starts on), and `disabled: true` (how a shipped agent is
  taken out of the roster — shipped files revert, they don't delete).

      ---
      title: Arcade
      description: Spawn an Arcade specialist …
      parent: aqua
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
  `parse_frontmatter/1` is shared with the skills tree (`SKILL.md` files
  under `aqua/skills/` follow the open Agent Skills convention: `name` +
  `description` frontmatter, instructions as the body).
  """

  alias Compendium.AquaPath
  alias Sanctum.Context

  @type role :: :orchestrator | :sub_agent

  @type t :: %{
          name: String.t(),
          title: String.t(),
          description: String.t(),
          role: role(),
          parent: String.t() | nil,
          default: boolean(),
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
  never from the frontmatter — the directory is the roster.
  """
  @spec parse(String.t(), binary()) :: {:ok, t()} | {:error, term()}
  def parse(name, binary) when is_binary(name) and is_binary(binary) do
    with {:ok, meta, body} <- parse_frontmatter(binary),
         {:ok, policy} <- checked_tool_policy(meta["tool_policy"]) do
      role = if meta["role"] == "orchestrator", do: :orchestrator, else: :sub_agent

      {:ok,
       %{
         name: name,
         title: string_or(meta["title"], name),
         description: string_or(meta["description"], ""),
         role: role,
         parent: if(is_binary(meta["parent"]) and meta["parent"] != "", do: meta["parent"]),
         default: meta["default"] == true,
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
        {"role", if(agent.role == :orchestrator, do: "orchestrator")},
        {"default", if(agent.default, do: true)},
        {"parent", agent.parent},
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
  Every agent under `aqua/agents/` — the overlay union, so shipped and
  member-created agents list alike. Disabled agents are included (flagged);
  `roster/1` is the view that drops them. A file that fails to parse is
  skipped with its error in the second element — one broken agent must not
  take the roster down.
  """
  @spec list(Context.t()) :: {:ok, [t()], [{String.t(), term()}]} | {:error, term()}
  def list(%Context{} = ctx) do
    case Arca.list_typed(ctx, AquaPath.agents_root()) do
      {:ok, entries} ->
        {agents, errors} =
          entries
          |> Enum.filter(fn {file, kind} -> kind == :file and String.ends_with?(file, ".md") end)
          |> Enum.map(fn {file, _kind} -> String.trim_trailing(file, ".md") end)
          |> Enum.reduce({[], []}, fn name, {ok, errs} ->
            case get(ctx, name) do
              {:ok, agent} -> {[agent | ok], errs}
              {:error, reason} -> {ok, [{name, reason} | errs]}
            end
          end)

        {:ok, Enum.sort_by(agents, & &1.name), Enum.reverse(errors)}

      {:error, :not_found} ->
        {:ok, [], []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "One agent by name, through the overlay union."
  @spec get(Context.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def get(%Context{} = ctx, name) when is_binary(name) do
    with {:ok, binary} <- Arca.get(ctx, AquaPath.agent_file(name)) do
      parse(name, binary)
    end
  end

  @doc """
  The validated, active roster: disabled agents dropped, then — at least
  one orchestrator; exactly one default (a single orchestrator IS the
  default, flag or no flag — portable files need no CYFR field; several
  need exactly one `default: true`); every sub-agent's parent must name an
  orchestrator.
  """
  @spec roster(Context.t()) ::
          {:ok, %{agents: [t()], orchestrators: [t()], default: t()}} | {:error, term()}
  def roster(%Context{} = ctx) do
    with {:ok, all, _errors} <- list(ctx) do
      agents = Enum.reject(all, & &1.disabled)
      orchestrators = Enum.filter(agents, &(&1.role == :orchestrator))
      names = MapSet.new(orchestrators, & &1.name)

      bad_parent =
        Enum.find(agents, fn a ->
          a.role == :sub_agent and not is_nil(a.parent) and not MapSet.member?(names, a.parent)
        end)

      cond do
        orchestrators == [] ->
          {:error, :no_orchestrator}

        bad_parent != nil ->
          {:error, {:unknown_parent, bad_parent.name, bad_parent.parent}}

        true ->
          case {orchestrators, Enum.filter(orchestrators, & &1.default)} do
            {[only], _} -> {:ok, %{agents: agents, orchestrators: orchestrators, default: only}}
            {_, [one]} -> {:ok, %{agents: agents, orchestrators: orchestrators, default: one}}
            {_, []} -> {:error, :no_default_orchestrator}
            {_, _many} -> {:error, :multiple_default_orchestrators}
          end
      end
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
