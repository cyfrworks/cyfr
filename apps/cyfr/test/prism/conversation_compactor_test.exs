defmodule Prism.ConversationCompactorTest do
  use ExUnit.Case, async: true

  alias Prism.ConversationCompactor

  describe "compact/1" do
    test "passes through short conversations unchanged" do
      messages = [
        %{"role" => "user", "content" => "Hello"},
        %{"role" => "assistant", "content" => "Hi there!"},
        %{"role" => "user", "content" => "How are you?"}
      ]

      assert ConversationCompactor.compact(messages) == messages
    end

    test "returns non-list input unchanged" do
      assert ConversationCompactor.compact(nil) == nil
      assert ConversationCompactor.compact(%{}) == %{}
    end

    test "truncates OpenAI tool results in older messages" do
      big_result = String.duplicate("x", 10_000)

      messages =
        build_large_conversation(100) ++
          [
            %{"role" => "tool", "content" => big_result},
            %{"role" => "user", "content" => "What was that?"},
            %{"role" => "assistant", "content" => "Let me explain..."}
          ]

      result = ConversationCompactor.compact(messages)

      # Should still have the recent messages preserved
      last = List.last(result)
      assert last["role"] == "assistant"
      assert last["content"] == "Let me explain..."
    end

    test "truncates Claude tool results in older messages" do
      big_result = String.duplicate("y", 10_000)

      older_msg = %{
        "role" => "user",
        "content" => [
          %{"type" => "tool_result", "tool_use_id" => "abc", "content" => big_result}
        ]
      }

      messages =
        build_large_conversation(80) ++
          [
            older_msg
            | build_recent_messages(20)
          ]

      result = ConversationCompactor.compact(messages)

      # Recent 20 messages are always preserved
      recent_20 = Enum.take(result, -20)
      assert Enum.at(recent_20, 0)["content"] == "Recent 1"
      assert Enum.at(recent_20, 19)["content"] == "Recent 20"
    end

    test "truncates Claude nested tool result content" do
      big_text = String.duplicate("z", 10_000)

      older_msg = %{
        "role" => "user",
        "content" => [
          %{
            "type" => "tool_result",
            "tool_use_id" => "abc",
            "content" => [%{"type" => "text", "text" => big_text}]
          }
        ]
      }

      messages =
        build_large_conversation(80) ++
          [older_msg | build_recent_messages(20)]

      result = ConversationCompactor.compact(messages)

      # The tool result in older messages should be truncated if it's outside the recent window
      older_results =
        Enum.filter(result, fn msg ->
          case msg do
            %{"role" => "user", "content" => [%{"type" => "tool_result"} | _]} -> true
            _ -> false
          end
        end)

      for msg <- older_results do
        [%{"content" => content} | _] = msg["content"]

        case content do
          text when is_binary(text) ->
            assert byte_size(text) <= 520

          [%{"text" => text} | _] ->
            assert byte_size(text) <= 520
        end
      end
    end

    test "truncates Gemini functionResponse in older messages" do
      big_response = %{"data" => String.duplicate("g", 10_000)}

      older_msg = %{
        "role" => "user",
        "parts" => [
          %{
            "functionResponse" => %{
              "name" => "some_tool",
              "response" => big_response
            }
          }
        ]
      }

      messages =
        build_large_conversation(80) ++
          [older_msg | build_recent_messages(20)]

      result = ConversationCompactor.compact(messages)
      assert is_list(result)
      assert result != []
    end

    test "preserves last 20 messages even when over budget" do
      recent = build_recent_messages(20)

      # Add many large older messages
      older = build_large_conversation(200)

      messages = older ++ recent
      result = ConversationCompactor.compact(messages)

      # Last 20 must be preserved
      assert Enum.take(result, -20) == recent
    end

    test "drops oldest messages when truncation isn't enough" do
      # Every message is huge — truncation won't help much
      messages =
        Enum.map(1..100, fn i ->
          role = if rem(i, 2) == 1, do: "user", else: "assistant"
          %{"role" => role, "content" => String.duplicate("a", 10_000)}
        end)

      result = ConversationCompactor.compact(messages)

      # Should have fewer messages than the original
      assert length(result) < length(messages)

      # Last message should still be there
      assert List.last(result)["content"] == List.last(messages)["content"]
    end
  end

  describe "message pair integrity" do
    test "drops assistant+tool_results as a group (Claude format)" do
      # Build: user → assistant(tool_use) → user(tool_result) → user → assistant
      # When dropping, the assistant+tool_result pair should go together
      older = [
        %{"role" => "user", "content" => String.duplicate("a", 100_000)},
        %{
          "role" => "assistant",
          "content" => [
            %{"type" => "text", "text" => "Let me check"},
            %{"type" => "tool_use", "id" => "t1", "name" => "read", "input" => %{}}
          ]
        },
        %{
          "role" => "user",
          "content" => [
            %{"type" => "tool_result", "tool_use_id" => "t1", "content" => String.duplicate("b", 100_000)}
          ]
        },
        %{"role" => "user", "content" => String.duplicate("c", 100_000)}
      ]

      recent = build_recent_messages(20)
      messages = older ++ recent

      result = ConversationCompactor.compact(messages)

      # The assistant with tool_use and its tool_result should either both be present or both be gone
      has_tool_use = Enum.any?(result, fn msg ->
        case msg["content"] do
          content when is_list(content) ->
            Enum.any?(content, fn
              %{"type" => "tool_use", "id" => "t1"} -> true
              _ -> false
            end)
          _ -> false
        end
      end)

      has_tool_result = Enum.any?(result, fn msg ->
        case msg["content"] do
          content when is_list(content) ->
            Enum.any?(content, fn
              %{"type" => "tool_result", "tool_use_id" => "t1"} -> true
              _ -> false
            end)
          _ -> false
        end
      end)

      # Either both present or both gone — never orphaned
      assert has_tool_use == has_tool_result
    end

    test "drops assistant+tool_results as a group (OpenAI format)" do
      older = [
        %{"role" => "user", "content" => String.duplicate("a", 100_000)},
        %{
          "role" => "assistant",
          "content" => "I'll look that up",
          "tool_calls" => [%{"id" => "t1", "function" => %{"name" => "search"}}]
        },
        %{"role" => "tool", "content" => String.duplicate("d", 100_000)},
        %{"role" => "user", "content" => String.duplicate("e", 100_000)}
      ]

      recent = build_recent_messages(20)
      messages = older ++ recent
      result = ConversationCompactor.compact(messages)

      has_tool_calls = Enum.any?(result, fn msg ->
        is_list(msg["tool_calls"]) && msg["tool_calls"] != []
      end)

      has_tool_msg = Enum.any?(result, fn msg -> msg["role"] == "tool" end)

      assert has_tool_calls == has_tool_msg
    end

    test "drops canonical tool_results role as a group" do
      older = [
        %{"role" => "user", "content" => String.duplicate("a", 100_000)},
        %{
          "role" => "assistant",
          "content" => [
            %{"type" => "tool_use", "id" => "t1", "name" => "read", "input" => %{}}
          ]
        },
        %{
          "role" => "tool_results",
          "results" => [%{"tool_call_id" => "t1", "content" => String.duplicate("f", 100_000)}]
        }
      ]

      recent = build_recent_messages(20)
      messages = older ++ recent
      result = ConversationCompactor.compact(messages)

      has_tool_use = Enum.any?(result, fn msg ->
        case msg["content"] do
          content when is_list(content) ->
            Enum.any?(content, &match?(%{"type" => "tool_use"}, &1))
          _ -> false
        end
      end)

      has_tool_results = Enum.any?(result, fn msg -> msg["role"] == "tool_results" end)

      assert has_tool_use == has_tool_results
    end
  end

  describe "group_messages/1" do
    test "groups standalone messages individually" do
      messages = [
        %{"role" => "user", "content" => "hello"},
        %{"role" => "assistant", "content" => "hi"}
      ]

      groups = ConversationCompactor.group_messages(messages)
      assert groups == [[%{"role" => "user", "content" => "hello"}], [%{"role" => "assistant", "content" => "hi"}]]
    end

    test "groups assistant with tool_use + following tool results" do
      messages = [
        %{"role" => "user", "content" => "search for X"},
        %{
          "role" => "assistant",
          "content" => [%{"type" => "tool_use", "id" => "t1", "name" => "search", "input" => %{}}]
        },
        %{
          "role" => "user",
          "content" => [%{"type" => "tool_result", "tool_use_id" => "t1", "content" => "found it"}]
        },
        %{"role" => "assistant", "content" => "Here's what I found"}
      ]

      groups = ConversationCompactor.group_messages(messages)

      assert length(groups) == 3
      # First group: standalone user
      assert hd(groups) == [%{"role" => "user", "content" => "search for X"}]
      # Second group: assistant + tool_result pair
      assert length(Enum.at(groups, 1)) == 2
      # Third group: standalone assistant
      assert length(Enum.at(groups, 2)) == 1
    end

    test "groups OpenAI tool_calls + tool messages" do
      messages = [
        %{
          "role" => "assistant",
          "content" => "checking",
          "tool_calls" => [%{"id" => "t1", "function" => %{"name" => "read"}}]
        },
        %{"role" => "tool", "content" => "file contents"},
        %{"role" => "assistant", "content" => "done"}
      ]

      groups = ConversationCompactor.group_messages(messages)

      assert length(groups) == 2
      assert length(hd(groups)) == 2
      assert length(Enum.at(groups, 1)) == 1
    end
  end

  # Generates alternating user/assistant messages with ~4k chars each
  # 80 messages * 4000 chars = 320k, right at the budget threshold
  defp build_large_conversation(count) do
    Enum.map(1..count, fn i ->
      role = if rem(i, 2) == 1, do: "user", else: "assistant"
      %{"role" => role, "content" => String.duplicate("x", 4000)}
    end)
  end

  defp build_recent_messages(count) do
    Enum.map(1..count, fn i ->
      role = if rem(i, 2) == 1, do: "user", else: "assistant"
      %{"role" => role, "content" => "Recent #{i}"}
    end)
  end
end
