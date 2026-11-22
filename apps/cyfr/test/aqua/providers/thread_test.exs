# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Providers.ThreadTest do
  # Chat on the wire. The gates are the interesting part: what a client may
  # do, and — more to the point — what a running agent and a standing
  # credential may not.
  use ExUnit.Case, async: false

  require Ecto.Query

  alias Arca.ThreadStorage, as: Threads
  alias Aqua.Providers.Thread, as: Tool
  alias Sanctum.Visibility

  setup do
    Cyfr.Test.Sandbox.setup!()

    ctx = Sanctum.TestContext.local(:prism)
    {:ok, thread} = Arca.Test.Days.thread(Sanctum.Context.actor(ctx))
    {:ok, ctx: ctx, thread: thread}
  end

  defp call(ctx, args), do: Tool.handle("thread", ctx, args)

  # A call through the gate, which casts the arguments against the
  # declaration before any handler runs: a refusal there is the gate's.
  defp admission(ctx, tool, args) do
    case Sanctum.Gate.call_external(tool, ctx, args) do
      {:error, %Prima.Refusal{stage: :admission, reason: reason}} -> {:refused, reason}
      other -> other
    end
  end

  defp attach(ctx, thread, message_id, bytes) do
    call(ctx, %{
      "action" => "attach",
      "thread" => thread.id,
      "message_id" => message_id,
      "files" => [
        %{"filename" => "note.txt", "media_type" => "text/plain", "data" => Base.encode64(bytes)}
      ]
    })
  end

  defp discard(ctx, thread, message_id),
    do: call(ctx, %{"action" => "discard", "thread" => thread.id, "message_id" => message_id})

  describe "turns" do
    test "no one suspends or recovers a turn: the tool is unknown, alike to every caller, and offered to no one",
         %{ctx: ctx, thread: thread} do
      admin = %{ctx | platform_admin: true}
      key = %{ctx | auth_method: :api_key, permissions: MapSet.new([:*])}
      guest = guest(ctx)
      lineage = Cyfr.Test.AttemptFixtures.lineage!(ctx)

      unknown = %Prima.Refusal{
        stage: :admission,
        class: :not_found,
        reason: {:unknown_tool, "turn"},
        message: "Unknown tool: turn"
      }

      for action <- ["suspend", "recover"] do
        args = %{"action" => action, "thread" => thread.id, "turn" => "trn_named"}

        for caller <- [ctx, admin, key] do
          assert Sanctum.Gate.call_external("turn", caller, args) == {:error, unknown}
        end

        assert Sanctum.Gate.call_in_chain("turn", guest, args, chain_authority(),
                 lineage: lineage
               ) == {:error, unknown}
      end

      assert Enum.map(Tool.tools(), & &1.name) == ["thread", "crew", "threads"]
      refute Enum.any?(Sanctum.Catalog.tool_actions(), &String.starts_with?(&1, "turn."))

      for caller <- [ctx, admin, key] do
        shown = Visibility.filter_for_context(Sanctum.Catalog.list_tools(), caller)
        refute Enum.any?(shown, &(&1["name"] == "turn"))
      end

      in_chain = Sanctum.Catalog.in_chain_view(Sanctum.Catalog.list_tools())
      refute Enum.any?(in_chain, &(&1["name"] == "turn"))
    end
  end

  # A guest of the person's athanor inside a running chain, holding every
  # permission, so nothing but the tool's absence can refuse its call.
  defp guest(ctx) do
    Sanctum.Context.enter_guest(%Sanctum.Context{
      origin: :programmatic,
      user_id: ctx.user_id,
      athanor_id: ctx.athanor_id,
      scope: :athanor,
      permissions: MapSet.new([:*]),
      authenticated: true
    })
  end

  # A chain's grant whose one edge names an action the guest may reach,
  # so the authority admits the call up to the tool's lookup.
  defp chain_authority do
    node = "formula:local.turns"

    {:ok, blob} =
      Prima.Authority.Blob.parse(%{
        "canonical" => "jcs-1",
        "nodes" => %{
          node => %{
            "limits" => %{
              "timeout" => "1m",
              "max_memory_bytes" => 67_108_864,
              "max_request_size" => 1_048_576,
              "max_response_size" => 5_242_880,
              "rate_limit" => %{"requests" => 100, "window" => "1m"},
              "max_concurrent_tasks" => 10,
              "batch_timeout" => "1m"
            },
            "edges" => %{"@ingress" => %{"tools" => ["crew.list"]}}
          }
        }
      })

    {:ok, authority} =
      Prima.Authority.root(
        %{
          profile_id: "prof-turns",
          consent_id: "consent-turns",
          source_ref: node,
          kind: :owner,
          invoke_mode: :open_inert,
          activation: %{node => "sha256:turns"}
        },
        blob,
        ceiling: Sanctum.Policy.Ceiling.platform_ceiling()
      )

    authority
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
      star = %{ctx | auth_method: :api_key, permissions: MapSet.new([:*])}

      assert {:error,
              %Prima.Refusal{
                stage: :admission,
                reason: {:consent_class_required, {:surface_not_permitted, :api_key}}
              }} =
               Sanctum.Gate.call_external("thread", star, %{
                 "action" => "events",
                 "thread" => thread.id
               })

      scoped = %{ctx | auth_method: :api_key}

      assert {:error,
              %Prima.Refusal{
                stage: :admission,
                reason: {:consent_class_required, {:surface_not_permitted, :api_key}}
              }} =
               Sanctum.Gate.call_external("thread", scoped, %{
                 "action" => "send",
                 "thread" => thread.id,
                 "message" => "hi"
               })
    end

    test "a surface that would be refused is not shown the tool", %{ctx: ctx} do
      # Discovery reads the same annotation dispatch enforces: an API key
      # is not offered a door it cannot open.
      star = %{ctx | auth_method: :api_key, permissions: MapSet.new([:*])}

      shown = Visibility.filter_for_context(Sanctum.Catalog.list_tools(), star)
      refute Enum.any?(shown, &(&1["name"] == "thread"))

      shown_oidc = Visibility.filter_for_context(Sanctum.Catalog.list_tools(), ctx)
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

      assert {:error, %Prima.Refusal{stage: :admission, reason: {:guest_plane_call, "thread"}}} =
               Sanctum.Gate.call_external("thread", guest, %{
                 "action" => "events",
                 "thread" => thread.id
               })
    end

    test "every action but post, search and events is external-plane only and interactive-only; " <>
           "post is a chain's alone, and the two reads are the person's and a chain's" do
      actions = Tool.definition().annotations.actions

      assert map_size(actions) == 14

      for {name, spec} <- Map.drop(actions, ["post", "search", "events"]) do
        assert spec.planes == [:external], "#{name} is reachable in-chain"
        assert spec.consent == :interactive, "#{name} is reachable by a standing credential"
      end

      assert %{planes: [:in_chain], kind: :write} = post = actions["post"]
      refute Map.has_key?(post, :consent)

      for read <- ["search", "events"] do
        assert %{planes: [:external, :in_chain], kind: :read, consent: :interactive} =
                 actions[read]
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
          sent_by: "person",
          kind: "text",
          content: "one"
        })

      {:ok, _b} =
        Threads.append(Sanctum.Context.actor(ctx), thread.id, %{
          author: "aqua",
          sent_by: "aqua",
          kind: "text",
          content: "two"
        })

      assert {:ok, %{messages: msgs, cursor: cursor}} =
               call(ctx, %{"action" => "events", "thread" => thread.id})

      assert Enum.map(msgs, & &1.content) == ["one", "two"]

      assert Enum.map(msgs, &Map.take(&1, [:sent_by, :reply_to, :outcome, :workspace])) == [
               %{sent_by: "person", reply_to: nil, outcome: nil, workspace: nil},
               %{sent_by: "aqua", reply_to: nil, outcome: nil, workspace: nil}
             ]

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

    test "refusals are the typed vocabulary, not sentences", %{ctx: ctx, thread: thread} do
      assert {:refused, {:invalid_argument, _}} =
               admission(ctx, "thread", %{"action" => "send", "thread" => thread.id})

      assert {:refused, {:unknown_action, "thread.dance"}} =
               admission(ctx, "thread", %{"action" => "dance", "thread" => thread.id})

      assert {:refused, {:invalid_argument, _}} =
               admission(ctx, "thread", %{"action" => "events"})
    end

    test "another athanor's thread is not found", %{ctx: ctx, thread: thread} do
      elsewhere = %{ctx | athanor_id: "ath_elsewhere"}

      # Typed at the boundary: the runner's bare atom would render as a
      # generic "the tool call failed" on every surface.
      assert {:error, {:not_found, "thread", _}} =
               call(elsewhere, %{"action" => "events", "thread" => thread.id})
    end

    test "a headless client finds today's thread and lists threads — the id needs no console",
         %{ctx: ctx} do
      before = Aqua.Day.today(ctx)

      assert {:ok, %{id: id, kind: "daily", day: day, title: title, parent_id: nil}} =
               call(ctx, %{"action" => "today"})

      assert day in [before, Aqua.Day.today(ctx)]
      assert title == Date.to_iso8601(day)

      # Asked again on the same day, the same thread.
      assert {:ok, %{id: again, day: again_day}} = call(ctx, %{"action" => "today"})
      if again_day == day, do: assert(again == id)

      assert {:ok, %{threads: rows}} = call(ctx, %{"action" => "list"})
      assert Enum.count(rows, &(&1.id == id)) == 1
    end

    test "no thread is created on demand: create is no action of the tool", %{ctx: ctx} do
      before = Threads.list(Sanctum.Context.actor(ctx))

      assert {:refused, {:unknown_action, "thread.create"}} =
               admission(ctx, "thread", %{"action" => "create", "title" => "Plans"})

      assert Threads.list(Sanctum.Context.actor(ctx)) == before
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

      # A person of their own (`Sanctum.TestContext.person!/1`), working in
      # their own athanor, since aloud checks the source is theirs too, and
      # in a shared thread with someone else.
      {ctx, user} = Sanctum.TestContext.person!(ctx)
      ctx = %{ctx | athanor_id: Sanctum.Test.People.athanor!(user).id}

      {:ok, thread} = Arca.Test.Days.thread(Sanctum.Context.actor(ctx))
      {:ok, shared} = Sanctum.SharedThreads.create(ctx.user_id, "Trip")
      {:ok, ctx: ctx, thread: thread, shared: shared}
    end

    test "the ids are checked in shape and in number before anything is read", %{
      ctx: ctx,
      thread: thread,
      shared: shared
    } do
      base = %{"action" => "aloud", "thread" => thread.id, "target_thread" => shared.id}

      # The gate casts each element: a non-string one is refused before
      # anything is read.
      assert {:refused, {:invalid_argument, _}} =
               admission(ctx, "thread", Map.put(base, "message_ids", [1]))

      too_many = Enum.map(1..51, &"msg_#{&1}")
      assert {:error, {:invalid_argument, _}} = call(ctx, Map.put(base, "message_ids", too_many))
    end

    test "the target is a shared thread, named alone", %{ctx: ctx, thread: thread} do
      # The declaration takes the shared thread and nothing else: no
      # target athanor, and no call without the thread.
      assert {:refused, {:invalid_argument, _}} =
               admission(ctx, "thread", %{
                 "action" => "aloud",
                 "thread" => thread.id,
                 "message_ids" => ["msg_x"]
               })
    end

    test "your own line reaches the shared thread; someone else's is refused", %{
      ctx: ctx,
      thread: thread,
      shared: shared
    } do
      {:ok, mine} =
        Threads.append(Sanctum.Context.actor(ctx), thread.id, %{
          author: ctx.user_id,
          sent_by: "person",
          kind: "text",
          content: "hi"
        })

      {:ok, other} =
        Threads.append(Sanctum.Context.actor(ctx), thread.id, %{
          author: "local|idp|someone-else",
          sent_by: "person",
          kind: "text",
          content: "not yours"
        })

      shared_id = shared.id

      assert {:ok, %{said_aloud: 1, target_thread: ^shared_id}} =
               call(ctx, %{
                 "action" => "aloud",
                 "thread" => thread.id,
                 "message_ids" => [mine.id],
                 "target_thread" => shared.id
               })

      assert {:ok, [%{content: "hi", author: author}]} =
               Sanctum.SharedThreads.messages(ctx.user_id, shared.id)

      assert author == ctx.user_id

      assert {:error, {:invalid_argument, msg}} =
               call(ctx, %{
                 "action" => "aloud",
                 "thread" => thread.id,
                 "message_ids" => [other.id],
                 "target_thread" => shared.id
               })

      assert msg =~ "your own lines"
    end

    test "a shared thread the caller does not sit in is a missing one", %{
      ctx: ctx,
      thread: thread
    } do
      someone = Cyfr.Test.ShareFixtures.person!("Someone").user.id
      {:ok, theirs} = Sanctum.SharedThreads.create(someone, "Theirs")

      {:ok, mine} =
        Threads.append(Sanctum.Context.actor(ctx), thread.id, %{
          author: ctx.user_id,
          sent_by: "person",
          kind: "text",
          content: "hi"
        })

      theirs_id = theirs.id

      assert {:error, {:not_found, "Thread", ^theirs_id}} =
               call(ctx, %{
                 "action" => "aloud",
                 "thread" => thread.id,
                 "message_ids" => [mine.id],
                 "target_thread" => theirs.id
               })

      assert {:ok, []} = Sanctum.SharedThreads.messages(someone, theirs.id)
    end

    test "a source in an athanor not the caller's own is refused in plain words", %{
      ctx: ctx,
      thread: thread,
      shared: shared
    } do
      other = Cyfr.Test.ShareFixtures.person!("Other").athanor

      assert {:error, {:invalid_argument, msg}} =
               call(%{ctx | athanor_id: other.id}, %{
                 "action" => "aloud",
                 "thread" => thread.id,
                 "message_ids" => ["msg_x"],
                 "target_thread" => shared.id
               })

      assert msg == "aloud reads only threads of your own athanor"
      refute msg =~ "member"
      assert {:ok, []} = Sanctum.SharedThreads.messages(ctx.user_id, shared.id)
    end
  end

  describe "the send envelope and the thread's own verbs" do
    setup %{ctx: ctx} do
      # Every send starts a turn, which the sender's own filled athanor
      # admits: the sender is a person of their own, working there. Each
      # send here names its agent, and the turns it starts stop with the
      # test.
      {ctx, user} = Sanctum.TestContext.person!(ctx)
      ctx = %{ctx | athanor_id: Sanctum.Test.People.athanor!(user).id}
      Sanctum.TestContext.ready!(ctx.athanor_id)
      Cyfr.Test.Sandbox.stop_work_on_exit()
      # Today's daily thread, which a send naming it joins as named.
      {:ok, thread} = Aqua.Day.current(ctx)
      {:ok, ctx: ctx, thread: thread}
    end

    test "a send naming no thread joins today's daily thread and answers its id", %{
      ctx: ctx,
      thread: thread
    } do
      assert {:ok, %{accepted: true, message_id: id, thread: landed}} =
               call(ctx, %{"action" => "send", "message" => "good morning", "agent" => "aqua"})

      assert landed == thread.id
      assert {:ok, %{thread_id: ^landed}} = Threads.get_message(Sanctum.Context.actor(ctx), id)
      assert [%{id: ^landed}] = Threads.list(Sanctum.Context.actor(ctx), kind: "daily")
    end

    test "a send naming a past daily thread joins today's, and the past day keeps what it held",
         %{ctx: ctx, thread: thread} do
      actor = Sanctum.Context.actor(ctx)
      {:ok, past} = Arca.Test.Days.thread(actor)

      {:ok, kept} =
        Threads.append(actor, past.id, %{author: ctx.user_id, sent_by: "person", content: "then"})

      assert {:ok, %{accepted: true, message_id: id, thread: landed}} =
               call(ctx, %{
                 "action" => "send",
                 "thread" => past.id,
                 "message" => "now",
                 "agent" => "aqua"
               })

      assert landed == thread.id
      assert {:ok, %{thread_id: ^landed}} = Threads.get_message(actor, id)
      assert Enum.map(Threads.messages(actor, past.id), & &1.id) == [kept.id]
      assert {:ok, %{day: day}} = Threads.get(actor, past.id)
      assert day == past.day
    end

    test "a send whose files were attached before the day turned is refused and leaves nothing",
         %{ctx: ctx, thread: thread} do
      # The person's own session, which remembers what it stored.
      mine = %{ctx | session_token_hash: :crypto.hash(:sha256, "mine")}
      actor = Sanctum.Context.actor(ctx)
      {:ok, past} = Arca.Test.Days.thread(actor)
      message_id = Prima.UUID7.generate_id("msg")
      {:ok, %{attachments: [ref]}} = attach(mine, past, message_id, "past bytes")
      {:ok, blob} = Aqua.attachment_blob_path(past.id, message_id, ref)
      assert {:ok, "past bytes"} = Arca.get(actor, blob)
      threads = Threads.list(actor)
      turns = Arca.TurnStorage.open_turns(actor, thread.id)

      assert {:error,
              {:conflict,
               "The day has turned since these files were attached. Attach them again and send."}} =
               call(mine, %{
                 "action" => "send",
                 "thread" => past.id,
                 "message" => "with a file",
                 "agent" => "aqua",
                 "id" => message_id,
                 "attachments" => [ref]
               })

      # No row, no new day's thread, no turn, and none of the bytes the
      # send's own session stored under the message.
      assert {:error, :not_found} = Threads.get_message(actor, message_id)
      assert Threads.list(actor) == threads
      assert Threads.messages(actor, past.id) == []
      assert Threads.messages(actor, thread.id) == []
      assert Arca.TurnStorage.open_turns(actor, thread.id) == turns

      refute Arca.exists?(actor, blob)
    end

    test "a send with files that names no thread is refused and leaves nothing", %{
      ctx: ctx,
      thread: thread
    } do
      actor = Sanctum.Context.actor(ctx)
      message_id = Prima.UUID7.generate_id("msg")
      {:ok, %{attachments: [ref]}} = attach(ctx, thread, message_id, "today's bytes")
      threads = Threads.list(actor)

      assert {:error,
              {:invalid_argument, "A send with files names the thread they were attached to."}} =
               call(ctx, %{
                 "action" => "send",
                 "message" => "with a file",
                 "agent" => "aqua",
                 "id" => message_id,
                 "attachments" => [ref]
               })

      assert {:error, :not_found} = Threads.get_message(actor, message_id)
      assert Threads.list(actor) == threads
      assert Threads.messages(actor, thread.id) == []
    end

    test "a send whose files were attached to today's thread joins it with them", %{
      ctx: ctx,
      thread: thread
    } do
      actor = Sanctum.Context.actor(ctx)
      message_id = Prima.UUID7.generate_id("msg")
      {:ok, %{attachments: [ref]}} = attach(ctx, thread, message_id, "today's bytes")

      assert {:ok, %{accepted: true, thread: landed}} =
               call(ctx, %{
                 "action" => "send",
                 "thread" => thread.id,
                 "message" => "with a file",
                 "agent" => "aqua",
                 "id" => message_id,
                 "attachments" => [ref]
               })

      assert landed == thread.id
      {:ok, row} = Threads.get_message(actor, message_id)

      assert [%{"data" => data}] =
               Aqua.Attachments.load(ctx, landed, Aqua.Attachments.attachments_of([row]))

      assert Base.decode64!(data) == "today's bytes"
    end

    test "a send naming a crew member's thread goes to that thread, never to today's", %{
      ctx: ctx,
      thread: thread
    } do
      actor = Sanctum.Context.actor(ctx)
      {:ok, crew} = Threads.crew_thread(actor, thread.id, "planner")

      # The athanor has no crew member of that name, which only the crew
      # thread's own admission asks: today's thread would take the line.
      assert {:error, :not_addressable} =
               call(ctx, %{
                 "action" => "send",
                 "thread" => crew.id,
                 "message" => "hello",
                 "agent" => "aqua"
               })

      assert Threads.messages(actor, thread.id) == []
      assert [%{id: only}] = Threads.list(actor, kind: "daily")
      assert only == thread.id
    end

    test "a send naming another athanor's thread is not found, and makes no thread", %{
      ctx: ctx,
      thread: thread
    } do
      n = System.unique_integer([:positive])
      {other, user} = Sanctum.TestContext.person!(%{ctx | user_id: "local|idp|stranger-#{n}"})
      other = %{other | athanor_id: Sanctum.Test.People.athanor!(user).id}

      assert {:error, {:not_found, "thread", id}} =
               call(other, %{
                 "action" => "send",
                 "thread" => thread.id,
                 "message" => "hello",
                 "agent" => "aqua"
               })

      assert id == thread.id
      assert Threads.list(Sanctum.Context.actor(other)) == []
      assert Threads.messages(Sanctum.Context.actor(ctx), thread.id) == []
    end

    test "get answers the thread with its live state", %{ctx: ctx, thread: thread} do
      assert {:ok, %{id: id, running: false, queued: 0}} =
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

      assert {:ok, %{accepted: true, message_id: ^message_id, replayed: false}} =
               call(ctx, %{
                 "action" => "send",
                 "thread" => thread.id,
                 "message" => "here is a file",
                 "agent" => "aqua",
                 "id" => message_id,
                 "attachments" => [ref],
                 "client_id" => "c-1"
               })

      {:ok, row} = Threads.get_message(Sanctum.Context.actor(ctx), message_id)
      assert Threads.payload(row)["attachments"] == [ref]

      assert {:ok, %{messages: messages, cursor: cursor}} =
               call(ctx, %{"action" => "events", "thread" => thread.id})

      assert Enum.any?(messages, &(&1.id == message_id))
      assert is_integer(cursor)
    end

    test "discard removes only what the caller's own session attached under an unsent message",
         %{ctx: ctx, thread: thread} do
      mine = %{ctx | session_token_hash: :crypto.hash(:sha256, "mine")}
      theirs = %{ctx | session_token_hash: :crypto.hash(:sha256, "theirs")}
      message_id = Prima.UUID7.generate_id("msg")
      {:ok, %{attachments: [ref]}} = attach(mine, thread, message_id, "mine")
      {:ok, blob} = Aqua.attachment_blob_path(thread.id, message_id, ref)

      assert {:ok, %{discarded: []}} = discard(theirs, thread, message_id)
      assert {:ok, "mine"} = Arca.get(Sanctum.Context.actor(ctx), blob)

      assert {:ok, %{discarded: [name]}} = discard(mine, thread, message_id)
      assert name == ref["stored_name"]
      refute Arca.exists?(Sanctum.Context.actor(ctx), blob)
      assert {:ok, %{discarded: []}} = discard(mine, thread, message_id)
    end

    test "a sent message's files stay: discard refuses them and attach writes over none",
         %{ctx: ctx, thread: thread} do
      mine = %{ctx | session_token_hash: :crypto.hash(:sha256, "mine")}
      theirs = %{ctx | session_token_hash: :crypto.hash(:sha256, "theirs")}
      message_id = Prima.UUID7.generate_id("msg")
      {:ok, %{attachments: [ref]}} = attach(mine, thread, message_id, "sent bytes")
      {:ok, blob} = Aqua.attachment_blob_path(thread.id, message_id, ref)

      assert {:ok, %{accepted: true}} =
               call(mine, %{
                 "action" => "send",
                 "thread" => thread.id,
                 "message" => "with a file",
                 "agent" => "aqua",
                 "id" => message_id,
                 "attachments" => [ref],
                 "client_id" => "c-sent"
               })

      for who <- [mine, theirs] do
        assert {:error, {:conflict, _}} = discard(who, thread, message_id)
        assert {:error, {:conflict, _}} = attach(who, thread, message_id, "over")
      end

      assert {:ok, "sent bytes"} = Arca.get(Sanctum.Context.actor(ctx), blob)
    end

    test "attach writes over no file under an unsent message, the storing session's own included; discarded, the name is free again",
         %{ctx: ctx, thread: thread} do
      mine = %{ctx | session_token_hash: :crypto.hash(:sha256, "mine")}
      theirs = %{ctx | session_token_hash: :crypto.hash(:sha256, "theirs")}
      message_id = Prima.UUID7.generate_id("msg")
      {:ok, %{attachments: [ref]}} = attach(mine, thread, message_id, "first")
      {:ok, blob} = Aqua.attachment_blob_path(thread.id, message_id, ref)

      for who <- [theirs, mine] do
        assert {:error, {:conflict, sentence}} = attach(who, thread, message_id, "over")
        assert {:ok, "first"} = Arca.get(Sanctum.Context.actor(ctx), blob)

        # The answer says what is there and how to replace it, and blames no
        # other session: the storing session's own retry gets it too.
        assert sentence =~ "already under that message"
        assert sentence =~ "thread.discard"
        refute String.downcase(sentence) =~ "another session"
      end

      assert {:ok, %{discarded: [_]}} = discard(mine, thread, message_id)
      assert {:ok, %{attachments: [_]}} = attach(mine, thread, message_id, "again")
      assert {:ok, "again"} = Arca.get(Sanctum.Context.actor(ctx), blob)
    end

    test "a shared thread beside the thread is read for the send and never stored", %{
      ctx: ctx,
      thread: thread
    } do
      {:ok, beside} = Sanctum.SharedThreads.create(ctx.user_id, "Beside")
      {:ok, _} = Sanctum.SharedThreads.post(ctx.user_id, beside.id, "shared talk")

      assert {:ok, %{accepted: true, message_id: id}} =
               call(ctx, %{
                 "action" => "send",
                 "thread" => thread.id,
                 "message" => "about the shared thread",
                 "agent" => "aqua",
                 "room" => %{"shared_thread_id" => beside.id, "title" => "Beside"}
               })

      {:ok, row} = Threads.get_message(Sanctum.Context.actor(ctx), id)
      assert row.content == "about the shared thread"
      refute inspect(Threads.payload(row)) =~ "shared talk"

      # A shared thread the sender does not sit in leaves the send as it is.
      assert {:ok, %{accepted: true}} =
               call(ctx, %{
                 "action" => "send",
                 "thread" => thread.id,
                 "message" => "still sent",
                 "agent" => "aqua",
                 "room" => %{"shared_thread_id" => "sth_elsewhere"}
               })
    end

    test "the room a send names is a shared thread, by its id", %{ctx: ctx, thread: thread} do
      assert {:refused, {:invalid_argument, _}} =
               admission(ctx, "thread", %{
                 "action" => "send",
                 "thread" => thread.id,
                 "message" => "hello",
                 "room" => %{"title" => "no id"}
               })
    end

    test "delete removes the thread whole", %{ctx: ctx, thread: thread} do
      {:ok, _} =
        Threads.append(Sanctum.Context.actor(ctx), thread.id, %{
          author: ctx.user_id,
          sent_by: "person",
          content: "bye"
        })

      assert {:ok, %{deleted: true}} =
               call(ctx, %{"action" => "delete", "thread" => thread.id})

      assert {:error, {:not_found, "thread", _}} =
               call(ctx, %{"action" => "get", "thread" => thread.id})

      assert {:error, {:not_found, "thread", _}} =
               call(ctx, %{"action" => "delete", "thread" => thread.id})
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

  describe "post" do
    # A running turn with its root, as the loop starts one; its chain's
    # calls carry the lineage the gate stamps.
    defp running!(ctx, thread) do
      alias Aqua.Tape

      {:ok, %{turn: turn}} =
        Tape.accept(ctx, thread.id, %{
          message: %{author: ctx.user_id, sent_by: "person", content: "draw the moon"},
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
            turn_id: turn.id,
            origin: :interactive
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
          consent_id: "consent_x",
          recovery_limit: Aqua.Runner.RecoveryPolicy.max_attempts()
        })

      turn
    end

    defp post(ctx, turn, args) do
      call(
        Sanctum.Context.enter_guest(ctx),
        Map.merge(
          %{
            "action" => "post",
            "thread_id" => turn.thread_id,
            "root_execution_id" => turn.root_execution_id
          },
          args
        )
      )
    end

    @png %{
      "filename" => "moon.png",
      "media_type" => "image/png",
      "data" => Base.encode64("PNG-moon")
    }

    test "a turn posts text, files and links into its own thread, its files under the post's own row",
         %{ctx: ctx, thread: thread} do
      turn = running!(ctx, thread)

      assert {:ok, %{posted: id, thread: posted_in, files: 1}} =
               post(ctx, turn, %{
                 "text" => "The moon tonight.",
                 "files" => [@png],
                 "links" => [%{"url" => "https://moon.example/tonight", "title" => " Tonight "}]
               })

      assert posted_in == thread.id

      {:ok, row} = Threads.get_message(Sanctum.Context.actor(ctx), id)
      assert %{author: "aqua", sent_by: "aqua", kind: "text", content: "The moon tonight."} = row
      assert row.turn_id == turn.id

      assert %{
               "post" => true,
               "attachments" => [%{"filename" => "moon.png"} = ref],
               "links" => [%{"url" => "https://moon.example/tonight", "title" => "Tonight"}]
             } = Threads.payload(row)

      assert [%{"data" => data}] =
               Aqua.Attachments.load(ctx, thread.id, [%{message_id: id, ref: ref}])

      assert Base.decode64!(data) == "PNG-moon"
    end

    test "a holder a takeover replaced posts nothing and leaves none of its files",
         %{ctx: ctx, thread: thread} do
      turn = running!(ctx, thread)
      before = Threads.messages(Sanctum.Context.actor(ctx), thread.id)

      # The root's own call names the attempt that made it, which the
      # turn no longer runs.
      stale = %{
        "parent_execution_id" => turn.root_execution_id,
        "attempt" => "att_replaced",
        "text" => "late",
        "files" => [@png]
      }

      assert {:error, {:conflict, _}} = post(ctx, turn, stale)
      assert Threads.messages(Sanctum.Context.actor(ctx), thread.id) == before

      {:ok, entries} = Arca.list_typed(Sanctum.Context.actor(ctx), ["threads", thread.id])

      assert for({_name, :dir} = entry <- entries, do: entry)
             |> Enum.all?(&empty_dir?(ctx, thread, &1))
    end

    test "nothing posts outside a turn, and a post holds text, files or links, and only http links",
         %{ctx: ctx, thread: thread} do
      turn = running!(ctx, thread)

      assert {:error, :not_in_a_turn} =
               call(ctx, %{"action" => "post", "text" => "from outside"})

      assert {:error, :not_in_a_turn} =
               post(ctx, %{turn | root_execution_id: "exec_forged"}, %{"text" => "forged"})

      assert {:error, {:invalid_argument, _}} = post(ctx, turn, %{"text" => "  "})

      assert {:error, {:invalid_argument, _}} =
               post(ctx, turn, %{"links" => [%{"url" => "javascript:alert(1)"}]})

      assert {:error, {:invalid_argument, _}} =
               post(ctx, turn, %{
                 "links" => for(n <- 1..21, do: %{"url" => "https://x.example/#{n}"})
               })

      assert {:error, :message_too_long} =
               post(ctx, turn, %{"text" => String.duplicate("a", 33_000)})
    end
  end

  describe "recall" do
    # A workspace thread of the context's athanor, as `workspace.open`
    # leaves its row.
    defp workspace!(ctx, title) do
      %Arca.Schemas.Thread{}
      |> Arca.Schemas.Thread.changeset(%{
        id: Prima.UUID7.generate_id("thread"),
        athanor_id: ctx.athanor_id,
        kind: "workspace",
        workspace_state: "open",
        title: title,
        created_by: ctx.user_id
      })
      |> Arca.Repo.insert!()
      |> Map.from_struct()
    end

    defp say!(ctx, thread, content, attrs \\ %{}) do
      {:ok, row} =
        Threads.append(
          Sanctum.Context.actor(ctx),
          thread.id,
          Map.merge(%{author: ctx.user_id, sent_by: "person", content: content}, attrs)
        )

      row
    end

    defp search(ctx, args), do: call(ctx, Map.put(args, "action", "search"))

    # A turn's call, with the lineage the gate stamps.
    defp in_turn(ctx, turn, args) do
      call(
        Sanctum.Context.enter_guest(ctx),
        Map.merge(
          %{"thread_id" => turn.thread_id, "root_execution_id" => turn.root_execution_id},
          args
        )
      )
    end

    defp read_threads(ctx, turn) do
      {:ok, %{read_threads: read}} = Aqua.Tape.turn(ctx, turn.id)
      Arca.ThreadStorage.threads_of(read)
    end

    test "a search finds posts of the daily and workspace threads, newest first, each a pointer",
         %{ctx: ctx, thread: daily} do
      work = workspace!(ctx, "NVDA technical analysis")
      old = say!(ctx, daily, "Look at Nvidia's CHART for me")
      _other = say!(ctx, daily, "Remind me to call the plumber")
      rsi = say!(ctx, work, "RSI is 71 on the daily chart", %{author: "aqua", sent_by: "aqua"})

      assert {:ok, %{results: [first, second], count: 2, next: nil} = answer} =
               search(ctx, %{"q" => "  ChaRT  "})

      # The person's own read at the door joins no turn and names nothing.
      refute Map.has_key?(answer, :read_threads)

      assert %{message: id, kind: "workspace", title: "NVDA technical analysis", by: "aqua"} =
               first

      assert id == rsi.id and first.thread == work.id and first.seq == rsi.seq
      refute Map.has_key?(first, :day)
      assert %{message: id, kind: "daily", day: day, by: "person", seq: seq} = second
      assert id == old.id and day == daily.day and seq == old.seq
      assert second.snippet == "Look at Nvidia's CHART for me"
    end

    test "a query is held to its bytes and is no pattern: % and _ are literal, and case folds " <>
           "beyond ASCII",
         %{ctx: ctx, thread: daily} do
      say!(ctx, daily, "Été à SÃO JORGE")
      say!(ctx, daily, "100% done")
      say!(ctx, daily, "a_b and anything else")

      assert {:ok, %{count: 1}} = search(ctx, %{"q" => "été à são"})
      assert {:ok, %{count: 1}} = search(ctx, %{"q" => "%"})
      assert {:ok, %{count: 1}} = search(ctx, %{"q" => "_"})
      assert {:ok, %{count: 0}} = search(ctx, %{"q" => "a%b"})

      assert {:error, {:invalid_argument, _}} = search(ctx, %{"q" => "   "})
      assert {:error, {:invalid_argument, _}} = search(ctx, %{"q" => String.duplicate("é", 101)})
      assert {:ok, %{count: 0}} = search(ctx, %{"q" => String.duplicate("a", 200)})
    end

    test "a snippet is whole characters around the match, on one line, within its bytes",
         %{ctx: ctx, thread: daily} do
      lead = String.duplicate("ñandú ", 60)
      say!(ctx, daily, lead <> "\nthe NEEDLE is here\n" <> String.duplicate("文字 ", 80))

      assert {:ok, %{results: [%{snippet: snippet}]}} = search(ctx, %{"q" => "needle"})
      assert byte_size(snippet) <= 240 and String.valid?(snippet)
      assert snippet =~ "the NEEDLE is here"
      assert String.starts_with?(snippet, "…") and String.ends_with?(snippet, "…")
      refute snippet =~ "\n"
    end

    test "twenty posts at most a page, and the next page goes on with no post twice or missed",
         %{ctx: ctx, thread: daily} do
      ids = for n <- 1..25, do: say!(ctx, daily, "entry #{n} of the log").id

      assert {:ok, %{results: page, count: 20, next: next}} = search(ctx, %{"q" => "LOG"})
      assert {:ok, %{results: rest, count: 5}} = search(ctx, %{"q" => "log", "before" => next})
      assert {:ok, %{count: 5}} = search(ctx, %{"q" => "log", "limit" => 5})

      assert Enum.map(page ++ rest, & &1.message) == Enum.reverse(ids)

      assert {:error, {:invalid_argument, _}} =
               search(ctx, %{"q" => "log", "before" => "msg_not_here"})
    end

    test "equal-time posts use the same id order on both adapters", %{ctx: ctx, thread: daily} do
      a = say!(ctx, daily, "tie search", %{id: "msg_a"})
      b = say!(ctx, daily, "tie search", %{id: "msg_B"})
      at = ~U[2026-01-01 01:02:03.123456Z]

      {2, _} =
        Arca.Repo.update_all(
          Ecto.Query.from(m in Arca.Schemas.Message, where: m.id in ^[a.id, b.id]),
          set: [inserted_at: at]
        )

      assert {:ok, %{results: first, next: cursor}} =
               search(ctx, %{"q" => "tie search", "limit" => 1})

      assert {:ok, %{results: second}} = search(ctx, %{"q" => "tie search", "before" => cursor})

      # By their bytes, newest first: "msg_a" after "msg_B".
      assert Enum.map(first ++ second, & &1.message) == Enum.sort([a.id, b.id], :desc)
    end

    test "a crew member's thread and another athanor's are neither searched nor read",
         %{ctx: ctx, thread: daily} do
      actor = Sanctum.Context.actor(ctx)
      {:ok, crew} = Threads.crew_thread(actor, daily.id, "coder")
      say!(ctx, crew, "the crew's secret plan", %{author: "coder", sent_by: "coder"})

      other = %{ctx | athanor_id: "ath_elsewhere"}
      {:ok, theirs} = Arca.Test.Days.thread(Sanctum.Context.actor(other))
      say!(other, theirs, "their secret plan")

      assert {:ok, %{count: 0}} = search(ctx, %{"q" => "secret plan"})

      turn = running!(ctx, daily)

      for id <- [crew.id, theirs.id] do
        assert {:error, {:not_found, "thread", ^id}} =
                 in_turn(ctx, turn, %{"action" => "events", "thread" => id})
      end

      assert read_threads(ctx, turn) == []
    end

    test "a turn reads a daily or workspace thread's posts, fifty at most, after a seq",
         %{ctx: ctx, thread: daily} do
      work = workspace!(ctx, "A long one")
      for n <- 1..60, do: say!(ctx, work, "step #{n}")
      turn = running!(ctx, daily)

      assert {:ok, %{messages: page, cursor: cursor}} =
               in_turn(ctx, turn, %{"action" => "events", "thread" => work.id, "limit" => 500})

      name = Sanctum.Tenancy.Users.display_name(ctx.user_id)
      assert length(page) == 50 and hd(page).content == "#{name}: step 1"

      assert {:ok, %{messages: rest}} =
               in_turn(ctx, turn, %{
                 "action" => "events",
                 "thread" => work.id,
                 "after_seq" => cursor
               })

      assert Enum.map(rest, & &1.content) == for(n <- 51..60, do: "#{name}: step #{n}")

      # The person's own read keeps its bound of 500 rows.
      assert {:ok, %{messages: all}} = call(ctx, %{"action" => "events", "thread" => work.id})
      assert length(all) == 60
    end

    test "in a turn a read is worded and named, with the thread's open turns: a post of a " <>
           "turn that ended untaken says so, and the person's replay stays raw",
         %{ctx: ctx, thread: daily} do
      work = workspace!(ctx, "Plans")
      ended = running!(ctx, work)
      {:ok, _} = Aqua.Tape.finish(ctx, ended, "cancelled")
      {:ok, refused} = Aqua.Tape.message(ctx, ended.message_id)
      open = running!(ctx, work)
      {:ok, waiting} = Aqua.Tape.message(ctx, open.message_id)

      reply =
        say!(ctx, work, "It could not run.", %{
          author: "aqua",
          sent_by: "builder",
          reply_to: refused.id,
          outcome: "failed"
        })

      name = Sanctum.Tenancy.Users.display_name(ctx.user_id)
      args = %{"action" => "events", "thread" => work.id}

      assert {:ok, %{messages: read}} = in_turn(ctx, running!(ctx, daily), args)

      assert Enum.map(read, & &1.content) == [
               "[#{name} posted this and it was not taken: its turn ended before any model " <>
                 "read it. Act on it only if they ask again]\n#{refused.content}",
               "#{name}: #{waiting.content}",
               "[builder replied to request #{refused.id}: failed]\nIt could not run."
             ]

      assert %{sent_by: "builder", reply_to: to, outcome: "failed"} = List.last(read)
      assert to == refused.id

      assert {:ok, %{messages: raw}} = call(ctx, args)
      assert Enum.map(raw, & &1.content) == [refused.content, waiting.content, reply.content]
    end

    test "a turn's search and read join every thread they carry and their posts carry into " <>
           "the turn, before they answer",
         %{ctx: ctx, thread: daily} do
      work = workspace!(ctx, "Fares")
      news = workspace!(ctx, "News")
      feed = workspace!(ctx, "Feed")

      # A turn of the workspace thread read the news thread, and wrote a
      # post there.
      writer = running!(ctx, work)
      {:ok, _} = Aqua.Tape.record_model_intent(ctx, writer, %{threads: [news.id]})

      say!(ctx, work, "fares rise on Monday", %{
        author: "aqua",
        sent_by: "aqua",
        turn_id: writer.id
      })

      # The daily thread's report of it keeps what the reporting turn read.
      say!(ctx, daily, "Fares: fares rise on Monday", %{
        author: "aqua",
        sent_by: "aqua",
        kind: "report",
        workspace_id: work.id,
        payload: %{"read_threads" => [feed.id]}
      })

      reader = running!(ctx, daily)

      assert {:ok, %{results: [_report, _post], read_threads: carried}} =
               in_turn(ctx, reader, %{"action" => "search", "q" => "fares rise"})

      expected = Enum.sort([daily.id, feed.id, news.id, work.id])
      assert carried == expected
      assert read_threads(ctx, reader) == expected

      # A read of the workspace thread joins it and its writer's read threads.
      other = running!(ctx, workspace!(ctx, "Elsewhere"))

      assert {:ok, %{messages: read, read_threads: joined}} =
               in_turn(ctx, other, %{"action" => "events", "thread" => work.id})

      assert "fares rise on Monday" in Enum.map(read, & &1.content)
      assert joined == Enum.sort([news.id, work.id])
      assert read_threads(ctx, other) == joined
    end

    test "a holder a takeover replaced, a forged lineage and a chain with no turn read nothing",
         %{ctx: ctx, thread: daily} do
      say!(ctx, daily, "a private plan")
      turn = running!(ctx, daily)

      stale = %{
        "parent_execution_id" => turn.root_execution_id,
        "attempt" => "att_replaced",
        "action" => "search",
        "q" => "private"
      }

      assert {:error, {:conflict, _}} = in_turn(ctx, turn, stale)

      assert {:error, :not_in_a_turn} =
               in_turn(ctx, %{turn | root_execution_id: "exec_forged"}, %{
                 "action" => "search",
                 "q" => "private"
               })

      assert {:error, :not_in_a_turn} =
               call(Sanctum.Context.enter_guest(ctx), %{"action" => "search", "q" => "private"})

      assert {:error, :not_in_a_turn} =
               call(Sanctum.Context.enter_guest(ctx), %{
                 "action" => "events",
                 "thread" => daily.id
               })

      assert read_threads(ctx, turn) == []
    end
  end

  defp empty_dir?(ctx, thread, {name, :dir}) do
    case Arca.list_typed(Sanctum.Context.actor(ctx), ["threads", thread.id, name]) do
      {:ok, []} -> true
      {:error, :not_found} -> true
      _ -> false
    end
  end
end
