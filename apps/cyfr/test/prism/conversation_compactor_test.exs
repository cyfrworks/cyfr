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

      # Build a conversation that exceeds the budget
      # Each message needs to be large enough that the total exceeds 320k chars
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
            older_msg,
            %{"role" => "user", "content" => "Recent 1"},
            %{"role" => "assistant", "content" => "Recent 2"},
            %{"role" => "user", "content" => "Recent 3"},
            %{"role" => "assistant", "content" => "Recent 4"},
            %{"role" => "user", "content" => "Recent 5"},
            %{"role" => "assistant", "content" => "Recent 6"}
          ]

      result = ConversationCompactor.compact(messages)

      # Recent 6 messages are always preserved
      recent_6 = Enum.take(result, -6)
      assert Enum.at(recent_6, 0)["content"] == "Recent 1"
      assert Enum.at(recent_6, 5)["content"] == "Recent 6"
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
          [
            older_msg
            | Enum.map(1..6, fn i ->
                role = if rem(i, 2) == 1, do: "user", else: "assistant"
                %{"role" => role, "content" => "Recent #{i}"}
              end)
          ]

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
          [
            older_msg
            | Enum.map(1..6, fn i ->
                role = if rem(i, 2) == 1, do: "user", else: "assistant"
                %{"role" => role, "content" => "Recent #{i}"}
              end)
          ]

      result = ConversationCompactor.compact(messages)
      assert is_list(result)
      assert result != []
    end

    test "preserves last 6 messages even when over budget" do
      # Create a conversation where the last 6 messages alone are under budget
      recent =
        Enum.map(1..6, fn i ->
          role = if rem(i, 2) == 1, do: "user", else: "assistant"
          %{"role" => role, "content" => "Message #{i}"}
        end)

      # Add many large older messages
      older = build_large_conversation(200)

      messages = older ++ recent
      result = ConversationCompactor.compact(messages)

      # Last 6 must be preserved
      assert Enum.take(result, -6) == recent
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

  # Generates alternating user/assistant messages with ~4k chars each
  # 80 messages * 4000 chars = 320k, right at the budget threshold
  defp build_large_conversation(count) do
    Enum.map(1..count, fn i ->
      role = if rem(i, 2) == 1, do: "user", else: "assistant"
      %{"role" => role, "content" => String.duplicate("x", 4000)}
    end)
  end
end
