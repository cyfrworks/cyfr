# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.ThreadToolTest do
  # Chat on the wire. The gates are the interesting part: what a client may
  # do, and — more to the point — what a running agent and a standing
  # credential may not.
  use ExUnit.Case, async: false

  alias Arca.ThreadStorage, as: Threads
  alias Emissary.MCP.ThreadTool, as: Tool
  alias Cyfr.Ops.{Catalog, Visibility}

  setup do
    Cyfr.Test.Sandbox.setup!()

    ctx = Sanctum.TestContext.local()
    {:ok, thread} = Threads.create(Sanctum.Context.actor(ctx))
    {:ok, ctx: ctx, thread: thread}
  end

  defp call(ctx, args), do: Tool.handle("thread", ctx, args)

  # A card as the loop opens it: a turn with its root, the model step, the
  # call, and the approval on the tape; the intent is the card's.
  defp card!(ctx, thread, intent) do
    alias Aqua.Tape
    proposal = intent["proposal"]

    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, content: "@aqua do a thing"},
        turn: %{agent: "aqua", requested_by: ctx.user_id}
      })

    {:ok, %{execution: execution, attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: "exec_tool_#{System.unique_integer([:positive])}",
          reference: "agent:local.aqua",
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          component_type: "agent",
          kind: "turn",
          turn_id: turn.id
        },
        reservation: %{budget_id: "bgt_#{System.unique_integer([:positive])}", cap: 4},
        grant: Cyfr.Test.AttemptFixtures.grant(ctx.athanor_id),
        verify: &Sanctum.ExecutionStanding.verify/1
      )

    {:ok, turn} =
      Tape.start_turn(ctx, turn, %{
        root_execution_id: execution.id,
        attempt: attempt.attempt,
        profile_id: "prof_x",
        consent_id: "consent_x"
      })

    {:ok, model_step} = Tape.record_model_intent(ctx, turn, %{})

    {:ok, %{calls: [%{step: step}]}} =
      Tape.record_response(ctx, turn, model_step, %{
        text: nil,
        tool_calls: [
          %{
            tool_call_id: "c1",
            name: "#{proposal["tool"]}.#{proposal["action"]}",
            tool: proposal["tool"],
            action: proposal["action"],
            arguments: proposal["args"] || %{},
            kind: intent["action_kind"]
          }
        ]
      })

    {:ok, %{card: card}} =
      Tape.open_approval(ctx, turn, step, %{
        proposal_digest: Aqua.Loop.Policy.proposal_digest(proposal),
        card: %{
          content: intent["title"],
          payload: %{"intent" => Map.put(intent, "tool_call_id", "c1")}
        }
      })

    card
  end

  describe "the turn tool" do
    test "suspend and recover are declared once, and every derived view follows" do
      annotations =
        Tool.turn_definition()
        |> Cyfr.Ops.Annotations.actions_of()

      assert Map.keys(annotations) |> Enum.sort() == ["recover", "suspend"]

      for {action, annotation} <- annotations do
        assert annotation.kind == :write, "#{action}: not a write"

        assert annotation.planes == [:external],
               "#{action}: a running agent must not reach it"

        assert annotation.consent == :interactive,
               "#{action}: a standing credential must not move a person's work"

        assert annotation.standing == false, "#{action}: every call is a click"
      end

      # Recovery is never itself replay-safe.
      assert Cyfr.Ops.Annotations.recovery(Tool.turn_definition(), "recover") == nil
      assert Cyfr.Ops.Annotations.recovery(Tool.turn_definition(), "suspend") == nil

      # A turn to recover is named; a turn to suspend need not be.
      schema = Tool.turn_definition().input_schema
      assert "thread" in schema["required"]
      refute "turn" in schema["required"]

      # And the catalog serves both, under the provider's one service.
      served = MapSet.new(Catalog.tool_actions())
      assert MapSet.member?(served, "turn.suspend")
      assert MapSet.member?(served, "turn.recover")
      assert Cyfr.Ops.Services.service_name(Tool) == "thread"
    end

    test "an API key cannot set a person's turn down, and is not shown the tool", %{
      ctx: ctx,
      thread: thread
    } do
      star = %{ctx | auth_method: :api_key, api_key_type: :admin, permissions: MapSet.new([:*])}

      assert {:error, {:consent_class_required, {:surface_not_permitted, :api_key}}} =
               Catalog.call_external("turn", star, %{
                 "action" => "suspend",
                 "thread" => thread.id
               })

      shown = Visibility.filter_for_context(Catalog.list_tools(), star)
      refute Enum.any?(shown, &(&1["name"] == "turn"))

      assert Enum.any?(
               Visibility.filter_for_context(Catalog.list_tools(), ctx),
               &(&1["name"] == "turn")
             )
    end

    test "the wire says what happened in sentences, not the runner's atoms", %{
      ctx: ctx,
      thread: thread
    } do
      # Nothing is running here, so there is nothing to set down.
      assert {:error, {:conflict, message}} =
               Tool.handle("turn", ctx, %{"action" => "suspend", "thread" => thread.id})

      assert message =~ "No turn is running"

      # A turn nobody minted is absent, never denied.
      assert {:error, {:not_found, "thread", _}} =
               Tool.handle("turn", ctx, %{
                 "action" => "recover",
                 "thread" => thread.id,
                 "turn" => "trn_never_minted"
               })

      assert {:error, {:invalid_argument, _}} =
               Tool.handle("turn", ctx, %{"action" => "recover", "thread" => thread.id})

      assert {:error, {:unknown_action, "turn.stop"}} =
               Tool.handle("turn", ctx, %{"action" => "stop", "thread" => thread.id})
    end
  end

  describe "gates" do
    # The surface gate is the `consent: :interactive` declaration on every
    # action, so it is asserted through the REGISTRY — the handler no
    # longer carries a gate of its own, and calling it directly would prove
    # nothing about what a credential can reach.
    test "an API key cannot drive somebody's chat — a star key included", %{
      ctx: ctx,
      thread: thread
    } do
      # `authorize_interactive/1` admits `:oidc` and nothing else. The
      # plane gate says nothing about this axis: a `*` key is on the
      # external plane and would sail through it.
      star = %{ctx | auth_method: :api_key, api_key_type: :admin, permissions: MapSet.new([:*])}

      assert {:error, {:consent_class_required, {:surface_not_permitted, :api_key}}} =
               Catalog.call_external("thread", star, %{
                 "action" => "events",
                 "thread" => thread.id
               })

      scoped = %{ctx | auth_method: :api_key, api_key_type: :application}

      assert {:error, {:consent_class_required, {:surface_not_permitted, :api_key}}} =
               Catalog.call_external("thread", scoped, %{
                 "action" => "send",
                 "thread" => thread.id,
                 "message" => "hi"
               })
    end

    test "a surface that would be refused is not shown the tool", %{ctx: ctx} do
      # Discovery reads the same annotation dispatch enforces: an API key
      # is not offered a door it cannot open.
      star = %{ctx | auth_method: :api_key, api_key_type: :admin, permissions: MapSet.new([:*])}

      shown = Visibility.filter_for_context(Catalog.list_tools(), star)
      refute Enum.any?(shown, &(&1["name"] == "thread"))

      shown_oidc = Visibility.filter_for_context(Catalog.list_tools(), ctx)
      assert Enum.any?(shown_oidc, &(&1["name"] == "thread"))
    end

    test "a running agent cannot reach it, whatever its allowlist says", %{
      ctx: ctx,
      thread: thread
    } do
      # Structural, not policy: `tool_policy` is editable markdown, so a
      # rule that lived there could be granted away. The guest plane is
      # stamped one-way and refused at the registry door.
      guest = Sanctum.Context.enter_guest(ctx)

      assert {:error, {:guest_plane_call, "thread"}} =
               Catalog.call_external("thread", guest, %{
                 "action" => "events",
                 "thread" => thread.id
               })
    end

    test "every action is external-plane only and interactive-only" do
      actions = Tool.definition().annotations.actions

      assert map_size(actions) == 16

      for {name, spec} <- actions do
        assert spec.planes == [:external], "#{name} is reachable in-chain"
        assert spec.consent == :interactive, "#{name} is reachable by a standing credential"
      end
    end

    test "the message schema declares its advisory bound; the runner's byte check governs", %{
      ctx: ctx,
      thread: thread
    } do
      assert get_in(action_schema(Tool.definition(), "send"), [
               "properties",
               "message",
               "maxLength"
             ]) ==
               32_768

      # Graphemes slip a schema that bytes do not: the runner's check is
      # the SSOT and the tool renders it as a typed refusal.
      long = String.duplicate("é", 20_000)

      assert {:error, :message_too_long} =
               call(ctx, %{"action" => "send", "thread" => thread.id, "message" => long})

      assert Prima.Refusal.message(:message_too_long) =~ "32 KiB"
    end
  end

  describe "shape" do
    test "events replays messages by seq, not execution events", %{ctx: ctx, thread: thread} do
      {:ok, a} =
        Threads.append(Sanctum.Context.actor(ctx), thread.id, %{
          author: ctx.user_id,
          kind: "text",
          content: "one"
        })

      {:ok, _b} =
        Threads.append(Sanctum.Context.actor(ctx), thread.id, %{
          author: "aqua",
          kind: "text",
          content: "two"
        })

      assert {:ok, %{messages: msgs, cursor: cursor}} =
               call(ctx, %{"action" => "events", "thread" => thread.id})

      assert Enum.map(msgs, & &1.content) == ["one", "two"]
      assert cursor == List.last(msgs).seq

      # A reconnect replays from where it left off.
      assert {:ok, %{messages: [%{content: "two"}]}} =
               call(ctx, %{
                 "action" => "events",
                 "thread" => thread.id,
                 "after_seq" => a.seq
               })
    end

    test "an empty thread has no cursor to resume from", %{ctx: ctx, thread: thread} do
      assert {:ok, %{messages: [], cursor: nil}} =
               call(ctx, %{"action" => "events", "thread" => thread.id})
    end

    test "an approval row carries its intent on the wire, so a client decides what it can see",
         %{ctx: ctx, thread: thread} do
      intent = %{
        "kind" => "request_approval",
        "title" => "Pull component",
        "action_kind" => "write",
        "proposal" => %{"tool" => "component", "action" => "pull", "args" => %{"ref" => "x"}}
      }

      {:ok, apr} =
        Threads.append(Sanctum.Context.actor(ctx), thread.id, %{
          author: "aqua",
          kind: "approval",
          status: "pending",
          content: "Pull component",
          payload: %{"agent" => "aqua", "intent" => intent}
        })

      assert {:ok, %{messages: rows}} =
               call(ctx, %{"action" => "events", "thread" => thread.id})

      assert %{intent: ^intent} = Enum.find(rows, &(&1.id == apr.id))

      # A line that is not a card carries no intent key at all.
      {:ok, line} =
        Threads.append(Sanctum.Context.actor(ctx), thread.id, %{
          author: ctx.user_id,
          kind: "text",
          content: "hi"
        })

      assert {:ok, %{messages: rows}} =
               call(ctx, %{"action" => "events", "thread" => thread.id})

      refute Map.has_key?(Enum.find(rows, &(&1.id == line.id)), :intent)
    end

    test "refusals are the typed vocabulary, not sentences", %{ctx: ctx, thread: thread} do
      assert {:error, {:invalid_argument, _}} =
               call(ctx, %{"action" => "send", "thread" => thread.id})

      assert {:error, {:invalid_argument, _}} =
               call(ctx, %{"action" => "approve", "thread" => thread.id})

      assert {:error, {:invalid_argument, _}} =
               call(ctx, %{
                 "action" => "approve",
                 "thread" => thread.id,
                 "message_id" => "msg_x",
                 "scope" => "forever"
               })

      assert {:error, {:unknown_action, "thread.dance"}} =
               call(ctx, %{"action" => "dance", "thread" => thread.id})

      assert {:error, {:invalid_argument, _}} = call(ctx, %{"action" => "events"})
    end

    test "a refused standing answer is a sentence a person can read, not the runner's atom", %{
      ctx: ctx,
      thread: thread
    } do
      # Deciding a card is held to a member's standing, like a send.
      {:ok, _} =
        Sanctum.Tenancy.Members.ensure(ctx.user_id,
          scope: "athanor",
          athanor_id: ctx.athanor_id
        )

      # One turn holds a thread at a time — that is what the thread's claim
      # means — so each card is raised in a thread of its own, the first in
      # the setup's and the second in one opened here.
      {:ok, second} = Arca.ThreadStorage.create(Sanctum.Context.actor(ctx))

      destructive =
        card!(ctx, thread, %{
          "kind" => "request_approval",
          "title" => "Wipe it",
          "action_kind" => "destructive",
          "proposal" => %{"tool" => "component", "action" => "delete", "args" => %{}}
        })

      assert {:error, {:invalid_argument, msg}} =
               call(ctx, %{
                 "action" => "approve",
                 "thread" => thread.id,
                 "message_id" => destructive.id,
                 "scope" => "always"
               })

      assert msg == Aqua.ToolGrants.refusal_message({:scope_not_permitted, "destructive"})

      one_click =
        card!(ctx, second, %{
          "kind" => "request_approval",
          "title" => "Pin it",
          "action_kind" => "write",
          "standing" => false,
          "proposal" => %{"tool" => "notes", "action" => "pin", "args" => %{}}
        })

      assert {:error, {:invalid_argument, msg}} =
               call(ctx, %{
                 "action" => "approve",
                 "thread" => second.id,
                 "message_id" => one_click.id,
                 "scope" => "thread"
               })

      assert msg == Aqua.ToolGrants.refusal_message({:scope_not_permitted, :never_standing})
      refute msg =~ "never_standing"
    end

    test "another athanor's thread is not found", %{ctx: ctx, thread: thread} do
      elsewhere = %{ctx | athanor_id: "ath_elsewhere"}

      # Typed at the boundary: the runner's bare atom would render as a
      # generic "the tool call failed" on every surface.
      assert {:error, {:not_found, "thread", _}} =
               call(elsewhere, %{"action" => "events", "thread" => thread.id})
    end

    test "a headless client can mint and list threads — the id needs no console", %{ctx: ctx} do
      assert {:ok, %{id: id, title: "Plans"}} =
               call(ctx, %{"action" => "create", "title" => "Plans"})

      assert {:ok, %{threads: rows}} = call(ctx, %{"action" => "list"})
      assert Enum.any?(rows, &(&1.id == id))
    end

    test "the estate's thread count is held to the operator's cap", %{ctx: ctx} do
      # The setup already minted one thread; a cap of one refuses the next.
      original = Application.get_env(:sanctum, :caps, [])
      Application.put_env(:sanctum, :caps, Keyword.put(original, :max_threads_per_athanor, 1))
      on_exit(fn -> Application.put_env(:sanctum, :caps, original) end)

      assert {:error, {:limit_reached, :max_threads_per_athanor, 1}} =
               call(ctx, %{"action" => "create", "title" => "One too many"})

      # Another estate's count is its own.
      {:ok, room} =
        Sanctum.Tenancy.Athanors.create_group(
          ctx.user_id,
          "Room #{System.unique_integer([:positive])}"
        )

      assert {:ok, %{id: _}} = call(%{ctx | athanor_id: room.id}, %{"action" => "create"})
    end

    test "follow and unfollow are the caller's own rows, on this estate's threads only", %{
      ctx: ctx,
      thread: thread
    } do
      alias Arca.ThreadSubscriptionStorage, as: Subs

      :ok = Subs.unfollow(Sanctum.Context.actor(ctx), thread.id, ctx.user_id)
      refute MapSet.member?(Subs.followed(Sanctum.Context.actor(ctx), ctx.user_id), thread.id)

      assert {:ok, %{following: true}} =
               call(ctx, %{"action" => "follow", "thread" => thread.id})

      assert MapSet.member?(Subs.followed(Sanctum.Context.actor(ctx), ctx.user_id), thread.id)

      assert {:ok, %{following: false}} =
               call(ctx, %{"action" => "unfollow", "thread" => thread.id})

      refute MapSet.member?(Subs.followed(Sanctum.Context.actor(ctx), ctx.user_id), thread.id)

      # A thread in another estate is not followable from here.
      elsewhere = %{ctx | athanor_id: "ath_elsewhere"}

      assert {:error, {:not_found, "thread", _}} =
               call(elsewhere, %{"action" => "follow", "thread" => thread.id})
    end
  end

  describe "aloud on the wire" do
    setup %{ctx: ctx} do
      test_path = Path.join(System.tmp_dir!(), "thread_tool_aloud_#{:rand.uniform(1_000_000)}")
      original = Application.get_env(:arca, :base_path)
      Application.put_env(:arca, :base_path, test_path)

      on_exit(fn ->
        File.rm_rf!(test_path)

        if original,
          do: Application.put_env(:arca, :base_path, original),
          else: Application.delete_env(:arca, :base_path)
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
      {:ok, shared} = Threads.create(Sanctum.Context.actor(%{ctx | athanor_id: room.id}))
      {:ok, room: room, shared: shared}
    end

    test "the ids are checked in shape and in number before anything is read", %{
      ctx: ctx,
      thread: thread,
      room: room,
      shared: shared
    } do
      base = %{
        "action" => "aloud",
        "thread" => thread.id,
        "target_athanor" => room.id,
        "target_thread" => shared.id
      }

      # The validator does not look inside arrays: a non-string element
      # is a typed refusal here, not a clause error in storage.
      assert {:error, {:invalid_argument, _}} = call(ctx, Map.put(base, "message_ids", [1]))

      too_many = Enum.map(1..51, &"msg_#{&1}")
      assert {:error, {:invalid_argument, _}} = call(ctx, Map.put(base, "message_ids", too_many))
    end

    test "your own line reaches the room; someone else's is refused", %{
      ctx: ctx,
      thread: thread,
      room: room,
      shared: shared
    } do
      {:ok, mine} =
        Threads.append(Sanctum.Context.actor(ctx), thread.id, %{
          author: ctx.user_id,
          kind: "text",
          content: "hi"
        })

      {:ok, other} =
        Threads.append(Sanctum.Context.actor(ctx), thread.id, %{
          author: "local|idp|someone-else",
          kind: "text",
          content: "not yours"
        })

      assert {:ok, %{said_aloud: 1}} =
               call(ctx, %{
                 "action" => "aloud",
                 "thread" => thread.id,
                 "message_ids" => [mine.id],
                 "target_athanor" => room.id,
                 "target_thread" => shared.id
               })

      assert [%{content: "hi", author: author}] =
               Threads.messages(Sanctum.Context.actor(%{ctx | athanor_id: room.id}), shared.id)

      assert author == ctx.user_id

      assert {:error, {:invalid_argument, msg}} =
               call(ctx, %{
                 "action" => "aloud",
                 "thread" => thread.id,
                 "message_ids" => [other.id],
                 "target_athanor" => room.id,
                 "target_thread" => shared.id
               })

      assert msg =~ "your own lines"
    end
  end

  describe "the send envelope and the thread's own verbs" do
    setup %{ctx: ctx} do
      # Two members: a bare line is people talking, so a send here writes
      # a row and starts nothing.
      {:ok, _} =
        Sanctum.Tenancy.Members.ensure(ctx.user_id, scope: "athanor", athanor_id: ctx.athanor_id)

      {:ok, _} =
        Sanctum.Tenancy.Members.ensure("usr_other_#{System.unique_integer([:positive])}",
          scope: "athanor",
          athanor_id: ctx.athanor_id
        )

      :ok
    end

    test "get answers the thread with its live state", %{ctx: ctx, thread: thread} do
      assert {:ok, %{id: id, running: false, queued: 0, pending_approvals: []}} =
               call(ctx, %{"action" => "get", "thread" => thread.id})

      assert id == thread.id

      assert {:error, {:not_found, "thread", "thread_nothing"}} =
               call(ctx, %{"action" => "get", "thread" => "thread_nothing"})
    end

    test "files attach under a pre-minted id, and the send names them", %{
      ctx: ctx,
      thread: thread
    } do
      message_id = Prima.UUID7.generate_id("msg")

      assert {:ok, %{message_id: ^message_id, attachments: [ref]}} =
               call(ctx, %{
                 "action" => "attach",
                 "thread" => thread.id,
                 "message_id" => message_id,
                 "files" => [
                   %{
                     "filename" => "note.txt",
                     "media_type" => "text/plain",
                     "data" => Base.encode64("hi")
                   }
                 ]
               })

      assert {:error, {:invalid_argument, _}} =
               call(ctx, %{
                 "action" => "attach",
                 "thread" => thread.id,
                 "message_id" => message_id,
                 "files" => [%{"filename" => "x", "media_type" => "text/plain", "data" => "%%%"}]
               })

      assert {:ok, %{accepted: true, message_id: ^message_id, replayed: false, running: false}} =
               call(ctx, %{
                 "action" => "send",
                 "thread" => thread.id,
                 "message" => "here is a file",
                 "id" => message_id,
                 "attachments" => [ref],
                 "client_id" => "c-1"
               })

      {:ok, row} = Threads.get_message(Sanctum.Context.actor(ctx), message_id)
      assert Threads.payload(row)["attachments"] == [ref]

      assert {:ok, %{messages: [%{id: ^message_id}], cursor: cursor}} =
               call(ctx, %{"action" => "messages", "thread" => thread.id})

      assert is_integer(cursor)
    end

    test "a room beside the thread is read for the send and never stored", %{
      ctx: ctx,
      thread: thread
    } do
      {:ok, room} = Threads.create(Sanctum.Context.actor(ctx), %{title: "the room"})

      {:ok, _} =
        Threads.append(Sanctum.Context.actor(ctx), room.id, %{
          author: ctx.user_id,
          content: "room talk"
        })

      assert {:ok, %{accepted: true, message_id: id}} =
               call(ctx, %{
                 "action" => "send",
                 "thread" => thread.id,
                 "message" => "about the room",
                 "room" => %{
                   "athanor_id" => ctx.athanor_id,
                   "thread_id" => room.id,
                   "title" => "the room"
                 }
               })

      {:ok, row} = Threads.get_message(Sanctum.Context.actor(ctx), id)
      assert row.content == "about the room"
      refute inspect(Threads.payload(row)) =~ "room talk"

      # A room the sender cannot read leaves the send as it is.
      assert {:ok, %{accepted: true}} =
               call(ctx, %{
                 "action" => "send",
                 "thread" => thread.id,
                 "message" => "still sent",
                 "room" => %{"athanor_id" => "ath_elsewhere", "thread_id" => "thread_x"}
               })
    end

    test "delete removes the thread whole", %{ctx: ctx, thread: thread} do
      {:ok, _} =
        Threads.append(Sanctum.Context.actor(ctx), thread.id, %{
          author: ctx.user_id,
          content: "bye"
        })

      assert {:ok, %{deleted: true}} =
               call(ctx, %{"action" => "delete", "thread" => thread.id})

      assert {:error, {:not_found, "thread", _}} =
               call(ctx, %{"action" => "get", "thread" => thread.id})

      assert {:error, {:not_found, "thread", _}} =
               call(ctx, %{"action" => "delete", "thread" => thread.id})
    end

    test "revoke_grant withdraws a standing answer for the agent it was given for", %{
      ctx: ctx,
      thread: thread
    } do
      {:ok, _} =
        Aqua.ToolGrants.put(ctx, %{
          scope: "thread",
          effect: "allow",
          thread_id: thread.id,
          agent_name: "aqua",
          tool: "notes",
          action: "keep"
        })

      assert {:ok, [_]} = Aqua.ToolGrants.for_thread(ctx, thread.id, "aqua")

      assert {:ok, %{revoked: true}} =
               call(ctx, %{
                 "action" => "revoke_grant",
                 "thread" => thread.id,
                 "agent_name" => "aqua",
                 "tool" => "notes",
                 "tool_action" => "keep"
               })

      assert {:ok, []} = Aqua.ToolGrants.for_thread(ctx, thread.id, "aqua")
    end
  end

  # One action's own declaration, as `Prima.Operation.cast/2` applies it;
  # the tool's discovery schema merges every action into one flat object.
  defp action_schema(tool, action) do
    case Enum.find(tool.operations, &(&1.action == action)) do
      nil ->
        flunk("missing schema for #{tool.name}.#{action}")

      operation ->
        operation.args
        |> Prima.Arg.schema()
        |> put_in(["properties", "action"], %{"type" => "string", "const" => action})
        |> Map.update!("required", &["action" | &1])
    end
  end
end
