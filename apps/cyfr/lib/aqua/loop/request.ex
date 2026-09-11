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
  schema the guest offered; a catalog tool keeps its own; a role the soul
  may clone into is a tool of its own; an external server's tool rides
  under its wire name; the `ui` event and `request_setup` are always
  offered.

  The messages are the projection shaped for the contract: a person's row
  is a `user` message (named when several people write), an agent's
  reply and the tool calls of one step are one `assistant` message with
  the stored typed blocks, tool results ride a `tool` message with the
  call's name, a compaction stands in for the rows before its boundary,
  an aborted mark tells the model what happened, and a call that never
  got its result carries a synthetic one saying so. The room excerpt is
  a transient block on this request's last `user` message; the turn's
  attachments are typed blocks on its initiating message. Cards, notes
  in the server's voice and errors are not the model's to read.
  """

  alias Arca.ConversationStorage, as: Conversations
  alias Arca.Schemas.Message

  @default_max_tokens 16_384
  @ui_tool "ui"

  @hand_schemas %{
    "files" => %{
      "description" =>
        "Workspace file operations. Use action=read to view files (returns line-numbered content), " <>
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
  spelling, `"tool.action" => "auto" | "ask" | "deny"`, `"role.*" =>
  "auto"`). `opts`: `:roles` (the roster entries the soul may clone into,
  `%{"name", "title", "description"}`), `:external` (the external servers'
  tools as `%{name, description, input_schema}`), `:soul?` (whether roles
  may be offered at all). Answers the contract's `tools` list.
  """
  @spec tool_definitions(map(), keyword()) :: [tool()]
  def tool_definitions(policy, opts \\ []) when is_map(policy) do
    offered = offered_actions(policy)

    hands =
      for {tool, actions} <- offered, Aqua.Hands.hand?(tool), tool != "request_setup" do
        hand_tool(tool, actions, policy)
      end

    catalog =
      for {tool, actions} <- offered,
          not Aqua.Hands.hand?(tool),
          not String.contains?(tool, ":") do
        catalog_tool(tool, actions, policy)
      end
      |> Enum.reject(&is_nil/1)

    roles =
      if Keyword.get(opts, :soul?, true) do
        for role <- Keyword.get(opts, :roles, []),
            Map.get(policy, "#{role["name"]}.*") == "auto",
            do: role_tool(role)
      else
        []
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

    hands ++
      catalog ++ roles ++ external ++ [@ui_schema, hand_tool("request_setup", ["open"], policy)]
  end

  @doc """
  The request: `model`, `system`, `messages`, `tools`, `provider_tools`
  and `max_tokens`. `opts`: `:model`, `:system`, `:tools`, `:messages`,
  `:capabilities` (for the output ceiling and the provider tools),
  `:native_search?` (the policy grants `native_search: auto`).
  """
  @spec build(keyword()) :: map()
  def build(opts) do
    caps = Keyword.get(opts, :capabilities, %{})

    max_tokens =
      [Keyword.get(opts, :max_tokens), Map.get(caps, :default_max_tokens), @default_max_tokens]
      |> Enum.find(&(is_integer(&1) and &1 > 0))
      |> min(Map.get(caps, :max_output_tokens) || @default_max_tokens)

    provider_tools =
      if Keyword.get(opts, :native_search?, false) and
           "web_search" in (Map.get(caps, :provider_tools) || []),
         do: ["web_search"],
         else: []

    %{
      "model" => Keyword.fetch!(opts, :model),
      "system" => Keyword.get(opts, :system, ""),
      "messages" => Keyword.fetch!(opts, :messages),
      "tools" => Keyword.get(opts, :tools, []),
      "provider_tools" => provider_tools,
      "max_tokens" => max_tokens
    }
  end

  @doc """
  The projection shaped for the contract. `opts`: `:names` (a map of
  user id to display name, used when `:multi_author?` is true),
  `:excerpt` (the room excerpt, a transient block), `:attachments` (typed
  blocks for the initiating message), `:task_message_id`.
  """
  @spec messages([Message.t()], keyword()) :: [map()]
  def messages(rows, opts \\ []) when is_list(rows) do
    rows
    |> apply_compaction()
    |> Enum.reduce([], fn row, acc -> shape(row, acc, opts) end)
    |> Enum.reverse()
    |> Enum.map(&finish_message/1)
    |> answer_dangling_calls()
    |> merge_same_role()
    |> attach(:attachments, Keyword.get(opts, :attachments))
    |> attach(:excerpt, Keyword.get(opts, :excerpt))
  end

  # ---------------------------------------------------------------------------
  # Tools
  # ---------------------------------------------------------------------------

  # `tool => [actions]` for every key that is auto or ask, tools with a
  # colon (an external server's) and role globs excluded.
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
    case Cyfr.Ops.Catalog.get_tool(tool) do
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
            "parameters" =>
              schema
              |> Map.put(
                "properties",
                Map.put(properties, "action", Map.put(action_prop, "enum", kept))
              )
          }
        end

      _ ->
        nil
    end
  end

  defp role_tool(role) do
    name = role["name"]

    %{
      "name" => name,
      "description" =>
        "Hand a task to the #{role["title"] || name} role, which works with its own hands and answers " <>
          "with a summary. " <> (role["description"] || ""),
      "parameters" => %{
        "type" => "object",
        "required" => ["task"],
        "properties" => %{
          "task" => %{
            "type" => "string",
            "description" => "The task for the #{name} role. Be specific and include context."
          }
        }
      }
    }
  end

  defp asks(tool, actions, policy) do
    case Enum.filter(actions, &(Map.get(policy, "#{tool}.#{&1}") == "ask")) do
      [] ->
        ""

      asking ->
        " Actions #{Enum.join(asking, ", ")} need the person's approval; calling one pauses the turn until they decide."
    end
  end

  # ---------------------------------------------------------------------------
  # Messages
  # ---------------------------------------------------------------------------

  # The latest compaction stands in for the rows before its boundary;
  # every compaction row is dropped from the model's reading.
  defp apply_compaction(rows) do
    case rows |> Enum.filter(&(&1.kind == "compaction")) |> List.last() do
      nil ->
        Enum.reject(rows, &(&1.kind == "compaction"))

      %Message{} = compaction ->
        %{"first_kept_seq" => first} = Conversations.payload(compaction)

        kept = Enum.filter(rows, &(&1.kind != "compaction" and &1.seq >= first))

        summary = %{
          role: "user",
          blocks: [
            %{
              "type" => "text",
              "text" => "[Summary of the conversation so far]\n" <> (compaction.content || "")
            }
          ],
          step: nil
        }

        [{:shaped, summary} | kept]
    end
  end

  defp shape({:shaped, message}, acc, _opts), do: [message | acc]

  defp shape(%Message{kind: "text"} = row, acc, opts) do
    if row.author in [Message.agent_author(), Message.system_author()] do
      step = step_of(row)
      block = %{"type" => "text", "text" => row.content || ""}

      case acc do
        [%{role: "assistant", step: ^step} = current | rest] when not is_nil(step) ->
          [%{current | blocks: current.blocks ++ [block]} | rest]

        _ ->
          [%{role: "assistant", blocks: [block], step: step} | acc]
      end
    else
      text =
        if Keyword.get(opts, :multi_author?, false),
          do: "#{display(row.author, opts)}: #{row.content}",
          else: row.content || ""

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
  end

  defp shape(%Message{kind: "tool_call"} = row, acc, _opts) do
    payload = Conversations.payload(row)
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

  defp shape(%Message{kind: "tool_result"} = row, acc, _opts) do
    payload = Conversations.payload(row)

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

  defp shape(%Message{kind: "turn_aborted"} = row, acc, _opts) do
    text =
      "[The server restarted while the assistant was working; tools may have partially executed. " <>
        (row.content || "") <> "]"

    [%{role: "user", blocks: [%{"type" => "text", "text" => text}], step: nil} | acc]
  end

  # Cards, notes in the server's voice and errors are not the model's.
  defp shape(%Message{}, acc, _opts), do: acc

  defp finish_message(%{role: role, blocks: blocks} = message) do
    %{"role" => role, "content" => blocks}
    |> Map.put(:message_id, Map.get(message, :message_id))
  end

  # A call whose result never landed gets a synthetic one, so the
  # provider sees every call answered and the model knows what happened.
  defp answer_dangling_calls(messages) do
    messages
    |> Enum.chunk_every(2, 1, [nil])
    |> Enum.flat_map(fn
      [%{"role" => "assistant", "content" => blocks} = message, next] ->
        calls = blocks |> Enum.filter(&(&1["type"] == "tool_call")) |> Enum.map(& &1["id"])

        answered =
          case next do
            %{"role" => "tool", "content" => results} -> Enum.map(results, & &1["tool_call_id"])
            _ -> []
          end

        case calls -- answered do
          [] ->
            [message]

          missing ->
            synthetic =
              Enum.map(missing, fn id ->
                name = Enum.find_value(blocks, fn b -> b["id"] == id && b["name"] end)

                %{
                  "type" => "tool_result",
                  "tool_call_id" => id,
                  "name" => name,
                  "content" =>
                    "The call's outcome is unknown; the tool may have partially executed.",
                  "is_error" => true
                }
              end)

            [message, %{"role" => "tool", "content" => synthetic, message_id: nil}]
        end

      [message, _] ->
        [message]
    end)
  end

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

  defp attach(messages, _what, nil), do: strip_ids(messages)
  defp attach(messages, _what, []), do: strip_ids(messages)

  defp attach(messages, :attachments, blocks) when is_list(blocks) do
    # The initiating message is the first user message when the task id
    # is not known; blocks go after its text.
    messages
    |> Enum.map_reduce(false, fn
      %{"role" => "user"} = m, false -> {%{m | "content" => m["content"] ++ blocks}, true}
      m, done -> {m, done}
    end)
    |> elem(0)
    |> strip_ids()
  end

  defp attach(messages, :excerpt, excerpt) when is_binary(excerpt) do
    block = %{"type" => "text", "text" => "## Read from the room\n\n" <> excerpt}

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
    case Conversations.payload(row) do
      %{"step_id" => step} when is_binary(step) -> step
      _ -> nil
    end
  end

  defp display(author, opts) do
    Map.get(Keyword.get(opts, :names, %{}), author, author)
  end
end
