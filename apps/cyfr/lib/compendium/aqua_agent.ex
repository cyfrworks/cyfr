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
      title: Artisan
      description: Put on the Artisan role to …
      catalyst_ref: catalyst:local.claude
      model: claude-sonnet-4-6
      tool_policy:
        files.read: auto
        build.compile: ask
      ---
      You are AQUA in the Artisan role …

  The frontmatter grammar is restricted on purpose: string and boolean
  scalars plus the one flat string→string map (`tool_policy`) — enough for
  portability, small enough that `serialize/1` can emit it byte-stably.
  The policy's own grammar — keys `tool.action`, `tool.*` or
  `native_search`, values `ask` or `auto` — is `check_tool_policy/1`, the
  one rule the file parser and the `aqua` tool door both apply, so a
  value the runtime would otherwise have to reinterpret never lands. What
  an authored policy may say on top of that grammar is
  `validate_tool_policy/2`, the door's rule alone.
  `parse_frontmatter/1` is shared with the scrolls (`SKILL.md` files under
  `aqua/skills/` follow the open Agent Skills convention: `name` +
  `description` frontmatter, instructions as the body).
  """

  alias Compendium.AquaPath
  alias Grimoire.VirtualTools
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
  never from the frontmatter — the tree is the roster. A `tool_policy`
  outside the grammar refuses the whole file with its typed reason
  (`t:tool_policy_error/0`) rather than parsing to something the runtime
  would have to guess at.
  """
  @spec parse(String.t(), binary()) :: {:ok, t()} | {:error, term()}
  def parse(name, binary) when is_binary(name) and is_binary(binary) do
    with {:ok, meta, body} <- parse_frontmatter(binary),
         policy = policy_or_empty(meta["tool_policy"]),
         :ok <- check_tool_policy(policy) do
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
    case Arca.list_typed(Sanctum.Context.actor(ctx), AquaPath.roles_root()) do
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

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The key on a soul's allowlist that gives it leave to clone into the role
  `name` — the delegation glob the runtime reads (`Aqua.ToolGrants`) and
  every writer of it spells through here.
  """
  @spec clone_glob(String.t()) :: String.t()
  def clone_glob(name) when is_binary(name), do: name <> ".*"

  @doc "Whether this agent is the athanor's soul, by the one reserved name."
  @spec soul?(t()) :: boolean()
  def soul?(%{name: name}), do: AquaPath.soul?(name)

  @soul_type "soul"
  @role_type "role"

  @doc """
  The `type` a soul carries on the wire — what the `aqua` tool's `list` and
  `get` answer and what every surface filters on. Spelled here once, so a
  reader that compares against the literal cannot drift from the writer.
  """
  @spec soul_type() :: String.t()
  def soul_type, do: @soul_type

  @doc "The `type` a role carries on the wire — see `soul_type/0`."
  @spec role_type() :: String.t()
  def role_type, do: @role_type

  @doc """
  An agent's wire `type`, decided by the tree: the reserved name is the
  soul, every other name a role (`soul?/1`).
  """
  @spec type_of(t()) :: String.t()
  def type_of(agent), do: if(soul?(agent), do: @soul_type, else: @role_type)

  @doc """
  The security-relevant subset of an agent, as a manifest: what it is
  (soul or role), which catalyst and model run it, whether it is
  disabled, and its tool policy. Nothing else — not the prompt, the title
  or the description, which change what the agent says and never what it
  may do. Pure: the same agent projects to the same map, so a digest of
  it is the agent's capability revision.
  """
  @spec to_manifest(t()) :: map()
  def to_manifest(%{name: name} = agent) do
    # An unset catalyst or model is absent, never a null: the projection
    # names what the agent declares, and its digest is canonical JSON.
    %{
      "name" => name,
      "type" => type_of(agent),
      "disabled" => agent.disabled == true,
      "tool_policy" => agent.tool_policy
    }
    |> Prima.MapUtil.put_present("catalyst_ref", agent.catalyst_ref)
    |> Prima.MapUtil.put_present("model", agent.model)
  end

  @doc "The digest of `to_manifest/1`: the agent's capability revision."
  @spec capability_digest(t()) :: {:ok, String.t()} | {:error, term()}
  def capability_digest(agent), do: Prima.JCS.hash(to_manifest(agent))

  @doc "One agent by name — the soul or a role, whichever the name is — through the overlay union."
  @spec get(Context.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def get(%Context{} = ctx, name) when is_binary(name) do
    with {:ok, binary} <- Arca.get(Sanctum.Context.actor(ctx), AquaPath.agent_file(name)) do
      parse(name, binary)
    end
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  # An absent `tool_policy` is the empty allowlist; anything present is
  # checked as written.
  defp policy_or_empty(nil), do: %{}
  defp policy_or_empty(policy), do: policy

  defp string_or(value, _fallback) when is_binary(value) and value != "", do: value
  defp string_or(_value, fallback), do: fallback

  defp blank_to_nil(value) when is_binary(value) and value != "", do: value
  defp blank_to_nil(_), do: nil

  @typedoc """
  Why a `tool_policy` is refused: not a map at all, a key that is neither
  `tool.action`, `tool.*` nor `native_search`, or a value that is neither
  `"ask"` nor `"auto"`.
  """
  @type tool_policy_error ::
          :tool_policy_not_a_map
          | {:tool_policy_invalid_key, term()}
          | {:tool_policy_invalid_value, String.t(), term()}

  @doc """
  Check a `tool_policy` map against the grammar the runtime reads: every
  key is `tool.action`, `tool.*` or the bare `native_search`, every value
  exactly `"ask"` or `"auto"`. The guest treats only `"auto"` as
  automatic and anything else as ask, so a value outside the vocabulary is
  refused here — at the file and at the tool door alike — rather than
  persisted for the runtime to reinterpret.
  """
  @spec check_tool_policy(term()) :: :ok | {:error, tool_policy_error()}
  def check_tool_policy(policy) when is_map(policy) do
    Enum.find_value(policy, :ok, fn {key, value} ->
      cond do
        not valid_policy_key?(key) -> {:error, {:tool_policy_invalid_key, key}}
        value not in ["ask", "auto"] -> {:error, {:tool_policy_invalid_value, key, value}}
        true -> nil
      end
    end)
  end

  def check_tool_policy(_policy), do: {:error, :tool_policy_not_a_map}

  @doc """
  What an AUTHORED `tool_policy` may say: the grammar
  (`check_tool_policy/1`) first, then the rules a write door applies on
  top of it. A door refuses what a person must not be able to write: a
  UI event held at anything but `auto`, an automatic destructive or
  external action on any agent, a `tool.*` glob at `auto` whose actions
  include one of those, and an `ask` on a role (a cloned role's answer is
  a tool result, not a turn — it has no card to raise).

  The parser keeps grammar only, so a hand-edited file still loads; the
  assistant's runtime ceiling demotes whatever loaded anyway, so a file
  written past this door reaches the guest already demoted.

  An action's kind is the gate's classification (`Grimoire.tool_kind/2`:
  a virtual hand's from `Grimoire.VirtualTools`, `:external` for a
  `server:tool`, else the catalogued tool's annotation); only a kind
  `Grimoire.VirtualTools.auto_permitted_kind?/1` admits may be `auto`, and an
  action whose kind is unknown is left to that ceiling.

  `:ok`, a typed grammar refusal, or `{:error, sentence}` — the sentence
  is the person's.
  """
  @spec validate_tool_policy(term(), String.t()) ::
          :ok | {:error, tool_policy_error() | String.t()}
  def validate_tool_policy(policy, agent_type) do
    with :ok <- check_tool_policy(policy),
         :ok <- check_auto_only(policy) do
      check_authored(policy, agent_type)
    end
  end

  defp check_authored(policy, agent_type) do
    role? = agent_type == @role_type

    Enum.find_value(policy, :ok, fn {key, value} ->
      cond do
        role? and value == "ask" ->
          {:error,
           "#{key} cannot be held at ask on a role — a cloned role has no card to raise; " <>
             "grant it (auto) or leave it out"}

        value == "auto" ->
          auto_refusal(key)

        true ->
          nil
      end
    end)
  end

  defp auto_refusal(key) do
    case String.split(key, ".", parts: 2) do
      [tool, "*"] ->
        case Enum.reject(actions_of(tool), &auto_permitted?(tool, &1)) do
          [] ->
            nil

          asking ->
            {:error,
             "#{key} at auto would cover #{Enum.map_join(asking, ", ", &"#{tool}.#{&1}")}, " <>
               "which always asks — list the actions instead"}
        end

      [tool, action] ->
        cond do
          VirtualTools.auto_only?(tool, action) -> nil
          kind_for(tool, action) == nil -> nil
          auto_permitted?(tool, action) -> nil
          true -> {:error, "#{key} always asks — it cannot be set to auto"}
        end

      _ ->
        nil
    end
  end

  # A UI event (`request_setup.open`) is answered by the guest in place, so
  # a policy that holds it at `ask` names a card nothing can execute.
  defp check_auto_only(policy) do
    Enum.find_value(policy, :ok, fn {key, value} ->
      case String.split(key, ".", parts: 2) do
        [tool, action] ->
          if VirtualTools.auto_only?(tool, action) and value != "auto",
            do: {:error, "#{key} runs on its own — it is auto or absent, never ask"}

        _ ->
          nil
      end
    end)
  end

  # The gate's one classification: a virtual hand's kind, `:external` for
  # a `server:tool`, else the catalogued tool's annotation, nil unknown.
  defp kind_for(tool, action), do: Grimoire.tool_kind(tool, action)

  defp auto_permitted?(tool, action),
    do: VirtualTools.auto_permitted_kind?(kind_for(tool, action))

  # What a `tool.*` glob stands for, in declared order.
  defp actions_of(tool), do: Grimoire.tool_actions(tool)

  defp valid_policy_key?("native_search"), do: true

  defp valid_policy_key?(key) when is_binary(key) do
    case String.split(key, ".") do
      [tool, action] when tool != "" and action != "" -> true
      _ -> false
    end
  end

  defp valid_policy_key?(_key), do: false

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
