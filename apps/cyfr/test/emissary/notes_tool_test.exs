# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.NotesToolTest do
  # Notes are not the transcript. These pin the difference, and the rule
  # that makes "whose notes" a fact about where you are rather than an
  # argument: a note lands in the estate in focus.
  use ExUnit.Case, async: false

  alias Emissary.MCP.NotesTool, as: Tool
  alias Cyfr.Ops.Catalog
  alias Sanctum.Authority
  alias Sanctum.Authority.Blob
  alias Sanctum.Context

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "notes_#{:rand.uniform(1_000_000)}")
    original = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original,
        do: Application.put_env(:cyfr, :base_path, original),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    n = System.unique_integer([:positive])

    {:ok, u} =
      Sanctum.Tenancy.Users.upsert_from_provider(%{id: "local|idp|note-#{n}", provider: "local"})

    user = u.id

    {:ok, mine} =
      Sanctum.Tenancy.Athanors.create(%{
        kind: "person",
        name: "Me",
        slug: "me#{n}",
        owner_user_id: user,
        created_by: user
      })

    {:ok, _} = Sanctum.Tenancy.Users.set_personal_athanor(u, mine.id)
    # The owner's seat in their own athanor — production mints it in
    # `ensure_personal_athanor/1`, and `Context.focus/2` (the "mine" read)
    # checks it.
    {:ok, _} = Sanctum.Tenancy.Members.create(%{user_id: user, athanor_id: mine.id})
    {:ok, estate} = Sanctum.Tenancy.Athanors.create_group(user, "Trip #{n}")

    ctx = %{Sanctum.TestContext.local() | user_id: user, athanor_id: estate.id}
    {:ok, home} = Sanctum.Context.focus(ctx, mine.id)
    {:ok, ctx: ctx, home: home, mine: mine, estate: estate}
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
        blob
      )

    auth
  end

  defp in_chain(ctx, args, auth, opts \\ []),
    do: Catalog.call_in_chain("notes", Context.enter_guest(ctx), args, auth, opts)

  test "a note lands in the estate you are working in, and nowhere else", %{
    ctx: ctx,
    home: home,
    mine: mine,
    estate: estate
  } do
    {:ok, kept} = call(ctx, %{"action" => "keep", "name" => "decided", "content" => "Lisbon"})
    assert kept.athanor_id == estate.id

    {:ok, at_home} = call(home, %{"action" => "keep", "name" => "flight", "content" => "BA117"})
    assert at_home.athanor_id == mine.id

    # Where you are is what you see by default.
    assert {:ok, %{notes: [%{name: "decided", athanor_id: id}]}} =
             call(ctx, %{"action" => "list"})

    assert id == estate.id

    assert {:ok, %{notes: [%{name: "flight"}]}} = call(home, %{"action" => "list"})
    refute estate.id == mine.id
  end

  test "keeping under a name that exists replaces it, and says so", %{ctx: ctx} do
    assert {:ok, %{kept: "decided", replaced: false}} =
             call(ctx, %{"action" => "keep", "name" => "decided", "content" => "Lisbon"})

    assert {:ok, %{kept: "decided", replaced: true}} =
             call(ctx, %{"action" => "keep", "name" => "decided", "content" => "Porto"})

    assert {:ok, %{content: "Porto"}} = call(ctx, %{"action" => "read", "name" => "decided"})
    assert {:ok, %{notes: [_]}} = call(ctx, %{"action" => "list"})
  end

  test "a write names no estate", %{ctx: ctx} do
    for args <- [
          %{"action" => "keep", "name" => "x", "content" => "y", "scope" => "mine"},
          %{"action" => "pin", "name" => "about-us", "content" => "y", "scope" => "estate"},
          %{"action" => "forget", "name" => "x", "scope" => "mine"}
        ] do
      assert {:error, {:invalid_argument, msg}} = call(ctx, args)
      assert msg =~ "scope"
    end
  end

  test "your own notes are read from anywhere you are, and only by you", %{
    ctx: ctx,
    home: home,
    mine: mine
  } do
    {:ok, _} = call(home, %{"action" => "keep", "name" => "flight", "content" => "BA117"})

    # From the trip, "mine" reaches home — through `Context.focus/2`, so
    # membership is checked on the way.
    assert {:ok, %{notes: [%{name: "flight", athanor_id: id}]}} =
             call(ctx, %{"action" => "list", "scope" => "mine"})

    assert id == mine.id

    assert {:ok, %{content: "BA117", athanor_id: ^id}} =
             call(ctx, %{"action" => "read", "name" => "flight", "scope" => "mine"})

    # The estate's own pile does not hold it.
    assert {:ok, %{notes: []}} = call(ctx, %{"action" => "list"})

    assert {:error, {:not_found, "note", "flight"}} =
             call(ctx, %{"action" => "read", "name" => "flight"})
  end

  test "a group's notes are readable by its members", %{ctx: ctx} do
    {:ok, _} = call(ctx, %{"action" => "keep", "name" => "decided", "content" => "Lisbon"})

    other = %{ctx | user_id: "local|idp|somebody-else"}

    {:ok, _} =
      Sanctum.Tenancy.Members.create(%{user_id: other.user_id, athanor_id: ctx.athanor_id})

    # No private notes in a shared estate — the invariant is a fact here,
    # not a sentence in a docstring.
    assert {:ok, %{notes: [%{name: "decided"}]}} = call(other, %{"action" => "list"})
    assert {:ok, %{content: "Lisbon"}} = call(other, %{"action" => "read", "name" => "decided"})
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
    {:ok, %{pinned: "about-us"}} =
      call(ctx, %{"action" => "pin", "name" => "about-us", "content" => "We are planning a trip."})

    assert {:ok, %{content: "We are planning a trip."}} =
             call(ctx, %{"action" => "read", "name" => "about-us"})

    # Over the cap is refused, never truncated — a page read into every
    # turn is trimmed by a person, not by the tool.
    long = String.duplicate("x", Aqua.Notes.pin_max_bytes() + 1)

    assert {:error, {:invalid_argument, msg}} =
             call(ctx, %{"action" => "pin", "name" => "about-us", "content" => long})

    assert msg =~ "bytes"

    assert {:ok, %{content: "We are planning a trip."}} =
             call(ctx, %{"action" => "read", "name" => "about-us"})

    {:ok, %{cleared: "about-us"}} =
      call(ctx, %{"action" => "pin", "name" => "about-us", "content" => "  "})

    assert {:error, {:not_found, "note", "about-us"}} =
             call(ctx, %{"action" => "read", "name" => "about-us"})

    # Only the two pinned names take a pin.
    assert {:error, {:invalid_argument, msg}} =
             call(ctx, %{"action" => "pin", "name" => "flight", "content" => "BA117"})

    assert msg =~ "about-you, about-us"
  end

  test "pinned names are protected from keep and forget", %{ctx: ctx} do
    {:ok, _} = call(ctx, %{"action" => "pin", "name" => "about-us", "content" => "A trip."})

    assert {:error, {:invalid_argument, msg}} =
             call(ctx, %{"action" => "keep", "name" => "about-us", "content" => "overwrite"})

    assert msg =~ "pin"

    assert {:error, {:invalid_argument, msg}} =
             call(ctx, %{"action" => "forget", "name" => "about-us"})

    assert msg =~ "pin"

    assert {:ok, %{content: "A trip."}} = call(ctx, %{"action" => "read", "name" => "about-us"})
  end

  test "a note carries who kept it and when, and the body is only the body", %{ctx: ctx} do
    {:ok, _} = call(ctx, %{"action" => "keep", "name" => "decided", "content" => "Lisbon\n"})

    assert {:ok, note} = call(ctx, %{"action" => "read", "name" => "decided"})
    assert note.content == "Lisbon"
    assert note.kept_by == ctx.user_id
    assert {:ok, _, 0} = DateTime.from_iso8601(note.kept_at)
    assert is_nil(note.conversation)
    assert is_nil(note.execution)
  end

  test "search finds a note by content or name, across every estate you belong to", %{
    ctx: ctx,
    home: home,
    mine: mine,
    estate: estate
  } do
    {:ok, _} =
      call(ctx, %{"action" => "keep", "name" => "decided", "content" => "We go to Lisbon in May."})

    {:ok, _} =
      call(home, %{"action" => "keep", "name" => "porto-hotel", "content" => "Booked, room 4."})

    assert {:ok, %{matches: [%{name: "decided", snippet: "We go to Lisbon in May."}]}} =
             call(ctx, %{"action" => "search", "query" => "lisbon"})

    # A name matches too, and the snippet is then the first line.
    assert {:ok, %{matches: [%{name: "porto-hotel", athanor_id: id}]}} =
             call(ctx, %{"action" => "search", "query" => "PORTO", "scope" => "everywhere"})

    assert id == mine.id

    {:ok, %{matches: everywhere}} =
      call(ctx, %{"action" => "search", "query" => "o", "scope" => "everywhere"})

    assert Enum.map(everywhere, & &1.athanor_id) |> Enum.sort() == Enum.sort([estate.id, mine.id])

    # Read is not a place to guess which estate held a hit.
    assert {:error, {:invalid_argument, msg}} =
             call(ctx, %{"action" => "read", "name" => "decided", "scope" => "everywhere"})

    assert msg =~ "search"
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

  test "an approved call keeps a note from inside the chain, and only an OIDC session's chain may",
       %{ctx: ctx, estate: estate} do
    auth = granting([{"notes", "keep"}, {"notes", "read"}])

    # What the model wrote as provenance — ignored in a chain: the host
    # stamps the card's own execution and conversation as lineage, and
    # those are the only provenance the tool records there.
    args = %{
      "action" => "keep",
      "name" => "decided",
      "content" => "Lisbon",
      "conversation" => "forged",
      "execution" => "forged"
    }

    lineage = [lineage: %{root_execution_id: "exec_1", conversation_id: "conv_1"}]

    # The person's own session, now guest-planed by the approved run: the
    # plane is not asked again, the surface is.
    assert {:ok, %{kept: "decided", athanor_id: id}} = in_chain(ctx, args, auth, lineage)
    assert id == estate.id

    assert {:ok, %{conversation: "conv_1", execution: "exec_1", kept_by: kept_by}} =
             in_chain(ctx, %{"action" => "read", "name" => "decided"}, auth)

    assert kept_by == ctx.user_id

    # Without host lineage the forged values are still not recorded.
    assert {:ok, _} = in_chain(ctx, %{args | "name" => "bare"}, auth)

    assert {:ok, %{conversation: nil, execution: nil}} =
             in_chain(ctx, %{"action" => "read", "name" => "bare"}, auth)

    # The same formula started by a key or a schedule is refused inside the
    # chain exactly as it is at the door — the click was a session's.
    for method <- [:api_key, :scheduled] do
      assert {:error, {:consent_class_required, {:surface_not_permitted, ^method}}} =
               in_chain(%{ctx | auth_method: method}, args, auth)
    end

    # And the door still refuses the guest plane outright — before consent
    # is even consulted.
    assert {:error, {:guest_plane_call, "notes"}} =
             Catalog.call_external("notes", Context.enter_guest(ctx), args)

    # A chain whose authority predates the notes actions is denied before
    # the tool is reached — legibly, so re-consent is the obvious answer.
    assert {:error, "Denied by chain authority: " <> _} =
             in_chain(ctx, args, granting([{"notes", "read"}]))
  end

  test "list and search answer pages, one budget across every estate", %{ctx: ctx, home: home} do
    for n <- 1..3,
        do:
          {:ok, _} =
            call(ctx, %{"action" => "keep", "name" => "e#{n}", "content" => "lisbon #{n}"})

    for n <- 1..3,
        do:
          {:ok, _} =
            call(home, %{"action" => "keep", "name" => "m#{n}", "content" => "lisbon #{n}"})

    # The focus first, then the person's other estates, names sorted; a
    # page of two, then the next page from its cursor, and so on — no
    # overlap, nothing skipped.
    {:ok, %{notes: page1, more: true, next: cursor1}} =
      call(home, %{"action" => "list", "scope" => "everywhere", "limit" => 2})

    assert Enum.map(page1, & &1.name) == ["m1", "m2"]

    {:ok, %{notes: page2, more: true, next: cursor2}} =
      call(home, %{"action" => "list", "scope" => "everywhere", "limit" => 2, "after" => cursor1})

    assert Enum.map(page2, & &1.name) == ["m3", "e1"]

    {:ok, %{notes: page3, more: false, next: nil}} =
      call(home, %{"action" => "list", "scope" => "everywhere", "limit" => 2, "after" => cursor2})

    assert Enum.map(page3, & &1.name) == ["e2", "e3"]

    # A search pages the same way, and reads no note past its page.
    {:ok, %{matches: hits, more: true, next: cursor}} =
      call(home, %{
        "action" => "search",
        "query" => "lisbon",
        "scope" => "everywhere",
        "limit" => 4
      })

    assert length(hits) == 4

    {:ok, %{matches: rest, more: false}} =
      call(home, %{
        "action" => "search",
        "query" => "lisbon",
        "scope" => "everywhere",
        "after" => cursor
      })

    assert Enum.map(rest, & &1.name) == ["e2", "e3"]

    assert {:error, {:invalid_argument, msg}} =
             call(home, %{"action" => "list", "after" => "garbage"})

    assert msg =~ "cursor"
  end

  test "a search's estate is a locator a read may follow — under the reader's own seat", %{
    ctx: ctx,
    home: home,
    estate: estate
  } do
    {:ok, _} =
      call(ctx, %{"action" => "keep", "name" => "porto-hotel", "content" => "the Yeatman"})

    {:ok, %{matches: [%{name: "porto-hotel", athanor_id: id}]}} =
      call(home, %{"action" => "search", "query" => "yeatman", "scope" => "everywhere"})

    assert id == estate.id

    assert {:ok, %{content: "the Yeatman", athanor_id: ^id}} =
             call(home, %{"action" => "read", "name" => "porto-hotel", "athanor_id" => id})

    # An estate the reader holds no seat in reads as no such note — the
    # locator is not a way to learn which estates exist.
    assert {:error, {:not_found, "estate", "ath_nobody"}} =
             call(home, %{
               "action" => "read",
               "name" => "porto-hotel",
               "athanor_id" => "ath_nobody"
             })
  end

  test "a room's assistant reads only the room's notes", %{ctx: ctx, home: home} do
    auth = granting([{"notes", "list"}, {"notes", "search"}])
    {:ok, _} = call(home, %{"action" => "keep", "name" => "flight", "content" => "BA117"})

    # From the trip, a chain cannot open the person's own pile — however
    # the model asks for it.
    for args <- [
          %{"action" => "list", "scope" => "mine"},
          %{"action" => "search", "query" => "BA117", "scope" => "everywhere"}
        ] do
      assert {:error, {:invalid_argument, msg}} = in_chain(ctx, args, auth)
      assert msg =~ "room's assistant"
    end

    # The person's own turn, in their own athanor, may look everywhere.
    assert {:ok, %{matches: [%{name: "flight"}]}} =
             in_chain(
               home,
               %{"action" => "search", "query" => "BA117", "scope" => "everywhere"},
               auth
             )

    # And the person themselves, at the door, was never bounded.
    assert {:ok, %{notes: [%{name: "flight"}]}} =
             call(ctx, %{"action" => "list", "scope" => "mine"})
  end

  test "an estate has one pinned page", %{ctx: ctx, home: home} do
    assert {:error, {:invalid_argument, msg}} =
             call(ctx, %{"action" => "pin", "name" => "about-you", "content" => "me"})

    assert msg =~ "about-us"

    assert {:error, {:invalid_argument, msg}} =
             call(home, %{"action" => "pin", "name" => "about-us", "content" => "us"})

    assert msg =~ "about-you"

    assert {:ok, %{pinned: "about-you"}} =
             call(home, %{
               "action" => "pin",
               "name" => "about-you",
               "content" => "Prefers mornings."
             })

    assert {:ok, %{name: "about-you", content: "Prefers mornings."}} = Aqua.Notes.pinned(home)
    assert :none = Aqua.Notes.pinned(ctx)
  end

  test "the shipped soul's manifest grants the notes actions its policy names" do
    # The chain authority is exact `tool.action` membership in the consent
    # blob, minted from the manifest's caps against the loaded providers —
    # a name no provider serves drops silently, so this pins that every
    # notes action the soul may propose survives the expansion.
    manifest = shipped_soul_manifest()

    caps = Compendium.Manifest.Caps.from_manifest(manifest)
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
    seed = Path.expand("../../../../seed/aqua", __DIR__)
    roles = Path.join(seed, Compendium.AquaPath.roles_dirname())

    names =
      roles
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".md"))
      |> Enum.map(&Path.basename(&1, ".md"))

    {:ok, soul} = Compendium.AquaAgent.parse("aqua", File.read!(Path.join(seed, "aqua.md")))
    Compendium.AgentSource.manifest(soul, MapSet.new(["aqua" | names]))
  end

  test "the annotations say what a person may pre-answer" do
    actions = Tool.definition().annotations.actions

    # A filed note follows the thread it was kept from, never the agent;
    # a pinned page is changed one click at a time; forget is destructive
    # and already takes no standing allow.
    assert actions["keep"].standing == :conversation
    assert actions["pin"].standing == false
    assert actions["forget"].kind == :destructive

    for name <- ~w(forget list read search) do
      refute Map.has_key?(actions[name], :standing), "#{name} declares a standing rule"
    end
  end

  test "a standing credential cannot keep, read or forget notes", %{ctx: ctx} do
    # The host-only root stops the guest; this stops the credential. A key
    # scoped to an estate must not reach the creator's personal tree
    # through "mine" — or the estate's notes through anything.
    star = %{ctx | auth_method: :api_key, api_key_type: :admin, permissions: MapSet.new([:*])}

    assert {:error, {:consent_class_required, {:surface_not_permitted, :api_key}}} =
             Cyfr.Ops.Catalog.call_external("notes", star, %{
               "action" => "keep",
               "name" => "sneak",
               "content" => "x"
             })

    assert {:error, {:consent_class_required, {:surface_not_permitted, :api_key}}} =
             Cyfr.Ops.Catalog.call_external("notes", star, %{
               "action" => "list",
               "scope" => "mine"
             })

    # Discovery agrees with dispatch: the key is not shown the tool.
    shown =
      Cyfr.Ops.Visibility.filter_for_context(
        Cyfr.Ops.Catalog.list_tools(),
        star
      )

    refute Enum.any?(shown, &(&1["name"] == "notes"))
  end

  test "an archived personal athanor cannot be read into", %{ctx: ctx, mine: mine} do
    # "mine" goes through `Context.focus/2`, so it inherits the archive
    # refusal a raw struct update would have skipped.
    {:ok, _} = Sanctum.Tenancy.Athanors.archive(mine, force: true)

    assert {:error, {:invalid_argument, msg}} =
             call(ctx, %{"action" => "list", "scope" => "mine"})

    assert msg =~ "archived"
  end

  test "a note name is held to a grammar", %{ctx: ctx} do
    assert {:error, {:invalid_argument, _}} =
             call(ctx, %{"action" => "keep", "name" => "../escape", "content" => "x"})

    assert {:error, {:invalid_argument, _}} = call(ctx, %{"action" => "read", "name" => "a/b"})
  end
end
