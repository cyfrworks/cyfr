# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.Request do
  @moduledoc """
  The `model/chat@1` request a turn sends, built from what the tape
  holds and what the agent may call.

  The tool surface is the member's offered set (`Aqua.Offered`) over the
  tools that exist: a tool is offered when at least one of its actions
  is, and its `action` enum is those actions. A hand keeps the
  schema the guest offered; a catalog tool keeps its own, but for the
  account an `execution.run` names (`connection`), which lists the apps
  whose own profile binds named accounts and their names, never an
  entry or a value; an external server's tool rides under its wire
  name; the `ui` event and `request_setup` are always offered.

  The messages are the projection shaped for the contract, each row in
  the words `Aqua.Reader` reads it in: what the reading agent said and the
  tool calls of one step are one `assistant` message with the stored
  typed blocks; what is said to it is a `user` message. A request the
  reading agent made itself is its tool call's to show, and is read as a
  row only once a compaction summarized that call away while the
  request still waits (`Aqua.Loop.Planner.pinned?/1`). Tool results ride
  a `tool` message with the call's name, a compaction stands in for the
  rows before its boundary, and a call that never got its result carries
  a synthetic one saying so. The room excerpt is a transient block on
  this request's last `user` message; the turn's attachments are typed
  blocks on its initiating message, and a later post's files are typed
  blocks on that post's own message, where it stands.
  """

  alias Aqua.{Reader, Tape}

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
  The tools a turn offers, from the member's offered set
  (`t:Aqua.Offered.t/0`). `opts`:
  `:external` (the external servers' tools as `%{name, description,
  input_schema}`), `:accounts` (the apps a launch may name an account
  of, `t:Aqua.Hands.launch_accounts/0`, which the `connection`
  argument's description lists; absent or nil, as when they could not be
  read, the declared description stands). Answers the contract's `tools`
  list.
  """
  @spec tool_definitions(map(), keyword()) :: [tool()]
  def tool_definitions(offered, opts \\ []) when is_map(offered) do
    hands =
      for {tool, actions} <- offered_actions(offered),
          Aqua.Hands.hand?(tool),
          tool != "request_setup" do
        hand_tool(tool, actions)
      end

    external =
      for tool <- Keyword.get(opts, :external, []) do
        %{
          "name" => Aqua.Loop.Binding.model_name(tool.name),
          "description" => tool.description || "",
          "parameters" => tool.input_schema || %{"type" => "object"}
        }
      end

    catalog = with_accounts(catalog_tools(offered), Keyword.get(opts, :accounts))

    hands ++ catalog ++ external ++ [@ui_schema, hand_tool("request_setup", ["open"])]
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
  The catalog tools `offered` offers and nothing else: each tool with an
  offered action, its action enum narrowed to those.
  """
  @spec catalog_tools(map()) :: [tool()]
  def catalog_tools(offered) when is_map(offered) do
    for {tool, actions} <- offered_actions(offered),
        not Aqua.Hands.hand?(tool),
        not String.contains?(tool, ":"),
        definition = catalog_tool(tool, actions),
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
  Whether a turn asks the provider for its own search: the member is
  offered `native_search` and the grant the turn runs under carries it
  on the agent's ingress (`Compendium.AgentSource`). A grant that lacks
  it never searches, whatever the member is offered.
  """
  @spec native_search?(map(), Prima.Authority.t()) :: boolean()
  def native_search?(offered, %Prima.Authority{
        resources: %Prima.Authority.Blob.Edge{tools: tools}
      })
      when is_map(offered) and is_list(tools),
      do: Aqua.Offered.offered?(offered, "native_search") and "native_search" in tools

  def native_search?(_offered, _authority), do: false

  @doc """
  Whether a turn's request offers the provider's own search: the turn may
  search (`native_search?/2`) and the model has the tool. What the
  request's `provider_tools` follow (`build/1`).
  """
  @spec offers_search?(map(), Prima.Authority.t(), map() | nil) :: boolean()
  def offers_search?(offered, authority, capabilities),
    do:
      native_search?(offered, authority) and
        "web_search" in (Map.get(capabilities || %{}, :provider_tools) || [])

  @doc """
  The request: `model`, `system`, `messages`, `tools`, `provider_tools`
  and `max_tokens`, and `options` when given. `opts`: `:model`,
  `:system`, `:tools`, `:messages`, `:capabilities` (for the output
  ceiling, the provider tools and the options the brain declares),
  `:offers_search?` (`offers_search?/3`), `:max_tokens` and `:options`
  (the brain options a crew request set). An option the brain
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
  The projection shaped for the contract, each row as `reading` reads it
  (`t:Aqua.Reader.reading/0`). Every row the request carries that holds a
  file the person deleted (the reading's `removed`) is named in one block
  beside the initiating message's own. `opts`: `:excerpt` (the room
  excerpt, a transient block), `:attachments` (typed blocks for the
  initiating message), `:task_message_id` (which message those blocks
  belong to; without it they land on the first user message, which is
  only the right one in a transcript of one), `:files` (typed blocks by
  row id, for the later posts written into the turn: each set on its own
  post's message, after its text, and nowhere when that post is not
  carried).
  """
  @spec messages([Aqua.Tape.row()], Reader.reading(), keyword()) :: [map()]
  def messages(rows, reading, opts \\ []) when is_list(rows) and is_map(reading) do
    items = apply_compaction(rows)
    blocks = List.wrap(Keyword.get(opts, :attachments)) ++ removed_note(items, reading.removed)
    files = Keyword.get(opts, :files, %{})

    items
    |> Enum.reduce([], fn row, acc -> row |> shape(acc, reading) |> with_files(row, files) end)
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

  # `tool => [actions]` for every offered key, tools with a colon (an
  # external server's) excluded.
  defp offered_actions(offered) do
    offered
    |> Enum.filter(fn {_key, state} -> state == "offered" end)
    |> Enum.reduce(%{}, fn {key, _state}, acc ->
      case String.split(key, ".", parts: 2) do
        [tool, action] when tool != "native_search" ->
          Map.update(acc, tool, [action], &Enum.uniq([action | &1]))

        _ ->
          acc
      end
    end)
    |> Map.new(fn {tool, actions} -> {tool, Enum.sort(actions)} end)
  end

  defp hand_tool(tool, actions) do
    schema = Map.fetch!(@hand_schemas, tool)

    %{
      "name" => tool,
      "description" => schema["description"],
      "parameters" => %{
        "type" => "object",
        "required" => schema["required"],
        "properties" =>
          Map.put(schema["properties"], "action", %{"type" => "string", "enum" => actions})
      }
    }
  end

  defp catalog_tool(tool, actions) do
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
            "description" => definition["description"] || "",
            "parameters" => Sanctum.Catalog.restrict_tool(definition, kept)["inputSchema"]
          }
        end

      _ ->
        nil
    end
  end

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
        [%{"type" => "text", "text" => Reader.removed_note(refs)}]
    end
  end

  defp shape({:shaped, message}, acc, _reading), do: [message | acc]
  defp shape({:pinned, row}, acc, _reading), do: said(Reader.waiting(row), row, acc)

  defp shape(%{kind: "tool_call"} = row, acc, _reading) do
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

  defp shape(%{kind: "tool_result"} = row, acc, _reading) do
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

  defp shape(row, acc, reading) do
    case Reader.read(row, reading) do
      {:own, text} -> spoken(text, row, acc)
      {:said, text} -> said(text, row, acc)
      :none -> acc
    end
  end

  # A later post's files on the message its row was shaped as, before any
  # merge joins that message to its neighbour's.
  defp with_files([%{role: "user", message_id: id} = said | rest], %{id: id}, files)
       when is_map_key(files, id),
       do: [%{said | blocks: said.blocks ++ Map.fetch!(files, id)} | rest]

  defp with_files(acc, _row, _files), do: acc

  defp spoken(text, row, acc) do
    step = step_of(row)
    block = %{"type" => "text", "text" => text}

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

  defp finish_message(%{role: role, blocks: blocks} = message) do
    %{"role" => role, "content" => blocks}
    |> Map.put(:message_id, Map.get(message, :message_id))
  end

  # A call whose result never landed gets a synthetic one right after it,
  # so the provider sees every call answered and the model knows what
  # happened. A call's results are those up to the next assistant message,
  # its own group (the projection reads them right after it, every post
  # and restart's mark after them): a wire id a later round reuses answers
  # that round's call alone.
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
end
