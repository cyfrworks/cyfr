# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.CanvasTest do
  @moduledoc """
  A person's canvases as components (`Compendium.Canvas`). A write checks
  the declaration before anything is allocated, allocates one patch above
  every version allocated, installed or shipped, then creates that
  version whole and registers it, never replacing one; two writes from
  one read get distinct versions or one conflict. An activation spends
  the trial's validation credential first, whatever the outcome, re-checks
  the tincture's grant for a tree, and publishes the versions document at
  the revision it read: two activations over one revision publish one, a
  member that lost its slot activates nothing, and a tree for the version
  already working changes nothing. A restore makes the kept version the
  working one under today's grant. The catalog is what a canvas may read,
  derived from the stream table.

  Racing writers are held after they read the versions document, observed
  through the repository's query telemetry, and released together: both
  have read one revision before either publishes, on either adapter.
  """

  # Writes platform settings, the control plane's standing record and the
  # storage paths, each restored when the case ends; holds racing writers
  # through a telemetry handler of its own.
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Arca.CanvasVersions
  alias Arca.Schemas.{CellLease, FrameCredential}
  alias Compendium.Canvas
  alias Compendium.ComponentPath
  alias Sanctum.Context
  alias Sanctum.Test.ConsentFixtures
  alias Sanctum.TinctureAuth

  @name "markets"
  @reference "tincture:local.markets"
  @athanor "ath_test"
  @module ~S|export default function (canvas) { canvas.render({type: "text", value: "hi"}) }|

  @keys [
    {Arca.ControlPlane, :standing},
    {Arca.ControlPlane, :generation},
    {Arca.ControlPlane, :slot}
  ]

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    Arca.Cache.init()

    base = Path.join(System.tmp_dir!(), "canvas_#{System.unique_integer([:positive])}")
    prev_base = Application.fetch_env!(:arca, :base_path)
    prev_seed = Application.fetch_env!(:arca, :seed_path)
    Application.put_env(:arca, :base_path, Path.join(base, "data"))
    Application.put_env(:arca, :seed_path, Path.join(base, "seed"))
    File.mkdir_p!(Path.join([base, "seed", "components"]))

    on_exit(fn ->
      Application.put_env(:arca, :base_path, prev_base)
      Application.put_env(:arca, :seed_path, prev_seed)
      File.rm_rf!(base)
    end)

    settings!()
    {:ok, ctx: person_ctx!()}
  end

  # ---------------------------------------------------------------------------
  # canvas.write
  # ---------------------------------------------------------------------------

  describe "write" do
    test "writes the next version whole and registers it, and activates nothing", %{ctx: ctx} do
      assert {:ok, %{canvas: @name, version: "0.1.0", reference: reference}} =
               Canvas.write(ctx, write_args())

      assert reference == "tincture:local.markets:0.1.0"

      # Exactly the manifest and the module; the manifest is a canvas's declaration.
      assert {:ok, files} = Arca.list_typed(actor(ctx), version_dir("0.1.0"))
      assert Enum.sort(files) == [{"canvas.js", :file}, {"cyfr-manifest.json", :file}]
      assert {:ok, @module} = Arca.get(actor(ctx), version_dir("0.1.0") ++ ["canvas.js"])

      {:ok, manifest} = Arca.get(actor(ctx), version_dir("0.1.0") ++ ["cyfr-manifest.json"])

      assert Jason.decode!(manifest) == %{
               "type" => "tincture",
               "name" => @name,
               "version" => "0.1.0",
               "tincture" => %{
                 "frame" => %{"placement" => "canvas"},
                 "canvas" => %{"module" => "canvas.js", "toolkit" => 1},
                 "streams" => []
               }
             }

      # Registered, released, and served from its module.
      assert {:ok, %{"release_digest" => "sha256:" <> _}} =
               Compendium.inspect_component(ctx, reference)

      # Allocated, and nothing working: a glass validates it first.
      assert %{document: %{allocated: "0.1.0", working: nil, kept: nil}, revision: 1} =
               versions!(ctx)

      # The next write is the next version; the first is left as it was.
      assert {:ok, %{version: "0.1.1"}} = Canvas.write(ctx, write_args(module: "// two"))
      assert {:ok, @module} = Arca.get(actor(ctx), version_dir("0.1.0") ++ ["canvas.js"])
      assert {:ok, "// two"} = Arca.get(actor(ctx), version_dir("0.1.1") ++ ["canvas.js"])
      assert %{document: %{allocated: "0.1.1", working: nil}, revision: 2} = versions!(ctx)
    end

    test "allocates one patch above every version allocated, installed or shipped", %{ctx: ctx} do
      Arca.Test.UnitFixtures.seed_component!("tincture", "local", @name, "0.4.2",
        manifest: canvas_manifest("0.4.2"),
        files: [{"canvas.js", "// shipped"}]
      )

      assert {:ok, %{version: "0.4.3"}} = Canvas.write(ctx, write_args())

      # An allocation the document records, past every version there is.
      %{document: document, revision: revision} = versions!(ctx)

      {:ok, _} =
        CanvasVersions.publish(actor(ctx), @name, %{document | allocated: "0.9.0"}, revision)

      assert {:ok, %{version: "0.9.1"}} = Canvas.write(ctx, write_args())

      # An installed version past the document's allocation.
      %{document: document, revision: revision} = versions!(ctx)
      {:ok, _} = CanvasVersions.publish(actor(ctx), @name, %{document | allocated: nil}, revision)
      assert {:ok, %{version: "0.9.2"}} = Canvas.write(ctx, write_args())
    end

    test "a refused write allocates nothing", %{ctx: ctx} do
      four_byte = "𝄞"
      assert byte_size(four_byte) == 4
      over_in_bytes = String.duplicate(four_byte, div(Canvas.module_max_bytes(), 4) + 1)
      assert String.length(over_in_bytes) < Canvas.module_max_bytes()

      refused = [
        write_args(name: "Markets"),
        write_args(name: "../markets"),
        write_args(name: ""),
        write_args(name: nil),
        write_args(module: String.duplicate("a", Canvas.module_max_bytes() + 1)),
        write_args(module: over_in_bytes),
        write_args(module: <<0xFF, 0xFE>>),
        write_args(module: nil),
        write_args(streams: "runs.changes"),
        write_args(streams: [%{"name" => 7}]),
        write_args(streams: [%{"name" => "runs.changes", "extra" => true}]),
        write_args(streams: [%{"name" => "vault.changes"}]),
        write_args(streams: [%{"name" => "mcp_servers.changes"}])
      ]

      for args <- refused do
        assert {:error, {:invalid_argument, sentence}} = Canvas.write(ctx, args),
               inspect(Map.delete(args, "module"))

        assert is_binary(sentence)
      end

      assert {:error, {:invalid_argument, sentence}} =
               Canvas.write(ctx, write_args(streams: [%{"name" => "mcp_servers.changes"}]))

      assert sentence =~ "mcp_servers.changes, which a canvas cannot read"

      assert {:error, {:invalid_argument, _}} =
               Canvas.write(ctx, Map.delete(write_args(), "module"))

      assert {:error, :not_found} = CanvasVersions.get(actor(ctx), @name)
      assert {:error, {:not_found, "Canvas", @name}} = Canvas.versions(ctx, @name)

      # At the bound, a module is written.
      exact = String.duplicate("a", Canvas.module_max_bytes())
      assert {:ok, %{version: "0.1.0"}} = Canvas.write(ctx, write_args(module: exact))
    end

    test "a name installed as a tincture that is no canvas is a conflict, and allocates nothing",
         %{ctx: ctx} do
      install!(ctx, "notes", "1.0.0", %{
        "entry" => "index.html",
        "frame" => %{"placement" => "float"}
      })

      assert {:error, {:conflict, sentence}} = Canvas.write(ctx, write_args(name: "notes"))
      assert sentence =~ "tincture:local.notes"
      assert {:error, :not_found} = CanvasVersions.get(actor(ctx), "notes")
      assert {:error, {:not_found, "Canvas", "notes"}} = Canvas.versions(ctx, "notes")
    end

    test "two synchronized writes from one newest version get distinct versions or one conflict, " <>
           "and no version's bytes are replaced",
         %{ctx: ctx} do
      {:ok, %{version: "0.1.0"}} = Canvas.write(ctx, write_args(module: "// first"))
      %{revision: read} = versions!(ctx)
      hold_after_read!()

      answers =
        race([
          fn -> Canvas.write(ctx, write_args(module: "// left")) end,
          fn -> Canvas.write(ctx, write_args(module: "// right")) end
        ])

      versions = for {:ok, %{version: version}} <- answers, do: version
      conflicts = for {:error, {:conflict, _}} <- answers, do: :conflict

      assert {length(versions), length(conflicts)} in [{2, 0}, {1, 1}]
      assert Enum.uniq(versions) == versions

      # Both read one revision, so one publishes and the other is refused.
      assert versions == ["0.1.1"]
      assert %{document: %{allocated: "0.1.1"}, revision: revision} = versions!(ctx)
      assert revision == read + 1

      # The winner's bytes are the version's; the loser wrote nothing; the
      # first version is as it was.
      {:ok, written} = Arca.get(actor(ctx), version_dir("0.1.1") ++ ["canvas.js"])
      assert written in ["// left", "// right"]
      assert {:ok, "// first"} = Arca.get(actor(ctx), version_dir("0.1.0") ++ ["canvas.js"])

      {:ok, dirs} =
        Arca.list_typed(actor(ctx), ComponentPath.name_dir("tincture", "local", @name))

      assert Enum.sort(for {version, :dir} <- dirs, do: version) == ["0.1.0", "0.1.1"]
    end
  end

  # ---------------------------------------------------------------------------
  # canvas.activate
  # ---------------------------------------------------------------------------

  describe "activate" do
    test "activation consumes its validation credential once", %{ctx: ctx} do
      v1 = write!(ctx)
      trial = trial!(ctx, v1)

      assert {:ok, %{activated: true, version: ^v1, document: document, revision: revision}} =
               activate(ctx, v1, trial.frame)

      assert document == %{CanvasVersions.empty() | allocated: v1, working: v1}
      assert %{document: ^document, revision: ^revision} = versions!(ctx)
      assert %FrameCredential{state: "revoked"} = Arca.Repo.get(FrameCredential, trial.id)

      assert {:error, %Prima.Refusal{class: :forbidden, reason: :not_validated, message: message}} =
               activate(ctx, v1, trial.frame)

      assert String.ends_with?(message, "(not_validated)")
      assert %{revision: ^revision} = versions!(ctx)

      # Every outcome spends it: a failed trial records its failure once.
      v2 = write!(ctx)

      for outcome <- ["no_tree", "died"] do
        failed = trial!(ctx, v2)

        assert {:ok, %{activated: false, document: %{failed: failure} = document}} =
                 activate(ctx, v2, failed.frame, outcome)

        assert %{version: ^v2, outcome: ^outcome, at: at} = failure
        assert {:ok, at_time, 0} = DateTime.from_iso8601(at)
        assert at == DateTime.to_iso8601(DateTime.truncate(at_time, :second))
        assert %{working: ^v1, kept: nil} = document

        assert {:error, %Prima.Refusal{reason: :not_validated}} =
                 activate(ctx, v2, failed.frame, outcome)
      end

      # A credential minted for one version activates no other, and is
      # left unspent.
      other = trial!(ctx, v1)

      assert {:error, %Prima.Refusal{class: :forbidden, reason: :not_validated}} =
               activate(ctx, v2, other.frame)

      assert %FrameCredential{state: "active"} = Arca.Repo.get(FrameCredential, other.id)

      # A version that is no installed canvas version is not found, and
      # spends nothing.
      assert {:error, {:not_found, "Canvas version", "markets 9.9.9"}} =
               activate(ctx, "9.9.9", other.frame)

      assert %FrameCredential{state: "active"} = Arca.Repo.get(FrameCredential, other.id)
    end

    test "a tree for the version already working publishes nothing, and kept keeps its value",
         %{ctx: ctx} do
      v1 = write!(ctx)
      {:ok, _} = activate(ctx, v1, trial!(ctx, v1).frame)
      v2 = write!(ctx)
      {:ok, _} = activate(ctx, v2, trial!(ctx, v2).frame)

      %{document: before, revision: revision} = versions!(ctx)
      assert %{working: ^v2, kept: ^v1} = before

      again = trial!(ctx, v2)

      assert {:ok, %{activated: true, document: ^before, revision: ^revision}} =
               activate(ctx, v2, again.frame)

      assert %{document: ^before, revision: ^revision} = versions!(ctx)
      assert %FrameCredential{state: "revoked"} = Arca.Repo.get(FrameCredential, again.id)
    end

    test "a tree for a version older than the working one answers conflict and changes nothing",
         %{ctx: ctx} do
      # Versions whose string order is not their version order.
      {:ok, 1} =
        CanvasVersions.publish(
          actor(ctx),
          @name,
          %{CanvasVersions.empty() | allocated: "0.1.8"},
          0
        )

      older = write!(ctx)
      newer = write!(ctx)
      assert {older, newer} == {"0.1.9", "0.1.10"}
      assert older > newer

      {:ok, _} = activate(ctx, newer, trial!(ctx, newer).frame)
      {:ok, before} = CanvasVersions.get(actor(ctx), @name)
      assert %{working: ^newer, kept: nil} = before.document

      late = trial!(ctx, older)

      assert {:error, {:conflict, sentence}} = activate(ctx, older, late.frame)

      assert sentence ==
               "a newer version of canvas markets is working (0.1.10), so 0.1.9 is not activated"

      # Spent and checked, and the document is as it was, byte for byte.
      assert %FrameCredential{state: "revoked"} = Arca.Repo.get(FrameCredential, late.id)
      assert {:ok, ^before} = CanvasVersions.get(actor(ctx), @name)

      # A failed trial of the older version is still recorded.
      failed = trial!(ctx, older)

      assert {:ok, %{activated: false, document: %{working: ^newer, kept: nil, failed: failure}}} =
               activate(ctx, older, failed.frame, "no_tree")

      assert %{version: ^older, outcome: "no_tree"} = failure
    end

    test "two activations over one revision publish one", %{ctx: ctx} do
      v1 = write!(ctx)
      v2 = write!(ctx)
      t1 = trial!(ctx, v1)
      t2 = trial!(ctx, v2)
      %{revision: read} = versions!(ctx)
      hold_after_read!()

      answers =
        race([
          fn -> activate(ctx, v1, t1.frame) end,
          fn -> activate(ctx, v2, t2.frame) end
        ])

      assert [{:ok, %{version: winner}}] = for({:ok, _} = ok <- answers, do: ok)
      assert [{:error, {:conflict, _}}] = for({:error, _} = refused <- answers, do: refused)

      # The winner is working; the loser is neither working nor kept.
      assert %{document: %{working: ^winner, kept: nil}, revision: revision} = versions!(ctx)
      assert revision == read + 1

      # Both spent their credentials: a refused publication is no trial
      # to report twice.
      for trial <- [t1, t2],
          do:
            assert(%FrameCredential{state: "revoked"} = Arca.Repo.get(FrameCredential, trial.id))
    end

    test "a member that lost its slot activates nothing", %{ctx: ctx} do
      slot = claimant!()
      v1 = write!(ctx)
      %{document: before, revision: revision} = versions!(ctx)

      # Lost before the credential is spent: nothing is spent or published.
      lost_early = trial!(ctx, v1)
      take_over!(slot, 1)

      assert {:error, :not_owner} = activate(ctx, v1, lost_early.frame)
      assert %FrameCredential{state: "active"} = Arca.Repo.get(FrameCredential, lost_early.id)
      assert %{document: ^before, revision: ^revision} = versions!(ctx)

      # Lost after the document is read: the credential is spent, and the
      # publication is refused.
      slot = claimant!()
      lost_late = trial!(ctx, v1)
      hold_after_read!()

      task = Task.async(fn -> paused(fn -> activate(ctx, v1, lost_late.frame) end) end)
      assert_receive {:read_versions, reader}, 15_000
      take_over!(slot, 1)
      send(reader, :go)

      assert {:error, :not_owner} = Task.await(task, 30_000)
      assert %{document: ^before, revision: ^revision} = versions!(ctx)
    end

    test "activation re-checks the grant though validation ran under it", %{ctx: ctx} do
      v1 = write!(ctx)
      owner_profile!(ctx, :active)
      assert {:ok, 1} = Compendium.tincture_grant_revision(ctx, @reference)
      trial = trial!(ctx, v1)

      # The owner profile waits for the person again: nothing activates.
      owner_profile!(ctx, :needs_consent)
      assert {:error, :ungranted} = Compendium.tincture_grant_revision(ctx, @reference)

      %{revision: revision} = versions!(ctx)
      assert {:error, :consent_required} = activate(ctx, v1, trial.frame)
      assert %{document: %{working: nil}, revision: ^revision} = versions!(ctx)

      # The credential was spent first, so a second report needs a trial.
      assert %FrameCredential{state: "revoked"} = Arca.Repo.get(FrameCredential, trial.id)

      # A failed trial records its failure whatever the grant.
      failed = trial!(ctx, v1, 1)
      assert {:ok, %{activated: false}} = activate(ctx, v1, failed.frame, "no_tree")

      owner_profile!(ctx, :active)
      assert {:ok, %{activated: true}} = activate(ctx, v1, trial!(ctx, v1).frame)
    end

    test "activation names a frame id, never a bearer, in its arguments, its audit record and " <>
           "its refusals",
         %{ctx: ctx} do
      v1 = write!(ctx)
      trial = trial!(ctx, v1)

      [tool] = Compendium.Providers.Canvas.tools()
      activate = Enum.find(tool.operations, &(&1.action == "activate"))
      assert Enum.map(activate.args, & &1.name) == ~w(canvas version frame outcome)

      args = %{"canvas" => @name, "version" => v1, "frame" => trial.frame, "outcome" => "tree"}
      gate = Sanctum.TestContext.via(ctx, :prism)

      assert {:ok, _} =
               Grimoire.call_external("canvas", gate, Map.put(args, "action", "activate"))

      assert {:error, %Prima.Refusal{class: :forbidden} = refusal} =
               Grimoire.call_external("canvas", gate, Map.put(args, "action", "activate"))

      refute refusal.message =~ trial.bearer
      refute refusal.message =~ trial.frame

      rows =
        Arca.Repo.all(
          from(l in Arca.Schemas.McpLog,
            where: l.athanor_id == ^@athanor and l.tool == "canvas" and l.action == "activate"
          )
        )

      assert length(rows) == 2
      assert Enum.all?(rows, &(&1.input =~ trial.frame))

      decisions =
        Arca.Repo.all(
          from(d in Arca.Schemas.DecisionLog,
            where: d.athanor_id == ^@athanor and d.tool == "canvas"
          )
        )

      for row <- rows ++ decisions,
          value <- Map.values(Map.from_struct(row)),
          is_binary(value),
          do: refute(value =~ trial.bearer)

      # A bearer where the frame id goes is refused without an echo, and
      # spends nothing.
      unspent = trial!(ctx, v1)

      for refused <- [
            activate(ctx, v1, unspent.bearer),
            activate(ctx, v1, unspent.frame <> "/" <> unspent.bearer)
          ] do
        assert {:error, reason} = refused
        refute inspect(reason) =~ unspent.bearer
      end

      assert %FrameCredential{state: "active"} = Arca.Repo.get(FrameCredential, unspent.id)
    end

    test "the refusals of the credential's spend are the operation's", %{ctx: ctx} do
      v1 = write!(ctx)
      trial = trial!(ctx, v1)
      {:ok, framed} = Sanctum.Caller.establish({:frame_credential, trial.bearer})

      assert {:error, %Prima.Refusal{class: :forbidden, reason: :not_primary, message: message}} =
               activate(framed, v1, trial.frame)

      assert String.ends_with?(message, "(not_primary)")
      assert %FrameCredential{state: "active"} = Arca.Repo.get(FrameCredential, trial.id)

      for {args, sentence} <- [
            {%{"version" => "1.0"}, "a canvas version is MAJOR.MINOR.PATCH"},
            {%{"outcome" => "maybe"}, "the outcome is one of tree, no_tree, died"},
            {%{"canvas" => "Markets"}, "a canvas's name"}
          ] do
        assert {:error, {:invalid_argument, said}} =
                 Canvas.activate(
                   ctx,
                   Map.merge(
                     %{
                       "canvas" => @name,
                       "version" => v1,
                       "frame" => trial.frame,
                       "outcome" => "tree"
                     },
                     args
                   )
                 )

        assert said =~ sentence
      end

      assert %FrameCredential{state: "active"} = Arca.Repo.get(FrameCredential, trial.id)
    end
  end

  # ---------------------------------------------------------------------------
  # canvas.restore
  # ---------------------------------------------------------------------------

  describe "restore" do
    test "a kept version whose grant moved answers consent_required", %{ctx: ctx} do
      owner_profile!(ctx, :active)
      v1 = write!(ctx)
      {:ok, _} = activate(ctx, v1, trial!(ctx, v1, 1).frame)
      v2 = write!(ctx)
      {:ok, _} = activate(ctx, v2, trial!(ctx, v2, 1).frame)
      %{document: before, revision: revision} = versions!(ctx)
      assert %{working: ^v2, kept: ^v1} = before

      # The grant the kept version was kept under is not today's.
      owner_profile!(ctx, :needs_consent)
      assert {:error, :consent_required} = Canvas.restore(ctx, @name)
      assert %{document: ^before, revision: ^revision} = versions!(ctx)

      owner_profile!(ctx, :active)
      assert {:ok, %{document: restored, revision: published}} = Canvas.restore(ctx, @name)
      assert %{working: ^v1, kept: ^v2} = restored
      assert published == revision + 1
      assert %{document: ^restored} = versions!(ctx)

      # Restoring again is the way forward to the version it replaced.
      assert {:ok, %{document: %{working: ^v2, kept: ^v1}}} = Canvas.restore(ctx, @name)
    end

    test "a canvas with no kept version is not found", %{ctx: ctx} do
      assert {:error, {:not_found, "Kept version of canvas", @name}} = Canvas.restore(ctx, @name)

      v1 = write!(ctx)
      assert {:error, {:not_found, "Kept version of canvas", @name}} = Canvas.restore(ctx, @name)

      {:ok, _} = activate(ctx, v1, trial!(ctx, v1).frame)
      assert {:error, {:not_found, "Kept version of canvas", @name}} = Canvas.restore(ctx, @name)
      assert %{document: %{working: ^v1, kept: nil}} = versions!(ctx)

      assert {:error, {:invalid_argument, _}} = Canvas.restore(ctx, "../markets")
    end

    test "a restore racing an activation is one conflict", %{ctx: ctx} do
      v1 = write!(ctx)
      {:ok, _} = activate(ctx, v1, trial!(ctx, v1).frame)
      v2 = write!(ctx)
      {:ok, _} = activate(ctx, v2, trial!(ctx, v2).frame)
      v3 = write!(ctx)
      t3 = trial!(ctx, v3)
      %{revision: read} = versions!(ctx)
      hold_after_read!()

      answers =
        race([
          fn -> activate(ctx, v3, t3.frame) end,
          fn -> Canvas.restore(ctx, @name) end
        ])

      assert [{:ok, _}] = for({:ok, _} = ok <- answers, do: ok)
      assert [{:error, {:conflict, _}}] = for({:error, _} = refused <- answers, do: refused)

      assert %{document: document, revision: revision} = versions!(ctx)
      assert revision == read + 1

      assert {document.working, document.kept} in [{v3, v2}, {v1, v2}]
    end
  end

  # ---------------------------------------------------------------------------
  # canvas.versions and canvas.catalog
  # ---------------------------------------------------------------------------

  describe "versions" do
    test "answers the document and its revision, the empty one for a canvas installed without " <>
           "one, and not_found for a name with no installed canvas",
         %{ctx: ctx} do
      install!(ctx, "weather", "1.0.0", %{
        "frame" => %{"placement" => "canvas"},
        "canvas" => %{"module" => "canvas.js", "toolkit" => 1}
      })

      assert {:ok, %{canvas: "weather", document: document, revision: 0}} =
               Canvas.versions(ctx, "weather")

      assert document == CanvasVersions.empty()
      assert Compendium.canvas_versions(ctx, "weather") == Canvas.versions(ctx, "weather")

      install!(ctx, "notes", "1.0.0", %{"entry" => "index.html"})
      assert {:error, {:not_found, "Canvas", "notes"}} = Canvas.versions(ctx, "notes")
      assert {:error, {:not_found, "Canvas", "absent"}} = Canvas.versions(ctx, "absent")
      assert {:error, {:invalid_argument, _}} = Canvas.versions(ctx, "No Such")

      v1 = write!(ctx)

      assert {:ok, %{canvas: @name, document: %{allocated: ^v1}, revision: 1}} =
               Compendium.canvas_versions(ctx, @name)
    end
  end

  describe "catalog" do
    test "is the toolkit majors and every stream that declares a shape, by name, and no value",
         %{ctx: ctx} do
      shaped =
        for %Prima.Provider.Stream{shape: shape} = stream <- Grimoire.streams(), shape != nil do
          %{
            name: stream.name,
            subject: stream.subject,
            shape: shape,
            filter: stream.filter,
            refresh: stream.refresh != nil
          }
        end

      assert {:ok, %{toolkit: [1], streams: streams} = catalog} = Canvas.catalog(ctx)
      assert streams == Enum.sort_by(shaped, & &1.name)
      assert Compendium.canvas_catalog(ctx) == {:ok, catalog}
      assert catalog.toolkit == Compendium.tincture_toolkit_majors()

      # A canvas reads exactly a feed's results, by the feed's name, and
      # the athanor's runs; every other stream declares no shape.
      assert [
               %{
                 name: "feed.results",
                 subject: ~S"\A[a-z0-9][a-z0-9-]{0,47}\z",
                 shape: %{"type" => "object", "fields" => feed_fields},
                 filter: "feed",
                 refresh: true
               },
               %{
                 name: "runs.changes",
                 subject: nil,
                 shape: %{"type" => "object", "fields" => run_fields},
                 filter: nil,
                 refresh: true
               }
             ] = streams

      assert Enum.sort(Map.keys(feed_fields)) ==
               ~w(actions at binding feed label result revision)

      assert Enum.sort(Map.keys(run_fields)) ==
               ~w(component_type duration_ms error execution_id kind parent_execution_id reference)

      assert length(Grimoire.streams()) > length(streams)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp actor(ctx), do: Context.actor(ctx)

  defp version_dir(version), do: ComponentPath.version_dir("tincture", "local", @name, version)

  defp write_args(overrides \\ []) do
    Map.merge(
      %{"name" => @name, "module" => @module, "streams" => []},
      Map.new(overrides, fn {key, value} -> {Atom.to_string(key), value} end)
    )
  end

  defp write!(ctx) do
    {:ok, %{version: version}} = Canvas.write(ctx, write_args())
    version
  end

  defp canvas_manifest(version) do
    %{
      "type" => "tincture",
      "name" => @name,
      "version" => version,
      "tincture" => %{
        "frame" => %{"placement" => "canvas"},
        "canvas" => %{"module" => "canvas.js", "toolkit" => 1},
        "streams" => []
      }
    }
  end

  # A tincture version laid in the athanor's tree and registered, with
  # `tincture` as its manifest's block.
  defp install!(ctx, name, version, tincture) do
    files =
      if get_in(tincture, ["frame", "placement"]) == "canvas",
        do: [{"canvas.js", "// installed"}],
        else: [{"index.html", "<html></html>"}]

    Arca.Test.UnitFixtures.tenant_component!(ctx, "tincture", "local", name, version,
      manifest: %{
        "type" => "tincture",
        "name" => name,
        "version" => version,
        "tincture" => tincture
      },
      files: files
    )

    {:ok, _} =
      Compendium.Registry.register_from_arca(
        ctx,
        ComponentPath.version_dir("tincture", "local", name, version)
      )
  end

  defp versions!(ctx) do
    {:ok, %{document: document, revision: revision}} = Canvas.versions(ctx, @name)
    %{document: document, revision: revision}
  end

  defp activate(ctx, version, frame, outcome \\ "tree") do
    Canvas.activate(ctx, %{
      "canvas" => @name,
      "version" => version,
      "frame" => frame,
      "outcome" => outcome
    })
  end

  # A glass's trial of `version`: a hidden frame's validation credential,
  # minted for the version's release digest under the grant revision a
  # frame opens under.
  defp trial!(ctx, version, revision \\ nil) do
    {:ok, %{"release_digest" => digest}} =
      Compendium.inspect_component(ctx, "#{@reference}:#{version}")

    revision =
      revision ||
        case Compendium.tincture_grant_revision(ctx, @reference) do
          {:ok, revision} -> revision
        end

    frame = "frm_#{System.unique_integer([:positive])}_trial"

    {:ok, %{credential: bearer, id: id}} =
      TinctureAuth.mint_validation_credential(
        ctx,
        %{publisher: "local", name: @name, version: version},
        digest,
        revision,
        frame
      )

    %{frame: frame, bearer: bearer, id: id}
  end

  # The canvas's one owner profile, active or waiting for the person.
  defp owner_profile!(ctx, status) do
    policy = "{}"

    :ok =
      ConsentFixtures.seed_head!(
        ctx,
        %{
          id: "prof_canvas_markets",
          kind: :owner,
          source_ref: @reference,
          label: "owner",
          status: status
        },
        %{
          id: "cons_canvas_markets",
          revision: 1,
          scope: :versionless,
          pinned_version: "",
          invoke_mode: :open_inert,
          shape_digest: "sha256:shape",
          commit_digest: "sha256:commit",
          blob_digest: Prima.JCS.hash_binary(policy),
          resolved_policy: policy,
          activation: %{}
        }
      )
  end

  # ---- racing on one read ----------------------------------------------------

  # Every process that runs under `paused/1` stops once, right after its
  # read of the canvas's versions document, and says so; it goes on when
  # it is told to. The read is observed, never waited out.
  defp hold_after_read! do
    id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(id, [:arca, :repo, :query], &__MODULE__.held_read/4, %{
        test: self(),
        key: CanvasVersions.key(@name)
      })

    on_exit(fn -> :telemetry.detach(id) end)
  end

  @doc false
  def held_read(_event, _measurements, %{source: "fenced_documents", params: params}, config) do
    if Process.get(:hold_after_read) == true and config.key in params and
         not Arca.Repo.in_transaction?() do
      Process.put(:hold_after_read, false)
      send(config.test, {:read_versions, self()})

      receive do
        :go -> :ok
      after
        30_000 -> :ok
      end
    end
  end

  def held_read(_event, _measurements, _metadata, _config), do: :ok

  defp paused(fun) do
    Process.put(:hold_after_read, true)
    fun.()
  end

  # Start each of `funs` held after its read, wait until every one has
  # read, then let them all go at once.
  defp race(funs) do
    tasks = Enum.map(funs, fn fun -> Task.async(fn -> paused(fun) end) end)

    readers =
      for _ <- tasks do
        assert_receive {:read_versions, reader}, 15_000
        reader
      end

    Enum.each(readers, &send(&1, :go))
    Task.await_many(tasks, 30_000)
  end

  # ---- the person, the settings and the slot -------------------------------

  defp person_ctx! do
    {local, user} = Sanctum.TestContext.person!(Sanctum.TestContext.local())
    {:ok, _} = Sanctum.Tenancy.Members.ensure(user.id, scope: "athanor", athanor_id: @athanor)
    {:ok, session} = Sanctum.TestContext.create_session(local)
    {:ok, established} = Sanctum.Caller.establish(session.token, focus: @athanor)
    %{established | client_ip: "127.0.0.1"}
  end

  defp settings! do
    previous = Arca.PlatformSettings.installed()

    on_exit(fn ->
      if previous,
        do: Arca.PlatformSettings.install_defaults!(previous),
        else: Arca.PlatformSettings.uninstall()
    end)

    Arca.PlatformSettings.install_defaults!(
      Map.merge(previous || %{}, %{
        "asset_credential_window_s" => %{default: 3_600, stale: :serve},
        "frame_credential_deadline_s" => %{default: 900, stale: :serve}
      })
    )
  end

  # A claimant runs, as a deployment's does, and this member holds its
  # slot: the umbrella's test configuration runs none, which would leave
  # the live checks nothing to check.
  defp claimant! do
    saved = Map.new(@keys, &{&1, :persistent_term.get(&1, :absent)})
    claim = Application.get_env(:arca, :control_plane_claim_enabled)

    on_exit(fn ->
      for {key, value} <- saved do
        if value == :absent,
          do: :persistent_term.erase(key),
          else: :persistent_term.put(key, value)
      end

      if is_nil(claim),
        do: Application.delete_env(:arca, :control_plane_claim_enabled),
        else: Application.put_env(:arca, :control_plane_claim_enabled, claim)
    end)

    Application.put_env(:arca, :control_plane_claim_enabled, true)
    node = "node-canvas-#{System.unique_integer([:positive])}"
    {:ok, slot} = Arca.ControlPlane.take(node, node <> "#boot_a", 60_000)
    slot
  end

  # A successor takes the slot over; this member still believes it holds
  # it, so only the writes' own live checks stand between it and a write.
  defp take_over!(slot, rows) do
    {^rows, _} =
      Arca.Repo.update_all(from(l in CellLease, where: l.node == ^slot.node),
        set: [owner: slot.node <> "#boot_b", generation: slot.generation + 1]
      )

    assert Arca.ControlPlane.held?()
  end
end
