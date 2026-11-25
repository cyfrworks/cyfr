# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Providers.AquaConsentTest do
  # The `aqua` tool's write door: every write is a person's own act, so a
  # standing credential is refused at the registry's dispatch gate and is
  # not shown the writes in `tools/list`; the reads stay open to every
  # surface, because a turn resolves its soul through them.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Compendium.Providers.Aqua, as: Tool
  alias Sanctum.Visibility

  @writes ~w(create update delete reset skill_create skill_update skill_file skill_delete)
  @reads ~w(list get status skill_list skill_get)

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  test "the annotations say who may write" do
    actions = Tool.definition().annotations.actions

    for action <- @writes do
      assert actions[action].consent == :interactive, "aqua.#{action} is not interactive"
    end

    for action <- @reads do
      refute Map.has_key?(actions[action], :consent), "aqua.#{action} declares a consent class"
    end
  end

  test "a standing credential cannot write the soul, a role or a scroll", %{ctx: ctx} do
    # A `*` admin key holds every permission and is still refused: the
    # consent class admits a surface, never a permission atom.
    star = %{ctx | auth_method: :api_key, permissions: MapSet.new([:*])}

    calls = [
      {"skill_create", %{"name" => "mine:sneak", "description" => "d", "content" => "c"}},
      {"skill_update", %{"name" => "cyfr:capability-acquisition", "content" => "c"}},
      {"skill_file", %{"proposal" => "msg_sneak", "sha256" => Prima.Digest.sha256("c")}},
      {"reset", %{"all" => true}},
      {"update", %{"name" => "aqua", "content" => "x"}},
      {"create", %{"name" => "sneak", "content" => "x"}},
      {"delete", %{"name" => "aqua"}},
      {"reset", %{"name" => "aqua"}},
      {"skill_delete", %{"name" => "cyfr:capability-acquisition"}}
    ]

    for {action, args} <- calls do
      assert {:error,
              %Prima.Refusal{
                stage: :admission,
                reason: {:consent_class_required, {:surface_not_permitted, :api_key}}
              }} =
               Sanctum.Gate.call_external("aqua", star, Map.put(args, "action", action)),
             "aqua.#{action} answered a standing credential"
    end

    # The reads stay open to the key — a turn resolves its soul and its
    # scrolls through them.
    assert {:ok, %{skills: _}} =
             Sanctum.Gate.call_external("aqua", star, %{"action" => "skill_list"})

    # Discovery agrees with dispatch: the key is shown the reads alone.
    [aqua] =
      Sanctum.Catalog.list_tools()
      |> Visibility.filter_for_context(star)
      |> Enum.filter(&(&1["name"] == "aqua"))

    shown = get_in(aqua, ["inputSchema", "properties", "action", "enum"])
    assert Enum.sort(shown) == Enum.sort(@reads)
  end

  # Inside a turn's chain the class keeps its surface half: a turn the
  # person's own session started proposes a scroll, which writes nothing
  # until the person saves it, and one a schedule or a key started is
  # refused before the tool, whatever its member is offered, and proposes
  # nothing.
  test "a turn a schedule or a key started cannot write a scroll from its chain" do
    auth = granting(["aqua.skill_create"])
    # The turn's root, as the person's session admitted it; the surface a
    # call is refused on is the one its context names.
    ctx = Sanctum.TestContext.local(:prism)
    lineage = turn!(ctx)

    create = fn ctx, name ->
      Sanctum.Gate.call_in_chain(
        "aqua",
        Sanctum.Context.enter_guest(ctx),
        %{"action" => "skill_create", "name" => name, "description" => "d", "content" => "c"},
        auth,
        lineage: lineage
      )
    end

    for method <- [:scheduled, :api_key] do
      assert {:error,
              %Prima.Refusal{
                stage: :admission,
                reason: {:consent_class_required, {:surface_not_permitted, ^method}}
              }} = create.(%{ctx | auth_method: method}, "mine:by-#{method}")

      assert {:error, {:not_found, "Scroll", _}} =
               Tool.handle(ctx, %{"action" => "skill_get", "name" => "mine:by-#{method}"})
    end

    assert {:ok, %{proposed: "mine:by-person", against: "none"}} = create.(ctx, "mine:by-person")

    assert {:error, {:not_found, "Scroll", "mine:by-person"}} =
             Tool.handle(ctx, %{"action" => "skill_get", "name" => "mine:by-person"})
  end

  # A scroll a turn writes waits for the person: in a chain the person's
  # session started, a create or an update answers the whole scroll as it
  # would be stored and what it was made against, and writes nothing, so
  # no read sees it; the person's Save sends exactly those back from their
  # own session, and is refused, with nothing written, once the scroll
  # changed since the proposal.
  test "a chain proposes a scroll and writes nothing; Save writes exactly what it showed" do
    auth = granting(["aqua.skill_create", "aqua.skill_update"])
    ctx = Sanctum.TestContext.local(:prism)
    lineage = turn!(ctx)

    in_chain = fn args ->
      Sanctum.Gate.call_in_chain("aqua", Sanctum.Context.enter_guest(ctx), args, auth,
        lineage: lineage
      )
    end

    save = fn proposal, action ->
      Sanctum.Gate.call_external("aqua", ctx, %{
        "action" => action,
        "name" => proposal.proposed,
        "description" => proposal.description,
        "content" => proposal.content,
        "against" => proposal.against
      })
    end

    create = %{
      "action" => "skill_create",
      "name" => "mine:kept-way",
      "description" => "  How the fern is kept  ",
      "content" => "\nWater it weekly.\n"
    }

    assert {:ok, proposal} = in_chain.(create)

    assert Map.delete(proposal, :note) == %{
             proposed: "mine:kept-way",
             description: "How the fern is kept",
             content: "Water it weekly.",
             against: "none"
           }

    # Unsaved, it is nothing any read sees.
    assert {:error, {:not_found, "Scroll", "mine:kept-way"}} =
             Tool.handle(ctx, %{"action" => "skill_get", "name" => "mine:kept-way"})

    {:ok, index} = Compendium.Packs.index(ctx)
    refute "mine:kept-way" in Enum.map(index, & &1.name)

    assert {:error,
            {:invalid_argument, "crew.ask: this athanor has no scroll named \"mine:kept-way\""}} =
             Aqua.Crew.scrolls(ctx, ["mine:kept-way"], "crew.ask")

    assert {:ok, %{created: "mine:kept-way"}} = save.(proposal, "skill_create")

    assert {:ok, %{description: "How the fern is kept", content: "Water it weekly."}} =
             Tool.handle(ctx, %{"action" => "skill_get", "name" => "mine:kept-way"})

    # A proposal that names only a description stores the body it showed.
    assert {:ok, %{content: "Water it weekly.", against: against} = described} =
             in_chain.(%{
               "action" => "skill_update",
               "name" => "mine:kept-way",
               "description" => "How the fern stays green"
             })

    {:ok, stored} =
      Arca.get(
        Sanctum.Context.actor(ctx),
        Compendium.AquaPath.scroll_manifest("mine", "kept-way")
      )

    assert against == Prima.Digest.sha256(stored)

    # Its body edited elsewhere after the proposal, the save is refused and
    # nothing is written.
    assert {:ok, %{updated: "mine:kept-way"}} =
             Sanctum.Gate.call_external("aqua", ctx, %{
               "action" => "skill_update",
               "name" => "mine:kept-way",
               "content" => "Water it daily."
             })

    assert {:error, {:conflict, refusal}} = save.(described, "skill_update")
    assert refusal =~ "The scroll 'mine:kept-way' changed since Aqua proposed this"

    assert {:ok, %{description: "How the fern is kept", content: "Water it daily."}} =
             Tool.handle(ctx, %{"action" => "skill_get", "name" => "mine:kept-way"})

    # Proposed again over the scroll as it is, the save writes exactly it.
    assert {:ok, again} =
             in_chain.(%{
               "action" => "skill_update",
               "name" => "mine:kept-way",
               "description" => "How the fern stays green"
             })

    assert {:ok, %{updated: "mine:kept-way"}} = save.(again, "skill_update")

    assert {:ok, %{description: "How the fern stays green", content: "Water it daily."}} =
             Tool.handle(ctx, %{"action" => "skill_get", "name" => "mine:kept-way"})

    # A name already taken is refused at the proposal and at the save.
    assert {:error, {:invalid_argument, "Scroll 'mine:kept-way' already exists"}} =
             in_chain.(create)

    assert {:error, {:invalid_argument, "Scroll 'mine:kept-way' already exists"}} =
             save.(proposal, "skill_create")
  end

  # Every proposal is a running turn's own call
  # (`Arca.TurnStorage.own_turn/3`): a component a turn started, a page's
  # call through the turn, a call naming no open turn of the person's, and
  # a call of a turn paused or not yet started propose nothing, a scroll or
  # a file alike; the running turn's own call proposes each.
  test "only a turn's own call proposes a scroll or a file" do
    auth = granting(["aqua.skill_create", "aqua.skill_update", "aqua.skill_file"])
    ctx = Sanctum.TestContext.local(:prism)
    lineage = turn!(ctx)

    {:ok, _} =
      Arca.Files.write(
        Sanctum.Context.actor(ctx),
        "aqua/scrolls/mine/skills/fern/SKILL.md",
        "---\nname: fern\ndescription: d\n---\n\nWater it.\n"
      )

    component = Cyfr.Test.AttemptFixtures.lineage!(ctx)

    callers = [
      {"a component the turn started",
       %{lineage | parent_execution_id: component.parent_execution_id, attempt: component.attempt}},
      {"a page through the turn", Map.put(lineage, :called_by_page, true)},
      {"a call naming no turn", caller!(ctx)},
      {"a paused turn", turn!(ctx, "paused")},
      {"a turn not yet started", turn!(ctx, "accepted")}
    ]

    proposals = [
      %{
        "action" => "skill_create",
        "name" => "mine:kept",
        "description" => "d",
        "content" => "c"
      },
      %{"action" => "skill_update", "name" => "mine:fern", "content" => "Water it daily."},
      %{
        "action" => "skill_file",
        "name" => "mine:fern",
        "path" => "skills/fern/a.sh",
        "content" => "#!/bin/sh\n"
      }
    ]

    call = fn args, lineage ->
      Sanctum.Gate.call_in_chain("aqua", Sanctum.Context.enter_guest(ctx), args, auth,
        lineage: lineage
      )
    end

    for {who, other} <- callers, args <- proposals do
      assert {:error, :propose_not_a_turn} = call.(args, other), "#{who}: #{args["action"]}"
    end

    assert Prima.Refusal.message(:propose_not_a_turn) ==
             "Only Aqua or one of its members proposes a scroll or a file for your packs, in a " <>
               "turn of its own; a component or a page cannot"

    for args <- proposals do
      assert {:ok, %{proposed: _}} = call.(args, lineage), args["action"]
    end
  end

  # A file a turn proposes beside a scroll waits for the person: in the
  # turn's own call it answers what the card says of the file, never its
  # bytes, and writes nothing. The person's Save names the proposal's row
  # and the digest its card showed, and nothing of the file: it writes the
  # row's bytes only while they are that digest and the file is as the
  # proposal read it, and a row of no proposal, of another athanor, or a
  # file's bytes from the caller save nothing.
  test "a chain proposes a file and writes nothing; Save keeps the proposal its card showed" do
    auth = granting(["aqua.skill_file"])
    ctx = Sanctum.TestContext.local(:prism)
    actor = Sanctum.Context.actor(ctx)
    lineage = turn!(ctx)

    {:ok, _} =
      Arca.Files.write(
        actor,
        "aqua/scrolls/mine/skills/fern/SKILL.md",
        "---\nname: fern\ndescription: d\n---\n\nWater it.\n"
      )

    in_chain = fn args ->
      Sanctum.Gate.call_in_chain("aqua", Sanctum.Context.enter_guest(ctx), args, auth,
        lineage: lineage
      )
    end

    # The proposal's row as the loop keeps it (`Aqua.Loop`): the answer,
    # with the bytes from the call's own arguments.
    row! = fn answer, bytes ->
      proposal =
        answer
        |> Map.take([:path, :size, :sha256, :against, :against_size, :runs, :script])
        |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
        |> Map.merge(%{"name" => answer.proposed, "content" => bytes})

      {:ok, row} =
        Arca.ThreadStorage.append(actor, lineage.thread_id, %{
          author: Prima.Author.agent(),
          sent_by: "aqua",
          kind: "tool_result",
          status: "proposed",
          content: "proposed",
          payload: %{"tool_call_id" => "c1", "name" => "aqua", "proposal" => proposal}
        })

      row
    end

    save = fn id, sha256 ->
      Sanctum.Gate.call_external("aqua", ctx, %{
        "action" => "skill_file",
        "proposal" => id,
        "sha256" => sha256
      })
    end

    script = "#!/bin/sh\necho water\n"
    other_script = "#!/bin/sh\necho\n"
    path = ~w(aqua scrolls mine skills fern scripts water.sh)

    ask = %{
      "action" => "skill_file",
      "name" => "mine:fern",
      "path" => "skills/fern/scripts/water.sh",
      "content" => script
    }

    assert {:ok, answer} = in_chain.(ask)

    assert Map.delete(answer, :note) == %{
             proposed: "mine:fern",
             path: "skills/fern/scripts/water.sh",
             size: byte_size(script),
             sha256: Prima.Digest.sha256(script),
             against: "none",
             against_size: nil,
             runs: true,
             script: true
           }

    assert {:ok, second} = in_chain.(%{ask | "content" => other_script})
    assert {:error, :not_found} = Arca.get(actor, path)

    first_row = row!.(answer, script)
    second_row = row!.(second, other_script)

    # A digest that is not of the row's bytes, as a card drawn before the
    # row changed sends, saves nothing.
    assert {:error, {:conflict, "This proposal is not the file its card showed" <> _}} =
             save.(first_row.id, Prima.Digest.sha256(other_script))

    assert {:error, :not_found} = Arca.get(actor, path)

    assert {:ok, %{written: "mine:fern"}} = save.(first_row.id, Prima.Digest.sha256(script))
    assert {:ok, ^script} = Arca.get(actor, path)

    # The second read the same absence: saved after the first, it is
    # refused and the first stays.
    assert {:error, {:conflict, refusal}} =
             save.(second_row.id, Prima.Digest.sha256(other_script))

    assert refusal =~ "changed since Aqua proposed this"
    assert {:ok, ^script} = Arca.get(actor, path)

    # A row that holds no proposal, and another athanor's row, are none.
    {:ok, post} =
      Arca.ThreadStorage.append(actor, lineage.thread_id, %{
        author: ctx.user_id,
        sent_by: "person",
        kind: "text",
        content: script
      })

    assert {:error, {:not_found, "Proposal", _}} = save.(post.id, Prima.Digest.sha256(script))

    {_a, b} = Sanctum.TestContext.two_contexts()

    assert {:error, {:not_found, "Proposal", _}} =
             Sanctum.Gate.call_external("aqua", Sanctum.TestContext.via(b, :prism), %{
               "action" => "skill_file",
               "proposal" => first_row.id,
               "sha256" => Prima.Digest.sha256(script)
             })

    # A file's bytes from the caller are no Save.
    for args <- [
          %{ask | "content" => "x"},
          Map.merge(ask, %{"proposal" => first_row.id, "sha256" => Prima.Digest.sha256(script)})
        ] do
      assert {:error, {:invalid_argument, "aqua.skill_file saves a file Aqua proposed" <> _}} =
               Sanctum.Gate.call_external("aqua", ctx, args)
    end
  end

  # A scroll's bound, stated once where it is written: a manifest of at
  # most 131,072 bytes and a description of at most 1,024 characters.
  test "the writer holds a scroll to its bound" do
    ctx = Sanctum.TestContext.local(:prism)

    write = fn name, description, content ->
      Sanctum.Gate.call_external("aqua", ctx, %{
        "action" => "skill_create",
        "name" => name,
        "description" => description,
        "content" => content
      })
    end

    overhead = byte_size(~s(---\nname: "at-bound"\ndescription: "d"\n---\n\n\n))
    whole = String.duplicate("a", 131_072 - overhead)

    assert {:ok, %{created: "mine:at-bound"}} = write.("mine:at-bound", "d", whole)

    {:ok, stored} =
      Arca.get(
        Sanctum.Context.actor(ctx),
        Compendium.AquaPath.scroll_manifest("mine", "at-bound")
      )

    assert byte_size(stored) == 131_072

    over = ~s(---\nname: "past-bound"\ndescription: "d"\n---\n\n\n)
    past = String.duplicate("a", 131_073 - byte_size(over))
    assert {:error, {:invalid_argument, refusal}} = write.("mine:past-bound", "d", past)
    assert refusal =~ "The scroll 'past-bound' is too large for Aqua to use"

    assert {:ok, _} = write.("mine:long-line", String.duplicate("é", 1_024), "c")

    assert {:error, {:invalid_argument, _}} =
             write.("mine:longer-line", String.duplicate("é", 1_025), "c")
  end

  # A scroll stored past the bound, written before or replaced through
  # Files, is handed to no harness: a chain neither lists nor reads it and
  # no job carries it, while the person's own session reads it, to see and
  # change it. Files keeps no check of its own for it.
  test "a scroll replaced through Files past the bound is carried by no harness and read from outside",
       %{ctx: ctx} do
    auth = granting(["aqua.skill_get", "aqua.skill_list"])
    session = Sanctum.TestContext.local(:prism)
    lineage = caller!(session)
    body = String.duplicate("a", 131_072)

    {:ok, _} =
      Tool.handle(ctx, %{
        "action" => "skill_create",
        "name" => "mine:too-big",
        "description" => "d",
        "content" => "short"
      })

    assert {:ok, _written} =
             Arca.Files.write(
               Sanctum.Context.actor(ctx),
               Enum.join(Compendium.AquaPath.scroll_manifest("mine", "too-big"), "/"),
               ~s(---\nname: "too-big"\ndescription: "d"\n---\n\n) <> body <> "\n"
             )

    in_chain = fn args ->
      Sanctum.Gate.call_in_chain("aqua", Sanctum.Context.enter_guest(session), args, auth,
        lineage: lineage
      )
    end

    assert {:error, {:invalid_argument, refusal}} =
             in_chain.(%{"action" => "skill_get", "name" => "mine:too-big"})

    assert refusal =~ "The scroll 'mine:too-big' is too large for Aqua to use"
    assert {:ok, %{skills: listed}} = in_chain.(%{"action" => "skill_list"})
    refute "mine:too-big" in Enum.map(listed, & &1.name)

    assert {:ok, %{content: ^body}} =
             Tool.handle(ctx, %{"action" => "skill_get", "name" => "mine:too-big"})

    assert {:ok, %{skills: all}} = Tool.handle(ctx, %{"action" => "skill_list"})
    assert %{carried: false} = Enum.find(all, &(&1.name == "mine:too-big"))

    assert {:error,
            {:invalid_argument,
             "crew.ask: the scroll 'mine:too-big' is too large for Aqua to use"}} =
             Aqua.Crew.scrolls(ctx, ["mine:too-big"], "crew.ask")

    prompt =
      Aqua.Prompt.compose(ctx, agent: %{"prompt" => ""})

    refute prompt.text =~ "too-big"
  end

  # The bound is on what a scroll's frame delivers: a short scroll whose
  # files' names take it past one line is carried by no harness, alone or
  # with others in a job.
  test "a scroll whose files' names take it past the bound is carried by no harness", %{ctx: ctx} do
    {:ok, _} =
      Tool.handle(ctx, %{
        "action" => "skill_create",
        "name" => "mine:many-files",
        "description" => "d",
        "content" => "short"
      })

    # The files land in one revision of the pack, as a bring-in lands them.
    :ok =
      Arca.Overlay.edit_unit(
        Sanctum.Context.actor(ctx),
        Compendium.AquaPath.pack_dir("mine"),
        fn pairs ->
          {:ok,
           pairs ++
             for(
               n <- 1..600,
               do: {["skills", "many-files", String.pad_leading("#{n}", 230, "f")], "x"}
             )}
        end
      )

    assert {:ok, %{carried: false, delivered: delivered}} =
             Compendium.skill(ctx, "mine:many-files")

    assert delivered > 131_072

    assert {:error,
            {:invalid_argument,
             "crew.ask: the scroll 'mine:many-files' is too large for Aqua to use"}} =
             Aqua.Crew.scrolls(ctx, ["mine:many-files"], "crew.ask")
  end

  # A job's bound is on what the member reads: scrolls whose names and
  # bodies fit it, each in its frame, delimiters and separators with it,
  # do not, and the ask is refused in the sentence that names the bound.
  # Two near the bound make the case here; many small ones are reckoned
  # alike (`Aqua.CrewBoundTest`).
  test "scrolls that fit as parts and not as framed are refused for one job", %{ctx: ctx} do
    body = String.duplicate("b", 65_500)
    names = ["mine:s1", "mine:s2"]

    for name <- ["s1", "s2"] do
      :ok =
        Arca.put(
          Sanctum.Context.actor(ctx),
          Compendium.AquaPath.scroll_manifest("mine", name),
          ~s(---\nname: "#{name}"\ndescription: "d"\n---\n\n#{body}\n)
        )
    end

    assert {:error, {:invalid_argument, refusal}} = Aqua.Crew.scrolls(ctx, names, "crew.ask")

    framed =
      for(name <- names, do: %{"name" => name, "body" => body, "files" => []})
      |> Aqua.Reader.scrolls(Aqua.Reader.token())
      |> byte_size()

    assert Enum.sum(Enum.map(names, &(byte_size(&1) + byte_size(body)))) < 131_072
    assert framed > 131_072

    assert refusal ==
             "crew.ask: the scrolls named come to #{framed} bytes as the member reads them, " <>
               "more than the 131072 one job carries"
  end

  # The index a turn's prompt carries drops scrolls past the bound before
  # it counts to its limit, so they hide no usable one.
  test "scrolls past the bound sorted before a usable one hide it from no turn's index", %{
    ctx: ctx
  } do
    long = String.duplicate("d", 1_025)

    for n <- 1..41 do
      name = "aa" <> String.pad_leading("#{n}", 2, "0")

      :ok =
        Arca.put(
          Sanctum.Context.actor(ctx),
          Compendium.AquaPath.scroll_manifest("mine", name),
          ~s(---\nname: "#{name}"\ndescription: "#{long}"\n---\n\nbody\n)
        )
    end

    {:ok, _} =
      Tool.handle(ctx, %{
        "action" => "skill_create",
        "name" => "mine:zz-usable",
        "description" => "the one that works",
        "content" => "body"
      })

    {:ok, %{entries: entries}} = Compendium.skills_index(ctx, Compendium.skills_index_limit())
    assert "mine:zz-usable" in Enum.map(entries, & &1.name)
    refute Enum.any?(entries, &String.starts_with?(&1.name, "mine:aa"))

    prompt = Aqua.Prompt.compose(ctx, agent: %{"prompt" => ""})
    assert prompt.text =~ "- mine:zz-usable — the one that works"
  end

  # A chain authority granting exactly `tools`, the shape the consent blob
  # mints from a manifest's `caps.tools`.
  defp granting(tools) do
    node = "formula:local.assistant"

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
              "rate_limit" => %{"requests" => 10_000, "window" => "1m"},
              "max_concurrent_tasks" => 10,
              "batch_timeout" => "1m"
            },
            "edges" => %{"@ingress" => %{"tools" => tools}}
          }
        }
      })

    {:ok, auth} =
      Prima.Authority.root(
        %{
          profile_id: "prof-scrolls",
          consent_id: "consent-scrolls",
          source_ref: node,
          kind: :owner,
          invoke_mode: :open_inert,
          activation: %{node => "sha256:scrolls"}
        },
        blob,
        ceiling: Sanctum.Policy.Ceiling.platform_ceiling()
      )

    auth
  end

  # An in-chain call comes from a real execution's attempt, which the host
  # names in its lineage.
  defp caller!(ctx),
    do: ctx |> Cyfr.Test.AttemptFixtures.lineage!() |> Map.take([:parent_execution_id, :attempt])

  # The lineage of a call a running turn of the person's makes itself: its
  # thread, and the turn's root as the call's parent and root, as the loop
  # stamps it (`Aqua.Loop.Binding`).
  defp turn!(ctx, status \\ "running") do
    actor = Sanctum.Context.actor(ctx)
    lineage = Cyfr.Test.AttemptFixtures.lineage!(ctx)
    {:ok, thread} = Arca.Test.Days.thread(actor)

    {:ok, %{turn: turn}} =
      Arca.TurnStorage.accept_message(actor, thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: "keep it"},
        turn: %{agent: "aqua", requested_by: ctx.user_id, origin: :interactive}
      })

    {1, _} =
      Arca.Repo.update_all(
        from(t in Arca.Schemas.Turn, where: t.id == ^turn.id),
        set: [root_execution_id: lineage.root_execution_id, status: status]
      )

    Map.put(lineage, :thread_id, thread.id)
  end
end
