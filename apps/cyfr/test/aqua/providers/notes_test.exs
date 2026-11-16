# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Providers.NotesTest.Staging do
  @moduledoc false
  # A storage cap that runs what a test planted before it answers, which
  # guards itself to act once. `Arca.Storage.stage/3` asks it while a
  # note's bytes are staged, before the publication's transaction, so what
  # is planted lands in that window. The test plants it through
  # `Prima.Test.Env`, which restores it.
  @behaviour Prima.Caps

  @impl Prima.Caps
  def check_counted(_actor, _key, _count), do: :ok

  @impl Prima.Caps
  def check_storage(_actor, _incoming) do
    case :persistent_term.get({__MODULE__, :once}, nil) do
      nil -> :ok
      between -> between.()
    end

    :ok
  end
end

defmodule Aqua.Providers.NotesTest do
  # Notes are not the transcript. These pin the difference, and the rule
  # that makes "whose notes" a fact about where you are rather than an
  # argument: a note lands in the athanor in focus.
  use ExUnit.Case, async: false

  alias Aqua.Providers.Notes, as: Tool
  alias Prima.Authority
  alias Prima.Authority.Blob
  alias Sanctum.Context

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    test_path = Path.join(System.tmp_dir!(), "notes_#{:rand.uniform(1_000_000)}")
    original = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original,
        do: Application.put_env(:arca, :base_path, original),
        else: Application.delete_env(:arca, :base_path)
    end)

    n = System.unique_integer([:positive])

    {:ok, u} =
      Sanctum.Test.People.linked(%{id: "local|idp|note-#{n}", provider: "local"})

    user = u.id

    # The person works in their own athanor, the one their admission made.
    mine = Sanctum.Test.People.athanor!(u)
    ctx = %{Sanctum.TestContext.local(:prism) | user_id: user, athanor_id: mine.id}

    # Another person, working in their own athanor.
    {:ok, o} =
      Sanctum.Test.People.linked(%{id: "local|idp|note-other-#{n}", provider: "local"})

    theirs = Sanctum.Test.People.athanor!(o)
    other = %{Sanctum.TestContext.local(:prism) | user_id: o.id, athanor_id: theirs.id}
    {:ok, ctx: ctx, other: other, mine: mine, theirs: theirs}
  end

  defp call(ctx, args), do: Tool.handle("notes", ctx, args)

  # A chain authority granting exactly `pairs`, the shape the consent blob
  # mints from a manifest's `caps.tools`.
  defp granting(pairs) do
    node = "formula:local.assistant"
    tools = pairs |> Enum.map(fn {tool, action} -> "#{tool}.#{action}" end) |> Enum.sort()

    {:ok, blob} =
      Blob.parse(%{
        "canonical" => "jcs-1",
        "nodes" => %{
          node => %{
            "limits" => %{
              "timeout" => "1m",
              "max_memory_bytes" => 67_108_864,
              "max_request_size" => 1_048_576,
              "max_response_size" => 5_242_880,
              "rate_limit" => %{"requests" => 10_000, "window" => "1m"},
              "max_concurrent_tasks" => 10,
              "batch_timeout" => "1m"
            },
            "edges" => %{"@ingress" => %{"tools" => tools}}
          }
        }
      })

    {:ok, auth} =
      Authority.root(
        %{
          profile_id: "prof-notes",
          consent_id: "consent-notes",
          source_ref: node,
          kind: :owner,
          invoke_mode: :open_inert,
          activation: %{node => "sha256:notes"}
        },
        blob,
        ceiling: Sanctum.Policy.Ceiling.platform_ceiling()
      )

    auth
  end

  # An in-chain call comes from a real execution's attempt, which the host
  # names in its lineage; a lineage a case gives is stamped over it.
  defp in_chain(ctx, args, auth, opts \\ []) do
    caller = caller!(ctx)
    opts = Keyword.update(opts, :lineage, caller, &Map.merge(caller, &1))
    Sanctum.Gate.call_in_chain("notes", Context.enter_guest(ctx), args, auth, opts)
  end

  defp turn_row(athanor_id, id) do
    require Ecto.Query
    Ecto.Query.from(t in Arca.Schemas.Turn, where: t.athanor_id == ^athanor_id and t.id == ^id)
  end

  defp caller!(ctx),
    do: ctx |> Cyfr.Test.AttemptFixtures.lineage!() |> Map.take([:parent_execution_id, :attempt])

  test "a note lands in the athanor you are working in, and nowhere else", %{
    ctx: ctx,
    other: other,
    mine: mine,
    theirs: theirs
  } do
    {:ok, kept} = call(ctx, %{"action" => "keep", "name" => "decided", "content" => "Lisbon"})
    assert kept.athanor_id == mine.id

    {:ok, at_theirs} =
      call(other, %{"action" => "keep", "name" => "flight", "content" => "BA117"})

    assert at_theirs.athanor_id == theirs.id

    # Where you are is what you see.
    assert {:ok, %{notes: [%{name: "decided"}]}} = call(ctx, %{"action" => "list"})
    assert {:ok, %{notes: [%{name: "flight"}]}} = call(other, %{"action" => "list"})
    refute theirs.id == mine.id
  end

  test "keeping under a name that exists replaces it, and says so", %{ctx: ctx} do
    assert {:ok, %{kept: "decided", replaced: false}} =
             call(ctx, %{"action" => "keep", "name" => "decided", "content" => "Lisbon"})

    assert {:ok, %{kept: "decided", replaced: true}} =
             call(ctx, %{"action" => "keep", "name" => "decided", "content" => "Porto"})

    assert {:ok, %{content: "Porto"}} = call(ctx, %{"action" => "read", "name" => "decided"})
    assert {:ok, %{notes: [_]}} = call(ctx, %{"action" => "list"})
  end

  test "forgetting removes it", %{ctx: ctx} do
    {:ok, _} = call(ctx, %{"action" => "keep", "name" => "temp", "content" => "x"})
    {:ok, %{forgot: "temp"}} = call(ctx, %{"action" => "forget", "name" => "temp"})

    assert {:ok, %{notes: []}} = call(ctx, %{"action" => "list"})

    assert {:error, {:not_found, "note", "temp"}} =
             call(ctx, %{"action" => "read", "name" => "temp"})

    assert {:error, {:not_found, "note", "temp"}} =
             call(ctx, %{"action" => "forget", "name" => "temp"})
  end

  test "a pinned page is short, and pinning nothing clears it", %{ctx: ctx} do
    {:ok, %{pinned: "about-you"}} =
      call(ctx, %{
        "action" => "pin",
        "name" => "about-you",
        "content" => "We are planning a trip."
      })

    assert {:ok, %{content: "We are planning a trip."}} =
             call(ctx, %{"action" => "read", "name" => "about-you"})

    # Over the cap is refused, never truncated — a page read into every
    # turn is trimmed by a person, not by the tool.
    long = String.duplicate("x", Aqua.Notes.pin_max_bytes() + 1)

    assert {:error, {:invalid_argument, msg}} =
             call(ctx, %{"action" => "pin", "name" => "about-you", "content" => long})

    assert msg =~ "bytes"

    assert {:ok, %{content: "We are planning a trip."}} =
             call(ctx, %{"action" => "read", "name" => "about-you"})

    {:ok, %{cleared: "about-you"}} =
      call(ctx, %{"action" => "pin", "name" => "about-you", "content" => "  "})

    assert {:error, {:not_found, "note", "about-you"}} =
             call(ctx, %{"action" => "read", "name" => "about-you"})

    # Only the pinned name takes a pin.
    assert {:error, {:invalid_argument, msg}} =
             call(ctx, %{"action" => "pin", "name" => "flight", "content" => "BA117"})

    assert msg =~ "about-you"
  end

  test "pinned names are protected from keep and forget", %{ctx: ctx} do
    {:ok, _} = call(ctx, %{"action" => "pin", "name" => "about-you", "content" => "A trip."})

    assert {:error, {:invalid_argument, msg}} =
             call(ctx, %{"action" => "keep", "name" => "about-you", "content" => "overwrite"})

    assert msg =~ "pin"

    assert {:error, {:invalid_argument, msg}} =
             call(ctx, %{"action" => "forget", "name" => "about-you"})

    assert msg =~ "pin"

    assert {:ok, %{content: "A trip."}} = call(ctx, %{"action" => "read", "name" => "about-you"})
  end

  test "a note carries who kept it and when, and the body is only the body", %{ctx: ctx} do
    {:ok, _} = call(ctx, %{"action" => "keep", "name" => "decided", "content" => "Lisbon\n"})

    assert {:ok, note} = call(ctx, %{"action" => "read", "name" => "decided"})
    assert note.content == "Lisbon"
    assert note.kept_by == ctx.user_id
    assert {:ok, _, 0} = DateTime.from_iso8601(note.kept_at)
    assert is_nil(note.thread)
    assert is_nil(note.execution)
  end

  test "search finds a note by content or name", %{ctx: ctx} do
    {:ok, _} =
      call(ctx, %{"action" => "keep", "name" => "decided", "content" => "We go to Lisbon in May."})

    {:ok, _} =
      call(ctx, %{"action" => "keep", "name" => "porto-hotel", "content" => "Booked, room 4."})

    assert {:ok, %{matches: [%{name: "decided", snippet: "We go to Lisbon in May."}]}} =
             call(ctx, %{"action" => "search", "query" => "lisbon"})

    # A name matches too, and the snippet is then the first line.
    assert {:ok, %{matches: [%{name: "porto-hotel", snippet: "Booked, room 4."}]}} =
             call(ctx, %{"action" => "search", "query" => "PORTO"})
  end

  test "a guest cannot name the root; a chain reaches the tool, interactively" do
    # `Arca.Storage`'s layout gives `notes/` no guest name, so a WASM guest
    # cannot write to it as a path. The tool is what a chain reaches — by
    # proposing, and a person clicking — and the credential gate is the
    # same on both planes.
    refute Map.has_key?(Arca.Storage.guest_scopes(), "notes")
    assert "notes" in Arca.Storage.tenant_roots()

    # A workspace thread's notes are a chain's alone: its turn names the
    # thread.
    for {name, spec} <- Tool.definition().annotations.actions do
      planes = if name == "workspace", do: [:in_chain], else: [:external, :in_chain]
      assert spec.planes == planes, "#{name} is not reachable from a chain"
      assert spec.consent == :interactive, "#{name} is reachable by a standing credential"
    end
  end

  test "a note kept in a chain records every source the chain's turns read, outside or not",
       %{ctx: ctx} do
    auth = granting([{"notes", "keep"}, {"notes", "read"}])
    actor = Context.actor(ctx)
    root = "exec_root_#{System.unique_integer([:positive])}"
    vault = Prima.Source.new(:vault_disclosed)

    # A turn of the chain read a disclosed vault value, and nothing outside.
    {:ok, thread} = Arca.Test.Days.thread(actor)

    {:ok, %{turn: turn}} =
      Arca.TurnStorage.accept_message(actor, thread.id, %{
        message: %{author: actor.user_id, sent_by: "person", content: "@aqua go"},
        turn: %{agent: "aqua", requested_by: actor.user_id, origin: :interactive}
      })

    {1, _} =
      Arca.Repo.update_all(
        turn_row(actor.athanor_id, turn.id),
        set: [root_execution_id: root, sources: Prima.Source.encode([vault])]
      )

    args = %{"action" => "keep", "name" => "region", "content" => "eu-west"}
    lineage = [lineage: %{root_execution_id: root, thread_id: thread.id}]
    assert {:ok, %{kept: "region"}} = in_chain(ctx, args, auth, lineage)

    # Whoever reads it reads the disclosed value's provenance, which a
    # flow must let leave; it is no outside material, so nothing marks it.
    assert {:ok, %{sources: sources} = answer} =
             in_chain(ctx, %{"action" => "read", "name" => "region"}, auth)

    assert sources == Prima.Source.to_json_list([vault])
    assert vault in Tool.answer_sources(actor, answer)
  end

  test "a note kept by a component that runs no turn records the calling execution's ledger",
       %{ctx: ctx} do
    auth = granting([{"notes", "keep"}, {"notes", "read"}])
    actor = Context.actor(ctx)
    vault = Prima.Source.new(:vault_disclosed)

    # The calling execution read a disclosed vault value; no turn runs in
    # its chain.
    caller = caller!(ctx)
    assert :ok = Opus.Ledger.join(actor, caller.parent_execution_id, [vault])

    args = %{"action" => "keep", "name" => "standalone", "content" => "eu-west"}
    assert {:ok, %{kept: "standalone"}} = in_chain(ctx, args, auth, lineage: caller)

    assert {:ok, %{sources: sources}} =
             in_chain(ctx, %{"action" => "read", "name" => "standalone"}, auth)

    assert sources == Prima.Source.to_json_list([vault])
  end

  test "an approved call keeps a note from inside the chain, and only an OIDC session's chain may",
       %{ctx: ctx, mine: mine} do
    auth = granting([{"notes", "keep"}, {"notes", "read"}])

    # What the model wrote as provenance — ignored in a chain: the host
    # stamps the card's own execution and thread as lineage, and
    # those are the only provenance the tool records there. The guest's
    # own lineage keys are dropped before the stamp.
    args = %{
      "action" => "keep",
      "name" => "decided",
      "content" => "Lisbon",
      "thread" => "forged",
      "execution" => "forged",
      "thread_id" => "forged",
      "root_execution_id" => "forged"
    }

    lineage = [lineage: %{root_execution_id: "exec_1", thread_id: "thread_1"}]

    # The person's own session, now guest-planed by the approved run: the
    # plane is not asked again, the surface is.
    assert {:ok, %{kept: "decided", athanor_id: id}} = in_chain(ctx, args, auth, lineage)
    assert id == mine.id

    assert {:ok, %{thread: "thread_1", execution: "exec_1", kept_by: kept_by}} =
             in_chain(ctx, %{"action" => "read", "name" => "decided"}, auth)

    assert kept_by == ctx.user_id

    # With no thread or root in the host's lineage the forged values are
    # still not recorded: the execution kept is the calling one.
    assert {:ok, _} = in_chain(ctx, %{args | "name" => "bare"}, auth)

    assert {:ok, %{thread: nil, execution: execution}} =
             in_chain(ctx, %{"action" => "read", "name" => "bare"}, auth)

    assert String.starts_with?(execution, "exec_")

    # The same formula started by a key or a schedule is refused inside the
    # chain exactly as it is at the door — the click was a session's.
    for method <- [:api_key, :scheduled] do
      assert {:error,
              %Prima.Refusal{
                stage: :admission,
                reason: {:consent_class_required, {:surface_not_permitted, ^method}}
              }} =
               in_chain(%{ctx | auth_method: method}, args, auth)
    end

    # And the door still refuses the guest plane outright — before consent
    # is even consulted.
    assert {:error, %Prima.Refusal{stage: :admission, reason: {:guest_plane_call, "notes"}}} =
             Sanctum.Gate.call_external("notes", Context.enter_guest(ctx), args)

    # A chain whose authority predates the notes actions is denied before
    # the tool is reached — legibly, so re-consent is the obvious answer.
    assert {:error,
            %Prima.Refusal{
              stage: :admission,
              class: :forbidden,
              reason: {:invoke_denied, :tool_not_granted},
              message: "Denied by chain authority: " <> _
            }} = in_chain(ctx, args, granting([{"notes", "read"}]))
  end

  test "list and search answer pages", %{ctx: ctx} do
    for prefix <- ~w(e m),
        n <- 1..3,
        do:
          {:ok, _} =
            call(ctx, %{"action" => "keep", "name" => "#{prefix}#{n}", "content" => "lisbon #{n}"})

    # Names sorted; a page of two, then the next page from its cursor (the
    # last name shown), and so on — no overlap, nothing skipped.
    {:ok, %{notes: page1, more: true, next: "e2" = cursor1}} =
      call(ctx, %{"action" => "list", "limit" => 2})

    assert Enum.map(page1, & &1.name) == ["e1", "e2"]

    {:ok, %{notes: page2, more: true, next: "m1" = cursor2}} =
      call(ctx, %{"action" => "list", "limit" => 2, "after" => cursor1})

    assert Enum.map(page2, & &1.name) == ["e3", "m1"]

    {:ok, %{notes: page3, more: false, next: nil}} =
      call(ctx, %{"action" => "list", "limit" => 2, "after" => cursor2})

    assert Enum.map(page3, & &1.name) == ["m2", "m3"]

    # A search pages the same way, and reads no note past its page.
    {:ok, %{matches: hits, more: true, next: cursor}} =
      call(ctx, %{"action" => "search", "query" => "lisbon", "limit" => 4})

    assert length(hits) == 4

    {:ok, %{matches: rest, more: false}} =
      call(ctx, %{"action" => "search", "query" => "lisbon", "after" => cursor})

    assert Enum.map(rest, & &1.name) == ["m2", "m3"]

    # A cursor is a name a page answered; an empty one is refused.
    assert {:error, {:invalid_argument, msg}} = call(ctx, %{"action" => "list", "after" => ""})

    assert msg =~ "cursor"
  end

  test "a pinned page is the athanor's own", %{ctx: ctx, other: other} do
    assert {:ok, %{pinned: "about-you"}} =
             call(ctx, %{
               "action" => "pin",
               "name" => "about-you",
               "content" => "Prefers mornings."
             })

    assert {:ok, %{name: "about-you", content: "Prefers mornings."}} = Aqua.Notes.pinned(ctx)
    assert :none = Aqua.Notes.pinned(other)
  end

  test "a person's save during a turn stands: the turn's pin over the page it read, or over none, " <>
         "is refused and writes nothing, and one over the page read again writes it",
       %{ctx: ctx} do
    {:ok, _} = Aqua.Notes.pin(ctx, "about-you", "Likes ramen.")

    # The turn's prompt shows the page with the revision it stands at.
    composed = Aqua.Prompt.compose(ctx, agent: %{"prompt" => "", "tool_policy" => %{}})
    [_, read] = Regex.run(~r/### Pinned: about-you \(revision (\d+)\)/, composed.text)
    read = String.to_integer(read)

    # The person saves the page on the Aqua page while the turn works.
    assert {:ok, %{pinned: "about-you"}} =
             call(ctx, %{
               "action" => "pin",
               "name" => "about-you",
               "content" => "Likes ramen; vegetarian since May.",
               "revision" => read
             })

    {:ok, daily} = Arca.Test.Days.thread(Context.actor(ctx))
    turn = turn_in!(ctx, daily, [])

    pin = fn args ->
      call(
        Context.enter_guest(ctx),
        Map.merge(
          %{
            "action" => "pin",
            "name" => "about-you",
            "content" => "Likes ramen.\nPrefers mornings.",
            "thread_id" => daily.id,
            "root_execution_id" => turn.root_execution_id
          },
          args
        )
      )
    end

    # A pin that names no revision, and one over the revision the turn read.
    assert {:error, {:invalid_argument, unread}} = pin.(%{})
    assert unread =~ "revision"
    assert {:error, {:conflict, moved}} = pin.(%{"revision" => read})
    assert moved =~ "Read it again with notes.read"

    assert {:ok, %{content: "Likes ramen; vegetarian since May.", kept_by: by, revision: now}} =
             Aqua.Notes.read(ctx, "about-you")

    assert by == ctx.user_id and now == read + 1

    # Read again, the turn writes over what the person wrote.
    assert {:ok, %{pinned: "about-you"}} =
             pin.(%{"revision" => now, "content" => "Vegetarian since May.\nPrefers mornings."})

    assert {:ok, %{content: "Vegetarian since May.\nPrefers mornings.", kept_by: "aqua"}} =
             Aqua.Notes.read(ctx, "about-you")
  end

  # A running turn with its root, as the loop starts one.
  defp running!(ctx, thread) do
    {:ok, %{turn: turn}} =
      Aqua.Tape.accept(ctx, thread.id, %{
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
      Aqua.Tape.start_turn(ctx, turn, %{
        root_execution_id: execution.id,
        attempt: attempt.attempt,
        profile_id: "prof_x",
        consent_id: "consent_x",
        recovery_limit: Aqua.Runner.RecoveryPolicy.max_attempts()
      })

    turn
  end

  describe "a turn's page under its fence" do
    setup do
      installed = Prima.Caps.impl!()
      on_exit(fn -> Prima.Caps.install!(installed) end)
      Prima.Caps.install!(Aqua.Providers.NotesTest.Staging)
      :ok
    end

    test "a pin admitted before its turn loses the fence publishes nothing", %{ctx: ctx} do
      {:ok, daily} = Arca.Test.Days.thread(Context.actor(ctx))
      turn = running!(ctx, daily)
      parent = self()

      # The turn is superseded while the page's bytes are staged, after the
      # gate admitted the call and before the publication commits.
      once = :atomics.new(1, [])

      Prima.Test.Env.put_persistent_term({Aqua.Providers.NotesTest.Staging, :once}, fn ->
        if :atomics.compare_exchange(once, 1, 0, 1) == :ok do
          assert {:ok, _} = Aqua.Tape.supersede(ctx, turn)
          send(parent, :superseded_before_publication)
        end
      end)

      result =
        in_chain(
          ctx,
          %{
            "action" => "pin",
            "name" => "about-you",
            "content" => "stale owner's page",
            "revision" => 0
          },
          granting([{"notes", "pin"}]),
          lineage: %{
            root_execution_id: turn.root_execution_id,
            parent_execution_id: turn.root_execution_id,
            attempt: turn.attempt,
            thread_id: daily.id
          }
        )

      assert_received :superseded_before_publication
      assert {:ok, fresh} = Aqua.Tape.turn(ctx, turn.id)
      assert fresh.fence > turn.fence
      assert {:error, _refused} = result
      assert :none = Aqua.Notes.pinned(ctx)
    end

    test "a turn that lost its fence clears no page and writes no workspace notes", %{ctx: ctx} do
      {:ok, _} = Aqua.Notes.pin(ctx, "about-you", "Likes ramen.")
      {:ok, %{revision: read}} = Aqua.Notes.read(ctx, "about-you")
      {:ok, daily} = Arca.Test.Days.thread(Context.actor(ctx))
      turn = running!(ctx, daily)
      assert {:ok, _} = Aqua.Tape.supersede(ctx, turn)

      assert {:error, {:declined, :superseded}} =
               Aqua.Notes.pin(ctx, "about-you", "", [],
                 revision: read,
                 verify: fn -> Aqua.Tape.hold(ctx, turn) end
               )

      assert {:ok, %{content: "Likes ramen."}} = Aqua.Notes.pinned(ctx)

      # A workspace thread's notes are written in the transaction that
      # takes the turn's row on its fence (`Arca.TurnStorage.write_notes/4`).
      work = workspace!(ctx, "Fenced notes")
      held = running!(ctx, work)
      assert {:ok, _} = Aqua.Tape.supersede(ctx, held)

      assert {:error, {:conflict, _}} = Aqua.Notes.workspace(ctx, held, "late notes")
      assert notes_of(ctx, work) == nil
    end
  end

  test "the shipped soul's manifest grants the notes actions its policy names" do
    # The chain authority is exact `tool.action` membership in the consent
    # blob, minted from the manifest's caps against the loaded providers —
    # a name no provider serves drops silently, so this pins that every
    # notes action the soul may propose survives the expansion.
    manifest = shipped_soul_manifest()

    caps = Prima.Manifest.Caps.from_manifest(manifest, &Arca.Storage.valid_guest_path?/1)
    granted = Sanctum.Consent.ShapeDerivation.expand_tools(caps.tools)

    for action <- ~w(keep pin forget list read search workspace) do
      assert "notes.#{action}" in granted, "notes.#{action} is not in the shipped caps"
    end

    for action <- ~w(skill_list skill_get skill_create skill_update) do
      assert "aqua.#{action}" in granted, "aqua.#{action} is not in the shipped caps"
    end

    refute "aqua.skill_delete" in granted
  end

  # The shipped soul's manifest, derived from its own file.
  defp shipped_soul_manifest do
    seed = Path.expand("../../../../../seed/aqua", __DIR__)
    {:ok, soul} = Compendium.AquaAgent.parse("aqua", File.read!(Path.join(seed, "aqua.md")))
    Compendium.AgentSource.manifest(soul)
  end

  test "the annotations say what a person may pre-answer" do
    actions = Tool.definition().annotations.actions

    # A filed note follows the thread it was kept from, never the agent;
    # an endorsement is one click at a time; forget is destructive and
    # already takes no standing allow. The about-you page and a workspace
    # thread's notes are Aqua's to keep current: no standing rule of
    # their own, so an authored `auto` runs them with no card, and the
    # workspace notes are a chain's alone.
    assert actions["keep"].standing == :thread
    assert actions["endorse"].standing == false
    assert actions["forget"].kind == :destructive
    assert %{kind: :write, planes: [:in_chain], consent: :interactive} = actions["workspace"]

    for name <- ~w(pin workspace forget list read search) do
      refute Map.has_key?(actions[name], :standing), "#{name} declares a standing rule"
    end

    for action <- ~w(pin workspace), do: assert(Aqua.Kinds.auto_permitted?("notes", action))
    for action <- ~w(keep endorse forget), do: refute(Aqua.Kinds.auto_permitted?("notes", action))
  end

  describe "a workspace thread's notes" do
    # A turn of `thread` running on its own root, having read `sources`.
    defp turn_in!(ctx, thread, sources) do
      actor = Context.actor(ctx)

      {:ok, %{turn: turn}} =
        Arca.TurnStorage.accept_message(actor, thread.id, %{
          message: %{author: actor.user_id, sent_by: "person", content: "@aqua go"},
          turn: %{agent: "aqua", requested_by: actor.user_id, origin: :interactive}
        })

      root = "exec_ws_#{System.unique_integer([:positive])}"

      {1, _} =
        Arca.Repo.update_all(turn_row(actor.athanor_id, turn.id),
          set: [root_execution_id: root, sources: Prima.Source.encode(sources)]
        )

      %{turn | root_execution_id: root}
    end

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

    defp write(ctx, turn, args) do
      call(
        Context.enter_guest(ctx),
        Map.merge(
          %{
            "action" => "workspace",
            "thread_id" => turn.thread_id,
            "root_execution_id" => turn.root_execution_id
          },
          args
        )
      )
    end

    defp notes_of(ctx, thread) do
      {:ok, row} = Arca.ThreadStorage.get(Context.actor(ctx), thread.id)
      Aqua.Notes.thread_notes(row)
    end

    test "a turn writes its own workspace thread's notes, named by the lineage, with what it read",
         %{ctx: ctx} do
      host = Prima.Source.outside("news.example")
      work = workspace!(ctx, "Fares")
      elsewhere = workspace!(ctx, "Elsewhere")
      turn = turn_in!(ctx, work, [host, Prima.Source.thread(elsewhere.id)])

      # An argument naming another thread names nothing.
      assert {:ok, %{workspace_notes: id}} =
               write(ctx, turn, %{"content" => "Fares rise Monday.", "thread" => elsewhere.id})

      assert id == work.id
      assert notes_of(ctx, elsewhere) == nil

      assert %{content: "Fares rise Monday.", sources: [^host], kept_by: by, thread: thread} =
               notes_of(ctx, work)

      assert by == Prima.Author.agent() and thread == work.id

      # Whole each time; empty content clears them.
      assert {:ok, _} = write(ctx, turn, %{"content" => "Booked."})
      assert %{content: "Booked."} = notes_of(ctx, work)
      assert {:ok, %{cleared_workspace_notes: _}} = write(ctx, turn, %{"content" => "  "})
      assert notes_of(ctx, work) == nil

      too_long = String.duplicate("x", Aqua.Notes.pin_max_bytes() + 1)
      assert {:error, {:invalid_argument, _}} = write(ctx, turn, %{"content" => too_long})
      assert notes_of(ctx, work) == nil
    end

    test "a daily thread keeps no such notes, a stale holder writes none, and a chain with no turn none",
         %{ctx: ctx} do
      {:ok, daily} = Arca.Test.Days.thread(Context.actor(ctx))
      turn = turn_in!(ctx, daily, [])
      assert {:error, {:invalid_argument, _}} = write(ctx, turn, %{"content" => "x"})

      work = workspace!(ctx, "Fenced")
      held = turn_in!(ctx, work, [])

      stale = %{
        "content" => "late",
        "parent_execution_id" => held.root_execution_id,
        "attempt" => "att_replaced"
      }

      assert {:error, {:conflict, _}} = write(ctx, held, stale)

      assert {:error, :not_in_a_turn} =
               write(ctx, %{held | root_execution_id: "exec_forged"}, %{"content" => "x"})

      assert {:error, :not_in_a_turn} = call(ctx, %{"action" => "workspace", "content" => "x"})
      assert notes_of(ctx, work) == nil
    end

    test "deleting the workspace thread deletes its notes with it", %{ctx: ctx} do
      work = workspace!(ctx, "Short-lived")
      turn = turn_in!(ctx, work, [])
      assert {:ok, _} = write(ctx, turn, %{"content" => "Half done."})
      assert %{content: "Half done."} = notes_of(ctx, work)
      assert {:ok, _} = Arca.ThreadStorage.delete(Context.actor(ctx), work.id)

      assert {:error, :not_found} = Arca.ThreadStorage.get(Context.actor(ctx), work.id)
      assert Enum.all?(Arca.ThreadStorage.list(Context.actor(ctx)), &is_nil(&1.notes))
    end
  end

  test "a standing credential cannot keep, read or forget notes", %{ctx: ctx} do
    # The host-only root stops the guest; this stops the credential. A key
    # must not reach the athanor's notes through anything.
    star = %{ctx | auth_method: :api_key, permissions: MapSet.new([:*])}

    assert {:error,
            %Prima.Refusal{
              stage: :admission,
              reason: {:consent_class_required, {:surface_not_permitted, :api_key}}
            }} =
             Sanctum.Gate.call_external("notes", star, %{
               "action" => "keep",
               "name" => "sneak",
               "content" => "x"
             })

    assert {:error,
            %Prima.Refusal{
              stage: :admission,
              reason: {:consent_class_required, {:surface_not_permitted, :api_key}}
            }} =
             Sanctum.Gate.call_external("notes", star, %{"action" => "list"})

    # Discovery agrees with dispatch: the key is not shown the tool.
    shown =
      Sanctum.Visibility.filter_for_context(
        Sanctum.Catalog.list_tools(),
        star
      )

    refute Enum.any?(shown, &(&1["name"] == "notes"))
  end

  test "a note name is held to a grammar", %{ctx: ctx} do
    assert {:error, {:invalid_argument, _}} =
             call(ctx, %{"action" => "keep", "name" => "../escape", "content" => "x"})

    assert {:error, {:invalid_argument, _}} = call(ctx, %{"action" => "read", "name" => "a/b"})
  end
end
