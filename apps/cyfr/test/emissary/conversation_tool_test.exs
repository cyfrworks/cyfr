# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ConversationToolTest do
  # Chat on the wire. The gates are the interesting part: what a client may
  # do, and — more to the point — what a running agent and a standing
  # credential may not.
  use ExUnit.Case, async: false

  alias Arca.ConversationStorage, as: Conversations
  alias Emissary.MCP.ConversationTool, as: Tool
  alias Emissary.MCP.{ToolRegistry, ToolVisibility}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    ctx = Sanctum.TestContext.local()
    {:ok, conv} = Conversations.create(ctx)
    {:ok, ctx: ctx, conv: conv}
  end

  defp call(ctx, args), do: Tool.handle("conversation", ctx, args)

  describe "gates" do
    # The surface gate is the `consent: :interactive` declaration on every
    # action, so it is asserted through the REGISTRY — the handler no
    # longer carries a gate of its own, and calling it directly would prove
    # nothing about what a credential can reach.
    test "an API key cannot drive somebody's chat — a star key included", %{
      ctx: ctx,
      conv: conv
    } do
      # `authorize_interactive/1` admits `:oidc` and nothing else. The
      # plane gate says nothing about this axis: a `*` key is on the
      # external plane and would sail through it.
      star = %{ctx | auth_method: :api_key, api_key_type: :admin, permissions: MapSet.new([:*])}

      assert {:error, {:consent_class_required, {:surface_not_permitted, :api_key}}} =
               ToolRegistry.call_external("conversation", star, %{
                 "action" => "events",
                 "conversation" => conv.id
               })

      scoped = %{ctx | auth_method: :api_key, api_key_type: :application}

      assert {:error, {:consent_class_required, {:surface_not_permitted, :api_key}}} =
               ToolRegistry.call_external("conversation", scoped, %{
                 "action" => "send",
                 "conversation" => conv.id,
                 "message" => "hi"
               })
    end

    test "a surface that would be refused is not shown the tool", %{ctx: ctx} do
      # Discovery reads the same annotation dispatch enforces: an API key
      # is not offered a door it cannot open.
      star = %{ctx | auth_method: :api_key, api_key_type: :admin, permissions: MapSet.new([:*])}

      shown = ToolVisibility.filter_for_context(ToolRegistry.list_tools(), star)
      refute Enum.any?(shown, &(&1["name"] == "conversation"))

      shown_oidc = ToolVisibility.filter_for_context(ToolRegistry.list_tools(), ctx)
      assert Enum.any?(shown_oidc, &(&1["name"] == "conversation"))
    end

    test "a running agent cannot reach it, whatever its allowlist says", %{
      ctx: ctx,
      conv: conv
    } do
      # Structural, not policy: `tool_policy` is editable markdown, so a
      # rule that lived there could be granted away. The guest plane is
      # stamped one-way and refused at the registry door.
      guest = Sanctum.Context.enter_guest(ctx)

      assert {:error, {:guest_plane_call, "conversation"}} =
               ToolRegistry.call_external("conversation", guest, %{
                 "action" => "events",
                 "conversation" => conv.id
               })
    end

    test "every action is external-plane only and interactive-only" do
      actions = Tool.definition().annotations.actions

      assert map_size(actions) == 10

      for {name, spec} <- actions do
        assert spec.planes == [:external], "#{name} is reachable in-chain"
        assert spec.consent == :interactive, "#{name} is reachable by a standing credential"
      end
    end

    test "the message schema declares its advisory bound; the runner's byte check governs", %{
      ctx: ctx,
      conv: conv
    } do
      assert get_in(Tool.definition().input_schema, ["properties", "message", "maxLength"]) ==
               32_768

      # Graphemes slip a schema that bytes do not: the runner's check is
      # the SSOT and the tool renders it as a typed refusal.
      long = String.duplicate("é", 20_000)

      assert {:error, {:invalid_argument, msg}} =
               call(ctx, %{"action" => "send", "conversation" => conv.id, "message" => long})

      assert msg =~ "32 KiB"
    end
  end

  describe "shape" do
    test "events replays messages by seq, not execution events", %{ctx: ctx, conv: conv} do
      {:ok, a} =
        Conversations.append(ctx, conv.id, %{author: ctx.user_id, kind: "text", content: "one"})

      {:ok, _b} =
        Conversations.append(ctx, conv.id, %{author: "aqua", kind: "text", content: "two"})

      assert {:ok, %{messages: msgs, cursor: cursor}} =
               call(ctx, %{"action" => "events", "conversation" => conv.id})

      assert Enum.map(msgs, & &1.content) == ["one", "two"]
      assert cursor == List.last(msgs).seq

      # A reconnect replays from where it left off.
      assert {:ok, %{messages: [%{content: "two"}]}} =
               call(ctx, %{
                 "action" => "events",
                 "conversation" => conv.id,
                 "after_seq" => a.seq
               })
    end

    test "an empty thread has no cursor to resume from", %{ctx: ctx, conv: conv} do
      assert {:ok, %{messages: [], cursor: nil}} =
               call(ctx, %{"action" => "events", "conversation" => conv.id})
    end

    test "an approval row carries its intent on the wire, so a client decides what it can see",
         %{ctx: ctx, conv: conv} do
      intent = %{
        "kind" => "request_approval",
        "title" => "Pull component",
        "action_kind" => "write",
        "proposal" => %{"tool" => "component", "action" => "pull", "args" => %{"ref" => "x"}}
      }

      {:ok, apr} =
        Conversations.append(ctx, conv.id, %{
          author: "aqua",
          kind: "approval",
          status: "pending",
          content: "Pull component",
          payload: %{"orchestrator" => "aqua", "intent" => intent}
        })

      assert {:ok, %{messages: rows}} =
               call(ctx, %{"action" => "events", "conversation" => conv.id})

      assert %{intent: ^intent} = Enum.find(rows, &(&1.id == apr.id))

      # A line that is not a card carries no intent key at all.
      {:ok, line} =
        Conversations.append(ctx, conv.id, %{author: ctx.user_id, kind: "text", content: "hi"})

      assert {:ok, %{messages: rows}} =
               call(ctx, %{"action" => "events", "conversation" => conv.id})

      refute Map.has_key?(Enum.find(rows, &(&1.id == line.id)), :intent)
    end

    test "refusals are the typed vocabulary, not sentences", %{ctx: ctx, conv: conv} do
      assert {:error, {:invalid_argument, _}} =
               call(ctx, %{"action" => "send", "conversation" => conv.id})

      assert {:error, {:invalid_argument, _}} =
               call(ctx, %{"action" => "approve", "conversation" => conv.id})

      assert {:error, {:invalid_argument, _}} =
               call(ctx, %{
                 "action" => "approve",
                 "conversation" => conv.id,
                 "message_id" => "msg_x",
                 "scope" => "forever"
               })

      assert {:error, {:unknown_action, "conversation.dance"}} =
               call(ctx, %{"action" => "dance", "conversation" => conv.id})

      assert {:error, {:invalid_argument, _}} = call(ctx, %{"action" => "events"})
    end

    test "a refused standing answer is a sentence a person can read, not the runner's atom", %{
      ctx: ctx,
      conv: conv
    } do
      # Deciding a card is held to a member's standing, like a send.
      {:ok, _} =
        Sanctum.Tenancy.Members.ensure(ctx.user_id,
          scope: "athanor",
          athanor_id: ctx.athanor_id
        )

      card = fn intent ->
        {:ok, apr} =
          Conversations.append(ctx, conv.id, %{
            author: Arca.Schemas.Message.agent_author(),
            kind: "approval",
            status: "pending",
            content: "Do a thing",
            payload: %{"orchestrator" => "aqua", "intent" => intent}
          })

        apr
      end

      destructive =
        card.(%{
          "kind" => "request_approval",
          "title" => "Wipe it",
          "action_kind" => "destructive",
          "proposal" => %{"tool" => "component", "action" => "delete", "args" => %{}}
        })

      assert {:error, {:invalid_argument, msg}} =
               call(ctx, %{
                 "action" => "approve",
                 "conversation" => conv.id,
                 "message_id" => destructive.id,
                 "scope" => "always"
               })

      assert msg == Aqua.ToolGrants.refusal_message({:scope_not_permitted, "destructive"})

      one_click =
        card.(%{
          "kind" => "request_approval",
          "title" => "Pin it",
          "action_kind" => "write",
          "standing" => false,
          "proposal" => %{"tool" => "notes", "action" => "pin", "args" => %{}}
        })

      assert {:error, {:invalid_argument, msg}} =
               call(ctx, %{
                 "action" => "approve",
                 "conversation" => conv.id,
                 "message_id" => one_click.id,
                 "scope" => "conversation"
               })

      assert msg == Aqua.ToolGrants.refusal_message({:scope_not_permitted, :never_standing})
      refute msg =~ "never_standing"
    end

    test "another athanor's conversation is not found", %{ctx: ctx, conv: conv} do
      elsewhere = %{ctx | athanor_id: "ath_elsewhere"}

      # Typed at the boundary: the runner's bare atom would render as a
      # generic "the tool call failed" on every surface.
      assert {:error, {:not_found, "conversation", _}} =
               call(elsewhere, %{"action" => "events", "conversation" => conv.id})
    end

    test "a headless client can mint and list threads — the id needs no console", %{ctx: ctx} do
      assert {:ok, %{id: id, title: "Plans"}} =
               call(ctx, %{"action" => "create", "title" => "Plans"})

      assert {:ok, %{conversations: rows}} = call(ctx, %{"action" => "list"})
      assert Enum.any?(rows, &(&1.id == id))
    end

    test "the estate's thread count is held to the operator's cap", %{ctx: ctx} do
      # The setup already minted one thread; a cap of one refuses the next.
      original = Application.get_env(:cyfr, :caps, [])
      Application.put_env(:cyfr, :caps, Keyword.put(original, :max_conversations_per_athanor, 1))
      on_exit(fn -> Application.put_env(:cyfr, :caps, original) end)

      assert {:error, {:limit_reached, :max_conversations_per_athanor, 1}} =
               call(ctx, %{"action" => "create", "title" => "One too many"})

      # Another estate's count is its own.
      {:ok, room} =
        Sanctum.Tenancy.Athanors.create_group(
          ctx.user_id,
          "Room #{System.unique_integer([:positive])}"
        )

      assert {:ok, %{id: _}} = call(%{ctx | athanor_id: room.id}, %{"action" => "create"})
    end

    test "follow and unfollow are the caller's own rows, on this estate's topics only", %{
      ctx: ctx,
      conv: conv
    } do
      alias Arca.TopicSubscriptionStorage, as: Subs

      :ok = Subs.unfollow(ctx, conv.id, ctx.user_id)
      refute MapSet.member?(Subs.followed(ctx, ctx.user_id), conv.id)

      assert {:ok, %{following: true}} =
               call(ctx, %{"action" => "follow", "conversation" => conv.id})

      assert MapSet.member?(Subs.followed(ctx, ctx.user_id), conv.id)

      assert {:ok, %{following: false}} =
               call(ctx, %{"action" => "unfollow", "conversation" => conv.id})

      refute MapSet.member?(Subs.followed(ctx, ctx.user_id), conv.id)

      # A topic in another estate is not followable from here.
      elsewhere = %{ctx | athanor_id: "ath_elsewhere"}

      assert {:error, {:not_found, "conversation", _}} =
               call(elsewhere, %{"action" => "follow", "conversation" => conv.id})
    end
  end

  describe "aloud on the wire" do
    setup %{ctx: ctx} do
      test_path = Path.join(System.tmp_dir!(), "conv_tool_aloud_#{:rand.uniform(1_000_000)}")
      original = Application.get_env(:cyfr, :base_path)
      Application.put_env(:cyfr, :base_path, test_path)

      on_exit(fn ->
        File.rm_rf!(test_path)

        if original,
          do: Application.put_env(:cyfr, :base_path, original),
          else: Application.delete_env(:cyfr, :base_path)
      end)

      n = System.unique_integer([:positive])

      # Aloud checks membership on the SOURCE too; the fixture context's
      # seat there is implicit elsewhere, explicit here.
      {:ok, _} =
        Sanctum.Tenancy.Members.ensure(ctx.user_id,
          scope: "athanor",
          athanor_id: ctx.athanor_id
        )

      {:ok, room} = Sanctum.Tenancy.Athanors.create_group(ctx.user_id, "Room #{n}")
      {:ok, shared} = Conversations.create(%{ctx | athanor_id: room.id})
      {:ok, room: room, shared: shared}
    end

    test "the ids are checked in shape and in number before anything is read", %{
      ctx: ctx,
      conv: conv,
      room: room,
      shared: shared
    } do
      base = %{
        "action" => "aloud",
        "conversation" => conv.id,
        "target_athanor" => room.id,
        "target_conversation" => shared.id
      }

      # The validator does not look inside arrays: a non-string element
      # is a typed refusal here, not a clause error in storage.
      assert {:error, {:invalid_argument, _}} = call(ctx, Map.put(base, "message_ids", [1]))

      too_many = Enum.map(1..51, &"msg_#{&1}")
      assert {:error, {:invalid_argument, _}} = call(ctx, Map.put(base, "message_ids", too_many))
    end

    test "your own line reaches the room; someone else's is refused", %{
      ctx: ctx,
      conv: conv,
      room: room,
      shared: shared
    } do
      {:ok, mine} =
        Conversations.append(ctx, conv.id, %{author: ctx.user_id, kind: "text", content: "hi"})

      {:ok, other} =
        Conversations.append(ctx, conv.id, %{
          author: "local|idp|someone-else",
          kind: "text",
          content: "not yours"
        })

      assert {:ok, %{said_aloud: 1}} =
               call(ctx, %{
                 "action" => "aloud",
                 "conversation" => conv.id,
                 "message_ids" => [mine.id],
                 "target_athanor" => room.id,
                 "target_conversation" => shared.id
               })

      assert [%{content: "hi", author: author}] =
               Conversations.messages(%{ctx | athanor_id: room.id}, shared.id)

      assert author == ctx.user_id

      assert {:error, {:invalid_argument, msg}} =
               call(ctx, %{
                 "action" => "aloud",
                 "conversation" => conv.id,
                 "message_ids" => [other.id],
                 "target_athanor" => room.id,
                 "target_conversation" => shared.id
               })

      assert msg =~ "your own lines"
    end
  end
end
