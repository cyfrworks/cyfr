# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

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

    for {name, spec} <- Tool.definition().annotations.actions do
      assert spec.planes == [:external, :in_chain], "#{name} is not reachable from a chain"
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
    {:ok, thread} = Arca.ThreadStorage.create(actor)

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

  test "the shipped soul's manifest grants the notes actions its policy names" do
    # The chain authority is exact `tool.action` membership in the consent
    # blob, minted from the manifest's caps against the loaded providers —
    # a name no provider serves drops silently, so this pins that every
    # notes action the soul may propose survives the expansion.
    manifest = shipped_soul_manifest()

    caps = Prima.Manifest.Caps.from_manifest(manifest, &Arca.Storage.valid_guest_path?/1)
    granted = Sanctum.Consent.ShapeDerivation.expand_tools(caps.tools)

    for action <- ~w(keep pin forget list read search) do
      assert "notes.#{action}" in granted, "notes.#{action} is not in the shipped caps"
    end

    for action <- ~w(skill_list skill_get skill_create skill_update) do
      assert "aqua.#{action}" in granted, "aqua.#{action} is not in the shipped caps"
    end

    refute "aqua.skill_delete" in granted
  end

  # The shipped soul's manifest, derived from its own file over the roster
  # it ships with.
  defp shipped_soul_manifest do
    seed = Path.expand("../../../../../seed/aqua", __DIR__)
    roles = Path.join(seed, Compendium.AquaPath.roles_dirname())

    names =
      roles
      |> Path.join("*.md")
      |> Prima.Test.SourceTree.files!()
      |> Enum.map(&Path.basename(&1, ".md"))

    {:ok, soul} = Compendium.AquaAgent.parse("aqua", File.read!(Path.join(seed, "aqua.md")))
    Compendium.AgentSource.manifest(soul, MapSet.new(["aqua" | names]))
  end

  test "the annotations say what a person may pre-answer" do
    actions = Tool.definition().annotations.actions

    # A filed note follows the thread it was kept from, never the agent;
    # a pinned page is changed one click at a time; forget is destructive
    # and already takes no standing allow.
    assert actions["keep"].standing == :thread
    assert actions["pin"].standing == false
    assert actions["forget"].kind == :destructive

    for name <- ~w(forget list read search) do
      refute Map.has_key?(actions[name], :standing), "#{name} declares a standing rule"
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
