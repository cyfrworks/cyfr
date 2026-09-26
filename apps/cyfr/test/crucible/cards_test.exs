# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Crucible.CardsTest do
  @moduledoc """
  `card.refresh` and `card.press` (`Crucible.Cards`): the desktop names a
  placed card by its slot and nothing else. A refresh runs the card's
  declared source as a frame's invoke of it runs — under the card
  tincture's owner profile, as the person — projects it through the
  declaration and broadcasts it on the person's own cards topic; a press
  fires the declared button's action through the gate. A slot that is not
  a card, a tincture not installed, a card not declared, a tincture not
  granted, a projection over the card's bounds, a button out of range and
  an action the gate refuses the person are each refused, and a refused
  refresh broadcasts nothing.
  """

  use ExUnit.Case, async: false

  alias Cyfr.Test.ScriptedWorker
  alias Prima.Test.AuthorityFixtures
  alias Sanctum.Test.ConsentFixtures

  @math_wasm_path Path.expand("../support/test_wasm/math.wasm", __DIR__)
  @dep "reagent:local.card-dep"
  @dep_ref "reagent:local.card-dep:0.1.0"
  @tincture "cards-t"
  @ref "tincture:local.cards-t"
  @posture "desk"

  setup do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!()

    base = Path.join(System.tmp_dir!(), "cards_#{System.unique_integer([:positive])}")
    keys = [cyfr: :opus_workers, arca: :base_path]
    prev = Map.new(keys, fn {app, key} -> {{app, key}, Application.get_env(app, key)} end)
    Application.put_env(:arca, :base_path, base)

    owner = Sanctum.TestContext.local()
    _athanor = Sanctum.TestContext.athanor!()

    on_exit(fn ->
      Prima.Slots.forgive_unreaped(Crucible.Slots, owner.athanor_id)
      File.rm_rf!(base)

      for {{app, key}, value} <- prev do
        if value,
          do: Application.put_env(app, key, value),
          else: Application.delete_env(app, key)
      end
    end)

    {:ok, _dep} =
      Compendium.Registry.publish_bytes(owner, File.read!(@math_wasm_path), %{
        name: "card-dep",
        version: "0.1.0",
        type: "reagent"
      })

    tincture!(owner)
    person = person!("carder")
    other = person!("bystander")
    layout!(person)

    {:ok, owner: owner, ctx: person, other: other}
  end

  # A signed-in person of the fixture athanor, as a request establishes one.
  defp person!(namespace) do
    issuer =
      Sanctum.TestContext.issuer!(%{
        Sanctum.TestContext.local()
        | user_id: "local|local|#{namespace}",
          namespace: namespace
      })

    {:ok, session} = Sanctum.TestContext.create_session(issuer)
    {:ok, ctx} = Sanctum.Caller.establish(session.token)
    ctx
  end

  # The card tincture: a sourced card, a card whose projection breaks its
  # bounds, a static card, and buttons the gate admits, refuses the
  # person, and one that would press again.
  defp tincture!(ctx) do
    manifest = %{
      "name" => @tincture,
      "type" => "tincture",
      "version" => "1.0.0",
      "publisher" => "local",
      "tincture" => %{
        "entry" => "index.html",
        "actions" => ["system.status", "execution.force_release", "card.press"],
        "cards" => [
          %{
            "name" => "runs",
            "title" => "Runs",
            "number" => "status",
            "source" => %{
              "component" => @dep,
              "operation" => "count",
              "args" => %{"window" => "day"}
            },
            "buttons" => [
              %{"label" => "Status", "action" => "system.status"},
              %{"label" => "Release", "action" => "execution.force_release"},
              %{
                "label" => "Again",
                "action" => "card.press",
                "args" => %{"slot" => "runs", "posture" => @posture, "button" => 2}
              }
            ]
          },
          %{
            "name" => "broken",
            "title" => "Broken",
            "list" => "data",
            "source" => %{"component" => @dep, "operation" => "count"}
          },
          %{"name" => "note", "title" => "A note"}
        ]
      },
      "dependencies" => %{"static" => [%{"ref" => @dep, "reason" => "the cards"}]}
    }

    digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, @tincture), case: :lower)
    {:ok, release_digest} = Compendium.ReleaseDigest.compute(digest, manifest)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, _} =
      Arca.ComponentStorage.put_component(Sanctum.Context.actor(ctx), %{
        id: "cmp_#{@tincture}_#{System.unique_integer([:positive])}",
        name: @tincture,
        version: "1.0.0",
        component_type: "tincture",
        description: @tincture,
        tags: "[]",
        digest: digest,
        release_digest: release_digest,
        size: 100,
        exports: "[]",
        manifest: Jason.encode!(manifest),
        publisher: "local",
        publisher_id: "local|local|testns",
        source: Compendium.Source.filesystem(),
        signature_verified: false,
        inserted_at: now,
        updated_at: now
      })
  end

  # The tincture's owner profile, with a head consent binding its edge to
  # the dependency: the grant a frame's invoke runs under.
  defp grant!(ctx) do
    id = "prof_owner_#{System.unique_integer([:positive])}"
    {:ok, _ref, _type, component} = Crucible.Admission.inspect_component(ctx, @ref)
    {:ok, %{graph: activation}} = Compendium.Activation.resolve_verified(ctx, component)

    :ok =
      ConsentFixtures.seed_head!(
        ctx,
        %{id: id, kind: :owner, source_ref: @ref, label: "owner", status: :active},
        %{
          id: "consent_#{id}",
          revision: 1,
          scope: :versionless,
          pinned_version: "",
          invoke_mode: :open_inert,
          shape_digest: "sha256:shape-#{id}",
          commit_digest: "sha256:commit-#{id}",
          resolved_policy:
            Jason.encode!(%{
              "canonical" => "jcs-1",
              "nodes" => %{
                @ref => %{
                  "limits" => AuthorityFixtures.limits_map(),
                  "edges" => %{"@ingress" => %{}, @dep => %{}}
                },
                @dep => %{"limits" => AuthorityFixtures.limits_map(), "edges" => %{}}
              }
            }),
          activation: activation,
          vault_refs: []
        }
      )
  end

  defp slot(id, size, extra \\ %{}, tincture \\ @ref),
    do: Map.merge(%{"id" => id, "tincture" => tincture, "size" => size, "order" => 0}, extra)

  defp layout!(ctx) do
    document = %{
      "version" => 1,
      "postures" => %{
        @posture => %{
          "desktop" => "tincture:local.desktop",
          "slots" => [
            slot("runs", "card", %{"card" => "runs"}),
            slot("broken", "card", %{"card" => "broken"}),
            slot("note", "card", %{"card" => "note"}),
            slot("first", "card"),
            slot("icon", "icon"),
            slot("nope", "card", %{"card" => "nope"}),
            slot("gone", "card", %{}, "tincture:local.never-installed")
          ],
          "floating" => []
        }
      }
    }

    {:ok, _} =
      Compendium.Providers.Layout.handle("layout", ctx, %{
        "action" => "edit",
        "document" => document,
        "revision" => 0
      })
  end

  defp worker!(script),
    do: start_supervised!({ScriptedWorker, ref: @dep_ref, script: script})

  defp listen(ctx) do
    actor = Sanctum.Context.actor(ctx)
    :ok = Cyfr.Bus.subscribe(actor, Cyfr.Bus.cards(actor, ctx.user_id))
  end

  describe "a refresh" do
    test "runs the declared source under the tincture's grant and broadcasts to its placer alone",
         %{owner: owner, ctx: ctx, other: other} do
      grant!(owner)
      worker!([%{"answer" => 42}])
      ScriptedWorker.fresh_limits!(owner, [@dep_ref])
      listen(ctx)
      listen(other)

      assert {:ok, card} = Crucible.Cards.refresh(ctx, "runs", @posture)

      # The run's answer is the envelope the scripted worker completes with;
      # the card shows the declared field of it and nothing else.
      assert %{"name" => "runs", "title" => "Runs", "number" => 200, "list" => []} = card

      assert [%{"label" => "Status"}, %{"label" => "Release"}, %{"label" => "Again"}] =
               card["buttons"]

      refute Map.has_key?(card, "data")

      # The source ran as the frame's invoke would: the declared operation
      # and fixed arguments, under the tincture's owner profile.
      assert [%{authority: authority}] = ScriptedWorker.calls()
      assert authority.profile_kind == :owner

      user_id = ctx.user_id

      assert_receive %Cyfr.Bus.CardRefreshed{
        tincture: @ref,
        card: "runs",
        slot: "runs",
        user_id: ^user_id,
        data: ^card
      }

      # Another member of the same athanor hears nothing of it.
      other_id = other.user_id
      refute_receive %Cyfr.Bus.CardRefreshed{user_id: ^other_id}, 100
      refute_received %Cyfr.Bus.CardRefreshed{user_id: ^user_id}
    end

    test "of a static card runs nothing, and the first declared card shows without a name",
         %{ctx: ctx} do
      worker!([])

      assert {:ok, %{"title" => "A note"} = note} = Crucible.Cards.refresh(ctx, "note", @posture)
      refute Map.has_key?(note, "number")

      assert {:error, %Prima.Refusal{class: :consent_required}} =
               Crucible.Cards.refresh(ctx, "first", @posture)

      assert ScriptedWorker.calls() == []
    end

    test "of a tincture the person has not granted is the consent-needed refusal, through the gate",
         %{ctx: ctx} do
      worker!([%{"answer" => 1}])
      listen(ctx)

      assert {:error, %Prima.Refusal{class: :consent_required}} =
               Grimoire.call_external("card", ctx, %{
                 "action" => "refresh",
                 "slot" => "runs",
                 "posture" => @posture
               })

      assert ScriptedWorker.calls() == []
      refute_receive %Cyfr.Bus.CardRefreshed{}, 100
    end

    test "whose projection breaks the card's bounds is refused, and nothing is broadcast",
         %{owner: owner, ctx: ctx} do
      grant!(owner)
      worker!([%{"answer" => 1}])
      ScriptedWorker.fresh_limits!(owner, [@dep_ref])
      listen(ctx)

      assert {:error, {:conflict, sentence}} = Crucible.Cards.refresh(ctx, "broken", @posture)
      assert sentence == "card broken: data must be a list of texts"
      refute_receive %Cyfr.Bus.CardRefreshed{}, 100
    end

    test "refuses a slot that is not a card, a tincture not installed and a card not declared",
         %{ctx: ctx} do
      worker!([])

      assert {:error, {:invalid_argument, sentence}} =
               Crucible.Cards.refresh(ctx, "icon", @posture)

      assert sentence =~ "only a card-size slot shows a card"

      assert Crucible.Cards.refresh(ctx, "gone", @posture) ==
               {:error, {:not_found, "Tincture", "tincture:local.never-installed"}}

      assert Crucible.Cards.refresh(ctx, "nope", @posture) ==
               {:error, {:not_found, "Card", "#{@ref} nope"}}

      assert Crucible.Cards.refresh(ctx, "absent", @posture) ==
               {:error, {:not_found, "Slot", "absent"}}

      # Another person's layout is their own: this slot is not in it.
      assert ScriptedWorker.calls() == []
    end

    test "reads only the caller's own layout", %{other: other} do
      assert {:error, {:not_found, "Slot", "runs"}} =
               Crucible.Cards.refresh(other, "runs", @posture)
    end
  end

  describe "a press" do
    test "fires the declared action through the gate, and refuses what the gate refuses the person",
         %{ctx: ctx} do
      assert {:ok, _status} = Crucible.Cards.press(ctx, "runs", @posture, 0)

      # An operator's action on a member's card: the gate refuses it.
      assert {:error, %Prima.Refusal{class: :forbidden}} =
               Crucible.Cards.press(ctx, "runs", @posture, 1)
    end

    test "refuses a button out of range, and a button that would press a card again",
         %{ctx: ctx} do
      assert {:error, {:invalid_argument, sentence}} =
               Crucible.Cards.press(ctx, "runs", @posture, 3)

      assert sentence == "card runs has 3 button(s); there is no button 3"

      assert {:error, {:invalid_argument, _}} = Crucible.Cards.press(ctx, "note", @posture, 0)

      assert {:error, {:invalid_argument, "card runs: a button never fires card.press"}} =
               Crucible.Cards.press(ctx, "runs", @posture, 2)
    end

    test "is declared on both planes, naming the slot, the posture and the button" do
      assert {:ok, {Crucible.Provider, tool}} = Grimoire.lookup("card")
      actions = Grimoire.declared_actions(tool)
      assert Enum.sort(Map.keys(actions)) == ["press", "refresh"]

      for {_action, annotation} <- actions do
        assert annotation.kind == :write
        assert Enum.sort(annotation.planes) == [:external, :in_chain]
      end
    end
  end
end
