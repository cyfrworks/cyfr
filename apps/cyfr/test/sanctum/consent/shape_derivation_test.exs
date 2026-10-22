# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Consent.ShapeDerivationTest do
  use ExUnit.Case, async: false

  require Ecto.Query

  alias Prima.Manifest.Caps
  alias Sanctum.Consent.Bootstrap
  alias Sanctum.Consent.Components
  alias Sanctum.Consent.Loader
  alias Sanctum.Consent.ShapeDerivation

  @wasm Cyfr.Test.Guests.wasm(:reagent)

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    test_path = Path.join(System.tmp_dir!(), "shape_derivation_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)
    Cyfr.Test.SeedBundle.isolate!()

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    {:ok, ctx: Sanctum.TestContext.local(:prism)}
  end

  defp publish!(ctx, name, version, attrs \\ %{}) do
    type = Map.get(attrs, :type) || Map.get(attrs, "type") || "reagent"

    manifest =
      case Map.get(attrs, :manifest) || Map.get(attrs, "manifest") do
        json when is_binary(json) -> Jason.decode!(json)
        map when is_map(map) -> map
        _ -> %{}
      end
      |> Map.merge(%{
        "name" => name,
        "type" => type,
        "version" => version,
        "publisher" => "local"
      })

    {:ok, component} =
      Arca.Test.UnitFixtures.ship_and_register!(ctx, type, "local", name, version,
        manifest: manifest,
        wasm: type != "tincture" && Cyfr.Test.Guests.wasm(type)
      )

    component
  end

  defp head!(ctx, source_ref) do
    {:ok, [profile]} = Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), source_ref)
    {:ok, consent} = Arca.ConsentStorage.head_consent(Sanctum.Context.actor(ctx), profile.id)
    {profile, consent}
  end

  # A needs manifest whose only between-version delta is the (prose) need
  # reason: the release digest moves, the shape does not.
  defp roll_manifest(reason) do
    %{
      "needs" => %{
        "api_key" => %{
          "type" => "api_key:example.com",
          "reason" => reason,
          "fields" => ["EXAMPLE_API_KEY"]
        }
      }
    }
  end

  defp live!(ctx, name) do
    {:ok, component} = Compendium.Registry.get_latest(ctx, name, "local", "reagent")
    {:ok, live} = Compendium.Activation.resolve_verified(ctx, component)
    live
  end

  test "consent-time and live derivation agree by construction", %{ctx: ctx} do
    publish!(ctx, "shape-pin", "1.0.0")
    {:ok, _} = Bootstrap.run(ctx)

    {_profile, consent} = head!(ctx, "reagent:local.shape-pin")

    assert ShapeDerivation.live_digest(ctx, "reagent:local.shape-pin") ==
             {:ok, consent.shape_digest}
  end

  describe "one version's shape" do
    test "is the version's own, and a version changed in place is never answered the shape it had",
         %{ctx: ctx} do
      publish!(ctx, "shape-work", "1.0.0")
      publish!(ctx, "shape-work", "1.0.1", %{manifest: roll_manifest("newer")})
      ref = "reagent:local.shape-work"

      {:ok, before} = ShapeDerivation.version_digest(ctx, ref, "1.0.0")
      {:ok, input} = ShapeDerivation.shape_input(ctx, ref, "1.0.0")
      assert {:ok, before} == Sanctum.Consent.ShapeDigest.compute(input)
      refute {:ok, before} == ShapeDerivation.live_digest(ctx, ref)

      # 1.0.0 rebuilt under the same number with a need it did not ask for,
      # its row changed in place with no registry sweep after it: what is
      # cached for the bytes it had is not what it is answered.
      changed =
        %{
          "name" => "shape-work",
          "type" => "reagent",
          "version" => "1.0.0",
          "publisher" => "local"
        }
        |> Map.merge(roll_manifest("added"))

      [row] =
        Arca.Repo.all(
          Ecto.Query.from(c in Arca.Schemas.Component,
            where: c.name == "shape-work" and c.version == "1.0.0"
          )
        )

      {:ok, release} = Compendium.ReleaseDigest.compute(row.digest, changed)

      {1, _} =
        Arca.Repo.update_all(
          Ecto.Query.from(c in Arca.Schemas.Component, where: c.id == ^row.id),
          set: [manifest: Jason.encode!(changed), release_digest: release]
        )

      {:ok, after_change} = ShapeDerivation.version_digest(ctx, ref, "1.0.0")
      {:ok, input} = ShapeDerivation.shape_input(ctx, ref, "1.0.0")
      refute after_change == before
      assert {:ok, after_change} == Sanctum.Consent.ShapeDigest.compute(input)
    end
  end

  @tag :shape_outage
  test "an unreadable dependency closure has no shape, even when the source row was read",
       %{ctx: ctx} do
    row = publish!(ctx, "shape-unreadable", "1.0.0")
    ref = "reagent:local.shape-unreadable"
    real = Components.impl!()
    on_exit(fn -> Components.install!(real) end)
    Sanctum.TestContext.uninstall_port(Components)

    refusal = {:error, {:unavailable, "Components"}}
    assert ShapeDerivation.dependency_releases(ctx, row, ref) == refusal
    assert ShapeDerivation.shape_input(ctx, ref) == refusal
    assert ShapeDerivation.manifest_blocks(ctx, ref) == refusal
    assert ShapeDerivation.live_digest(ctx, ref) == refusal
  end

  test "an incomplete closure keeps its empty dependency set and a missing source stays absent",
       %{ctx: ctx} do
    row =
      publish!(ctx, "shape-incomplete", "1.0.0", %{
        manifest: %{
          "dependencies" => %{"static" => [%{"ref" => "reagent:local.shape-missing"}]}
        }
      })

    assert {:error, {:incomplete, _}} = Components.resolve(ctx, row)

    assert ShapeDerivation.dependency_releases(ctx, row, "reagent:local.shape-incomplete") ==
             {:ok, []}

    assert ShapeDerivation.shape_input(ctx, "reagent:local.shape-missing") == {:error, :not_found}
  end

  test "a new release with an unchanged shape allows and records", %{ctx: ctx} do
    publish!(ctx, "shape-roll", "1.0.0", %{manifest: Jason.encode!(roll_manifest("original"))})
    {:ok, _} = Bootstrap.run(ctx)
    {profile, consent} = head!(ctx, "reagent:local.shape-roll")

    # A release whose security-relevant manifest changed: the reworded need
    # reason moves the release digest (needs is digest-covered) and with it
    # the activation — but reason is prose, so the consent shape is
    # untouched.
    publish!(ctx, "shape-roll", "1.0.1", %{manifest: Jason.encode!(roll_manifest("reworded"))})

    live = live!(ctx, "shape-roll")
    refute live.graph == consent.activation

    {:ok, digest} = ShapeDerivation.live_digest(ctx, "reagent:local.shape-roll")

    assert {:ok, _authority, stamp} =
             Loader.load_root(ctx, profile,
               live: {:ok, live},
               live_shape_digest: digest
             )

    # The NEW activation is what gets recorded on the run.
    assert stamp.activation_graph == live.graph
  end

  describe "the activation closure is part of the shape" do
    # The two halves of the same rule, and neither implies the other:
    # re-releasing the SOURCE must still ride an existing versionless
    # consent (that is what versionless means), while re-releasing a
    # DEPENDENCY must not (that is new code under an old grant).
    # The dep ref carries NO version. `Activation.resolve_dependency/2`
    # pins an explicit one and follows `latest_row/4` only for a
    # versionless ref — so a pinned dep cannot drift at all, and it is the
    # versionless one this rule is about.
    defp with_dep!(ctx, root_name, dep_name, dep_version, dep_reason) do
      publish!(ctx, dep_name, dep_version, %{
        manifest: Jason.encode!(roll_manifest(dep_reason))
      })

      publish!(ctx, root_name, "1.0.0", %{
        type: "formula",
        manifest:
          Jason.encode!(%{
            "dependencies" => %{
              "static" => [%{"ref" => "reagent:local.#{dep_name}"}]
            }
          })
      })
    end

    defp formula_head!(ctx, source_ref) do
      {:ok, [profile]} = Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), source_ref)
      {:ok, consent} = Arca.ConsentStorage.head_consent(Sanctum.Context.actor(ctx), profile.id)
      {profile, consent}
    end

    test "a dependency re-released with different code demands fresh consent", %{ctx: ctx} do
      with_dep!(ctx, "dep-root", "dep-leaf", "1.0.0", "original")
      {:ok, _} = Bootstrap.run(ctx)
      {profile, _consent} = formula_head!(ctx, "formula:local.dep-root")

      # The dependency's release digest moves; the ROOT's manifest is
      # untouched. Before the closure entered the shape this was
      # indistinguishable from a source re-release: the live shape came
      # from the root's registry row alone, so `Decision.compare/6`
      # answered `{:allow_record, …}` and ran the new leaf under the blob
      # frozen at consent time.
      publish!(ctx, "dep-leaf", "1.0.1", %{manifest: Jason.encode!(roll_manifest("reworded"))})

      {:ok, root} = Compendium.Registry.get_latest(ctx, "dep-root", "local", "formula")
      {:ok, live} = Compendium.Activation.resolve_verified(ctx, root)
      {:ok, digest} = ShapeDerivation.live_digest(ctx, "formula:local.dep-root")

      assert {:error, {:consent_required, payload}} =
               Loader.load_root(ctx, profile,
                 live: {:ok, live},
                 live_shape_digest: digest
               )

      assert payload.profile_id == profile.id
    end

    test "re-releasing the source itself still rides the consent", %{ctx: ctx} do
      with_dep!(ctx, "src-root", "src-leaf", "1.0.0", "original")
      {:ok, _} = Bootstrap.run(ctx)
      {profile, _consent} = formula_head!(ctx, "formula:local.src-root")

      # Same dependency, new root release. The activation digest moves and
      # the shape does not, so this is the `{:allow_record, …}` arm — the
      # one the closure change must NOT break, or every versionless
      # consent would re-prompt on every publish.
      publish!(ctx, "src-root", "1.0.1", %{
        type: "formula",
        manifest:
          Jason.encode!(%{
            "description" => "reworded",
            "dependencies" => %{
              "static" => [%{"ref" => "reagent:local.src-leaf"}]
            }
          })
      })

      {:ok, root} = Compendium.Registry.get_latest(ctx, "src-root", "local", "formula")
      {:ok, live} = Compendium.Activation.resolve_verified(ctx, root)
      {:ok, digest} = ShapeDerivation.live_digest(ctx, "formula:local.src-root")

      assert {:ok, _authority, stamp} =
               Loader.load_root(ctx, profile,
                 live: {:ok, live},
                 live_shape_digest: digest
               )

      assert stamp.activation_graph == live.graph
    end
  end

  test "without a live shape the same drift fails closed to consent_required", %{ctx: ctx} do
    publish!(ctx, "shape-dark", "1.0.0", %{manifest: Jason.encode!(roll_manifest("original"))})
    {:ok, _} = Bootstrap.run(ctx)
    {profile, _consent} = head!(ctx, "shape-dark" |> then(&"reagent:local.#{&1}"))

    publish!(ctx, "shape-dark", "1.0.1", %{manifest: Jason.encode!(roll_manifest("reworded"))})

    assert {:error, {:consent_required, payload}} =
             Loader.load_root(ctx, profile, live: {:ok, live!(ctx, "shape-dark")})

    assert payload.profile_id == profile.id
  end

  test "a changed shape under the same drift requires re-consent", %{ctx: ctx} do
    publish!(ctx, "shape-chg", "1.0.0")
    {:ok, _} = Bootstrap.run(ctx)
    {profile, consent} = head!(ctx, "reagent:local.shape-chg")

    # The new release declares more: its caps block asks for a tool the
    # empty-ask revision never carried, so the live shape moves away from
    # what revision 1 was shown.
    publish!(ctx, "shape-chg", "1.0.1", %{
      manifest: Jason.encode!(%{"caps" => %{"tools" => ["component.search"]}})
    })

    {:ok, live_digest} = ShapeDerivation.live_digest(ctx, "reagent:local.shape-chg")
    refute live_digest == consent.shape_digest

    assert {:error, {:consent_required, %{current_revision: 1}}} =
             Loader.load_root(ctx, profile,
               live: {:ok, live!(ctx, "shape-chg")},
               live_shape_digest: live_digest
             )
  end

  test "expand_tools is the bootstrap expansion, verbatim, but for what only an exact name grants",
       %{ctx: ctx} do
    _ = ctx
    catalog = Sanctum.Catalog.tool_actions()

    assert ShapeDerivation.expand_tools(["*"]) ==
             Enum.sort(Enum.uniq(catalog -- Caps.agent_only_tools()))

    assert ShapeDerivation.expand_tools(["component.*"]) ==
             Enum.sort(Enum.filter(catalog, &String.starts_with?(&1, "component.")))
  end

  describe "the layout's write" do
    test "is never granted by a pattern, and is by its exact name" do
      catalog = Sanctum.Catalog.tool_actions()
      assert "layout.edit" in catalog and "layout.get" in catalog

      for patterns <- [["*"], ["layout.*"], ["layout.*", "*", "component.*"]] do
        refute "layout.edit" in ShapeDerivation.expand_tools(patterns), inspect(patterns)
      end

      # Reading the layout follows its pattern as any tool's action does.
      assert ShapeDerivation.expand_tools(["layout.*"]) == ["layout.get"]

      # Named exactly, it is kept, beside a pattern too.
      assert ShapeDerivation.expand_tools(["layout.edit"]) == ["layout.edit"]

      assert ShapeDerivation.expand_tools(["layout.*", "layout.edit"]) ==
               ["layout.edit", "layout.get"]
    end

    test "is asked for by no node key but an agent's, whatever its stored manifest names", %{
      ctx: ctx
    } do
      # A manifest claiming to be an agent's, as a row stored before the
      # publish held a manifest's type would keep it.
      stored = %{"type" => "agent", "caps" => %{"tools" => ["layout.edit", "layout.get"]}}

      for node <- ~w(catalyst:local.arranger reagent:local.arranger formula:local.arranger) do
        assert {:ok, %{tools: ["layout.get"]}} = ShapeDerivation.declared_caps(stored, node),
               node

        assert {:ok, %{"tools" => ["layout.get"]}, _limits} =
                 Sanctum.Consent.BlobBuilder.node_grant(node, stored)
      end

      # An agent's key keeps it, named exactly; a pattern grants it to none.
      assert {:ok, %{tools: ["layout.edit", "layout.get"]}} =
               ShapeDerivation.declared_caps(stored, "agent:local.arranger")

      assert {:ok, %{"tools" => ["layout.edit", "layout.get"]}, _limits} =
               Sanctum.Consent.BlobBuilder.node_grant("agent:local.arranger", stored)

      for {node, type} <- [
            {"formula:local.arranger", "formula"},
            {"agent:local.arranger", "agent"}
          ],
          tools <- [["*"], ["layout.*"]] do
        manifest = %{"type" => type, "caps" => %{"tools" => tools}}

        assert {:ok, %{"tools" => granted}, _limits} =
                 Sanctum.Consent.BlobBuilder.node_grant(node, manifest)

        refute "layout.edit" in granted, "#{node} #{inspect(tools)}"
      end
    end
  end

  describe "a schedule write" do
    test "is never granted by a pattern, and is by its exact name; the schedule's other actions follow their pattern" do
      catalog = Sanctum.Catalog.tool_actions()
      writes = ["schedule.create", "schedule.update"]
      assert writes -- catalog == []

      for patterns <- [["*"], ["schedule.*"], ["schedule.*", "*", "component.*"]] do
        expanded = ShapeDerivation.expand_tools(patterns)
        for write <- writes, do: refute(write in expanded, "#{write} #{inspect(patterns)}")
      end

      assert ShapeDerivation.expand_tools(["schedule.*"]) ==
               Enum.sort(
                 for action <- catalog,
                     String.starts_with?(action, "schedule."),
                     action not in writes,
                     do: action
               )

      assert "schedule.list" in ShapeDerivation.expand_tools(["schedule.*"])

      assert ShapeDerivation.expand_tools(["schedule.create"]) == ["schedule.create"]

      assert ShapeDerivation.expand_tools(["schedule.update", "schedule.list"]) ==
               ["schedule.list", "schedule.update"]
    end

    test "is asked for by no node key but an agent's, whatever its stored manifest names", %{
      ctx: ctx
    } do
      stored = %{
        "type" => "agent",
        "caps" => %{"tools" => ["schedule.create", "schedule.update", "schedule.list"]}
      }

      for node <-
            ~w(catalyst:local.timer reagent:local.timer formula:local.timer tincture:local.timer) do
        assert {:ok, %{tools: ["schedule.list"]}} = ShapeDerivation.declared_caps(stored, node),
               node
      end

      assert {:ok, %{tools: tools}} = ShapeDerivation.declared_caps(stored, "agent:local.timer")
      assert Enum.sort(tools) == ["schedule.create", "schedule.list", "schedule.update"]

      for {node, type} <- [{"formula:local.timer", "formula"}, {"agent:local.timer", "agent"}],
          tools <- [["*"], ["schedule.*"]] do
        manifest = %{"type" => type, "caps" => %{"tools" => tools}}

        assert {:ok, %{"tools" => granted}, _limits} =
                 Sanctum.Consent.BlobBuilder.node_grant(node, manifest)

        refute "schedule.create" in granted, "#{node} #{inspect(tools)}"
        refute "schedule.update" in granted, "#{node} #{inspect(tools)}"
      end
    end
  end

  describe "a feed write" do
    test "is never granted by a pattern, and is by its exact name" do
      catalog = Sanctum.Catalog.tool_actions()
      assert "feed.bind" in catalog and "feed.remove" in catalog

      for patterns <- [["*"], ["feed.*"], ["feed.*", "*", "component.*"]] do
        expanded = ShapeDerivation.expand_tools(patterns)
        refute "feed.bind" in expanded, inspect(patterns)
        refute "feed.remove" in expanded, inspect(patterns)
      end

      # The feed tool's other actions follow its pattern as any tool's do.
      assert ShapeDerivation.expand_tools(["feed.*"]) == ["feed.list", "feed.press"]

      # Named exactly, by any caller, each is kept, beside a pattern too.
      assert ShapeDerivation.expand_tools(["feed.bind"]) == ["feed.bind"]

      assert ShapeDerivation.expand_tools(["feed.*", "feed.remove"]) ==
               ["feed.list", "feed.press", "feed.remove"]
    end

    test "a formula stored with a manifest claiming to be an agent is granted neither", %{
      ctx: ctx
    } do
      # A publish refuses a manifest naming another type than the published
      # one; a row stored before it did keeps its claim, and the grant reads
      # the type the row was registered as, never the manifest's own.
      manifest = %{
        "type" => "agent",
        "caps" => %{"tools" => ["feed.bind", "feed.remove", "feed.list"]}
      }

      assert {:error, {:manifest_identity_mismatch, _}} =
               Compendium.Registry.publish_bytes(ctx, Cyfr.Test.Guests.wasm(:formula), %{
                 name: "spoof",
                 version: "1.0.0",
                 type: "formula",
                 manifest: Jason.encode!(manifest)
               })

      assert {:error, :not_found} =
               Compendium.Registry.get(ctx, "spoof", "1.0.0", "local", "formula")

      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      digest = "sha256:" <> String.duplicate("5", 64)
      {:ok, release_digest} = Compendium.ReleaseDigest.compute(digest, manifest)

      assert {:ok, _} =
               Arca.ComponentStorage.insert_component(Sanctum.Context.actor(ctx), %{
                 id: Ecto.UUID.generate(),
                 name: "spoof",
                 version: "1.0.0",
                 component_type: "formula",
                 description: "A formula stored with an agent's manifest",
                 tags: "[]",
                 category: "test",
                 license: "MIT",
                 digest: digest,
                 release_digest: release_digest,
                 size: byte_size(@wasm),
                 exports: "[]",
                 manifest: Jason.encode!(manifest),
                 publisher: "local",
                 publisher_id: nil,
                 source: Compendium.Source.filesystem(),
                 signature_verified: false,
                 signer_identity: nil,
                 signer_issuer: nil,
                 inserted_at: now,
                 updated_at: now
               })

      {:ok, row} = Compendium.Registry.get(ctx, "spoof", "1.0.0", "local", "formula")
      {:ok, stored} = Prima.Manifest.decode_strict(row.manifest)
      assert stored["type"] == "agent"

      assert {:ok, %{"tools" => ["feed.list"]}, _limits} =
               Sanctum.Consent.BlobBuilder.node_grant("formula:local.spoof", stored)

      assert {:ok, %{tools: ["feed.list"]}} =
               ShapeDerivation.declared_caps(stored, "formula:local.spoof")

      assert {:ok, %{tool_actions: ["feed.list"]}} =
               ShapeDerivation.shape_input(ctx, "formula:local.spoof")

      # The same block on an agent's node keeps both.
      assert {:ok, %{tools: ["feed.bind", "feed.list", "feed.remove"]}} =
               ShapeDerivation.declared_caps(stored, "agent:local.spoof")
    end

    test "is in no component's grant from a pattern, an agent's included", %{ctx: ctx} do
      for {node, type} <- [{"formula:local.feeder", "formula"}, {"agent:local.feeder", "agent"}],
          tools <- [["*"], ["feed.*"]] do
        manifest = %{"type" => type, "caps" => %{"tools" => tools}}
        assert :ok = Prima.Manifest.Caps.validate(manifest, &Arca.Storage.valid_guest_path?/1)

        assert {:ok, %{"tools" => granted}, _limits} =
                 Sanctum.Consent.BlobBuilder.node_grant(node, manifest)

        refute "feed.bind" in granted, "#{node} #{inspect(tools)}"
        refute "feed.remove" in granted, "#{node} #{inspect(tools)}"
      end

      # An agent that names both exactly is granted both.
      manifest = %{"type" => "agent", "caps" => %{"tools" => ["feed.bind", "feed.remove"]}}

      assert {:ok, %{"tools" => ["feed.bind", "feed.remove"]}, _limits} =
               Sanctum.Consent.BlobBuilder.node_grant("agent:local.feeder", manifest)
    end
  end

  describe "manifest-sourced shapes" do
    @needs_caps_manifest %{
      "needs" => %{
        "api_key" => %{
          "type" => "api_key:anthropic.com",
          "reason" => "to call the API with your key",
          "fields" => ["ANTHROPIC_API_KEY"]
        }
      },
      "caps" => %{
        "egress" => %{"domains" => ["api.anthropic.com"]},
        "tools" => ["execution.run"],
        "limits" => %{"timeout" => "2m"}
      }
    }

    test "a needs/caps manifest sources the shape from its declarations", %{ctx: ctx} do
      publish!(ctx, "shape-caps", "1.0.0", %{manifest: Jason.encode!(@needs_caps_manifest)})

      {:ok, input} = ShapeDerivation.shape_input(ctx, "reagent:local.shape-caps")

      assert input.slots == ["api_key"]
      assert [%{name: "api_key", type: "api_key:anthropic.com"}] = input.needs
      assert input.tool_actions == ["execution.run"]
      assert input.caps["egress.domains"] == ["api.anthropic.com"]
      assert input.caps["limits.timeout"] == "2m"
      # Empty asks are omitted — declaring nothing and asking for nothing
      # are the same shape.
      refute Map.has_key?(input.caps, "egress.methods")
    end

    test "a manifest with neither block derives the empty ask", %{ctx: ctx} do
      publish!(ctx, "shape-empty", "1.0.0")

      {:ok, input} = ShapeDerivation.shape_input(ctx, "reagent:local.shape-empty")

      assert input.needs == []
      # Flows and connect origins are named even when none are declared.
      assert input.caps == %{"flows" => [], "tincture.connect" => []}
      assert input.slots == []
      assert input.tool_actions == []

      # Absent blocks and explicitly empty blocks are the same shape.
      publish!(ctx, "shape-empty-blocks", "1.0.0", %{
        manifest: Jason.encode!(%{"needs" => %{}, "caps" => %{}})
      })

      {:ok, explicit} = ShapeDerivation.shape_input(ctx, "reagent:local.shape-empty-blocks")
      assert Map.delete(input, :source_ref) == Map.delete(explicit, :source_ref)
    end

    test "a stored caps block the grammar does not admit is refused, never read as empty",
         %{ctx: ctx} do
      publish!(ctx, "shape-respelled", "1.0.0", %{
        manifest: Jason.encode!(%{"caps" => %{"storage" => %{"paths" => ["data/secrets/"]}}})
      })

      ref = "reagent:local.shape-respelled"

      assert {:ok, %{caps: %{"storage.paths" => ["data/secrets/"]}}} =
               ShapeDerivation.shape_input(ctx, ref)

      # A row the publish check refuses, written past it: the stored
      # spelling is damage to every reader.
      stored = Jason.encode!(%{"caps" => %{"storage" => %{"paths" => ["data//secrets/"]}}})

      {1, _} =
        Arca.Repo.update_all(
          Ecto.Query.from(c in Arca.Schemas.Component, where: c.name == "shape-respelled"),
          set: [manifest: stored]
        )

      Compendium.Registry.invalidate_executor_caches(ctx)

      assert {:error, {:corrupt, {:manifest, ^ref}}} = ShapeDerivation.shape_input(ctx, ref)
      assert {:error, {:corrupt, {:manifest, ^ref}}} = ShapeDerivation.manifest_blocks(ctx, ref)

      # The builder reads the ask the same way: refused, not asked for nothing.
      assert {:error, {:corrupt, {:manifest, ^ref}}} =
               Sanctum.Consent.BlobBuilder.node_grant(ref, Jason.decode!(stored))
    end

    test "the reason text is not shape — editing it keeps the digest", %{ctx: ctx} do
      publish!(ctx, "shape-prose", "1.0.0", %{manifest: Jason.encode!(@needs_caps_manifest)})
      {:ok, before_digest} = ShapeDerivation.live_digest(ctx, "reagent:local.shape-prose")

      reworded =
        put_in(@needs_caps_manifest, ["needs", "api_key", "reason"], "reworded entirely")

      publish!(ctx, "shape-prose", "1.1.0", %{manifest: Jason.encode!(reworded)})
      {:ok, after_digest} = ShapeDerivation.live_digest(ctx, "reagent:local.shape-prose")

      assert before_digest == after_digest
    end

    # A manifest declaring none of a need's attach rule, hosts, paths or
    # disclosure, and no provides block: its digest is the one it had
    # before they joined the shape.
    @pinned_manifest %{
      "needs" => %{
        "api_key" => %{
          "type" => "api_key:anthropic.com",
          "reason" => "to call the API with your key",
          "fields" => ["ANTHROPIC_API_KEY"]
        }
      },
      "caps" => %{
        "egress" => %{"domains" => ["api.anthropic.com"]},
        "limits" => %{"timeout" => "2m"}
      }
    }

    # The pinned digest is the shape's since flows and connect origins are
    # in every shape, empty or not.
    test "a manifest that declares none of what attaching added keeps its digest", %{ctx: ctx} do
      publish!(ctx, "shape-pinned", "1.0.0", %{manifest: Jason.encode!(@pinned_manifest)})

      assert {:ok, "sha256:e7ef02f63635370d827a19e5cfed0093748c290ef0c423233819df67075a2ecf"} =
               ShapeDerivation.live_digest(ctx, "reagent:local.shape-pinned")
    end

    test "a need's attach rule, hosts, paths and disclosure, and the provides block, each " <>
           "move the digest",
         %{ctx: ctx} do
      publish!(ctx, "shape-attach-dep", "1.0.0", %{
        manifest: %{
          "needs" => %{
            "database" => %{
              "type" => "api_key:supabase.co",
              "reason" => "to reach the database",
              "fields" => ["anon_key"],
              "attach" => %{"in" => "header", "name" => "apikey", "template" => "{value}"}
            }
          }
        }
      })

      with_dep =
        Map.put(@pinned_manifest, "dependencies", %{
          "static" => [%{"ref" => "reagent:local.shape-attach-dep"}]
        })

      need = ["needs", "api_key"]

      versions = [
        with_dep,
        put_in(with_dep, need ++ ["attach"], %{
          "in" => "header",
          "name" => "x-api-key",
          "template" => "{value}"
        }),
        put_in(with_dep, need ++ ["hosts"], ["api.anthropic.com"]),
        put_in(with_dep, need ++ ["paths"], ["/v1/"]),
        put_in(with_dep, need ++ ["disclose"], true),
        Map.put(with_dep, "provides", %{
          "reagent:local.shape-attach-dep" => %{
            "database" => %{
              "destination" => %{"hosts" => ["abc.supabase.co"]},
              "values" => %{"anon_key" => "eyJ-public"}
            }
          }
        }),
        Map.put(with_dep, "provides", %{
          "reagent:local.shape-attach-dep" => %{
            "database" => %{
              "destination" => %{"hosts" => ["xyz.supabase.co"]},
              "values" => %{"anon_key" => "eyJ-public"}
            }
          }
        })
      ]

      digests =
        for {manifest, index} <- Enum.with_index(versions) do
          publish!(ctx, "shape-attach", "1.0.#{index}", %{manifest: manifest})
          Arca.Cache.delete_match(:_)
          {:ok, digest} = ShapeDerivation.live_digest(ctx, "reagent:local.shape-attach")
          digest
        end

      assert length(Enum.uniq(digests)) == length(versions)

      # A false disclosure declares nothing: the digest of the version
      # before it.
      publish!(ctx, "shape-attach", "1.1.0", %{
        manifest: put_in(with_dep, need ++ ["disclose"], false)
      })

      Arca.Cache.delete_match(:_)
      assert {:ok, hd(digests)} == ShapeDerivation.live_digest(ctx, "reagent:local.shape-attach")
    end

    test "a caps edit moves the digest; bootstrap and live agree", %{ctx: ctx} do
      publish!(ctx, "shape-caps-drift", "1.0.0", %{manifest: Jason.encode!(@needs_caps_manifest)})
      {:ok, _} = Bootstrap.run(ctx)

      {_profile, consent} = head!(ctx, "reagent:local.shape-caps-drift")
      {:ok, live_digest} = ShapeDerivation.live_digest(ctx, "reagent:local.shape-caps-drift")
      assert consent.shape_digest == live_digest

      widened =
        put_in(
          @needs_caps_manifest,
          ["caps", "egress", "domains"],
          ["api.anthropic.com", "extra.example"]
        )

      publish!(ctx, "shape-caps-drift", "1.1.0", %{manifest: Jason.encode!(widened)})
      {:ok, drifted} = ShapeDerivation.live_digest(ctx, "reagent:local.shape-caps-drift")
      assert drifted != live_digest
    end

    test "a bootstrapped caps manifest loads through the production source", %{ctx: ctx} do
      publish!(ctx, "shape-caps-load", "1.0.0", %{manifest: Jason.encode!(@needs_caps_manifest)})
      {:ok, _} = Bootstrap.run(ctx)

      {profile, _consent} = head!(ctx, "reagent:local.shape-caps-load")

      {:ok, live_shape} = ShapeDerivation.live_digest(ctx, "reagent:local.shape-caps-load")

      assert {:ok, authority, _stamp} =
               Loader.load_root(ctx, profile,
                 live: {:ok, live!(ctx, "shape-caps-load")},
                 live_shape_digest: live_shape
               )

      # The blob's ingress edge carries the caps ask, not a policy read.
      assert authority.resources.egress.domains == ["api.anthropic.com"]
      assert authority.resources.egress.schemes == ["https"]
      assert authority.resources.tools == ["execution.run"]

      # And no vault pointer was minted — a needs manifest has no legacy
      # grants, so the entry appears only when the operator binds one.
      assert authority.resources.vault == nil
    end
  end

  describe "a tincture's frame declaration is part of the shape" do
    @frame %{
      "frame" => %{"capabilities" => ["pointer_lock"]},
      "actions" => ["execution.list"],
      "streams" => [%{"name" => "mcp_servers.changes"}]
    }

    defp tincture!(ctx, name, version, tincture) do
      manifest = %{
        "name" => name,
        "type" => "tincture",
        "version" => version,
        "publisher" => "local",
        "tincture" => Map.put(tincture, "entry", "index.html")
      }

      {:ok, _} =
        Arca.Test.UnitFixtures.ship_and_register!(ctx, "tincture", "local", name, version,
          manifest: manifest,
          files: [{"index.html", "<html></html>"}]
        )

      "tincture:local.#{name}"
    end

    test "a declaration's digest joins the shape as tincture_digest", %{ctx: ctx} do
      ref = tincture!(ctx, "shape-frame", "1.0.0", @frame)
      {:ok, input} = ShapeDerivation.shape_input(ctx, ref)

      {:ok, declaration} =
        Prima.Manifest.Tincture.from_manifest(%{"tincture" => @frame})

      assert input.tincture_digest == Prima.Manifest.Tincture.digest(declaration)
      assert {:ok, _} = Sanctum.Consent.ShapeDigest.compute(input)
    end

    test "a tincture that declares nothing carries no digest: its shape is unchanged", %{ctx: ctx} do
      ref = tincture!(ctx, "shape-frameless", "1.0.0", %{})
      {:ok, input} = ShapeDerivation.shape_input(ctx, ref)
      refute Map.has_key?(input, :tincture_digest)
    end

    test "a version that declares more changes the shape; one that declares the same keeps it",
         %{ctx: ctx} do
      ref = tincture!(ctx, "shape-frame-drift", "1.0.0", @frame)
      {:ok, before_digest} = ShapeDerivation.live_digest(ctx, ref)

      reordered = put_in(@frame, ["frame", "capabilities"], ["pointer_lock", "pointer_lock"])
      tincture!(ctx, "shape-frame-drift", "1.1.0", reordered)
      Arca.Cache.delete_match(:_)
      {:ok, same_digest} = ShapeDerivation.live_digest(ctx, ref)
      assert same_digest == before_digest

      wider = Map.update!(@frame, "actions", &["records.delete" | &1])
      tincture!(ctx, "shape-frame-drift", "1.2.0", wider)
      Arca.Cache.delete_match(:_)
      {:ok, wider_digest} = ShapeDerivation.live_digest(ctx, ref)
      refute wider_digest == before_digest
    end

    test "the shape digest refuses a tincture digest that is not one" do
      assert {:error, {:invalid_shape, :tincture_digest, _}} =
               Sanctum.Consent.ShapeDigest.compute(%{
                 scope: :versionless,
                 source_ref: "tincture:local.x",
                 tincture_digest: "md5:abc"
               })
    end
  end

  describe "a component's exits and flows are part of the shape" do
    @flowing %{
      "caps" => %{
        "egress" => %{"domains" => ["api.one.example"]},
        "flows" => [
          %{"from" => "filed", "to" => "api.one.example"},
          %{"from" => "pinned", "to" => "api.one.example"}
        ]
      }
    }

    test "each declared flow joins the shape, in one spelling whatever its order", %{ctx: ctx} do
      publish!(ctx, "shape-flows", "1.0.0", %{manifest: @flowing})
      {:ok, input} = ShapeDerivation.shape_input(ctx, "reagent:local.shape-flows")
      assert input.caps["flows"] == ["pinned>api.one.example", "filed>api.one.example"]
      {:ok, before_digest} = ShapeDerivation.live_digest(ctx, "reagent:local.shape-flows")

      reordered = update_in(@flowing, ["caps", "flows"], &(Enum.reverse(&1) ++ &1))
      publish!(ctx, "shape-flows", "1.1.0", %{manifest: reordered})
      Arca.Cache.delete_match(:_)
      assert {:ok, ^before_digest} = ShapeDerivation.live_digest(ctx, "reagent:local.shape-flows")

      # Another class to the same exit is another question, asked again.
      wider =
        update_in(
          @flowing,
          ["caps", "flows"],
          &[%{"from" => "outside", "to" => "api.one.example"} | &1]
        )

      publish!(ctx, "shape-flows", "1.2.0", %{manifest: wider})
      Arca.Cache.delete_match(:_)
      {:ok, wider_digest} = ShapeDerivation.live_digest(ctx, "reagent:local.shape-flows")
      refute wider_digest == before_digest

      # And a flow fewer is too.
      fewer = update_in(@flowing, ["caps", "flows"], &tl/1)
      publish!(ctx, "shape-flows", "1.3.0", %{manifest: fewer})
      Arca.Cache.delete_match(:_)
      {:ok, fewer_digest} = ShapeDerivation.live_digest(ctx, "reagent:local.shape-flows")
      refute fewer_digest in [before_digest, wider_digest]
    end

    test "a tincture's connect origins are exits of its frame, and join the shape", %{ctx: ctx} do
      ref =
        tincture!(ctx, "shape-origins", "1.0.0", %{
          "connect" => ["two.example.com", "one.example.com"]
        })

      {:ok, input} = ShapeDerivation.shape_input(ctx, ref)
      assert input.caps["tincture.connect"] == ["one.example.com", "two.example.com"]
      {:ok, before_digest} = ShapeDerivation.live_digest(ctx, ref)

      tincture!(ctx, "shape-origins", "1.1.0", %{
        "connect" => ["one.example.com", "three.example.com"]
      })

      Arca.Cache.delete_match(:_)
      {:ok, moved} = ShapeDerivation.live_digest(ctx, ref)
      refute moved == before_digest

      # A tincture that declares none names no origin, and says so.
      bare = tincture!(ctx, "shape-no-origins", "1.0.0", %{})
      {:ok, bare_input} = ShapeDerivation.shape_input(ctx, bare)
      assert bare_input.caps["tincture.connect"] == []
    end

    test "a component that declares no flow and no origin names both as empty, so a shape " <>
           "without the two keys is another digest",
         %{ctx: ctx} do
      publish!(ctx, "shape-flowless", "1.0.0", %{
        manifest: %{"caps" => %{"egress" => %{"domains" => ["api.example.test"]}}}
      })

      {:ok, input} = ShapeDerivation.shape_input(ctx, "reagent:local.shape-flowless")
      assert input.caps["flows"] == []
      assert input.caps["tincture.connect"] == []

      # The same shape without the two keys digests differently, so a
      # consent to it does not answer for this shape.
      {:ok, digest} = Sanctum.Consent.ShapeDigest.compute(input)

      {:ok, without_keys} =
        Sanctum.Consent.ShapeDigest.compute(%{
          input
          | caps: Map.drop(input.caps, ["flows", "tincture.connect"])
        })

      refute digest == without_keys
    end
  end

  describe "a vault need names its projection" do
    defp fieldless(need_type, fields) do
      need = %{"type" => need_type, "reason" => "to call the API with your key"}
      need = if fields == :absent, do: need, else: Map.put(need, "fields", fields)
      %{"needs" => %{"api_key" => need}}
    end

    test "a need without its list, or with an empty one, is refused as a manifest error",
         %{ctx: ctx} do
      for {name, manifest} <- [
            {"shape-nofields", fieldless("api_key:example.com", :absent)},
            {"shape-emptyfields", fieldless("api_key:example.com", [])},
            {"shape-oauth-noscopes", fieldless("oauth:google", :absent)},
            {"shape-oauth-emptyscopes",
             put_in(fieldless("oauth:google", :absent), ["needs", "api_key", "scopes"], [])},
            {"shape-bundle-nofields", fieldless("bundle:example.com", [])}
          ] do
        publish!(ctx, name, "1.0.0", %{manifest: Jason.encode!(manifest)})
        ref = "reagent:local.#{name}"

        assert {:error, {:invalid_argument, message} = reason} =
                 ShapeDerivation.shape_input(ctx, ref)

        # The sentence names the component and the need, and renders as is.
        assert message =~ ref
        assert message =~ ~s("api_key")

        assert %Prima.Refusal{class: :invalid_argument, message: ^message} =
                 Prima.Refusal.classify(reason)

        # The live shape refuses the same way, so a load fails closed.
        assert ShapeDerivation.live_digest(ctx, ref) == {:error, reason}
      end
    end

    test "a fieldless need is refused at consent time and mints nothing", %{ctx: ctx} do
      publish!(ctx, "shape-nofields-mint", "1.0.0", %{
        manifest: Jason.encode!(fieldless("api_key:example.com", :absent))
      })

      ref = "reagent:local.shape-nofields-mint"

      assert {:error, {:invalid_argument, _message}} =
               Sanctum.Consent.Plan.plan(ctx, %{ref: ref})

      {:ok, _} = Bootstrap.run(ctx)
      assert {:ok, []} = Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), ref)
    end

    test "an OAuth need's projection is its scopes; it needs no fields", %{ctx: ctx} do
      manifest =
        put_in(fieldless("oauth:google", :absent), ["needs", "api_key", "scopes"], ["b", "a"])

      publish!(ctx, "shape-oauth-scopes", "1.0.0", %{manifest: Jason.encode!(manifest)})
      {:ok, input} = ShapeDerivation.shape_input(ctx, "reagent:local.shape-oauth-scopes")

      assert [%{name: "api_key", fields: [], scopes: ["a", "b"]}] = input.needs
    end

    test "every derived vault need row carries its declared fields", %{ctx: ctx} do
      manifest = %{
        "needs" => %{
          "api_key" => %{
            "type" => "api_key:example.com",
            "reason" => "to call the API with your key",
            "fields" => ["ORG", "KEY"]
          }
        }
      }

      publish!(ctx, "shape-fields", "1.0.0", %{manifest: Jason.encode!(manifest)})
      {:ok, input} = ShapeDerivation.shape_input(ctx, "reagent:local.shape-fields")

      assert [%{name: "api_key", fields: ["KEY", "ORG"]}] = input.needs
    end
  end

  describe "a stored manifest that does not decode" do
    # A row altered outside the publish path: its manifest column holds
    # bytes that are not JSON. The real facts port hands consent those
    # bytes as storage holds them.
    defp corrupt_manifest!(name) do
      {1, _} =
        Ecto.Query.from(c in Arca.Schemas.Component, where: c.name == ^name)
        |> Arca.Repo.update_all(set: [manifest: ~s({"needs": {"api_key": )])

      :ok
    end

    test "has no shape: every entry refuses it as corrupt, never the empty ask", %{ctx: ctx} do
      publish!(ctx, "shape-corrupt", "1.0.0", %{manifest: Jason.encode!(@needs_caps_manifest)})
      corrupt_manifest!("shape-corrupt")

      ref = "reagent:local.shape-corrupt"
      refusal = {:error, {:corrupt, {:manifest, ref}}}

      assert ShapeDerivation.shape_input(ctx, ref) == refusal
      assert ShapeDerivation.manifest_blocks(ctx, ref) == refusal
      assert ShapeDerivation.live_digest(ctx, ref) == refusal

      {:ok, row} = Sanctum.Consent.Components.get_latest(ctx, "shape-corrupt", "local", "reagent")
      assert ShapeDerivation.dependency_releases(ctx, row, ref) == refusal

      assert %Prima.Refusal{class: :corrupt, message: "The stored manifest is damaged."} =
               Prima.Refusal.classify({:corrupt, {:manifest, ref}})
    end

    test "reads as corrupt consent, not as a component that asks for nothing", %{ctx: ctx} do
      publish!(ctx, "shape-corrupt-status", "1.0.0")
      corrupt_manifest!("shape-corrupt-status")

      assert Aqua.ConsentStatus.state(ctx, "reagent:local.shape-corrupt-status") ==
               {:error, :corrupt}
    end

    test "the registry's own reads hand over the stored bytes, which a strict reader refuses",
         %{ctx: ctx} do
      publish!(ctx, "shape-corrupt-registry", "1.0.0")
      corrupt_manifest!("shape-corrupt-registry")

      for read <- [
            Compendium.Registry.get_latest(ctx, "shape-corrupt-registry", "local", "reagent"),
            Compendium.Registry.get(ctx, "shape-corrupt-registry", "1.0.0", "local", "reagent")
          ] do
        assert {:ok, %{manifest: stored}} = read
        assert is_binary(stored)
        assert Prima.Manifest.decode_strict(stored) == {:error, :malformed_manifest}
      end
    end
  end
end
