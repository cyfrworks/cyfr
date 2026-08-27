# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.OverlayTest.FailingCopyAdapter do
  @moduledoc false
  use Arca.Storage.TestDouble

  # Fails the materialization mid-copy: the wasm binary never lands.
  def put(_ctx, _path, "WASM-BYTES"), do: {:error, :enospc}
  def put(ctx, path, content), do: Arca.Adapters.Local.put(ctx, path, content)
end

defmodule Arca.OverlayTest.DownAdapter do
  @moduledoc false
  # A tenant adapter whose listings are down — the outage shape an object
  # store produces. Everything else answers normally.
  use Arca.Storage.TestDouble

  def list_typed(_ctx, _path), do: {:error, :adapter_down}
  def list_recursive(_ctx, _path), do: {:error, :adapter_down}
end

defmodule Arca.OverlayTest do
  @moduledoc """
  The seed overlay on the `components/` root: every facade reader sees the
  union of the athanor's tree over the seed bundle; an athanor's COMPLETED
  copy (its sentinel present) shadows the seed's unit whole; a write
  materializes (copy-on-write, droppings excluded, the cap consulted, the
  sentinel copied last so a crash can never half-shadow); deleting what
  the athanor does not own is refused, deleting a materialized copy
  reverts to pristine.
  """

  use ExUnit.Case, async: false

  @version_dir ["components", "catalysts", "local", "bundled", "1.0.0"]
  @sentinel "cyfr-manifest.json"

  setup do
    base = Path.join(System.tmp_dir!(), "overlay_#{System.unique_integer([:positive])}")
    seed = Path.join(base, "seed")

    bundle_version = Path.join([seed, "components", "catalysts", "local", "bundled", "1.0.0"])
    File.mkdir_p!(Path.join(bundle_version, "src"))
    File.mkdir_p!(Path.join(bundle_version, "src/target"))
    File.write!(Path.join(bundle_version, "cyfr-manifest.json"), ~s({"type":"catalyst"}))
    File.write!(Path.join(bundle_version, "catalyst.wasm"), "WASM-BYTES")
    File.write!(Path.join(bundle_version, "src/lib.rs"), "fn main() {}")
    File.write!(Path.join(bundle_version, "src/target/junk.o"), "DROPPINGS")

    prev_base = Application.fetch_env!(:cyfr, :base_path)
    prev_seed = Application.fetch_env!(:cyfr, :seed_path)
    Application.put_env(:cyfr, :base_path, Path.join(base, "data"))
    Application.put_env(:cyfr, :seed_path, seed)

    on_exit(fn ->
      Application.put_env(:cyfr, :base_path, prev_base)
      Application.put_env(:cyfr, :seed_path, prev_seed)
      File.rm_rf!(base)
    end)

    {:ok, ctx: Sanctum.TestContext.local(), seed_dir: seed}
  end

  # Lay raw tenant bytes under the overlay's internal-write scope —
  # simulating partial copies and crash windows without copy-on-write
  # firing. The context is ordinary; the exemption is the lexical scope.
  defp lay_raw(ctx, path, content) do
    internal =
      Sanctum.internal_context(user_id: "_test_lay", athanor_id: ctx.athanor_id, scope: :athanor)

    Arca.Overlay.with_internal_writes(fn -> Arca.put(internal, path, content) end)
  end

  describe "the locator wiring matches the component path's shape" do
    # The unit grammar is `Compendium.ComponentPath`'s to own; the
    # `:overlay_locators` config wires it in so `Arca` never gains a
    # compile dependency on Compendium. This witness is the link.
    test "a components path locates to its version_dir unit, manifest sentinel" do
      vd = Compendium.ComponentPath.version_dir("catalyst", "local", "n", "1.0.0")

      assert Arca.Storage.locate(vd ++ ["src", "lib.rs"]) ==
               {:dir, vd, Compendium.ComponentPath.manifest_name()}

      assert Arca.Storage.locate(vd) == {:dir, vd, Compendium.ComponentPath.manifest_name()}
      assert Arca.Storage.locate(Enum.take(vd, 4)) == :above_unit
      assert Arca.Storage.locate(["guest", "x"]) == :not_overlaid
      assert Arca.Storage.locate([]) == :not_overlaid
    end

    test "a junk shape under components/ is plain storage — never a unit", %{ctx: ctx} do
      # Only the grammar mints a unit: no copy-on-write, no origin mark,
      # no status entry for a shape the domain would never name.
      junk = ["components", "junk", "a", "b", "not-semver"]
      assert Arca.Storage.locate(junk ++ ["file.txt"]) == :above_unit

      :ok = Arca.put(ctx, junk ++ ["file.txt"], "stray")

      assert Arca.Overlay.unit_status(ctx, junk) == {:ok, :absent}
      assert {:ok, statuses} = Arca.Overlay.unit_statuses(ctx, "components")
      refute Map.has_key?(statuses, junk)
    end
  end

  describe "read-through" do
    test "every reader sees an unmaterialized bundle version", %{ctx: ctx} do
      assert {:ok, ~s({"type":"catalyst"})} =
               Arca.get(ctx, @version_dir ++ ["cyfr-manifest.json"])

      assert Arca.exists?(ctx, @version_dir ++ ["catalyst.wasm"])

      assert {:ok, entries} = Arca.list_typed(ctx, ["components"])
      assert {"catalysts", :dir} in entries

      assert {:ok, entries} = Arca.list_typed(ctx, @version_dir)
      assert {"cyfr-manifest.json", :file} in entries
      assert {"src", :dir} in entries

      assert {:ok, leaves} = Arca.list_recursive(ctx, ["components"])
      assert (@version_dir ++ ["catalyst.wasm"]) in leaves

      assert {:ok, pairs} = Arca.read_subtree(ctx, @version_dir)
      assert {["catalyst.wasm"], "WASM-BYTES"} in pairs
    end

    test "the union costs the athanor nothing — usage stays tenant-only", %{ctx: ctx} do
      assert {:ok, %{files: 0, bytes: 0}} = Arca.usage(ctx, ["components"])
    end

    test "a path outside the overlay root is untouched", %{ctx: ctx} do
      assert {:error, :not_found} = Arca.get(ctx, ["guest", "nope.txt"])
      refute Arca.exists?(ctx, ["guest", "nope.txt"])
    end
  end

  describe "shadowing" do
    test "a completed copy fully shadows the seed's unit — layers never mix", %{ctx: ctx} do
      # A copy is complete when its sentinel is present — content beside it
      # answers alone, and the seed's files stop showing.
      :ok = lay_raw(ctx, @version_dir ++ [@sentinel], ~s({"mine":true}))
      :ok = lay_raw(ctx, @version_dir ++ ["own.txt"], "mine")

      assert {:error, :not_found} = Arca.get(ctx, @version_dir ++ ["catalyst.wasm"])
      refute Arca.exists?(ctx, @version_dir ++ ["catalyst.wasm"])

      assert {:ok, entries} = Arca.list_typed(ctx, @version_dir)
      assert Enum.sort(entries) == [{"cyfr-manifest.json", :file}, {"own.txt", :file}]
    end

    test "an athanor-owned version beside a bundled one — both list", %{ctx: ctx} do
      own_dir = ["components", "catalysts", "local", "bundled", "2.0.0"]
      :ok = Arca.put(ctx, own_dir ++ ["catalyst.wasm"], "MINE")

      assert {:ok, entries} = Arca.list_typed(ctx, Enum.take(@version_dir, 4))
      assert {"1.0.0", :dir} in entries
      assert {"2.0.0", :dir} in entries

      assert {:ok, leaves} = Arca.list_recursive(ctx, ["components"])
      assert (@version_dir ++ ["catalyst.wasm"]) in leaves
      assert (own_dir ++ ["catalyst.wasm"]) in leaves
    end
  end

  describe "copy-on-write" do
    test "a write inside an unmaterialized version dir copies it first, droppings excluded", %{
      ctx: ctx
    } do
      :ok = Arca.put(ctx, @version_dir ++ ["notes.txt"], "hi")

      # The write landed, and the bundle's files are now the athanor's own.
      assert {:ok, "hi"} = Arca.get(ctx, @version_dir ++ ["notes.txt"])

      wasm_path = Arca.Adapters.Local.build_path(ctx, @version_dir ++ ["catalyst.wasm"])
      assert File.exists?(wasm_path)
      assert File.read!(wasm_path) == "WASM-BYTES"

      # The sentinel landed too — the copy is complete.
      assert Arca.Adapters.Local.exists?(ctx, @version_dir ++ [@sentinel])

      # Build droppings never materialize.
      refute File.exists?(
               Arca.Adapters.Local.build_path(ctx, @version_dir ++ ["src", "target", "junk.o"])
             )

      # The copy is real tenant bytes now — the cap sees it.
      assert {:ok, %{files: files, bytes: bytes}} = Arca.usage(ctx, ["components"])
      assert files >= 4
      assert bytes > 0
    end

    test "the storage cap gates the materialization bytes", %{ctx: ctx} do
      prev = Application.get_env(:cyfr, :caps)
      Application.put_env(:cyfr, :caps, athanor_storage_bytes: 5)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:cyfr, :caps, prev),
          else: Application.delete_env(:cyfr, :caps)
      end)

      Arca.Cache.init()
      Arca.Cache.delete_match({:athanor_usage, :_, :_})

      assert {:error, {:limit_reached, :athanor_storage_bytes, 5}} =
               Arca.put(ctx, @version_dir ++ ["notes.txt"], "hi")

      refute Arca.Adapters.Local.exists?(ctx, @version_dir ++ ["catalyst.wasm"])
    end

    test "a fresh version the seed does not ship writes plainly — no copy", %{ctx: ctx} do
      fresh = ["components", "catalysts", "local", "brand-new", "0.1.0"]
      :ok = Arca.put(ctx, fresh ++ ["catalyst.wasm"], "NEW")

      assert {:ok, [{"catalyst.wasm", :file}]} = Arca.list_typed(ctx, fresh)
    end

    test "a generic system writer copy-on-writes like any caller — only the lexical scope is exempt",
         %{ctx: ctx} do
      # The old sharp edge — any system context skipping copy-on-write —
      # is closed: a server-internal writer that is not inside
      # `with_internal_writes/1` materializes the unit like everyone else.
      generic =
        Sanctum.internal_context(user_id: "_test", athanor_id: ctx.athanor_id, scope: :athanor)

      :ok = Arca.put(generic, @version_dir ++ ["own.txt"], "mine")

      assert Arca.Adapters.Local.exists?(ctx, @version_dir ++ [@sentinel])
      assert Arca.Overlay.unit_status(ctx, @version_dir) == {:ok, :materialized}
      assert {:ok, entries} = Arca.list_typed(ctx, @version_dir)
      assert {"own.txt", :file} in entries
    end

    test "the old magic-string context shape carries no exemption", %{ctx: ctx} do
      # A context spelled exactly like the materializer's own
      # (auth_method: :system, user_id: "_overlay") used to skip
      # copy-on-write and the :bundled refusal. The exemption is lexical
      # now — this shape copy-on-writes and refuses like anyone.
      shaped =
        Sanctum.internal_context(user_id: "_overlay", athanor_id: ctx.athanor_id, scope: :athanor)

      assert {:error, :bundled} = Arca.delete_tree(shaped, @version_dir)

      :ok = Arca.put(shaped, @version_dir ++ ["own.txt"], "mine")
      assert Arca.Overlay.unit_status(ctx, @version_dir) == {:ok, :materialized}
      assert Arca.Adapters.Local.exists?(ctx, @version_dir ++ [@sentinel])
    end
  end

  describe "crash-safe materialization" do
    test "a failed copy rolls back — the seed stays fully visible", %{ctx: ctx} do
      original = Application.get_env(:cyfr, :storage_adapter)
      Application.put_env(:cyfr, :storage_adapter, Arca.OverlayTest.FailingCopyAdapter)

      on_exit(fn ->
        if original,
          do: Application.put_env(:cyfr, :storage_adapter, original),
          else: Application.delete_env(:cyfr, :storage_adapter)
      end)

      assert {:error, {:materialize_failed, :enospc}} =
               Arca.put(ctx, @version_dir ++ ["notes.txt"], "hi")

      # Nothing lingers on the tenant side, and the union is untouched.
      refute Arca.Adapters.Local.exists?(ctx, @version_dir ++ ["src", "lib.rs"])
      assert {:ok, "WASM-BYTES"} = Arca.get(ctx, @version_dir ++ ["catalyst.wasm"])

      # With the adapter healed, the same write materializes cleanly.
      Application.put_env(:cyfr, :storage_adapter, original || Arca.Adapters.Local)
      assert :ok = Arca.put(ctx, @version_dir ++ ["notes.txt"], "hi")
      assert Arca.Adapters.Local.exists?(ctx, @version_dir ++ [@sentinel])
    end

    test "a crashed copy (partial, no sentinel) keeps reading through and self-heals", %{
      ctx: ctx
    } do
      # Simulate the crash window: some files copied, the sentinel never
      # written. The unit must keep reading as unmaterialized — the seed
      # fully visible, the partial bytes never double-listed.
      :ok = lay_raw(ctx, @version_dir ++ ["src", "lib.rs"], "fn main() {}")

      assert {:ok, ~s({"type":"catalyst"})} = Arca.get(ctx, @version_dir ++ [@sentinel])
      assert {:ok, entries} = Arca.list_typed(ctx, @version_dir)
      assert {"catalyst.wasm", :file} in entries

      assert {:ok, pairs} = Arca.read_subtree(ctx, @version_dir)
      assert Enum.count(pairs, fn {rel, _} -> rel == ["src", "lib.rs"] end) == 1

      # The next write re-copies over the partial remains — complete again.
      assert :ok = Arca.put(ctx, @version_dir ++ ["notes.txt"], "hi")
      assert Arca.Adapters.Local.exists?(ctx, @version_dir ++ [@sentinel])
      assert {:ok, "WASM-BYTES"} = Arca.get(ctx, @version_dir ++ ["catalyst.wasm"])
    end

    @tag :unix
    test "an unreadable seed subtree refuses materialization instead of raising", %{
      ctx: ctx,
      seed_dir: seed
    } do
      if :os.type() == {:unix, :darwin} or System.get_env("USER") != "root" do
        # The sentinel stays readable (the walk must get past the sentinel
        # probe); the cap's seed walk then hits the locked subtree and the
        # write refuses with a typed error — never a MatchError.
        locked = Path.join([seed, "components", "catalysts", "local", "bundled", "1.0.0", "src"])
        File.chmod!(locked, 0o000)
        on_exit(fn -> File.chmod!(locked, 0o755) end)

        assert {:error, {:materialize_failed, {:seed_usage, {:usage_walk, _, :eacces}}}} =
                 Arca.put(ctx, @version_dir ++ ["notes.txt"], "hi")
      end
    end

    test "a seed unit without its sentinel is broken install media — the write refuses", %{
      ctx: ctx,
      seed_dir: seed
    } do
      stray = Path.join([seed, "components", "catalysts", "local", "stray", "1.0.0"])
      File.mkdir_p!(stray)
      File.write!(Path.join(stray, "catalyst.wasm"), "STRAY")

      assert {:error, {:materialize_failed, :seed_sentinel_missing}} =
               Arca.put(ctx, ["components", "catalysts", "local", "stray", "1.0.0", "x.txt"], "x")
    end
  end

  describe "deletes" do
    test "an unmaterialized bundle path refuses — the athanor does not own it", %{ctx: ctx} do
      assert {:error, :bundled} = Arca.delete(ctx, @version_dir ++ ["catalyst.wasm"])
      assert {:error, :bundled} = Arca.delete_tree(ctx, @version_dir)
      assert Arca.exists?(ctx, @version_dir ++ ["catalyst.wasm"])
    end

    test "deleting a materialized copy reverts to pristine", %{ctx: ctx} do
      :ok = Arca.put(ctx, @version_dir ++ ["notes.txt"], "edited")
      assert {:ok, "edited"} = Arca.get(ctx, @version_dir ++ ["notes.txt"])

      assert :ok = Arca.delete_tree(ctx, @version_dir)

      # The bundle shows through again, without the edit.
      assert {:ok, "WASM-BYTES"} = Arca.get(ctx, @version_dir ++ ["catalyst.wasm"])
      assert {:error, :not_found} = Arca.get(ctx, @version_dir ++ ["notes.txt"])
    end

    test "above the shadow unit, deletes touch only the athanor's own tree", %{ctx: ctx} do
      # Nothing materialized: the tree delete is a no-op on tenant bytes and
      # is not refused — the unit-level refusal is for named bundle paths.
      assert :ok = Arca.delete_tree(ctx, ["components"])
      assert Arca.exists?(ctx, @version_dir ++ ["catalyst.wasm"])
    end
  end

  describe "unit status and drift" do
    test "unit_status/2 tells the five states apart", %{ctx: ctx, seed_dir: seed} do
      assert Arca.Overlay.unit_status(ctx, @version_dir) == {:ok, :seed}

      :ok = Arca.put(ctx, @version_dir ++ ["notes.txt"], "edited")
      assert Arca.Overlay.unit_status(ctx, @version_dir) == {:ok, :materialized}

      own = ["components", "catalysts", "local", "brand-new", "0.1.0"]
      :ok = Arca.put(ctx, own ++ ["catalyst.wasm"], "NEW")
      assert Arca.Overlay.unit_status(ctx, own) == {:ok, :own}

      # The athanor's own complete unit over a later-shipped counterpart.
      shadowing = ["components", "catalysts", "local", "mine", "1.0.0"]
      :ok = Arca.put(ctx, shadowing ++ [@sentinel], ~s({"type":"catalyst"}))
      shipped = Path.join([seed, "components", "catalysts", "local", "mine", "1.0.0"])
      File.mkdir_p!(shipped)
      File.write!(Path.join(shipped, @sentinel), ~s({"type":"catalyst"}))
      assert Arca.Overlay.unit_status(ctx, shadowing) == {:ok, :own_shadowing}

      absent = ["components", "catalysts", "local", "nope", "9.9.9"]
      assert Arca.Overlay.unit_status(ctx, absent) == {:ok, :absent}

      # Longer paths answer for their unit; non-overlaid roots are :absent.
      assert Arca.Overlay.unit_status(ctx, @version_dir ++ ["notes.txt"]) == {:ok, :materialized}
      assert Arca.Overlay.unit_status(ctx, ["guest", "x"]) == {:ok, :absent}
    end

    test "unit_statuses/2 answers the whole root in three listings, matching unit_status/2",
         %{ctx: ctx, seed_dir: seed} do
      own = ["components", "catalysts", "local", "brand-new", "0.1.0"]
      :ok = Arca.put(ctx, own ++ ["catalyst.wasm"], "NEW")

      assert {:ok, %{@version_dir => :seed, ^own => :own}} =
               Arca.Overlay.unit_statuses(ctx, "components")

      :ok = Arca.put(ctx, @version_dir ++ ["notes.txt"], "edited")

      shadowing = ["components", "catalysts", "local", "mine", "1.0.0"]
      :ok = Arca.put(ctx, shadowing ++ [@sentinel], ~s({"type":"catalyst"}))
      shipped = Path.join([seed, "components", "catalysts", "local", "mine", "1.0.0"])
      File.mkdir_p!(shipped)
      File.write!(Path.join(shipped, @sentinel), ~s({"type":"catalyst"}))

      {:ok, statuses} = Arca.Overlay.unit_statuses(ctx, "components")

      assert %{@version_dir => :materialized, ^own => :own, ^shadowing => :own_shadowing} =
               statuses

      # The batch and per-unit forms can never classify the same facts
      # differently.
      for {unit, status} <- statuses do
        assert Arca.Overlay.unit_status(ctx, unit) == {:ok, status}
      end
    end

    test "diff_unit/2: a pristine copy diffs empty (droppings excluded), an edit shows", %{
      ctx: ctx
    } do
      # Materialize without editing anything the seed ships.
      :ok = Arca.put(ctx, @version_dir ++ ["notes.txt"], "note")
      :ok = Arca.delete(ctx, @version_dir ++ ["notes.txt"])

      assert {:ok, %{added: [], removed: [], changed: []}} =
               Arca.Overlay.diff_unit(ctx, @version_dir)

      :ok = Arca.put(ctx, @version_dir ++ ["catalyst.wasm"], "EDITED")
      :ok = Arca.put(ctx, @version_dir ++ ["extra.txt"], "extra")

      assert {:ok, %{added: [["extra.txt"]], removed: [], changed: [["catalyst.wasm"]]}} =
               Arca.Overlay.diff_unit(ctx, @version_dir)
    end

    test "collapse_unit/2 reverts a pristine copy and keeps an edited one", %{ctx: ctx} do
      assert Arca.Overlay.collapse_unit(ctx, @version_dir) == :absent

      :ok = Arca.put(ctx, @version_dir ++ ["notes.txt"], "note")
      :ok = Arca.delete(ctx, @version_dir ++ ["notes.txt"])
      assert Arca.Overlay.collapse_unit(ctx, @version_dir) == :collapsed
      assert {:ok, %{files: 0, bytes: 0}} = Arca.usage(ctx, ["components"])
      assert {:ok, "WASM-BYTES"} = Arca.get(ctx, @version_dir ++ ["catalyst.wasm"])

      :ok = Arca.put(ctx, @version_dir ++ ["catalyst.wasm"], "EDITED")
      assert Arca.Overlay.collapse_unit(ctx, @version_dir) == :kept
      assert {:ok, "EDITED"} = Arca.get(ctx, @version_dir ++ ["catalyst.wasm"])
    end

    test "a file-shaped unit diffs by its bytes — an edited agent is never 'pristine'", %{
      ctx: ctx,
      seed_dir: seed
    } do
      # The regression this pins: both adapters answer {:ok, []} for a
      # subtree read of a FILE path, so a depth-based diff once saw both
      # sides of an edited agent as empty — pristine — and boot-time
      # collapse deleted the member's edits. Shape now comes from the
      # locator, and the file unit compares actual bytes.
      agents = Path.join(seed, "aqua/agents")
      File.mkdir_p!(agents)
      File.write!(Path.join(agents, "a.md"), "shipped body")

      file = ["aqua", "agents", "a.md"]
      :ok = Arca.put(ctx, file, "edited body")

      assert {:ok, %{added: [], removed: [], changed: [[]]}} = Arca.Overlay.diff_unit(ctx, file)
      assert Arca.Overlay.collapse_unit(ctx, file) == :kept
      assert {:ok, "edited body"} = Arca.get(ctx, file)

      # A byte-identical copy collapses back to tracking the release.
      :ok = Arca.put(ctx, file, "shipped body")
      assert {:ok, %{added: [], removed: [], changed: []}} = Arca.Overlay.diff_unit(ctx, file)
      assert Arca.Overlay.collapse_unit(ctx, file) == :collapsed
      assert Arca.Overlay.unit_status(ctx, file) == {:ok, :seed}
      assert {:ok, "shipped body"} = Arca.get(ctx, file)
    end
  end

  describe "the revert verbs" do
    test "revert_copy/2 reverts only a materialized copy — member work refuses", %{
      ctx: ctx,
      seed_dir: seed
    } do
      # An edited (materialized) copy reverts: the seed shows through.
      :ok = Arca.put(ctx, @version_dir ++ ["catalyst.wasm"], "EDITED")
      assert Arca.Overlay.unit_status(ctx, @version_dir) == {:ok, :materialized}
      assert :ok = Arca.Overlay.revert_copy(ctx, @version_dir)
      assert Arca.Overlay.unit_status(ctx, @version_dir) == {:ok, :seed}
      assert {:ok, "WASM-BYTES"} = Arca.get(ctx, @version_dir ++ ["catalyst.wasm"])

      # The athanor's own work never reverts — with or without a shipped
      # counterpart underneath.
      own = ["components", "catalysts", "local", "brand-new", "0.1.0"]
      :ok = Arca.put(ctx, own ++ ["catalyst.wasm"], "NEW")
      assert {:error, :not_a_copy} = Arca.Overlay.revert_copy(ctx, own)
      assert {:ok, "NEW"} = Arca.get(ctx, own ++ ["catalyst.wasm"])

      shadowing = ["components", "catalysts", "local", "mine", "1.0.0"]
      :ok = Arca.put(ctx, shadowing ++ [@sentinel], ~s({"type":"catalyst"}))
      shipped = Path.join([seed, "components", "catalysts", "local", "mine", "1.0.0"])
      File.mkdir_p!(shipped)
      File.write!(Path.join(shipped, @sentinel), ~s({"type":"catalyst"}))
      assert Arca.Overlay.unit_status(ctx, shadowing) == {:ok, :own_shadowing}
      assert {:error, :not_a_copy} = Arca.Overlay.revert_copy(ctx, shadowing)

      # Nothing materialized → :bundled; neither side → :not_found;
      # outside the units → :not_overlaid.
      assert {:error, :bundled} = Arca.Overlay.revert_copy(ctx, @version_dir)

      absent = ["components", "catalysts", "local", "nope", "9.9.9"]
      assert {:error, :not_found} = Arca.Overlay.revert_copy(ctx, absent)
      assert {:error, :not_overlaid} = Arca.Overlay.revert_copy(ctx, ["guest", "x"])
      assert {:error, :not_overlaid} = Arca.Overlay.revert_copy(ctx, ["components"])
    end

    test "drop_unit/2 deletes what the athanor holds — and reveals any shipped counterpart",
         %{ctx: ctx, seed_dir: seed} do
      # Own work with nothing underneath is simply gone.
      own = ["components", "catalysts", "local", "brand-new", "0.1.0"]
      :ok = Arca.put(ctx, own ++ ["catalyst.wasm"], "NEW")
      assert {:ok, :deleted} = Arca.Overlay.drop_unit(ctx, own)
      assert Arca.Overlay.unit_status(ctx, own) == {:ok, :absent}

      # Own work shadowing a shipped counterpart: dropping it is the
      # reveal path.
      shadowing = ["components", "catalysts", "local", "mine", "1.0.0"]
      :ok = Arca.put(ctx, shadowing ++ [@sentinel], ~s({"mine":true}))
      shipped = Path.join([seed, "components", "catalysts", "local", "mine", "1.0.0"])
      File.mkdir_p!(shipped)
      File.write!(Path.join(shipped, @sentinel), ~s({"type":"catalyst"}))
      File.write!(Path.join(shipped, "catalyst.wasm"), "SHIPPED")
      assert Arca.Overlay.unit_status(ctx, shadowing) == {:ok, :own_shadowing}
      # The verb itself says what the delete uncovered — no caller has
      # to re-derive the disposition from status atoms.
      assert {:ok, :revealed_shipped} = Arca.Overlay.drop_unit(ctx, shadowing)
      assert Arca.Overlay.unit_status(ctx, shadowing) == {:ok, :seed}
      assert {:ok, "SHIPPED"} = Arca.get(ctx, shadowing ++ ["catalyst.wasm"])

      # What the athanor does not hold refuses.
      assert {:error, :bundled} = Arca.Overlay.drop_unit(ctx, @version_dir)
      assert {:error, :not_found} = Arca.Overlay.drop_unit(ctx, own)
      assert {:error, :not_overlaid} = Arca.Overlay.drop_unit(ctx, ["components"])
    end

    test "a file-shaped copy reverts by a single delete", %{ctx: ctx, seed_dir: seed} do
      agents = Path.join(seed, "aqua/agents")
      File.mkdir_p!(agents)
      File.write!(Path.join(agents, "a.md"), "shipped")

      :ok = Arca.put(ctx, ["aqua", "agents", "a.md"], "edited")
      assert Arca.Overlay.unit_status(ctx, ["aqua", "agents", "a.md"]) == {:ok, :materialized}
      assert :ok = Arca.Overlay.revert_copy(ctx, ["aqua", "agents", "a.md"])
      assert {:ok, "shipped"} = Arca.get(ctx, ["aqua", "agents", "a.md"])
    end
  end

  describe "origin marks — a copy of seed vs the athanor's own work" do
    test "a unit the athanor created BEFORE a release shipped it is its own — shadowing", %{
      ctx: ctx,
      seed_dir: seed
    } do
      mine = ["components", "catalysts", "local", "mine", "1.0.0"]
      :ok = Arca.put(ctx, mine ++ [@sentinel], ~s({"type":"catalyst"}))
      :ok = Arca.put(ctx, mine ++ ["catalyst.wasm"], "MY-WASM")
      assert Arca.Overlay.unit_status(ctx, mine) == {:ok, :own}

      # A later release ships the same name and version. The athanor's
      # bytes still win the union AND stay classified as its own work —
      # now visibly shadowing the shipped unit: reset must refuse them,
      # delete must work.
      shipped = Path.join([seed, "components", "catalysts", "local", "mine", "1.0.0"])
      File.mkdir_p!(shipped)
      File.write!(Path.join(shipped, @sentinel), ~s({"type":"catalyst"}))
      File.write!(Path.join(shipped, "catalyst.wasm"), "SHIPPED-WASM")

      assert {:ok, "MY-WASM"} = Arca.get(ctx, mine ++ ["catalyst.wasm"])
      assert Arca.Overlay.unit_status(ctx, mine) == {:ok, :own_shadowing}
      assert {:ok, %{^mine => :own_shadowing}} = Arca.Overlay.unit_statuses(ctx, "components")

      # Deleting the athanor's own work is allowed; the shipped unit then
      # shows through as pristine seed.
      assert :ok = Arca.delete_tree(ctx, mine)
      assert Arca.Overlay.unit_status(ctx, mine) == {:ok, :seed}
      assert {:ok, "SHIPPED-WASM"} = Arca.get(ctx, mine ++ ["catalyst.wasm"])
    end

    test "a complete copy without its mark (crash window) reads as the athanor's own", %{
      ctx: ctx
    } do
      # Simulate a crash between the sentinel landing and the origin mark:
      # the copy is complete but unmarked — it must classify as the
      # athanor's own (shadowing), the direction that never wipes bytes.
      :ok = lay_raw(ctx, @version_dir ++ [@sentinel], ~s({"type":"catalyst"}))
      :ok = lay_raw(ctx, @version_dir ++ ["catalyst.wasm"], "WASM-BYTES")

      assert Arca.Overlay.unit_status(ctx, @version_dir) == {:ok, :own_shadowing}
      assert Arca.Overlay.collapse_unit(ctx, @version_dir) == :kept
    end

    test "file-shaped units: editing a shipped agent is :materialized, own-then-shipped shadows",
         %{ctx: ctx, seed_dir: seed} do
      agents = Path.join(seed, "aqua/agents")
      File.mkdir_p!(agents)
      File.write!(Path.join(agents, "shipped.md"), "shipped body")

      # Editing the shipped agent is the file-shaped copy-on-write: the
      # single put shadows the seed file and records its mark.
      :ok = Arca.put(ctx, ["aqua", "agents", "shipped.md"], "edited body")

      assert Arca.Overlay.unit_status(ctx, ["aqua", "agents", "shipped.md"]) ==
               {:ok, :materialized}

      # An agent the athanor wrote first stays its own when a release
      # later ships the same name — and deleting it surfaces the seed's.
      :ok = Arca.put(ctx, ["aqua", "agents", "mine.md"], "my body")
      File.write!(Path.join(agents, "mine.md"), "shipped later")

      assert Arca.Overlay.unit_status(ctx, ["aqua", "agents", "mine.md"]) == {:ok, :own_shadowing}
      assert :ok = Arca.delete(ctx, ["aqua", "agents", "mine.md"])
      assert {:ok, "shipped later"} = Arca.get(ctx, ["aqua", "agents", "mine.md"])
      assert Arca.Overlay.unit_status(ctx, ["aqua", "agents", "mine.md"]) == {:ok, :seed}
    end

    test "concurrent materializations keep both marks — no lost update", %{
      ctx: ctx,
      seed_dir: seed
    } do
      other_version = Path.join([seed, "components", "catalysts", "local", "bundled", "2.0.0"])
      File.mkdir_p!(other_version)
      File.write!(Path.join(other_version, @sentinel), ~s({"type":"catalyst"}))
      File.write!(Path.join(other_version, "catalyst.wasm"), "V2")

      other_dir = ["components", "catalysts", "local", "bundled", "2.0.0"]

      [a, b] =
        Task.await_many([
          Task.async(fn -> Arca.put(ctx, @version_dir ++ ["notes.txt"], "one") end),
          Task.async(fn -> Arca.put(ctx, other_dir ++ ["notes.txt"], "two") end)
        ])

      assert a == :ok
      assert b == :ok

      {:ok, statuses} = Arca.Overlay.unit_statuses(ctx, "components")
      assert statuses[@version_dir] == :materialized
      assert statuses[other_dir] == :materialized
    end

    test "a member-level write cannot forge a mark — meta/ is reserved", %{ctx: ctx} do
      mark = ["meta", "origin" | @version_dir]
      assert {:error, :forbidden} = Arca.put(ctx, mark, ~s({"origin":"seed"}))
      assert {:error, :forbidden} = Arca.delete_tree(ctx, ["meta", "origin"])

      # Reads stay ordinary tenant reads; a system context may write.
      assert {:error, :not_found} = Arca.get(ctx, mark)

      system =
        Sanctum.internal_context(user_id: "_test", athanor_id: ctx.athanor_id, scope: :athanor)

      assert :ok = Arca.put(system, ["meta", "note.txt"], "server-side")
    end

    test "deleting a subtree clears the marks beneath it", %{ctx: ctx, seed_dir: seed} do
      agents = Path.join(seed, "aqua/agents")
      File.mkdir_p!(agents)
      File.write!(Path.join(agents, "a.md"), "shipped")

      # Materialize the agent — its mark exists, status :materialized.
      :ok = Arca.put(ctx, ["aqua", "agents", "a.md"], "edited")
      assert Arca.Overlay.unit_status(ctx, ["aqua", "agents", "a.md"]) == {:ok, :materialized}

      # A whole-scope delete (reset all: true's shape) clears the marks
      # with the bytes: re-completing the same unit without the overlay's
      # own copy machinery must NOT read as :materialized.
      assert :ok = Arca.delete_tree(ctx, ["aqua"])
      :ok = lay_raw(ctx, ["aqua", "agents", "a.md"], "recreated by hand")
      assert Arca.Overlay.unit_status(ctx, ["aqua", "agents", "a.md"]) == {:ok, :own_shadowing}
    end
  end

  describe "always-on decorator" do
    test "paths outside the overlaid roots pass through verbatim", %{ctx: ctx} do
      :ok = Arca.put(ctx, ["guest", "sub", "file.txt"], "guest bytes")
      :ok = Arca.put(ctx, ["conversations", "conv_1", "blob.bin"], "blob")

      assert {:ok, "guest bytes"} = Arca.get(ctx, ["guest", "sub", "file.txt"])
      assert {:ok, [{"sub", :dir}]} = Arca.list_typed(ctx, ["guest"])

      # The whole-athanor walk and tree deletes answer as the configured
      # adapter would — no seed merge outside the overlaid roots.
      assert {:ok, %{files: 2}} = Arca.usage(ctx, [])
      assert {:ok, leaves} = Arca.list_recursive(ctx, [])
      assert ["guest", "sub", "file.txt"] in leaves

      assert :ok = Arca.delete_tree(ctx, ["conversations"])
      refute Arca.exists?(ctx, ["conversations", "conv_1", "blob.bin"])
    end

    test "configuring the overlay as the adapter raises instead of recursing", %{ctx: ctx} do
      original = Application.get_env(:cyfr, :storage_adapter)
      Application.put_env(:cyfr, :storage_adapter, Arca.Overlay)

      on_exit(fn ->
        if original,
          do: Application.put_env(:cyfr, :storage_adapter, original),
          else: Application.delete_env(:cyfr, :storage_adapter)
      end)

      assert_raise ArgumentError, ~r/decorator/, fn -> Arca.get(ctx, ["guest", "x"]) end
    end
  end

  describe "seed stays read-only" do
    test "no write reaches the seed side, whoever asks", %{ctx: ctx} do
      system =
        Sanctum.internal_context(user_id: "_test", athanor_id: ctx.athanor_id, scope: :athanor)

      assert {:error, :seed_read_only} =
               Arca.put(system, ["seed" | @version_dir] ++ ["x.txt"], "x")

      assert {:error, :seed_read_only} = Arca.put(ctx, ["seed" | @version_dir] ++ ["x.txt"], "x")

      # The internal-write scope is a copy-on-write exemption, not a seed
      # write permit.
      assert {:error, :seed_read_only} =
               Arca.Overlay.with_internal_writes(fn ->
                 Arca.put(system, ["seed" | @version_dir] ++ ["x.txt"], "x")
               end)
    end
  end

  describe "commit_unit/4 — the one way a unit lands" do
    @own_dir ["components", "catalysts", "local", "committed", "1.0.0"]

    test "files source: sentinel lands last; write order is the return", %{ctx: ctx} do
      files = [
        {[@sentinel], ~s({"type":"catalyst"})},
        {["a.txt"], "A"},
        {["sub", "b.txt"], fn -> {:ok, "B"} end}
      ]

      assert {:ok, written} =
               Arca.Overlay.commit_unit(ctx, @own_dir, {:files, files}, cap: :exempt)

      # The sentinel is written last whatever the list order said.
      assert List.last(written) == [@sentinel]
      assert Enum.sort(written) == Enum.sort([["a.txt"], ["sub", "b.txt"], [@sentinel]])
      assert Arca.Overlay.unit_status(ctx, @own_dir) == {:ok, :own}
      assert {:ok, "B"} = Arca.get(ctx, @own_dir ++ ["sub", "b.txt"])
    end

    test "a mid-list failure rolls the whole unit back — no partial, no mark", %{ctx: ctx} do
      files = [
        {[@sentinel], ~s({"type":"catalyst"})},
        {["a.txt"], "A"},
        {["b.txt"], fn -> {:error, :enospc} end}
      ]

      assert {:error, :enospc} =
               Arca.Overlay.commit_unit(ctx, @own_dir, {:files, files}, cap: :exempt)

      assert {:ok, []} = Arca.list_recursive(ctx, Enum.take(@own_dir, 4))
      refute Arca.exists?(ctx, @own_dir ++ ["a.txt"])
      assert Arca.Overlay.unit_status(ctx, @own_dir) == {:ok, :absent}
    end

    test "a dir unit without sentinel bytes refuses before any write", %{ctx: ctx} do
      assert {:error, :missing_sentinel} =
               Arca.Overlay.commit_unit(ctx, @own_dir, {:files, [{["a.txt"], "A"}]}, cap: :exempt)

      refute Arca.exists?(ctx, @own_dir ++ ["a.txt"])
    end

    test "cap refuses before the first write", %{ctx: ctx} do
      prev = Application.get_env(:cyfr, :caps)
      Application.put_env(:cyfr, :caps, athanor_storage_bytes: 1)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:cyfr, :caps, prev),
          else: Application.delete_env(:cyfr, :caps)

        Arca.Cache.delete_match({:athanor_usage, :_, :_})
      end)

      files = [{[@sentinel], ~s({"type":"catalyst"})}, {["a.txt"], "AAAA"}]

      assert {:error, {:limit_reached, :athanor_storage_bytes, 1}} =
               Arca.Overlay.commit_unit(ctx, @own_dir, {:files, files}, cap: {:checked, 4096})

      refute Arca.exists?(ctx, @own_dir ++ ["a.txt"])
    end

    test "a commit replaces the unit wholesale — stale files do not survive", %{ctx: ctx} do
      first = [{[@sentinel], ~s({"v":1})}, {["old.txt"], "OLD"}]
      assert {:ok, _} = Arca.Overlay.commit_unit(ctx, @own_dir, {:files, first}, cap: :exempt)

      second = [{[@sentinel], ~s({"v":2})}, {["new.txt"], "NEW"}]
      assert {:ok, _} = Arca.Overlay.commit_unit(ctx, @own_dir, {:files, second}, cap: :exempt)

      refute Arca.exists?(ctx, @own_dir ++ ["old.txt"])
      assert {:ok, "NEW"} = Arca.get(ctx, @own_dir ++ ["new.txt"])
      assert {:ok, ~s({"v":2})} = Arca.get(ctx, @own_dir ++ [@sentinel])
    end

    test "tree source: streams another Arca tree; sentinel: overrides its manifest", %{ctx: ctx} do
      src = ["guest", "staging"]
      :ok = Arca.put(ctx, src ++ ["a.txt"], "A")
      :ok = Arca.put(ctx, src ++ [@sentinel], ~s({"stale":true}))

      assert {:ok, written} =
               Arca.Overlay.commit_unit(ctx, @own_dir, {:tree, src, []},
                 cap: :exempt,
                 sentinel: ~s({"stamped":true})
               )

      assert List.last(written) == [@sentinel]
      assert {:ok, ~s({"stamped":true})} = Arca.get(ctx, @own_dir ++ [@sentinel])
      assert {:ok, "A"} = Arca.get(ctx, @own_dir ++ ["a.txt"])
    end

    test "default origin is none — a committed unit over a seed counterpart shadows",
         %{ctx: ctx} do
      files = [{[@sentinel], ~s({"mine":true})}, {["own.txt"], "MINE"}]

      assert {:ok, _} =
               Arca.Overlay.commit_unit(ctx, @version_dir, {:files, files}, cap: :exempt)

      # No origin mark: the athanor's own work, which reset refuses.
      assert Arca.Overlay.unit_status(ctx, @version_dir) == {:ok, :own_shadowing}
      assert {:error, :not_a_copy} = Arca.Overlay.revert_copy(ctx, @version_dir)
    end

    test "origin: :seed marks the commit as a materialized copy", %{ctx: ctx} do
      seed_src = ["seed" | @version_dir]

      system =
        Sanctum.internal_context(user_id: "_test", athanor_id: ctx.athanor_id, scope: :athanor)

      assert {:ok, _} =
               Arca.Overlay.commit_unit(
                 system,
                 @version_dir,
                 {:tree, seed_src, exclude: &Arca.Storage.build_dropping?/1},
                 cap: :exempt,
                 origin: :seed
               )

      assert Arca.Overlay.unit_status(ctx, @version_dir) == {:ok, :materialized}
    end

    test "a file unit is one plain put — sentinel/origin refused, CoW mark untouched",
         %{ctx: ctx} do
      agent = ["aqua", "agents", "mine.md"]

      assert {:ok, [[]]} =
               Arca.Overlay.commit_unit(ctx, agent, {:files, [{[], "# mine"}]}, cap: :exempt)

      assert {:ok, "# mine"} = Arca.get(ctx, agent)
      assert Arca.Overlay.unit_status(ctx, agent) == {:ok, :own}

      assert_raise ArgumentError, ~r/the put is the commit/, fn ->
        Arca.Overlay.commit_unit(ctx, agent, {:files, [{[], "x"}]},
          cap: :exempt,
          origin: :seed
        )
      end
    end

    test "a non-unit path is a programmer error", %{ctx: ctx} do
      assert_raise ArgumentError, ~r/needs a unit path/, fn ->
        Arca.Overlay.commit_unit(ctx, ["components", "catalysts"], {:files, []}, cap: :exempt)
      end
    end
  end

  describe "a tenant adapter outage propagates — the union never lies" do
    # A union answer needs both sides: an outage answering seed-only would
    # be a plausible listing silently missing the athanor's files, and a
    # status surface would misreport its own units as shipped.
    setup %{ctx: ctx} do
      # Materialize the bundled unit while the real adapter is up, so the
      # outage has something real to misreport.
      :ok = Arca.put(ctx, @version_dir ++ ["notes.txt"], "edited")
      assert Arca.Overlay.unit_status(ctx, @version_dir) == {:ok, :materialized}

      original = Application.get_env(:cyfr, :storage_adapter)
      Application.put_env(:cyfr, :storage_adapter, Arca.OverlayTest.DownAdapter)

      on_exit(fn ->
        if original,
          do: Application.put_env(:cyfr, :storage_adapter, original),
          else: Application.delete_env(:cyfr, :storage_adapter)
      end)

      :ok
    end

    test "listings answer the outage, never a seed-only union", %{ctx: ctx} do
      assert {:error, :adapter_down} = Arca.list_typed(ctx, ["components"])
      assert {:error, :adapter_down} = Arca.list_recursive(ctx, ["components"])
    end

    test "status surfaces answer the outage, never :seed for a materialized unit", %{ctx: ctx} do
      assert {:error, :adapter_down} = Arca.Overlay.unit_status(ctx, @version_dir)
      assert {:error, :adapter_down} = Arca.Overlay.unit_statuses(ctx, "components")
      assert {:error, :adapter_down} = Arca.Overlay.revert_copy(ctx, @version_dir)
      assert {:error, :adapter_down} = Arca.Overlay.collapse_unit(ctx, @version_dir)
    end
  end
end
