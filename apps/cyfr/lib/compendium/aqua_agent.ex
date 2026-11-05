# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.AquaAgent do
  @moduledoc """
  The AQUA agent file format and the tree's roster: the soul at
  `aqua/aqua.md` and one frontmatter-markdown file per crew member under
  `aqua/crew/`, served through the seed overlay like every other aqua
  path, so an unedited file tracks the shipped seed and an edited one
  shadows only itself.

  The format is deliberately portable — the shape Claude Code speaks for
  its subagents (`.claude/agents/*.md`): YAML frontmatter carrying the
  metadata, the system prompt as the markdown body. Which file is the
  soul and which is a crew member is the tree's to say
  (`Compendium.AquaPath`), never the frontmatter's; the wire `type` is
  `"soul"` or `"crew"` accordingly.

      ---
      title: Explorer
      description: Deep web research — several searches, cross-checked
      avoid: Changing the athanor's files or components
      catalyst_ref: catalyst:local.gemini
      model: gemini-pro-latest
      options:
        effort: high
      ---
      You are the explorer …

  The keys: `title`; `description`, what the member is good at, which the
  soul reads when it hands a job; `avoid`, what to hand it never;
  `catalyst_ref` and `model`, the brain its turns run on; `options`, the
  brain options its every request sets (a flat map of strings, integers
  and booleans, which the brain's `describe` declares); `disabled: true`,
  how a shipped member is taken out of the crew (shipped files revert,
  they don't delete); and on the soul alone `tool_policy`, the per-action
  allowlist. A crew member has no policy of its own: it runs under the
  soul's (`under_soul/2`), narrowed only by the request that asks it, so a
  `tool_policy` in a crew file refuses the file.

  The frontmatter grammar is restricted on purpose: string and boolean
  scalars plus two flat maps (`tool_policy`, `options`) — enough for
  portability, small enough that `serialize/1` can emit it byte-stably.
  The policy's own grammar — keys `tool.action`, `tool.*` or
  `native_search`, values `ask` or `auto` — is the one rule the file
  parser and the `aqua` tool door both apply, so a value the runtime would
  otherwise have to reinterpret never lands. What an authored policy may
  say on top of that is `validate_tool_policy/1`, the door's rule alone.
  `parse_frontmatter/1` is shared with the scrolls (`SKILL.md` files under
  `aqua/skills/` follow the open Agent Skills convention: `name` +
  `description` frontmatter, instructions as the body).
  """

  alias Compendium.AquaPath
  alias Sanctum.VirtualTools
  alias Sanctum.Context

  @type option_value :: String.t() | integer() | boolean()

  @type t :: %{
          name: String.t(),
          title: String.t(),
          description: String.t(),
          avoid: String.t(),
          disabled: boolean(),
          catalyst_ref: String.t() | nil,
          model: String.t() | nil,
          options: %{String.t() => option_value()},
          tool_policy: %{String.t() => String.t()},
          prompt: String.t()
        }

  # ---------------------------------------------------------------------------
  # Format
  # ---------------------------------------------------------------------------

  @doc """
  Parse one agent file as it is written. The name comes from the filename
  (`<name>.md`), never from the frontmatter — the tree is the roster. A
  `tool_policy` outside the grammar, a `tool_policy` in a crew member's
  file (`:crew_has_no_tool_policy`), or `options` that are not a flat map
  of strings, integers and booleans (`:options_invalid`) refuse the whole
  file with its typed reason rather than parsing to something the runtime
  would have to guess at.

  A crew member parsed here holds no policy; the one it runs under is the
  soul's (`resolve/3`, `under_soul/2`).
  """
  @spec parse(String.t(), binary()) :: {:ok, t()} | {:error, term()}
  def parse(name, binary) when is_binary(name) and is_binary(binary) do
    with {:ok, meta, body} <- parse_frontmatter(binary),
         {:ok, policy} <- policy_of(name, meta),
         {:ok, options} <- options_of(meta["options"]) do
      {:ok,
       %{
         name: name,
         title: string_or(meta["title"], name),
         description: string_or(meta["description"], ""),
         avoid: string_or(meta["avoid"], ""),
         disabled: meta["disabled"] == true,
         catalyst_ref: blank_to_nil(meta["catalyst_ref"]),
         model: blank_to_nil(meta["model"]),
         options: options,
         tool_policy: policy,
         prompt: body
       }}
    end
  end

  @doc """
  An agent file as it runs: parsed (`parse/2`), and a crew member put
  under the soul the tree holds now (`under_soul/2`). The one read every
  runtime view of an agent's bytes goes through — the roster, the index's
  capability digest and a turn's pinned revision alike — so a crew
  member's capability always names the policy it runs under.
  """
  @spec resolve(Context.t(), String.t(), binary()) :: {:ok, t()} | {:error, term()}
  def resolve(%Context{} = ctx, name, binary) when is_binary(name) and is_binary(binary) do
    with {:ok, agent} <- parse(name, binary) do
      if AquaPath.soul?(name) do
        {:ok, agent}
      else
        with {:ok, policy} <- soul_policy(ctx), do: {:ok, under_soul(agent, policy)}
      end
    end
  end

  @doc """
  A crew member under the soul's tool policy: every member gets the
  soul's whole allowlist, and a request that asks it may narrow that for
  one job (`Aqua.Loop.Turn`). The soul itself is answered as it is.
  """
  @spec under_soul(t(), %{String.t() => String.t()}) :: t()
  def under_soul(%{name: name} = agent, soul_policy) when is_map(soul_policy) do
    if AquaPath.soul?(name), do: agent, else: %{agent | tool_policy: soul_policy}
  end

  # The soul's policy as the tree holds it now; an athanor with no soul, a
  # soul set aside or one that does not parse gives its crew none, as
  # `list/1` does. A store that cannot answer is its refusal.
  defp soul_policy(ctx) do
    case Arca.get(Sanctum.Context.actor(ctx), AquaPath.soul_file()) do
      {:ok, bytes} ->
        case parse(AquaPath.soul_name(), bytes) do
          {:ok, %{disabled: false} = soul} -> {:ok, soul.tool_policy}
          _set_aside_or_unparsed -> {:ok, %{}}
        end

      {:error, :not_found} ->
        {:ok, %{}}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Serialize an agent back to its file — the inverse of `parse/2`. A crew
  member's file carries no policy, whatever the agent map holds.
  """
  @spec serialize(t()) :: binary()
  def serialize(%{name: name} = agent) do
    fields =
      [
        {"title", agent.title},
        {"description", blank_to_nil(agent.description)},
        {"avoid", blank_to_nil(Map.get(agent, :avoid))},
        {"catalyst_ref", agent.catalyst_ref},
        {"model", agent.model},
        {"disabled", if(agent.disabled, do: true)}
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.map(fn {k, v} -> "#{k}: #{scalar(v)}\n" end)

    options =
      case Enum.sort(Map.get(agent, :options) || %{}) do
        [] -> []
        pairs -> ["options:\n" | Enum.map(pairs, fn {k, v} -> "  #{key(k)}: #{option(v)}\n" end)]
      end

    policy =
      case if(AquaPath.soul?(name), do: Enum.sort(agent.tool_policy || %{}), else: []) do
        [] ->
          []

        pairs ->
          ["tool_policy:\n" | Enum.map(pairs, fn {k, v} -> "  #{key(k)}: #{v}\n" end)]
      end

    IO.iodata_to_binary([
      "---\n",
      fields,
      options,
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
  The soul and every crew member under `aqua/` — the overlay union, so
  shipped and athanor-made members list alike, each crew member under the
  soul's policy (`under_soul/2`). Disabled agents are included (flagged);
  the callers that build a surface drop them. A file that fails to parse
  is skipped with its error in the second element — one broken member
  must not take the roster down; a soul that fails to parse gives the
  crew no policy. The soul comes first when the tree has one, then the
  crew by name.
  """
  @spec list(Context.t()) :: {:ok, [t()], [{String.t(), term()}]} | {:error, term()}
  def list(%Context{} = ctx) do
    case Arca.list_typed(Sanctum.Context.actor(ctx), AquaPath.crew_root()) do
      {:ok, entries} ->
        {soul, errors} =
          case get(ctx, AquaPath.soul_name()) do
            {:ok, agent} -> {[agent], []}
            {:error, :not_found} -> {[], []}
            {:error, reason} -> {[], [{AquaPath.soul_name(), reason}]}
          end

        policy =
          case soul do
            [%{disabled: false, tool_policy: policy}] -> policy
            _none_or_disabled -> %{}
          end

        {crew, errors} =
          entries
          |> Enum.filter(fn {file, kind} -> kind == :file and String.ends_with?(file, ".md") end)
          |> Enum.map(fn {file, _kind} -> String.trim_trailing(file, ".md") end)
          # The tree's grammar is the roster: a file whose name the path
          # grammar refuses is plain storage, never a crew member.
          |> Enum.filter(&AquaPath.valid_name?/1)
          |> Enum.reject(&AquaPath.soul?/1)
          |> Enum.reduce({[], errors}, fn name, {ok, errs} ->
            case read(ctx, name) do
              {:ok, member} -> {[under_soul(member, policy) | ok], errs}
              {:error, reason} -> {ok, [{name, reason} | errs]}
            end
          end)

        {:ok, soul ++ Enum.sort_by(crew, & &1.name), Enum.reverse(errors)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @soul_type "soul"
  @crew_type "crew"

  @doc """
  The `type` a soul carries on the wire — what the `aqua` tool's `list` and
  `get` answer and what every surface filters on. Spelled here once, so a
  reader that compares against the literal cannot drift from the writer.
  """
  @spec soul_type() :: String.t()
  def soul_type, do: @soul_type

  @doc "The `type` a crew member carries on the wire — see `soul_type/0`."
  @spec crew_type() :: String.t()
  def crew_type, do: @crew_type

  @doc """
  An agent's wire `type`, decided by the tree: the reserved name is the
  soul (`Compendium.AquaPath.soul?/1`), every other name a crew member.
  """
  @spec type_of(t()) :: String.t()
  def type_of(%{name: name}), do: type_of_name(name)

  defp type_of_name(name), do: if(AquaPath.soul?(name), do: @soul_type, else: @crew_type)

  @doc """
  The security-relevant subset of an agent, as a manifest: what it is
  (soul or crew), which catalyst and model run it with which options,
  whether it is disabled, and the tool policy it runs under (a crew
  member's is the soul's). Nothing else — not the prompt, the title, the
  description or what to avoid, which change what the agent says and
  never what it may do. Pure: the same agent projects to the same map, so
  a digest of it is the agent's capability revision.
  """
  @spec to_manifest(t()) :: map()
  def to_manifest(%{name: name} = agent) do
    # An unset catalyst or model, and no options, are absent, never a
    # null: the projection names what the agent declares, and its digest
    # is canonical JSON.
    options = Map.get(agent, :options) || %{}

    %{
      "name" => name,
      "type" => type_of(agent),
      "disabled" => agent.disabled == true,
      "tool_policy" => agent.tool_policy
    }
    |> Prima.MapUtil.put_present("catalyst_ref", agent.catalyst_ref)
    |> Prima.MapUtil.put_present("model", agent.model)
    |> Prima.MapUtil.put_present("options", if(options == %{}, do: nil, else: options))
  end

  @doc "The digest of `to_manifest/1`: the agent's capability revision."
  @spec capability_digest(t()) :: {:ok, String.t()} | {:error, term()}
  def capability_digest(agent), do: Prima.JCS.hash(to_manifest(agent))

  @doc """
  One agent by name — the soul or a crew member, whichever the name is —
  through the overlay union, as it runs (`resolve/3`).
  """
  @spec get(Context.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def get(%Context{} = ctx, name) when is_binary(name) do
    with {:ok, binary} <- Arca.get(Sanctum.Context.actor(ctx), AquaPath.agent_file(name)) do
      resolve(ctx, name, binary)
    end
  end

  # One file as it is written, for a list that composes the crew itself.
  defp read(ctx, name) do
    with {:ok, binary} <- Arca.get(Sanctum.Context.actor(ctx), AquaPath.agent_file(name)) do
      parse(name, binary)
    end
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  # The soul's policy is checked as written, an absent one the empty
  # allowlist; a crew member's file holds none.
  defp policy_of(name, meta) do
    case {AquaPath.soul?(name), Map.fetch(meta, "tool_policy")} do
      {true, :error} -> {:ok, %{}}
      {true, {:ok, nil}} -> {:ok, %{}}
      {true, {:ok, policy}} -> with :ok <- check_tool_policy(policy), do: {:ok, policy}
      {false, :error} -> {:ok, %{}}
      {false, {:ok, _policy}} -> {:error, :crew_has_no_tool_policy}
    end
  end

  # A brain's options as the file holds them: a flat map of non-empty
  # names to strings, integers and booleans, the kinds `Prima.Model`
  # declares. Which names and values the brain takes is the brain's to
  # say, checked when a turn opens on it.
  defp options_of(nil), do: {:ok, %{}}

  defp options_of(options) when is_map(options) do
    if Enum.all?(options, fn {name, value} ->
         is_binary(name) and name != "" and
           (is_binary(value) or is_integer(value) or is_boolean(value))
       end),
       do: {:ok, options},
       else: {:error, :options_invalid}
  end

  defp options_of(_options), do: {:error, :options_invalid}

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

  # A `tool_policy` map against the grammar the runtime reads: every key is
  # `tool.action`, `tool.*` or the bare `native_search`, every value exactly
  # `"ask"` or `"auto"`. The guest treats only `"auto"` as automatic and
  # anything else as ask, so a value outside the vocabulary is refused here
  # — at the file and at the tool door alike — rather than persisted for the
  # runtime to reinterpret.
  @spec check_tool_policy(term()) :: :ok | {:error, tool_policy_error()}
  defp check_tool_policy(policy) when is_map(policy) do
    Enum.find_value(policy, :ok, fn {key, value} ->
      cond do
        not valid_policy_key?(key) -> {:error, {:tool_policy_invalid_key, key}}
        value not in ["ask", "auto"] -> {:error, {:tool_policy_invalid_value, key, value}}
        true -> nil
      end
    end)
  end

  defp check_tool_policy(_policy), do: {:error, :tool_policy_not_a_map}

  @doc """
  What an AUTHORED `tool_policy` may say — the soul's, the one policy an
  athanor writes: the grammar first, then the rules a write door applies
  on top of it. A door refuses what a person must not be able to write: a
  UI event held at anything but `auto`, an automatic destructive or
  external action, and a `tool.*` glob at `auto` whose actions include one
  of those.

  The parser holds a file to the grammar only, so a hand-edited file that
  says more than a door would allow still loads; the assistant's runtime
  ceiling demotes whatever loaded, so a file written past this door
  reaches the guest already demoted.

  An action's kind is the gate's classification (`Sanctum.Catalog.tool_kind/2`:
  a virtual hand's from `Sanctum.VirtualTools`, `:external` for a
  `server:tool`, else the catalogued tool's annotation); only an action
  `Sanctum.Catalog.auto_permitted?/2` admits may be `auto` (a kind that may
  run without a card, declared to take a standing allow at agent scope),
  and an action whose kind is unknown is left to that ceiling.

  `:ok`, a typed refusal, or `{:error, sentence}` — the sentence is the
  person's.
  """
  @spec validate_tool_policy(term()) :: :ok | {:error, tool_policy_error() | String.t()}
  def validate_tool_policy(policy) do
    with :ok <- check_tool_policy(policy),
         :ok <- check_auto_only(policy) do
      check_authored(policy)
    end
  end

  defp check_authored(policy) do
    Enum.find_value(policy, :ok, fn
      {key, "auto"} -> auto_refusal(key)
      _held -> nil
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
  defp kind_for(tool, action), do: Sanctum.Catalog.tool_kind(tool, action)

  defp auto_permitted?(tool, action), do: Sanctum.Catalog.auto_permitted?(tool, action)

  # What a `tool.*` glob stands for, in declared order.
  defp actions_of(tool), do: Sanctum.Catalog.tool_actions(tool)

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

  # An option's value keeps its kind through the round trip: an integer
  # or a boolean bare, a string always JSON-quoted, so "true" or "8"
  # written as a string is read back as one.
  defp option(value) when is_boolean(value) or is_integer(value), do: to_string(value)
  defp option(value) when is_binary(value), do: Jason.encode!(value)

  defp key(k) do
    if k =~ ~r/\A[A-Za-z0-9_.\-]+(\.\*)?\z/ or k =~ ~r/\A[A-Za-z0-9_\-]+\z/,
      do: k,
      else: inspect(k)
  end
end
