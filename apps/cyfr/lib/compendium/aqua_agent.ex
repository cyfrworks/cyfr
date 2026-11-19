# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.AquaAgent do
  @moduledoc """
  The Aqua agent file format and the tree's roster: the soul at
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
      mode: read-only
      options:
        effort: high
      ---
      You are the explorer …

  The keys: `title`; `description`, what the member is good at, which the
  soul reads when it hands a job; `avoid`, what to hand it never; the
  brain its turns run on, named once, as a catalyst (`catalyst_ref`) or
  as a program (`program`, the id of the athanor's program row it runs
  in), and `model`, the model it asks for (for a program, its harness's
  model name); `options`, the brain options its every request sets (a
  flat map of strings, integers and booleans, which the brain's
  `describe` declares); `disabled: true`, how a shipped member is taken
  out of the crew (shipped files revert, they don't delete); `mode`,
  `read-only` or `auto`, which decides what of its offered tools it runs
  (`Aqua.Loop.Policy`; a file without the line is `auto`); and on the
  soul alone `tools`, the tools it is offered, each `tool.action`,
  `native_search` or `server:tool`, one action an entry (there is no
  wildcard: every action of a tool is listed by name). An absent list
  offers nothing. A crew member is offered the soul's (`under_soul/2`), narrowed
  only by the request that asks it, so a `tools` list in a crew file
  refuses the file. A file that still holds the retired `tool_policy`
  is refused, soul or crew (`:tool_policy_retired`), with the sentence
  `Prima.AgentRef.tool_policy_retired/0` says.

  The frontmatter grammar is restricted on purpose: string and boolean
  scalars, one list of strings (`tools`) and one flat map (`options`) —
  enough for portability, small enough that `serialize/1` can emit it
  byte-stably. The list's grammar is the one rule the file parser and the
  `aqua` tool door both apply (`check_tools/1`), so an entry the runtime
  would otherwise have to reinterpret never lands.
  `parse_frontmatter/1` is shared with the scrolls (`SKILL.md` files under
  `aqua/skills/` follow the open Agent Skills convention: `name` +
  `description` frontmatter, instructions as the body).
  """

  alias Compendium.AquaPath
  alias Sanctum.Context

  @type option_value :: String.t() | integer() | boolean()

  @type t :: %{
          name: String.t(),
          title: String.t(),
          description: String.t(),
          avoid: String.t(),
          disabled: boolean(),
          catalyst_ref: String.t() | nil,
          program: String.t() | nil,
          model: String.t() | nil,
          options: %{String.t() => option_value()},
          mode: mode(),
          tools: [String.t()],
          prompt: String.t()
        }

  @typedoc "What of its offered tools a member runs: reads alone, or all of them."
  @type mode :: String.t()

  @modes ["read-only", "auto"]

  # ---------------------------------------------------------------------------
  # Format
  # ---------------------------------------------------------------------------

  @doc """
  Parse one agent file as it is written. The name comes from the filename
  (`<name>.md`), never from the frontmatter — the tree is the roster. A
  `tool_policy` in any file (`:tool_policy_retired`), a `mode` that is
  neither `read-only` nor `auto` (`{:mode_invalid, value}`), a `tools`
  list outside the grammar (`check_tools/1`), a `tools` list in a crew
  member's file (`:crew_has_no_tools`), `options` that are not a flat map
  of strings, integers and booleans (`:options_invalid`), or a brain
  named both as a catalyst and as a program (`:catalyst_and_program`,
  `check_brain/1`) refuse the whole file with its typed reason rather
  than parsing to something the runtime would have to guess at.

  A crew member parsed here is offered nothing; what it is offered is the
  soul's list (`resolve/3`, `under_soul/2`). The list is kept sorted and
  without repeats, so a file's tools have one form.
  """
  @spec parse(String.t(), binary()) :: {:ok, t()} | {:error, term()}
  def parse(name, binary) when is_binary(name) and is_binary(binary) do
    with {:ok, meta, body} <- parse_frontmatter(binary),
         :ok <- not_retired(meta),
         {:ok, mode} <- mode_of(meta),
         {:ok, tools} <- tools_of(name, meta),
         {:ok, options} <- options_of(meta["options"]),
         agent = %{
           name: name,
           title: string_or(meta["title"], name),
           description: string_or(meta["description"], ""),
           avoid: string_or(meta["avoid"], ""),
           disabled: meta["disabled"] == true,
           catalyst_ref: blank_to_nil(meta["catalyst_ref"]),
           program: blank_to_nil(meta["program"]),
           model: blank_to_nil(meta["model"]),
           options: options,
           mode: mode,
           tools: tools,
           prompt: body
         },
         :ok <- check_brain(agent) do
      {:ok, agent}
    end
  end

  @doc """
  Whether `agent` names its brain at most once: a catalyst
  (`catalyst_ref`) or a program (`program`), never both. The one rule the
  file parser and the `aqua` tool door both apply, so no write lands a
  file that would not parse back.
  """
  @spec check_brain(map()) :: :ok | {:error, :catalyst_and_program}
  def check_brain(agent) when is_map(agent) do
    if named?(Map.get(agent, :catalyst_ref)) and named?(Map.get(agent, :program)),
      do: {:error, :catalyst_and_program},
      else: :ok
  end

  defp named?(value), do: is_binary(value) and value != ""

  @doc """
  An agent file as it runs: parsed (`parse/2`), and a crew member put
  under the soul the tree holds now (`under_soul/2`). The one read every
  runtime view of an agent's bytes goes through — the roster, the index's
  capability digest and a turn's pinned revision alike — so a crew
  member's capability always names the tools it is offered.
  """
  @spec resolve(Context.t(), String.t(), binary()) :: {:ok, t()} | {:error, term()}
  def resolve(%Context{} = ctx, name, binary) when is_binary(name) and is_binary(binary) do
    with {:ok, agent} <- parse(name, binary) do
      if AquaPath.soul?(name) do
        {:ok, agent}
      else
        with {:ok, tools} <- soul_tools(ctx), do: {:ok, under_soul(agent, tools)}
      end
    end
  end

  @doc """
  A crew member under the soul's tools: every member is offered the
  soul's whole list, and a request that asks it may narrow that for one
  job (`Aqua.Loop.Turn`). Its mode stays its own. The soul itself is
  answered as it is.
  """
  @spec under_soul(t(), [String.t()]) :: t()
  def under_soul(%{name: name} = agent, soul_tools) when is_list(soul_tools) do
    if AquaPath.soul?(name), do: agent, else: %{agent | tools: soul_tools}
  end

  # The soul's tools as the tree holds them now; an athanor with no soul,
  # a soul set aside or one that does not parse offers its crew none, as
  # `list/1` does. A store that cannot answer is its refusal.
  defp soul_tools(ctx) do
    case Arca.get(Sanctum.Context.actor(ctx), AquaPath.soul_file()) do
      {:ok, bytes} ->
        case parse(AquaPath.soul_name(), bytes) do
          {:ok, %{disabled: false} = soul} -> {:ok, soul.tools}
          _set_aside_or_unparsed -> {:ok, []}
        end

      {:error, :not_found} ->
        {:ok, []}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Serialize an agent back to its file — the inverse of `parse/2`. A crew
  member's file carries no tools, whatever the agent map holds, and a
  member in `auto` names its mode, as the shipped files do.
  """
  @spec serialize(t()) :: binary()
  def serialize(%{name: name} = agent) do
    fields =
      [
        {"title", agent.title},
        {"description", blank_to_nil(agent.description)},
        {"avoid", blank_to_nil(Map.get(agent, :avoid))},
        {"catalyst_ref", agent.catalyst_ref},
        {"program", Map.get(agent, :program)},
        {"model", agent.model},
        {"mode", Map.get(agent, :mode) || "auto"},
        {"disabled", if(agent.disabled, do: true)}
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.map(fn {k, v} -> "#{k}: #{scalar(v)}\n" end)

    options =
      case Enum.sort(Map.get(agent, :options) || %{}) do
        [] -> []
        pairs -> ["options:\n" | Enum.map(pairs, fn {k, v} -> "  #{key(k)}: #{option(v)}\n" end)]
      end

    tools =
      case if(AquaPath.soul?(name), do: canonical(Map.get(agent, :tools) || []), else: []) do
        [] -> []
        names -> ["tools:\n" | Enum.map(names, &"  - #{key(&1)}\n")]
      end

    IO.iodata_to_binary([
      "---\n",
      fields,
      options,
      tools,
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
  soul's tools (`under_soul/2`). Disabled agents are included (flagged);
  the callers that build a surface drop them. A file that fails to parse
  is skipped with its error in the second element — one broken member
  must not take the roster down; a soul that fails to parse offers the
  crew nothing. The soul comes first when the tree has one, then the
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

        tools =
          case soul do
            [%{disabled: false, tools: tools}] -> tools
            _none_or_disabled -> []
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
              {:ok, member} -> {[under_soul(member, tools) | ok], errs}
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
  (soul or crew), which brain (a catalyst or a program row) and model run
  it with which options, whether it is disabled, its mode, and the tools
  it is offered (a crew member's are the soul's). Nothing else — not the prompt, the title, the
  description or what to avoid, which change what the agent says and
  never what it may do. Pure: the same agent projects to the same map, so
  a digest of it is the agent's capability revision.
  """
  @spec to_manifest(t()) :: map()
  def to_manifest(%{name: name} = agent) do
    # An unset brain or model, and no options, are absent, never a null:
    # the projection names what the agent declares, and its digest is
    # canonical JSON.
    options = Map.get(agent, :options) || %{}

    %{
      "name" => name,
      "type" => type_of(agent),
      "disabled" => agent.disabled == true,
      "mode" => Map.get(agent, :mode) || "auto",
      "tools" => Map.get(agent, :tools) || []
    }
    |> Prima.MapUtil.put_present("catalyst_ref", agent.catalyst_ref)
    |> Prima.MapUtil.put_present("program", Map.get(agent, :program))
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

  # A file that still names the retired `tool_policy` is refused whole,
  # soul or crew: no reader of the old key remains to say what it meant.
  defp not_retired(meta) do
    if Map.has_key?(meta, "tool_policy"), do: {:error, :tool_policy_retired}, else: :ok
  end

  # A member's mode as written; a file without the line runs `auto`.
  defp mode_of(meta) do
    case Map.fetch(meta, "mode") do
      :error -> {:ok, "auto"}
      {:ok, mode} when mode in @modes -> {:ok, mode}
      {:ok, other} -> {:error, {:mode_invalid, other}}
    end
  end

  # The soul's tools are checked as written, an absent list offering
  # nothing; a crew member's file holds none.
  defp tools_of(name, meta) do
    case {AquaPath.soul?(name), Map.fetch(meta, "tools")} do
      {_soul?, :error} -> {:ok, []}
      {true, {:ok, nil}} -> {:ok, []}
      {true, {:ok, tools}} -> with :ok <- check_tools(tools), do: {:ok, canonical(tools)}
      {false, {:ok, _tools}} -> {:error, :crew_has_no_tools}
    end
  end

  @doc "The modes a member may be in, as the file spells them."
  @spec modes() :: [mode()]
  def modes, do: @modes

  @typedoc """
  Why a `tools` list is refused: not a list of strings, or an entry that
  is neither `tool.action`, `native_search` nor `server:tool` (a `*` in
  either name is no entry, and neither is a null).
  """
  @type tools_error :: :tools_not_a_list | {:tools_invalid_entry, term()}

  @doc """
  A `tools` list against the grammar the runtime reads: a list, every
  entry a string naming one action, `tool.action`, the bare
  `native_search` or an outside server's `server:tool`. The one rule the
  file parser and the `aqua` tool door both apply, so no write lands a
  list that would not parse back.
  """
  @spec check_tools(term()) :: :ok | {:error, tools_error()}
  def check_tools(tools) when is_list(tools) do
    case Enum.reject(tools, &valid_tool?/1) do
      [] -> :ok
      [entry | _rest] -> {:error, {:tools_invalid_entry, entry}}
    end
  end

  def check_tools(_tools), do: {:error, :tools_not_a_list}

  @doc "A `tools` list in its one form: sorted, without repeats."
  @spec canonical([String.t()]) :: [String.t()]
  def canonical(tools) when is_list(tools), do: tools |> Enum.uniq() |> Enum.sort()

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

  defp valid_tool?("native_search"), do: true

  # One action an entry: a `*` names none (the list has no wildcard).
  defp valid_tool?(name) when is_binary(name) do
    case {String.contains?(name, "*"), String.split(name, ":"), String.split(name, ".")} do
      {true, _colons, _dots} ->
        false

      {false, [server, tool], _dots} ->
        server != "" and tool != "" and not String.contains?(server, ".")

      {false, [_no_server], [tool, action]} ->
        tool != "" and action != ""

      _ ->
        false
    end
  end

  defp valid_tool?(_name), do: false

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
