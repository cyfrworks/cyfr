# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.Request do
  @moduledoc """
  The `model/chat@1` request a turn sends, built from what the tape
  holds and what the agent may call.

  The tool surface is the agent's effective policy over the tools that
  exist: a tool is offered when at least one of its actions is `auto` or
  `ask`, its `action` enum is those actions, and an action that asks says
  so in the description so the model expects the pause. A hand keeps the
  schema the guest offered; a catalog tool keeps its own, but for the
  account an `execution.run` names (`connection`), which lists the apps
  whose own profile binds named accounts and their names, never an
  entry or a value; an external server's tool rides under its wire
  name; the `ui` event and `request_setup` are always offered.

  The messages are the projection shaped for the contract, read by the
  agent the turn runs (`:me`): what that agent said (`sent_by`) and the
  tool calls of one step are one `assistant` message with the stored
  typed blocks; anything anyone else said is a `user` message — a
  person's (named when several people write), another agent's under its
  name, a crew member's reply under the request it answers. A request the
  reading agent made itself is its tool call's to show, and is read as a
  row only once a compaction summarized that call away while the
  request still waits (`Aqua.Loop.Planner.pinned?/1`). Tool results ride
  a `tool` message with the call's name, a compaction stands in for the
  rows before its boundary, an aborted mark tells the model what
  happened, and a call that never got its result carries a synthetic one
  saying so. The room excerpt is a transient block on this request's
  last `user` message; the turn's attachments are typed blocks on its
  initiating message. A workspace thread's rows read as their writer
  words them: an opening as the ask, attributed to the person who asked,
  then each daily-thread post it refers to as it reads now (`:refs`), then
  the files it carries; a pointer as one line naming its workspace thread
  and title; a report as one block naming its workspace thread, outcome
  and summary. A post the reading agent made with `thread.post` is its
  call's to show. Cards, notes in the server's voice and errors are not
  the model's to read.
  """

  alias Aqua.Tape

  @default_max_tokens 16_384
  # The apps the `connection` argument lists, at most.
  @accounts_listed 50
  @ui_tool "ui"

  @hand_schemas %{
    "files" => %{
      "description" =>
        "File operations on the athanor's files. Use action=read to view files (returns line-numbered content), " <>
          "write to create or overwrite, edit to apply line edits, search for a glob, grep for a regex, " <>
          "tree or list to browse, delete to remove.",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" => "File or directory path (read/write/edit/grep/tree/list/delete)"
        },
        "content" => %{"type" => "string", "description" => "File content (write)"},
        "start_line" => %{
          "type" => "integer",
          "description" => "1-based start line (read, optional)"
        },
        "end_line" => %{
          "type" => "integer",
          "description" => "Inclusive end line (read, optional)"
        },
        "edits" => %{
          "type" => "array",
          "description" => "Edits to apply (edit)",
          "items" => %{
            "type" => "object",
            "required" => ["action", "start", "end", "content"],
            "properties" => %{
              "action" => %{"type" => "string", "enum" => ["replace", "insert", "delete"]},
              "start" => %{"type" => "integer"},
              "end" => %{"type" => "integer"},
              "content" => %{"type" => "string"}
            }
          }
        },
        "base_path" => %{"type" => "string", "description" => "Directory to search in (search)"},
        "pattern" => %{
          "type" => "string",
          "description" => "Glob (search) or regex (grep) pattern"
        },
        "include" => %{
          "type" => "string",
          "description" => "File filter glob, e.g. '*.rs' (grep)"
        },
        "depth" => %{"type" => "integer", "description" => "Max depth (tree/list, default 3)"}
      },
      "required" => ["action"]
    },
    "storage" => %{
      "description" =>
        "Persistent key-value storage. Keys are slash-separated paths, values are JSON, kept under data/storage/.",
      "properties" => %{
        "key" => %{"type" => "string", "description" => "Storage key, e.g. 'research/notion'"},
        "value" => %{"description" => "JSON value to store (write)"}
      },
      "required" => ["action"]
    },
    "http" => %{
      "description" =>
        "Outbound HTTP. read fetches a page as markdown, links lists a page's links, metadata its title and " <>
          "description; get/head/options/post/put/patch/delete are the raw methods.",
      "properties" => %{
        "url" => %{"type" => "string", "description" => "URL to fetch"},
        "headers" => %{"type" => "object", "description" => "Custom HTTP headers"},
        "body" => %{"type" => "string", "description" => "Request body (post/put/patch)"},
        "max" => %{
          "type" => "integer",
          "description" => "Most links to return (links, default 500)"
        }
      },
      "required" => ["action", "url"]
    },
    "request_setup" => %{
      "description" =>
        "Open the setup form for a component that needs configuration (a key, a policy). " <>
          "The person sees an inline form; nothing runs.",
      "properties" => %{
        "component_ref" => %{
          "type" => "string",
          "description" => "Component reference, type:publisher.name:version"
        }
      },
      "required" => ["action", "component_ref"]
    }
  }

  @ui_schema %{
    "name" => @ui_tool,
    "description" =>
      "Drive the person's console: navigate to a page, open or close an overlay, focus a record, copy text.",
    "parameters" => %{
      "type" => "object",
      "required" => ["kind"],
      "properties" => %{
        "kind" => %{
          "type" => "string",
          "enum" => [
            "ui.navigate",
            "ui.overlay.open",
            "ui.overlay.close",
            "ui.overlay.focus_input",
            "ui.copy_clipboard",
            "ui.activity.focus",
            "ui.execution.focus",
            "ui.schedule.focus",
            "ui.component.focus",
            "ui.tincture.focus",
            "ui.mcp_server.focus"
          ]
        }
      },
      "additionalProperties" => true
    }
  }

  @type tool :: %{String.t() => term()}

  @doc """
  The tools a turn offers, from the agent's effective policy (the guest
  spelling, `"tool.action" => "auto" | "ask" | "deny"`). `opts`:
  `:external` (the external servers' tools as `%{name, description,
  input_schema}`), `:accounts` (the apps a launch may name an account
  of, `t:Aqua.Hands.launch_accounts/0`, which the `connection`
  argument's description lists; absent or nil, as when they could not be
  read, the declared description stands). Answers the contract's `tools`
  list.
  """
  @spec tool_definitions(map(), keyword()) :: [tool()]
  def tool_definitions(policy, opts \\ []) when is_map(policy) do
    offered = offered_actions(policy)

    hands =
      for {tool, actions} <- offered, Aqua.Hands.hand?(tool), tool != "request_setup" do
        hand_tool(tool, actions, policy)
      end

    external =
      for tool <- Keyword.get(opts, :external, []) do
        %{
          "name" => Aqua.Loop.Binding.model_name(tool.name),
          "description" =>
            (tool.description || "") <>
              " Needs the person's approval; calling it pauses the turn.",
          "parameters" => tool.input_schema || %{"type" => "object"}
        }
      end

    catalog = with_accounts(catalog_tools(policy), Keyword.get(opts, :accounts))

    hands ++ catalog ++ external ++ [@ui_schema, hand_tool("request_setup", ["open"], policy)]
  end

  # The account a launch names, described by the apps that bind one: the
  # names alone, and the default as what omitting it takes.
  defp with_accounts(tools, nil), do: tools

  defp with_accounts(tools, %{apps: apps, truncated?: truncated?}) do
    Enum.map(tools, fn
      %{"name" => "execution", "parameters" => %{"properties" => %{"connection" => _}}} = tool ->
        put_in(
          tool,
          ["parameters", "properties", "connection", "description"],
          connection_description(apps, truncated?)
        )

      tool ->
        tool
    end)
  end

  # At most `@accounts_listed` apps, by reference. A list cut short says
  # how many more stand; when the heads read were themselves cut short, it
  # says only that more may.
  defp connection_description(apps, truncated?) do
    {shown, past} = Enum.split(apps, @accounts_listed)

    listed =
      Enum.map(shown, fn {ref, names} -> "#{ref} (#{Enum.map_join(names, ", ", &inspect/1)})" end)

    rest =
      cond do
        truncated? -> ["and more"]
        past == [] -> []
        true -> ["and #{length(past)} more"]
      end

    head =
      "The account the launched app's own calls use, by the name its grant binds it under; " <>
        "omit `connection` for its default account."

    case listed ++ rest do
      [] -> head <> " No app binds a named account."
      apps -> head <> " Apps with named accounts: " <> Enum.join(apps, "; ") <> "."
    end
  end

  @doc """
  The catalog tools `policy` offers and nothing else: each tool whose
  actions are `auto` or `ask`, its action enum narrowed to those.
  """
  @spec catalog_tools(map()) :: [tool()]
  def catalog_tools(policy) when is_map(policy) do
    for {tool, actions} <- offered_actions(policy),
        not Aqua.Hands.hand?(tool),
        not String.contains?(tool, ":"),
        definition = catalog_tool(tool, actions, policy),
        definition != nil,
        do: definition
  end

  @doc """
  `messages` with `text` as the person's last word: a text block on the
  final user message, or a user message of its own after any other.
  """
  @spec instruct([map()], String.t()) :: [map()]
  def instruct(messages, text) when is_list(messages) and is_binary(text) do
    block = %{"type" => "text", "text" => text}

    case List.last(messages) do
      %{"role" => "user", "content" => content} = last ->
        List.replace_at(messages, -1, %{last | "content" => List.wrap(content) ++ [block]})

      _ ->
        messages ++ [%{"role" => "user", "content" => [block]}]
    end
  end

  @doc """
  Whether a turn asks the provider for its own search: the agent's policy
  turns it on (`native_search: auto`) and the grant the turn runs under
  carries it on the agent's ingress (`Compendium.AgentSource`). A grant
  that lacks it never searches, whatever the policy says.
  """
  @spec native_search?(map(), Prima.Authority.t()) :: boolean()
  def native_search?(policy, %Prima.Authority{resources: %Prima.Authority.Blob.Edge{tools: tools}})
      when is_map(policy) and is_list(tools),
      do: Map.get(policy, "native_search") == "auto" and "native_search" in tools

  def native_search?(_policy, _authority), do: false

  @doc """
  Whether a turn's request offers the provider's own search: the turn may
  search (`native_search?/2`) and the model has the tool. The one answer
  both the request (`build/1`'s `provider_tools`) and the sources the turn
  records read.
  """
  @spec offers_search?(map(), Prima.Authority.t(), map() | nil) :: boolean()
  def offers_search?(policy, authority, capabilities),
    do:
      native_search?(policy, authority) and
        "web_search" in (Map.get(capabilities || %{}, :provider_tools) || [])

  @doc """
  The request: `model`, `system`, `messages`, `tools`, `provider_tools`
  and `max_tokens`, and `session` and `options` when given. `opts`:
  `:model`, `:system`, `:tools`, `:messages`, `:capabilities` (for the
  output ceiling, the provider tools and the options the brain declares),
  `:offers_search?` (`offers_search?/3`),
  `:max_tokens`, `:session` (the brain's session a response named) and
  `:options` (the brain options a crew request set). An option the brain
  does not declare, or a value not of its kind, is refused
  (`Prima.Model.check_chat_request/2`), never sent or dropped: the
  request raises, and the turn fails on it.
  """
  @spec build(keyword()) :: map()
  def build(opts) do
    opts =
      Keyword.validate!(opts, [
        :model,
        :system,
        :messages,
        :tools,
        :capabilities,
        :offers_search?,
        :max_tokens,
        :session,
        :options
      ])

    caps = Keyword.get(opts, :capabilities, %{})
    max_tokens = max_tokens(caps, Keyword.get(opts, :max_tokens))

    provider_tools = if Keyword.get(opts, :offers_search?, false), do: ["web_search"], else: []

    request =
      %{
        "model" => Keyword.fetch!(opts, :model),
        "system" => Keyword.get(opts, :system, ""),
        "messages" => Keyword.fetch!(opts, :messages),
        "tools" => Keyword.get(opts, :tools, []),
        "provider_tools" => provider_tools,
        "max_tokens" => max_tokens
      }
      |> Prima.MapUtil.put_present("session", Keyword.get(opts, :session))
      |> put_options(Keyword.get(opts, :options))

    case Prima.Model.check_chat_request(request, Map.get(caps, :options) || []) do
      :ok ->
        request

      {:error, {:invalid, member}} ->
        raise ArgumentError, "the brain does not take #{member} as it is set"
    end
  end

  defp put_options(request, options) when is_map(options) and map_size(options) > 0,
    do: Map.put(request, "options", options)

  defp put_options(request, _none), do: request

  @doc """
  The output ceiling a request asks for under `caps`: the caller's, else
  the catalyst's default, else the contract's, never past the model's
  own ceiling.
  """
  @spec max_tokens(map(), pos_integer() | nil) :: pos_integer()
  def max_tokens(caps, requested \\ nil) do
    [requested, Map.get(caps, :default_max_tokens), @default_max_tokens]
    |> Enum.find(&(is_integer(&1) and &1 > 0))
    |> min(Map.get(caps, :max_output_tokens) || @default_max_tokens)
  end

  @doc """
  The projection shaped for the contract. `removed`, by row id, the refs
  of a row's files the person deleted, is every caller's to give, so none
  can leave a deleted file unnamed: every row the request carries that
  holds one is named in one block beside the initiating message's own,
  and an opening never names one as carried. `opts`: `:me` (the agent the
  turn runs, whose rows are its own speech), `:names` (a map of
  user id to display name, used when `:multi_author?` is true),
  `:excerpt` (the room excerpt, a transient block), `:attachments` (typed
  blocks for the initiating message), `:task_message_id` (which message
  those blocks belong to; without it they land on the first user message,
  which is only the right one in a transcript of one), `:refs` (the
  daily-thread posts an opening refers to, by id, as they read now).
  """
  @spec messages([Aqua.Tape.row()], %{String.t() => [map()]}, keyword()) :: [map()]
  def messages(rows, removed, opts \\ []) when is_list(rows) and is_map(removed) do
    opts = Keyword.put(opts, :removed, removed)
    items = apply_compaction(rows)
    blocks = List.wrap(Keyword.get(opts, :attachments)) ++ removed_note(items, removed)

    items
    |> Enum.reduce([], fn row, acc -> shape(row, acc, opts) end)
    |> Enum.reverse()
    |> Enum.map(&finish_message/1)
    |> answer_dangling_calls()
    |> merge_same_role()
    |> attach_blocks(blocks, Keyword.get(opts, :task_message_id))
    |> attach(:excerpt, Keyword.get(opts, :excerpt))
  end

  @doc """
  The rows a request made of `rows` carries to the model: those the
  latest compaction keeps, and the older ones it pins. What a round reads
  of storage for its request it reads for these alone.
  """
  @spec carried([Aqua.Tape.row()]) :: [Aqua.Tape.row()]
  def carried(rows) when is_list(rows) do
    for item <- apply_compaction(rows), row = carried_row(item), do: row
  end

  defp carried_row({:pinned, row}), do: row
  defp carried_row({:shaped, _summary}), do: nil
  defp carried_row(row), do: row

  # ---------------------------------------------------------------------------
  # Tools
  # ---------------------------------------------------------------------------

  # `tool => [actions]` for every key that is auto or ask, tools with a
  # colon (an external server's) and globs excluded.
  defp offered_actions(policy) do
    policy
    |> Enum.filter(fn {_key, mode} -> mode in ["auto", "ask"] end)
    |> Enum.reduce(%{}, fn {key, _mode}, acc ->
      case String.split(key, ".", parts: 2) do
        [tool, action] when action != "*" and tool != "native_search" ->
          Map.update(acc, tool, [action], &Enum.uniq([action | &1]))

        _ ->
          acc
      end
    end)
    |> Map.new(fn {tool, actions} -> {tool, Enum.sort(actions)} end)
  end

  defp hand_tool(tool, actions, policy) do
    schema = Map.fetch!(@hand_schemas, tool)

    %{
      "name" => tool,
      "description" => schema["description"] <> asks(tool, actions, policy),
      "parameters" => %{
        "type" => "object",
        "required" => schema["required"],
        "properties" =>
          Map.put(schema["properties"], "action", %{"type" => "string", "enum" => actions})
      }
    }
  end

  defp catalog_tool(tool, actions, policy) do
    case Sanctum.Catalog.get_tool(tool) do
      {:ok, definition} ->
        schema = definition["inputSchema"] || %{"type" => "object"}
        properties = Map.get(schema, "properties", %{})
        action_prop = Map.get(properties, "action", %{"type" => "string"})
        known = Map.get(action_prop, "enum", actions)
        kept = Enum.filter(actions, &(&1 in known))

        if kept == [] do
          nil
        else
          %{
            "name" => tool,
            "description" => (definition["description"] || "") <> asks(tool, kept, policy),
            "parameters" => Sanctum.Catalog.restrict_tool(definition, kept)["inputSchema"]
          }
        end

      _ ->
        nil
    end
  end

  defp asks(tool, actions, policy) do
    asking = Enum.filter(actions, &(Map.get(policy, "#{tool}.#{&1}") == "ask"))

    granted =
      Enum.filter(
        actions,
        &(Aqua.Launch.launch_action?(tool, &1) and Map.get(policy, "#{tool}.#{&1}") == "auto")
      )

    asking_sentence(asking) <> granted_sentence(granted)
  end

  defp asking_sentence([]), do: ""

  defp asking_sentence(asking),
    do:
      " Actions #{Enum.join(asking, ", ")} need the person's approval; calling one pauses the turn until they decide."

  # A launch the policy runs `auto` runs on the component's grant, and
  # still asks when the turn has read what that grant does not let
  # through (`Aqua.Loop.Policy`).
  defp granted_sentence([]), do: ""

  defp granted_sentence(granted),
    do:
      " A component the person has granted runs at once through #{Enum.join(granted, " and ")};" <>
        " a run still needs the person's approval, and pauses the turn until they decide, when " <>
        "this turn has read something that component's grant does not let it send on."

  # ---------------------------------------------------------------------------
  # Messages
  # ---------------------------------------------------------------------------

  # The latest compaction stands in for the rows before its boundary,
  # but for the requests there still waiting on a reply, which stay
  # pinned after it; every compaction row is dropped from the model's
  # reading.
  defp apply_compaction(rows) do
    case rows |> Enum.filter(&(&1.kind == "compaction")) |> List.last() do
      nil ->
        Enum.reject(rows, &(&1.kind == "compaction"))

      %{} = compaction ->
        %{"first_kept_seq" => first} = Tape.payload(compaction)

        pinned =
          for row <- rows, row.seq < first, Aqua.Loop.Planner.pinned?(row), do: {:pinned, row}

        kept = Enum.filter(rows, &(&1.kind != "compaction" and &1.seq >= first))

        summary = %{
          role: "user",
          blocks: [
            %{
              "type" => "text",
              "text" => "[Summary of the thread so far]\n" <> (compaction.content || "")
            }
          ],
          step: nil
        }

        [{:shaped, summary} | pinned ++ kept]
    end
  end

  # The files the person deleted of every row the request carries, named in
  # one block, whatever the row is and however it is shown.
  defp removed_note(items, removed) do
    case for(item <- items, row = carried_row(item), ref <- Map.get(removed, row.id, []), do: ref) do
      [] ->
        []

      refs ->
        names = Enum.map_join(refs, ", ", & &1["filename"])

        [
          %{
            "type" => "text",
            "text" =>
              "[The person deleted these files of posts in this thread; they can no longer " <>
                "be read: #{names}]"
          }
        ]
    end
  end

  defp shape({:shaped, message}, acc, _opts), do: [message | acc]

  defp shape({:pinned, row}, acc, _opts) do
    said(
      "[Request #{row.id} to #{row.addressee}, still waiting on its reply]\n#{row.content}",
      row,
      acc
    )
  end

  defp shape(%{kind: "opening"} = row, acc, opts), do: said(opening_text(row, opts), row, acc)
  defp shape(%{kind: "pointer"} = row, acc, _opts), do: said(pointer_text(row), row, acc)
  defp shape(%{kind: "report"} = row, acc, _opts), do: said(report_text(row), row, acc)
  defp shape(%{kind: "nudge"} = row, acc, _opts), do: said(server_text(row), row, acc)

  defp shape(%{kind: "text"} = row, acc, opts) do
    me = Keyword.get(opts, :me)

    cond do
      decided_notice?(row) -> acc
      # The reader's own post is its call's to show (`thread.post`).
      posted?(row) and own?(row, me) -> acc
      is_binary(Map.get(row, :reply_to)) -> said(reply_text(row), row, acc)
      request?(row) and own?(row, me) -> acc
      request?(row) -> said(request_text(row, opts), row, acc)
      # Before the reader's own speech: a line in the server's voice, a
      # schedule's or the server's own post, which a request that names no
      # reader reads as its own.
      server?(row) -> said(server_text(row), row, acc)
      own?(row, me) -> spoken(row, acc)
      agent?(row) -> said("[#{row.sent_by}]\n#{row.content}", row, acc)
      true -> said(person_text(row, opts), row, acc)
    end
  end

  defp shape(%{kind: "tool_call"} = row, acc, _opts) do
    payload = Tape.payload(row)
    step = payload["step_id"]

    block =
      %{
        "type" => "tool_call",
        "id" => payload["tool_call_id"],
        "name" => payload["name"],
        "arguments" => payload["arguments"] || %{},
        "provider_data" => payload["provider_data"]
      }
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    case acc do
      [%{role: "assistant", step: ^step} = current | rest] when not is_nil(step) ->
        [%{current | blocks: current.blocks ++ [block]} | rest]

      _ ->
        [%{role: "assistant", blocks: [block], step: step} | acc]
    end
  end

  defp shape(%{kind: "tool_result"} = row, acc, _opts) do
    payload = Tape.payload(row)

    block = %{
      "type" => "tool_result",
      "tool_call_id" => payload["tool_call_id"],
      "name" => payload["name"],
      "content" => row.content || "",
      "is_error" => payload["is_error"] == true
    }

    case acc do
      [%{role: "tool"} = current | rest] ->
        [%{current | blocks: current.blocks ++ [block]} | rest]

      _ ->
        [%{role: "tool", blocks: [block], step: nil} | acc]
    end
  end

  defp shape(%{kind: "turn_aborted"} = row, acc, _opts) do
    text =
      "[The server restarted while the assistant was working; tools may have partially executed. " <>
        (row.content || "") <> "]"

    [%{role: "user", blocks: [%{"type" => "text", "text" => text}], step: nil} | acc]
  end

  # Cards, notes in the server's voice and errors are not the model's.
  defp shape(%{}, acc, _opts), do: acc

  defp spoken(row, acc) do
    step = step_of(row)
    block = %{"type" => "text", "text" => row.content || ""}

    case acc do
      [%{role: "assistant", step: ^step} = current | rest] when not is_nil(step) ->
        [%{current | blocks: current.blocks ++ [block]} | rest]

      _ ->
        [%{role: "assistant", blocks: [block], step: step} | acc]
    end
  end

  defp said(text, row, acc) do
    [
      %{
        role: "user",
        blocks: [%{"type" => "text", "text" => text}],
        step: nil,
        message_id: row.id
      }
      | acc
    ]
  end

  # The reading agent's own speech: a row it sent. A row written before
  # rows named their sender is read by its author.
  defp own?(%{sent_by: sent_by}, me) when is_binary(sent_by) and is_binary(me), do: sent_by == me
  defp own?(row, _me), do: row.author in Prima.Author.reserved()

  defp agent?(%{sent_by: sent_by}), do: is_binary(sent_by) and sent_by != "person"
  defp agent?(_row), do: false

  # A line in the server's voice: written by the server, never by the
  # person or an agent.
  defp server?(%{author: author}), do: author == Prima.Author.system()
  defp server?(_row), do: false

  # A schedule's line, which its fire wrote for the person, names the
  # schedule (`Aqua.ScheduleTurns`); any other line of the server's is its
  # own (`Aqua.Nudge`).
  defp server_text(row) do
    case Tape.payload(row)["schedule"] do
      %{"id" => id, "name" => name} when is_binary(id) and is_binary(name) ->
        "[The schedule \"#{name}\" (#{id}) fired with its line]\n#{row.content}"

      _own ->
        "[A line from the server, not the person]\n" <> (row.content || "")
    end
  end

  defp request?(row),
    do: is_binary(Map.get(row, :addressee)) and Map.get(row, :status) in ["pending", "answered"]

  defp posted?(row), do: Tape.payload(row)["post"] == true

  # A workspace thread's opening: the ask, attributed to the person
  # who asked, then each daily-thread post it refers to as that post reads
  # now (`:refs`, read by the loop and never copied), then the files it
  # carries, which ride as blocks on the turn it opened.
  defp opening_text(row, opts) do
    payload = Tape.payload(row)
    title = payload["title"] || ""
    asker = display(payload["asked_by"] || row.author, opts)

    refs =
      for id <- List.wrap(payload["refs"]),
          %{} = cited <- [Map.get(Keyword.get(opts, :refs, %{}), id)] do
        "\n\n[Post #{cited.id} of the daily thread, by #{sender(cited, opts)}]\n#{cited.content}"
      end

    gone =
      for ref <- Map.get(Keyword.fetch!(opts, :removed), row.id, []), do: ref["stored_name"]

    files =
      case Enum.reject(Aqua.Attachments.refs_of(row), &(&1["stored_name"] in gone)) do
        [] -> ""
        refs -> "\n\n[Files carried in: #{Enum.map_join(refs, ", ", & &1["filename"])}]"
      end

    "[#{asker} asked, in this workspace thread \"#{title}\" (#{row.thread_id})]\n" <>
      (row.content || "") <> Enum.join(refs) <> files
  end

  # A pointer: one line naming the workspace thread and its title.
  defp pointer_text(row) do
    payload = Tape.payload(row)

    "[The workspace thread \"#{payload["title"] || ""}\" (#{row.workspace_id}) was opened or asked again from here]"
  end

  # A report: one block naming the workspace thread, its outcome and
  # its summary.
  defp report_text(row) do
    payload = Tape.payload(row)

    "[Report from the workspace thread \"#{payload["title"] || ""}\" (#{row.workspace_id}): " <>
      "#{reported(payload)}]\n" <> (row.content || "")
  end

  # The outcome as the reading model is told it: Aqua's `done` or
  # `needs_you`, the server's `error`, or a card's notice.
  defp reported(%{"outcome" => "needs_you", "approval_id" => _card}),
    do: "a card waits on the person"

  defp reported(%{"outcome" => "needs_you"}), do: "needs the person"
  defp reported(%{"outcome" => "error"}), do: "error, Aqua could not run it"
  defp reported(_payload), do: "done"

  defp sender(%{sent_by: "person"} = row, opts), do: display(row.author, opts)
  defp sender(%{sent_by: sent_by}, _opts) when is_binary(sent_by), do: sent_by
  defp sender(row, opts), do: display(row.author, opts)

  defp request_text(row, opts) do
    asker = if row.sent_by == "person", do: display(row.author, opts), else: row.sent_by

    "[#{asker} asked #{row.addressee} (request #{row.id}, #{row.status})]\n#{row.content}"
  end

  # A notice is read while its card waits; a decided card waits for no one.
  defp decided_notice?(row),
    do: Map.get(row, :outcome) == "needs_you" and Map.get(row, :status) != "pending"

  defp reply_text(%{outcome: "needs_you"} = row) do
    "[#{row.sent_by} needs the person on request #{row.reply_to}: a card waits for them " <>
      "in #{row.sent_by}'s thread]\n#{row.content}"
  end

  defp reply_text(row),
    do: "[#{row.sent_by} replied to request #{row.reply_to}: #{row.outcome}]\n#{row.content}"

  defp person_text(row, opts) do
    if Keyword.get(opts, :multi_author?, false),
      do: "#{display(row.author, opts)}: #{row.content}",
      else: row.content || ""
  end

  defp finish_message(%{role: role, blocks: blocks} = message) do
    %{"role" => role, "content" => blocks}
    |> Map.put(:message_id, Map.get(message, :message_id))
  end

  # A call whose result never landed gets a synthetic one right after it,
  # so the provider sees every call answered and the model knows what
  # happened. A call's results are those up to the next assistant message,
  # its own group, past any post that landed between: a wire id a later
  # round reuses answers that round's call alone.
  defp answer_dangling_calls([%{"role" => "assistant", "content" => blocks} = message | rest]) do
    answered =
      for %{"role" => "tool", "content" => results} <-
            Enum.take_while(rest, &(&1["role"] != "assistant")),
          result <- results,
          do: result["tool_call_id"]

    case calls(blocks) -- answered do
      [] ->
        [message | answer_dangling_calls(rest)]

      missing ->
        synthetic =
          Enum.map(missing, fn id ->
            name = Enum.find_value(blocks, fn b -> b["id"] == id && b["name"] end)

            %{
              "type" => "tool_result",
              "tool_call_id" => id,
              "name" => name,
              "content" => "The call's outcome is unknown; the tool may have partially executed.",
              "is_error" => true
            }
          end)

        [message, %{"role" => "tool", "content" => synthetic, message_id: nil}] ++
          answer_dangling_calls(rest)
    end
  end

  defp answer_dangling_calls([message | rest]), do: [message | answer_dangling_calls(rest)]
  defp answer_dangling_calls([]), do: []

  defp calls(blocks), do: for(%{"type" => "tool_call"} = b <- blocks, do: b["id"])

  defp merge_same_role(messages) do
    Enum.reduce(messages, [], fn
      %{"role" => role, "content" => blocks}, [%{"role" => role} = prev | rest]
      when role != "tool" ->
        [%{prev | "content" => prev["content"] ++ blocks} | rest]

      m, acc ->
        [m | acc]
    end)
    |> Enum.reverse()
  end

  @excerpt_prefix "## Read from a shared thread\n\n"

  @doc """
  The request without the room excerpt `attach/3` placed last: the form
  the payload store keeps of a request that carried the transient read.
  The block is the last content block of the last message, and is
  removed only when it carries the excerpt's own heading; a message left
  empty goes with it. A request without one is answered unchanged.
  """
  @spec without_excerpt(map()) :: map()
  def without_excerpt(%{"messages" => messages} = request) when is_list(messages) do
    with %{"content" => content} = last when is_list(content) <- List.last(messages),
         %{"type" => "text", "text" => @excerpt_prefix <> _} <- List.last(content) do
      rest = Enum.drop(content, -1)

      messages =
        if rest == [],
          do: Enum.drop(messages, -1),
          else: List.replace_at(messages, -1, %{last | "content" => rest})

      %{request | "messages" => messages}
    else
      _ -> request
    end
  end

  def without_excerpt(request), do: request

  defp attach_blocks(messages, [], _task_message_id), do: strip_ids(messages)

  defp attach_blocks(messages, blocks, task_message_id) when is_list(blocks) do
    # Onto the message that carried them. Falling back to the first user
    # message is only right for a transcript of one: with history behind it,
    # an image sent now would be handed to the oldest thing anyone said.
    target =
      if task_message_id && Enum.any?(messages, &(&1[:message_id] == task_message_id)),
        do: &(&1[:message_id] == task_message_id),
        else: &(&1["role"] == "user")

    messages
    |> Enum.map_reduce(false, fn
      m, false ->
        if target.(m), do: {%{m | "content" => m["content"] ++ blocks}, true}, else: {m, false}

      m, true ->
        {m, true}
    end)
    |> elem(0)
    |> strip_ids()
  end

  defp attach(messages, _what, nil), do: strip_ids(messages)
  defp attach(messages, _what, []), do: strip_ids(messages)

  defp attach(messages, :excerpt, excerpt) when is_binary(excerpt) do
    block = %{"type" => "text", "text" => @excerpt_prefix <> excerpt}

    case List.last(messages) do
      %{"role" => "user"} = last ->
        List.replace_at(messages, -1, %{last | "content" => last["content"] ++ [block]})

      _ ->
        messages ++ [%{"role" => "user", "content" => [block]}]
    end
    |> strip_ids()
  end

  defp strip_ids(messages), do: Enum.map(messages, &Map.delete(&1, :message_id))

  defp step_of(row) do
    case Tape.payload(row) do
      %{"step_id" => step} when is_binary(step) -> step
      _ -> nil
    end
  end

  defp display(author, opts) do
    Map.get(Keyword.get(opts, :names, %{}), author, author)
  end
end
