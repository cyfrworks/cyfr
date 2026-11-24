# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Providers.AquaConsentTest do
  # The `aqua` tool's write door: every write is a person's own act, so a
  # standing credential is refused at the registry's dispatch gate and is
  # not shown the writes in `tools/list`; the reads stay open to every
  # surface, because a turn resolves its soul through them.
  use ExUnit.Case, async: false

  alias Compendium.Providers.Aqua, as: Tool
  alias Sanctum.Visibility

  @writes ~w(create update delete reset skill_create skill_update skill_delete skill_reset)
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
      {"skill_create", %{"name" => "sneak", "description" => "d", "content" => "c"}},
      {"skill_update", %{"name" => "capability-acquisition", "content" => "c"}},
      {"reset", %{"all" => true}},
      {"update", %{"name" => "aqua", "content" => "x"}},
      {"create", %{"name" => "sneak", "content" => "x"}},
      {"delete", %{"name" => "aqua"}},
      {"reset", %{"name" => "aqua"}},
      {"skill_delete", %{"name" => "capability-acquisition"}},
      {"skill_reset", %{"name" => "capability-acquisition"}}
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
    lineage = caller!(ctx)

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
              }} = create.(%{ctx | auth_method: method}, "by-#{method}")

      assert {:error, {:not_found, "Scroll", _}} =
               Tool.handle(ctx, %{"action" => "skill_get", "name" => "by-#{method}"})
    end

    assert {:ok, %{proposed: "by-person", against: "none"}} = create.(ctx, "by-person")

    assert {:error, {:not_found, "Scroll", "by-person"}} =
             Tool.handle(ctx, %{"action" => "skill_get", "name" => "by-person"})
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
    lineage = caller!(ctx)

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
      "name" => "kept-way",
      "description" => "  How the fern is kept  ",
      "content" => "\nWater it weekly.\n"
    }

    assert {:ok, proposal} = in_chain.(create)

    assert Map.delete(proposal, :note) == %{
             proposed: "kept-way",
             description: "How the fern is kept",
             content: "Water it weekly.",
             against: "none"
           }

    # Unsaved, it is nothing any read sees.
    assert {:error, {:not_found, "Scroll", "kept-way"}} =
             Tool.handle(ctx, %{"action" => "skill_get", "name" => "kept-way"})

    {:ok, index} = Compendium.AquaSkills.index(ctx)
    refute "kept-way" in Enum.map(index, & &1.name)

    assert {:error,
            {:invalid_argument, "crew.ask: this athanor has no scroll named \"kept-way\""}} =
             Aqua.Crew.scrolls(ctx, ["kept-way"], "crew.ask")

    assert {:ok, %{created: "kept-way"}} = save.(proposal, "skill_create")

    assert {:ok, %{description: "How the fern is kept", content: "Water it weekly."}} =
             Tool.handle(ctx, %{"action" => "skill_get", "name" => "kept-way"})

    # A proposal that names only a description stores the body it showed.
    assert {:ok, %{content: "Water it weekly.", against: against} = described} =
             in_chain.(%{
               "action" => "skill_update",
               "name" => "kept-way",
               "description" => "How the fern stays green"
             })

    {:ok, stored} =
      Arca.get(Sanctum.Context.actor(ctx), Compendium.AquaPath.skill_manifest("kept-way"))

    assert against == Prima.Digest.sha256(stored)

    # Its body edited elsewhere after the proposal, the save is refused and
    # nothing is written.
    assert {:ok, %{updated: "kept-way"}} =
             Sanctum.Gate.call_external("aqua", ctx, %{
               "action" => "skill_update",
               "name" => "kept-way",
               "content" => "Water it daily."
             })

    assert {:error, {:conflict, refusal}} = save.(described, "skill_update")
    assert refusal =~ "The scroll 'kept-way' changed since Aqua proposed this"

    assert {:ok, %{description: "How the fern is kept", content: "Water it daily."}} =
             Tool.handle(ctx, %{"action" => "skill_get", "name" => "kept-way"})

    # Proposed again over the scroll as it is, the save writes exactly it.
    assert {:ok, again} =
             in_chain.(%{
               "action" => "skill_update",
               "name" => "kept-way",
               "description" => "How the fern stays green"
             })

    assert {:ok, %{updated: "kept-way"}} = save.(again, "skill_update")

    assert {:ok, %{description: "How the fern stays green", content: "Water it daily."}} =
             Tool.handle(ctx, %{"action" => "skill_get", "name" => "kept-way"})

    # A name already taken is refused at the proposal and at the save.
    assert {:error, {:invalid_argument, "Scroll 'kept-way' already exists"}} = in_chain.(create)

    assert {:error, {:invalid_argument, "Scroll 'kept-way' already exists"}} =
             save.(proposal, "skill_create")
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

    assert {:ok, %{created: "at-bound"}} = write.("at-bound", "d", whole)

    {:ok, stored} =
      Arca.get(Sanctum.Context.actor(ctx), Compendium.AquaPath.skill_manifest("at-bound"))

    assert byte_size(stored) == 131_072

    over = ~s(---\nname: "past-bound"\ndescription: "d"\n---\n\n\n)
    past = String.duplicate("a", 131_073 - byte_size(over))
    assert {:error, {:invalid_argument, refusal}} = write.("past-bound", "d", past)
    assert refusal =~ "The scroll 'past-bound' is too large for Aqua to use"

    assert {:ok, _} = write.("long-line", String.duplicate("é", 1_024), "c")

    assert {:error, {:invalid_argument, _}} =
             write.("longer-line", String.duplicate("é", 1_025), "c")
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
        "name" => "too-big",
        "description" => "d",
        "content" => "short"
      })

    assert {:ok, _written} =
             Arca.Files.write(
               Sanctum.Context.actor(ctx),
               Enum.join(Compendium.AquaPath.skill_manifest("too-big"), "/"),
               ~s(---\nname: "too-big"\ndescription: "d"\n---\n\n) <> body <> "\n"
             )

    in_chain = fn args ->
      Sanctum.Gate.call_in_chain("aqua", Sanctum.Context.enter_guest(session), args, auth,
        lineage: lineage
      )
    end

    assert {:error, {:invalid_argument, refusal}} =
             in_chain.(%{"action" => "skill_get", "name" => "too-big"})

    assert refusal =~ "The scroll 'too-big' is too large for Aqua to use"
    assert {:ok, %{skills: listed}} = in_chain.(%{"action" => "skill_list"})
    refute "too-big" in Enum.map(listed, & &1.name)

    assert {:ok, %{content: ^body}} =
             Tool.handle(ctx, %{"action" => "skill_get", "name" => "too-big"})

    assert {:ok, %{skills: all}} = Tool.handle(ctx, %{"action" => "skill_list"})
    assert %{carried: false} = Enum.find(all, &(&1.name == "too-big"))

    assert {:error,
            {:invalid_argument, "crew.ask: the scroll 'too-big' is too large for Aqua to use"}} =
             Aqua.Crew.scrolls(ctx, ["too-big"], "crew.ask")

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
        "name" => "many-files",
        "description" => "d",
        "content" => "short"
      })

    for n <- 1..600 do
      name = String.pad_leading("#{n}", 230, "f")

      :ok =
        Arca.put(
          Sanctum.Context.actor(ctx),
          Compendium.AquaPath.skill_dir("many-files") ++ [name],
          "x"
        )
    end

    assert {:ok, %{carried: false, delivered: delivered}} = Compendium.skill(ctx, "many-files")
    assert delivered > 131_072

    assert {:error,
            {:invalid_argument, "crew.ask: the scroll 'many-files' is too large for Aqua to use"}} =
             Aqua.Crew.scrolls(ctx, ["many-files"], "crew.ask")
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
          Compendium.AquaPath.skill_manifest(name),
          ~s(---\nname: "#{name}"\ndescription: "#{long}"\n---\n\nbody\n)
        )
    end

    {:ok, _} =
      Tool.handle(ctx, %{
        "action" => "skill_create",
        "name" => "zz-usable",
        "description" => "the one that works",
        "content" => "body"
      })

    {:ok, %{entries: entries}} = Compendium.skills_index(ctx, Compendium.skills_index_limit())
    assert "zz-usable" in Enum.map(entries, & &1.name)
    refute Enum.any?(entries, &String.starts_with?(&1.name, "aa"))

    prompt = Aqua.Prompt.compose(ctx, agent: %{"prompt" => ""})
    assert prompt.text =~ "- zz-usable — the one that works"
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
end
