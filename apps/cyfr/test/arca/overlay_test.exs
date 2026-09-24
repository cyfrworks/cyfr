# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.OverlayTest.FailingCopyAdapter do
  @moduledoc false
  use Arca.Storage.TestDouble

  # Fails the materialization mid-copy: the wasm binary never lands.
  def put(_ctx, _path, "WASM-BYTES"), do: {:error, :enospc}

  def put(actor, path, content),
    do: Arca.Adapters.Local.put(actor, path, content)
end

defmodule Arca.OverlayTest.GatedStagingAdapter do
  @moduledoc false
  # Parks one commit while it stages: the first object written under a
  # staging prefix (the in-progress marker aside) waits for the test, so
  # the test can act inside the window between a draft and its commit.
  use Arca.Storage.TestDouble

  @gate {__MODULE__, :gate}

  def arm(test_pid), do: :persistent_term.put(@gate, test_pid)
  def disarm, do: :persistent_term.erase(@gate)

  def put(actor, path, content) do
    test_pid = :persistent_term.get(@gate, nil)

    if test_pid && Arca.Storage.UnitLocator.staging?(path) &&
         List.last(path) != Arca.Storage.UnitLocator.marker_name() do
      # One caller only: the first to arrive takes the gate down.
      disarm()
      send(test_pid, {:staging, self()})

      receive do
        :proceed -> :ok
      after
        10_000 -> :ok
      end
    end

    Arca.Adapters.Local.put(actor, path, content)
  end
end

defmodule Arca.OverlayTest.NoSwapAdapter do
  @moduledoc false
  # A tenant adapter that exports no `replace_tree/3` — an object store's
  # shape. Everything else answers as the Local adapter does.
  use Arca.Storage.TestDouble
end

defmodule Arca.OverlayTest.UndeletableAdapter do
  @moduledoc false
  # A tenant adapter whose deletes fail and write nothing — a store that
  # refused. Everything else answers as the Local adapter does.
  use Arca.Storage.TestDouble

  def delete(_actor, _path), do: {:error, :eacces}
  def delete_tree(_actor, _path), do: {:error, :eacces}
end

defmodule Arca.OverlayTest.DownAdapter do
  @moduledoc false
  # A tenant adapter whose listings are down — the outage shape an object
  # store produces. Everything else answers normally.
  use Arca.Storage.TestDouble

  def list_typed(_ctx, _path), do: {:error, :adapter_down}
  def list_recursive(_ctx, _path), do: {:error, :adapter_down}

  # A listing that never answers empty leaves the double's prefix listing
  # nothing to probe: it is down too.
  def list_prefix(actor, path), do: list_recursive(actor, path)
end

defmodule Arca.OverlayTest do
  @moduledoc """
  The seeded roots on the `components/` and `aqua/` roots: every facade
  reader sees the athanor's own tree and nothing else; the seed tree is
  the shipped default a unit is copied FROM — at provisioning, on a pull
  of a shipped version, on a restore — whole, droppings excluded,
  published by its row and never by its objects. A unit the seed ships is
  a shipped copy whatever its bytes; an edit shows in its diff; a shipped
  copy is restored, never deleted.
  """

  use ExUnit.Case, async: false

  @version_dir ["components", "catalysts", "local", "bundled", "1.0.0"]
  @sentinel "cyfr-manifest.json"

  setup do
    # Shared: a unit's row is read and written by the tasks a test spawns.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    base = Path.join(System.tmp_dir!(), "overlay_#{System.unique_integer([:positive])}")
    seed = Path.join(base, "seed")

    bundle_version = Path.join([seed, "components", "catalysts", "local", "bundled", "1.0.0"])
    File.mkdir_p!(Path.join(bundle_version, "src"))
    File.mkdir_p!(Path.join(bundle_version, "src/target"))
    File.write!(Path.join(bundle_version, "cyfr-manifest.json"), ~s({"type":"catalyst"}))
    File.write!(Path.join(bundle_version, "catalyst.wasm"), "WASM-BYTES")
    File.write!(Path.join(bundle_version, "src/lib.rs"), "fn main() {}")
    File.write!(Path.join(bundle_version, "src/target/junk.o"), "DROPPINGS")

    prev_base = Application.fetch_env!(:arca, :base_path)
    prev_seed = Application.fetch_env!(:arca, :seed_path)
    Application.put_env(:arca, :base_path, Path.join(base, "data"))
    Application.put_env(:arca, :seed_path, seed)

    on_exit(fn ->
      Application.put_env(:arca, :base_path, prev_base)
      Application.put_env(:arca, :seed_path, prev_seed)
      File.rm_rf!(base)
    end)

    {:ok, actor: Sanctum.Context.actor(Sanctum.TestContext.local()), seed_dir: seed}
  end

  # The athanor's own unit, landed the one way a unit lands.
  defp own_unit!(actor, unit, completion, files \\ []) do
    source =
      case Arca.Storage.locate(unit) do
        {:file, ^unit} -> {:files, [{[], completion}]}
        {:dir, ^unit, sentinel} -> {:files, [{[sentinel], completion} | files]}
      end

    {:ok, _written} =
      Arca.Overlay.commit_unit(actor, unit, source, cap: :exempt)

    :ok
  end

  defp journal(actor, unit) do
    {root, key} = Arca.Storage.UnitLocator.unit_key(unit)
    {:ok, commits} = Arca.StorageUnits.journal(actor, root, key)
    commits
  end

  # Every registered draft, aged past its lifetime: what a writer that died
  # mid-staging leaves behind, without the wait.
  defp expire_drafts! do
    long_ago =
      DateTime.add(DateTime.utc_now(), -2 * Arca.StorageUnits.draft_ttl_ms(), :millisecond)

    Arca.Repo.update_all(Arca.Schemas.StorageUnit, set: [updated_at: long_ago])
  end

  # Park the next commit while it stages (`GatedStagingAdapter`).
  defp gate_staging! do
    Application.put_env(:arca, :storage_adapter, Arca.OverlayTest.GatedStagingAdapter)

    on_exit(fn ->
      Arca.OverlayTest.GatedStagingAdapter.disarm()
      Application.put_env(:arca, :storage_adapter, Arca.Adapters.Local)
    end)

    Arca.OverlayTest.GatedStagingAdapter.arm(self())
  end

  # Lay a shipped role file in the seed tree.
  defp ship_role!(seed, name, body) do
    roles = Path.join(seed, "aqua/roles")
    File.mkdir_p!(roles)
    File.write!(Path.join(roles, name), body)
    ["aqua", "roles", name]
  end

  # Lay a shipped component version in the seed tree.
  defp ship_version!(seed, name, version, wasm) do
    dir = Path.join([seed, "components", "catalysts", "local", name, version])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, @sentinel), ~s({"type":"catalyst"}))
    File.write!(Path.join(dir, "catalyst.wasm"), wasm)
    ["components", "catalysts", "local", name, version]
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
      assert Arca.Storage.locate(["data", "x"]) == :not_overlaid
      assert Arca.Storage.locate([]) == :not_overlaid
    end

    test "a junk shape under components/ is plain storage — never a unit", %{actor: actor} do
      # Only the grammar mints a unit: no lock, no status entry for a
      # shape the domain would never name.
      junk = ["components", "junk", "a", "b", "not-semver"]
      assert Arca.Storage.locate(junk ++ ["file.txt"]) == :above_unit

      :ok = Arca.put(actor, junk ++ ["file.txt"], "stray")

      assert Arca.Overlay.unit_status(actor, junk) == {:ok, :absent}

      assert {:ok, statuses} =
               Arca.Overlay.unit_statuses(actor, "components")

      refute Map.has_key?(statuses, junk)
    end
  end

  describe "the athanor's tree answers alone" do
    test "a shipped unit the athanor has not pulled is invisible to every reader — and available",
         %{actor: actor} do
      assert {:error, :not_found} =
               Arca.get(actor, @version_dir ++ [@sentinel])

      refute Arca.exists?(actor, @version_dir ++ ["catalyst.wasm"])
      assert {:ok, []} = Arca.list_typed(actor, ["components"])
      assert {:ok, []} = Arca.list_recursive(actor, ["components"])
      assert {:ok, %{files: 0, bytes: 0}} = Arca.usage(actor, ["components"])

      # What the seed ships is a fact the status surfaces still answer.
      assert Arca.Overlay.unit_status(actor, @version_dir) ==
               {:ok, :available}

      assert {:ok, %{@version_dir => :available}} =
               Arca.Overlay.unit_statuses(actor, "components")

      assert {:ok, [@version_dir]} = Arca.Overlay.shipped_units("components")
    end

    test "a path outside the seeded roots is untouched", %{actor: actor} do
      assert {:error, :not_found} = Arca.get(actor, ["data", "nope.txt"])
      refute Arca.exists?(actor, ["data", "nope.txt"])
      assert {:ok, []} = Arca.Overlay.shipped_units("data")
    end
  end

  describe "pulling what ships" do
    test "pull_shipped/2 copies the unit whole — droppings excluded, sentinel last, uncapped",
         %{actor: actor} do
      prev = Application.get_env(:sanctum, :caps)
      Application.put_env(:sanctum, :caps, athanor_storage_bytes: 5)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:sanctum, :caps, prev),
          else: Application.delete_env(:sanctum, :caps)

        Arca.Cache.delete_match({:athanor_usage, :_, :_})
      end)

      Arca.Cache.init()
      Arca.Cache.delete_match({:athanor_usage, :_, :_})

      # Shipped media lands whatever the cap says.
      assert :ok = Arca.Overlay.pull_shipped(actor, @version_dir)

      assert {:ok, "WASM-BYTES"} =
               Arca.get(actor, @version_dir ++ ["catalyst.wasm"])

      assert {:ok, "fn main() {}"} =
               Arca.get(actor, @version_dir ++ ["src", "lib.rs"])

      assert Arca.Adapters.Local.exists?(actor, @version_dir ++ [@sentinel])
      refute Arca.exists?(actor, @version_dir ++ ["src", "target", "junk.o"])

      # The copy is real tenant bytes now — the cap sees it.
      assert {:ok, %{files: files, bytes: bytes}} =
               Arca.usage(actor, ["components"])

      assert files >= 3
      assert bytes > 0

      assert Arca.Overlay.unit_status(actor, @version_dir) == {:ok, :shipped}

      # A member's own write is still capped.
      assert {:error, {:limit_reached, :athanor_storage_bytes, 5}} =
               Arca.put(actor, @version_dir ++ ["notes.txt"], "hi")
    end

    test "materialize_shipped/2 copies every available unit and leaves the rest alone", %{
      actor: actor,
      seed_dir: seed
    } do
      v2 = ship_version!(seed, "bundled", "2.0.0", "V2")
      own = ["components", "catalysts", "local", "brand-new", "0.1.0"]
      :ok = Arca.put(actor, own ++ ["catalyst.wasm"], "NEW")

      assert {:ok, copied} =
               Arca.Overlay.materialize_shipped(actor, "components")

      assert Enum.sort(copied) == Enum.sort([@version_dir, v2])

      {:ok, statuses} = Arca.Overlay.unit_statuses(actor, "components")
      assert %{@version_dir => :shipped, ^v2 => :shipped, ^own => :own} = statuses

      # Edits survive a second fill: only what is still available is copied.
      :ok = Arca.put(actor, @version_dir ++ ["notes.txt"], "edited")

      assert {:ok, []} =
               Arca.Overlay.materialize_shipped(actor, "components")

      assert {:ok, "edited"} = Arca.get(actor, @version_dir ++ ["notes.txt"])
    end

    test "a pull replaces whatever stands at a shipped path", %{actor: actor, seed_dir: seed} do
      # A crashed copy: some files, no sentinel. It reads as available, and
      # the next pull replaces it whole.
      :ok =
        Arca.put(actor, @version_dir ++ ["src", "lib.rs"], "fn pwned() {}")

      assert Arca.Overlay.unit_status(actor, @version_dir) ==
               {:ok, :available}

      assert :ok = Arca.Overlay.pull_shipped(actor, @version_dir)

      assert {:ok, "fn main() {}"} =
               Arca.get(actor, @version_dir ++ ["src", "lib.rs"])

      # A complete unit the athanor wrote at a path a release ships is the
      # shipped copy from then on: a pull puts the shipped bytes there.
      mine = ["components", "catalysts", "local", "mine", "1.0.0"]
      :ok = own_unit!(actor, mine, ~s({"mine":true}))
      _ = ship_version!(seed, "mine", "1.0.0", "SHIPPED")
      assert Arca.Overlay.unit_status(actor, mine) == {:ok, :shipped}
      assert :ok = Arca.Overlay.pull_shipped(actor, mine)

      assert {:ok, ~s({"type":"catalyst"})} =
               Arca.get(actor, mine ++ [@sentinel])

      assert {:ok, "SHIPPED"} = Arca.get(actor, mine ++ ["catalyst.wasm"])

      # What the seed does not ship cannot be pulled; a non-unit path is a
      # programmer error the verb refuses typed.
      absent = ["components", "catalysts", "local", "nope", "9.9.9"]

      assert {:error, :not_shipped} =
               Arca.Overlay.pull_shipped(actor, absent)

      assert {:error, :not_a_unit} =
               Arca.Overlay.pull_shipped(actor, @version_dir ++ ["src"])

      assert {:error, :not_overlaid} =
               Arca.Overlay.pull_shipped(actor, ["components"])

      assert {:error, :not_overlaid} =
               Arca.Overlay.pull_shipped(actor, ["data", "x"])
    end

    test "a failed copy rolls back — nothing lingers, and the healed pull lands", %{actor: actor} do
      original = Application.get_env(:arca, :storage_adapter)
      Application.put_env(:arca, :storage_adapter, Arca.OverlayTest.FailingCopyAdapter)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arca, :storage_adapter, original),
          else: Application.delete_env(:arca, :storage_adapter)
      end)

      assert {:error, :enospc} =
               Arca.Overlay.pull_shipped(actor, @version_dir)

      refute Arca.Adapters.Local.exists?(
               actor,
               @version_dir ++ ["src", "lib.rs"]
             )

      assert Arca.Overlay.unit_status(actor, @version_dir) ==
               {:ok, :available}

      Application.put_env(:arca, :storage_adapter, original || Arca.Adapters.Local)
      assert :ok = Arca.Overlay.pull_shipped(actor, @version_dir)
      assert Arca.Overlay.unit_status(actor, @version_dir) == {:ok, :shipped}
    end

    test "a seed unit without its sentinel is broken install media — the pull refuses", %{
      actor: actor,
      seed_dir: seed
    } do
      stray = Path.join([seed, "components", "catalysts", "local", "stray", "1.0.0"])
      File.mkdir_p!(stray)
      File.write!(Path.join(stray, "catalyst.wasm"), "STRAY")

      assert {:error, {:materialize_failed, :seed_sentinel_missing}} =
               Arca.Overlay.pull_shipped(actor, [
                 "components",
                 "catalysts",
                 "local",
                 "stray",
                 "1.0.0"
               ])
    end
  end

  describe "edits" do
    test "a write inside a shipped copy lands and shows in its diff; the athanor's own unit writes plainly",
         %{actor: actor} do
      :ok = Arca.Overlay.pull_shipped(actor, @version_dir)
      :ok = Arca.put(actor, @version_dir ++ ["notes.txt"], "hi")

      assert {:ok, "hi"} = Arca.get(actor, @version_dir ++ ["notes.txt"])
      assert Arca.Overlay.unit_status(actor, @version_dir) == {:ok, :shipped}
      assert {:ok, true} = Arca.Overlay.edited?(actor, @version_dir)

      fresh = ["components", "catalysts", "local", "brand-new", "0.1.0"]
      :ok = Arca.put(actor, fresh ++ ["catalyst.wasm"], "NEW")

      assert {:ok, [{"catalyst.wasm", :file}]} =
               Arca.list_typed(actor, fresh)

      assert Arca.Overlay.unit_status(actor, fresh) == {:ok, :own}
    end

    test "a forged internal-looking actor carries no exemption", %{actor: actor} do
      :ok = Arca.Overlay.pull_shipped(actor, @version_dir)

      shaped = %{
        Prima.Actor.system()
        | user_id: "_overlay",
          athanor_id: actor.athanor_id,
          scope: :athanor
      }

      assert {:error, :bundled} = Arca.delete_tree(shaped, @version_dir)
      assert Arca.exists?(actor, @version_dir ++ ["catalyst.wasm"])
    end
  end

  describe "deletes" do
    test "a shipped copy refuses deletion whole — inside it, a delete is an edit", %{
      actor: actor,
      seed_dir: seed
    } do
      :ok = Arca.Overlay.pull_shipped(actor, @version_dir)

      assert {:error, :bundled} = Arca.delete_tree(actor, @version_dir)
      assert Arca.exists?(actor, @version_dir ++ ["catalyst.wasm"])

      assert :ok = Arca.delete(actor, @version_dir ++ ["catalyst.wasm"])
      refute Arca.exists?(actor, @version_dir ++ ["catalyst.wasm"])
      assert Arca.Overlay.unit_status(actor, @version_dir) == {:ok, :shipped}

      assert {:ok, %{removed: [["catalyst.wasm"]]}} =
               Arca.Overlay.diff_unit(actor, @version_dir)

      role = ship_role!(seed, "a.md", "shipped")
      :ok = Arca.Overlay.pull_shipped(actor, role)
      assert {:error, :bundled} = Arca.delete(actor, role)
      assert {:ok, "shipped"} = Arca.get(actor, role)
    end

    test "the athanor's own unit deletes plainly", %{actor: actor} do
      own = ["components", "catalysts", "local", "brand-new", "0.1.0"]
      :ok = Arca.put(actor, own ++ [@sentinel], ~s({"type":"catalyst"}))
      assert Arca.Overlay.unit_status(actor, own) == {:ok, :own}

      assert :ok = Arca.delete_tree(actor, own)
      assert Arca.Overlay.unit_status(actor, own) == {:ok, :absent}
    end

    test "a delete the store refuses is not a deletion the registry acknowledges", %{
      actor: actor
    } do
      ctx = Sanctum.TestContext.local()
      name = "undeletable-#{System.unique_integer([:positive])}"
      unit = ["components", "reagents", "local", name, "1.0.0"]

      wasm =
        <<0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
          0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01, 0x03, "run", 0x00, 0x00, 0x0A, 0x04, 0x01,
          0x02, 0x00, 0x0B>>

      :ok = Arca.put(actor, unit ++ ["reagent.wasm"], wasm)
      :ok = Arca.put(actor, unit ++ [@sentinel], ~s({"type":"reagent","description":"kept"}))
      assert {:ok, %{description: "kept"}} = Compendium.Registry.get(ctx, name, "1.0.0")

      prev_adapter = Application.get_env(:arca, :storage_adapter)
      Application.put_env(:arca, :storage_adapter, Arca.OverlayTest.UndeletableAdapter)

      on_exit(fn ->
        if prev_adapter,
          do: Application.put_env(:arca, :storage_adapter, prev_adapter),
          else: Application.delete_env(:arca, :storage_adapter)
      end)

      # The caller is told; the bytes stay, and so does the row derived
      # from them — the unit's last change is no tombstone, and it is read.
      assert {:error, :eacces} = Arca.delete_tree(actor, unit)
      assert Arca.exists?(actor, unit ++ [@sentinel])

      assert {:ok, %{units: [%{tombstone: false, ready: true}]}} =
               Arca.StorageProjectionChanges.snapshot(actor, "components",
                 units: ["reagents/local/#{name}/1.0.0"]
               )

      assert {:ok, %{description: "kept"}} = Compendium.Registry.get(ctx, name, "1.0.0")

      assert {:ok, %{epoch: epoch, acknowledged_epoch: epoch}} =
               Arca.StorageProjectionRoots.epoch(actor, "components")
    end

    test "above the shadow unit, deletes touch only the athanor's own tree", %{actor: actor} do
      # Nothing held: the tree delete is a no-op on tenant bytes and is not
      # refused — the unit-level refusal is for shipped copies.
      assert :ok = Arca.delete_tree(actor, ["components"])
      assert {:ok, [@version_dir]} = Arca.Overlay.shipped_units("components")
    end
  end

  describe "unit status and drift" do
    test "unit_status/2 tells the four states apart", %{actor: actor, seed_dir: seed} do
      assert Arca.Overlay.unit_status(actor, @version_dir) ==
               {:ok, :available}

      :ok = Arca.Overlay.pull_shipped(actor, @version_dir)
      assert Arca.Overlay.unit_status(actor, @version_dir) == {:ok, :shipped}

      # An edit does not change whose unit it is.
      :ok = Arca.put(actor, @version_dir ++ ["notes.txt"], "edited")
      assert Arca.Overlay.unit_status(actor, @version_dir) == {:ok, :shipped}

      own = ["components", "catalysts", "local", "brand-new", "0.1.0"]
      :ok = Arca.put(actor, own ++ ["catalyst.wasm"], "NEW")
      assert Arca.Overlay.unit_status(actor, own) == {:ok, :own}

      # The athanor's own complete unit at a path a later release ships
      # is a shipped copy from then on.
      mine = ["components", "catalysts", "local", "mine", "1.0.0"]
      :ok = own_unit!(actor, mine, ~s({"type":"catalyst"}))
      assert Arca.Overlay.unit_status(actor, mine) == {:ok, :own}
      _ = ship_version!(seed, "mine", "1.0.0", "SHIPPED")
      assert Arca.Overlay.unit_status(actor, mine) == {:ok, :shipped}

      absent = ["components", "catalysts", "local", "nope", "9.9.9"]
      assert Arca.Overlay.unit_status(actor, absent) == {:ok, :absent}

      # Longer paths answer for their unit; non-overlaid roots are :absent.
      assert Arca.Overlay.unit_status(actor, @version_dir ++ ["notes.txt"]) ==
               {:ok, :shipped}

      assert Arca.Overlay.unit_status(actor, ["data", "x"]) == {:ok, :absent}
    end

    test "unit_statuses/2 answers the whole root in two listings, matching unit_status/2",
         %{actor: actor, seed_dir: seed} do
      own = ["components", "catalysts", "local", "brand-new", "0.1.0"]
      :ok = Arca.put(actor, own ++ ["catalyst.wasm"], "NEW")

      assert {:ok, %{@version_dir => :available, ^own => :own}} =
               Arca.Overlay.unit_statuses(actor, "components")

      :ok = Arca.Overlay.pull_shipped(actor, @version_dir)
      v2 = ship_version!(seed, "bundled", "2.0.0", "V2")
      :ok = Arca.Overlay.pull_shipped(actor, v2)
      :ok = Arca.put(actor, v2 ++ ["notes.txt"], "edited")
      v3 = ship_version!(seed, "bundled", "3.0.0", "V3")

      {:ok, statuses} = Arca.Overlay.unit_statuses(actor, "components")

      assert %{@version_dir => :shipped, ^v2 => :shipped, ^v3 => :available, ^own => :own} =
               statuses

      # The batch and per-unit forms can never classify the same facts
      # differently.
      for {unit, status} <- statuses do
        assert Arca.Overlay.unit_status(actor, unit) == {:ok, status}
      end
    end

    test "diff_unit/2: a pristine copy diffs empty (droppings excluded), an edit shows", %{
      actor: actor
    } do
      :ok = Arca.Overlay.pull_shipped(actor, @version_dir)

      assert {:ok, %{added: [], removed: [], changed: []}} =
               Arca.Overlay.diff_unit(actor, @version_dir)

      :ok = Arca.put(actor, @version_dir ++ ["catalyst.wasm"], "EDITED")
      :ok = Arca.put(actor, @version_dir ++ ["extra.txt"], "extra")

      assert {:ok, %{added: [["extra.txt"]], removed: [], changed: [["catalyst.wasm"]]}} =
               Arca.Overlay.diff_unit(actor, @version_dir)
    end

    test "a file-shaped unit diffs by its bytes — an edited agent is never 'pristine'", %{
      actor: actor,
      seed_dir: seed
    } do
      file = ship_role!(seed, "a.md", "shipped body")
      :ok = Arca.Overlay.pull_shipped(actor, file)

      assert {:ok, %{added: [], removed: [], changed: []}} =
               Arca.Overlay.diff_unit(actor, file)

      :ok = Arca.put(actor, file, "edited body")

      assert {:ok, %{added: [], removed: [], changed: [[]]}} =
               Arca.Overlay.diff_unit(actor, file)

      assert {:ok, true} = Arca.Overlay.edited?(actor, file)
      assert Arca.Overlay.unit_status(actor, file) == {:ok, :shipped}

      # A restore brings the shipped bytes back.
      assert :ok = Arca.Overlay.pull_shipped(actor, file)
      assert {:ok, "shipped body"} = Arca.get(actor, file)
      assert {:ok, false} = Arca.Overlay.edited?(actor, file)
    end
  end

  describe "the revert verbs" do
    test "pull_shipped/2 restores a held copy whatever was written into it", %{
      actor: actor,
      seed_dir: seed
    } do
      :ok = Arca.Overlay.pull_shipped(actor, @version_dir)
      :ok = Arca.put(actor, @version_dir ++ ["catalyst.wasm"], "EDITED")
      :ok = Arca.put(actor, @version_dir ++ ["notes.txt"], "note")
      assert {:ok, true} = Arca.Overlay.edited?(actor, @version_dir)

      assert :ok = Arca.Overlay.pull_shipped(actor, @version_dir)
      assert {:ok, false} = Arca.Overlay.edited?(actor, @version_dir)

      assert {:ok, "WASM-BYTES"} =
               Arca.get(actor, @version_dir ++ ["catalyst.wasm"])

      refute Arca.exists?(actor, @version_dir ++ ["notes.txt"])

      # Restoring an unedited copy changes nothing and answers the same.
      assert :ok = Arca.Overlay.pull_shipped(actor, @version_dir)

      # The athanor's own work has nothing shipped to restore to.
      own = ["components", "catalysts", "local", "brand-new", "0.1.0"]
      :ok = Arca.put(actor, own ++ ["catalyst.wasm"], "NEW")
      assert {:error, :not_shipped} = Arca.Overlay.pull_shipped(actor, own)
      assert {:ok, "NEW"} = Arca.get(actor, own ++ ["catalyst.wasm"])

      # A shipped unit the athanor does not hold is copied in — the same
      # verb is the pull.
      v2 = ship_version!(seed, "bundled", "2.0.0", "V2")
      assert :ok = Arca.Overlay.pull_shipped(actor, v2)
      assert {:ok, "V2"} = Arca.get(actor, v2 ++ ["catalyst.wasm"])
    end

    test "drop_unit/2 deletes the athanor's own work and refuses a shipped copy", %{
      actor: actor,
      seed_dir: seed
    } do
      # Own work with nothing underneath is simply gone.
      own = ["components", "catalysts", "local", "brand-new", "0.1.0"]
      :ok = Arca.put(actor, own ++ ["catalyst.wasm"], "NEW")
      assert {:ok, :deleted} = Arca.Overlay.drop_unit(actor, own)
      assert Arca.Overlay.unit_status(actor, own) == {:ok, :absent}

      # A shipped copy — edited or not, and whoever wrote it — is restored,
      # never deleted.
      :ok = Arca.Overlay.pull_shipped(actor, @version_dir)
      assert {:error, :bundled} = Arca.Overlay.drop_unit(actor, @version_dir)
      :ok = Arca.put(actor, @version_dir ++ ["notes.txt"], "edited")
      assert {:error, :bundled} = Arca.Overlay.drop_unit(actor, @version_dir)

      mine = ["components", "catalysts", "local", "mine", "1.0.0"]
      :ok = own_unit!(actor, mine, ~s({"mine":true}))
      _ = ship_version!(seed, "mine", "1.0.0", "SHIPPED")
      assert {:error, :bundled} = Arca.Overlay.drop_unit(actor, mine)

      # What the athanor does not hold is not found; outside the units is
      # not a unit.
      v2 = ship_version!(seed, "bundled", "2.0.0", "V2")
      assert {:error, :not_found} = Arca.Overlay.drop_unit(actor, v2)
      assert {:error, :not_found} = Arca.Overlay.drop_unit(actor, own)

      assert {:error, :not_overlaid} =
               Arca.Overlay.drop_unit(actor, ["components"])
    end
  end

  describe "a shipped path is a shipped unit, whoever wrote it" do
    test "a unit the athanor created BEFORE a release shipped it becomes the shipped copy", %{
      actor: actor,
      seed_dir: seed
    } do
      mine = ["components", "catalysts", "local", "mine", "1.0.0"]
      :ok = own_unit!(actor, mine, ~s({"type":"catalyst"}), [{["catalyst.wasm"], "MY-WASM"}])
      assert Arca.Overlay.unit_status(actor, mine) == {:ok, :own}
      assert :ok = Arca.delete_tree(actor, mine)
      assert Arca.Overlay.unit_status(actor, mine) == {:ok, :absent}

      :ok = own_unit!(actor, mine, ~s({"type":"catalyst"}), [{["catalyst.wasm"], "MY-WASM"}])

      # A later release ships the same name and version. The bytes stay
      # until a restore replaces them; the unit reads shipped and edited,
      # and no longer deletes.
      _ = ship_version!(seed, "mine", "1.0.0", "SHIPPED-WASM")

      assert {:ok, "MY-WASM"} = Arca.get(actor, mine ++ ["catalyst.wasm"])
      assert Arca.Overlay.unit_status(actor, mine) == {:ok, :shipped}

      assert {:ok, %{^mine => :shipped}} =
               Arca.Overlay.unit_statuses(actor, "components")

      assert {:ok, true} = Arca.Overlay.edited?(actor, mine)
      assert {:error, :bundled} = Arca.delete_tree(actor, mine)

      assert :ok = Arca.Overlay.pull_shipped(actor, mine)

      assert {:ok, "SHIPPED-WASM"} =
               Arca.get(actor, mine ++ ["catalyst.wasm"])
    end

    test "file-shaped units follow the same rule", %{actor: actor, seed_dir: seed} do
      shipped = ship_role!(seed, "shipped.md", "shipped body")
      :ok = Arca.Overlay.pull_shipped(actor, shipped)
      assert Arca.Overlay.unit_status(actor, shipped) == {:ok, :shipped}

      :ok = Arca.put(actor, shipped, "edited body")
      assert Arca.Overlay.unit_status(actor, shipped) == {:ok, :shipped}
      assert {:ok, true} = Arca.Overlay.edited?(actor, shipped)

      # An agent the athanor wrote first is a shipped copy once a release
      # ships the same name: it no longer deletes, and a restore replaces it.
      mine = ["aqua", "roles", "mine.md"]
      :ok = own_unit!(actor, mine, "my body")
      assert Arca.Overlay.unit_status(actor, mine) == {:ok, :own}
      _ = ship_role!(seed, "mine.md", "shipped later")

      assert Arca.Overlay.unit_status(actor, mine) == {:ok, :shipped}
      assert {:error, :bundled} = Arca.delete(actor, mine)
      assert :ok = Arca.Overlay.pull_shipped(actor, mine)
      assert {:ok, "shipped later"} = Arca.get(actor, mine)
    end
  end

  describe "copies, commits and edits, with no lock between them" do
    test "concurrent pulls of two units both land", %{actor: actor, seed_dir: seed} do
      v2 = ship_version!(seed, "bundled", "2.0.0", "V2")

      [a, b] =
        Task.await_many([
          Task.async(fn ->
            Arca.Overlay.pull_shipped(actor, @version_dir)
          end),
          Task.async(fn -> Arca.Overlay.pull_shipped(actor, v2) end)
        ])

      assert a == :ok
      assert b == :ok

      {:ok, statuses} = Arca.Overlay.unit_statuses(actor, "components")
      assert statuses[@version_dir] == :shipped
      assert statuses[v2] == :shipped
    end

    test "while a commit stages, readers keep the previous revision and an edit does not wait",
         %{actor: actor} do
      :ok = own_unit!(actor, @version_dir, ~s({"v":1}), [{["old.txt"], "OLD"}])
      gate_staging!()

      committer =
        Task.async(fn ->
          Arca.Overlay.commit_unit(
            actor,
            @version_dir,
            {:files, [{[@sentinel], ~s({"v":2})}, {["fresh.txt"], "fresh"}]},
            cap: :exempt
          )
        end)

      assert_receive {:staging, committer_pid}, 10_000

      # Nothing of the staged revision is served, and the unit still reads
      # as it did: the row has not moved.
      assert {:ok, ~s({"v":1})} =
               Arca.get(actor, @version_dir ++ [@sentinel])

      assert {:ok, "OLD"} = Arca.get(actor, @version_dir ++ ["old.txt"])
      refute Arca.exists?(actor, @version_dir ++ ["fresh.txt"])
      assert Arca.Overlay.unit_status(actor, @version_dir) == {:ok, :shipped}
      assert [_first] = journal(actor, @version_dir)

      # An edit of the served revision lands at once: nothing holds the unit.
      assert :ok = Arca.put(actor, @version_dir ++ ["late.txt"], "late")

      send(committer_pid, :proceed)
      assert {:ok, _written} = Task.await(committer, 30_000)

      # The commit replaced the unit whole: the new revision and nothing of
      # the one it replaced, the edit of that revision included.
      assert {:ok, ~s({"v":2})} =
               Arca.get(actor, @version_dir ++ [@sentinel])

      assert {:ok, "fresh"} = Arca.get(actor, @version_dir ++ ["fresh.txt"])
      refute Arca.exists?(actor, @version_dir ++ ["old.txt"])
      refute Arca.exists?(actor, @version_dir ++ ["late.txt"])
      assert [_first, _second] = journal(actor, @version_dir)
    end

    test "a second writer is refused while a draft is live, and lands once it is given back",
         %{actor: actor} do
      gate_staging!()
      unit = ["components", "catalysts", "local", "contended", "1.0.0"]

      source = fn body ->
        {:files, [{[@sentinel], ~s({"type":"catalyst"})}, {["a.txt"], body}]}
      end

      first =
        Task.async(fn ->
          Arca.Overlay.commit_unit(actor, unit, source.("A"), cap: :exempt)
        end)

      assert_receive {:staging, first_pid}, 10_000

      assert {:error, :stale_writer} =
               Arca.Overlay.commit_unit(actor, unit, source.("B"), cap: :exempt)

      send(first_pid, :proceed)
      assert {:ok, _written} = Task.await(first, 30_000)
      assert {:ok, "A"} = Arca.get(actor, unit ++ ["a.txt"])

      assert {:ok, _written} =
               Arca.Overlay.commit_unit(actor, unit, source.("B"), cap: :exempt)

      assert {:ok, "B"} = Arca.get(actor, unit ++ ["a.txt"])
      assert [%{prior_revision: nil}, %{prior_revision: prior}] = journal(actor, unit)
      assert is_binary(prior)
    end

    test "concurrent edits of one copy keep every acknowledged write", %{actor: actor} do
      :ok = Arca.Overlay.pull_shipped(actor, @version_dir)
      writers = 8

      results =
        1..writers
        |> Enum.map(fn i ->
          Task.async(fn ->
            {i, Arca.put(actor, @version_dir ++ ["w#{i}.txt"], "body-#{i}")}
          end)
        end)
        |> Task.await_many(30_000)

      acknowledged = for {i, :ok} <- results, do: i

      assert length(acknowledged) == writers,
             "some writes did not return :ok: #{inspect(results)}"

      for i <- acknowledged do
        assert {:ok, "body-#{i}"} ==
                 Arca.get(actor, @version_dir ++ ["w#{i}.txt"]),
               "w#{i}.txt was acknowledged and then lost"
      end

      assert {:ok, "WASM-BYTES"} =
               Arca.get(actor, @version_dir ++ ["catalyst.wasm"])

      assert Arca.Overlay.unit_status(actor, @version_dir) == {:ok, :shipped}
    end

    test "a unit dropped inside a commit's window is not published by that commit", %{
      actor: actor
    } do
      # `component.delete` and the publish rollback both reach
      # `Arca.delete_tree` on a version dir. A dir with NO seed behind it,
      # so "gone" reads `:absent` and nothing else.
      dir = ["components", "catalysts", "local", "race-target", "1.0.0"]
      gate_staging!()

      committer =
        Task.async(fn ->
          Arca.Overlay.commit_unit(
            actor,
            dir,
            {:files, [{[@sentinel], ~s({"type":"catalyst"})}, {["a.txt"], "A"}]},
            cap: :exempt
          )
        end)

      assert_receive {:staging, committer_pid}, 10_000
      assert :ok = Arca.delete_tree(actor, dir)
      send(committer_pid, :proceed)

      # The drop retired the row the commit staged against, so the commit
      # is refused and leaves nothing: no served object, no staged one.
      assert {:error, :missing_unit} = Task.await(committer, 30_000)
      assert Arca.Overlay.unit_status(actor, dir) == {:ok, :absent}
      refute Arca.exists?(actor, dir ++ [@sentinel])
      refute Arca.exists?(actor, dir ++ ["a.txt"])

      assert {:ok, []} =
               Arca.list_recursive(
                 actor,
                 Arca.Storage.UnitLocator.staging_prefix(dir)
               )

      assert journal(actor, dir) == []
    end

    test "a tree delete above units is refused while a unit stands beneath it", %{
      actor: actor,
      seed_dir: seed
    } do
      role = ship_role!(seed, "a.md", "shipped")
      :ok = Arca.Overlay.pull_shipped(actor, role)
      :ok = Arca.put(actor, role, "edited")

      # The wholesale form would clear units without retiring their rows;
      # a populated tree refuses at every level above the unit, and the
      # unit stands — a caller walks its units and drops them one at a
      # time, each with its row.
      assert {:error, :above_unit} = Arca.delete_tree(actor, ["aqua"])

      assert {:error, :above_unit} =
               Arca.delete_tree(actor, ["aqua", "roles"])

      assert {:ok, "edited"} = Arca.get(actor, role)

      # The internal-write scope keeps the wholesale form.
      assert :ok =
               Arca.Overlay.with_internal_writes(fn ->
                 Arca.delete_tree(actor, ["aqua"])
               end)

      assert Arca.Overlay.unit_status(actor, role) == {:ok, :available}
    end

    test "a tree above units holding no unit deletes plainly", %{actor: actor} do
      # Plain storage a unit grammar never claims — nothing a lock would
      # cover, so the tidy the registry does on an emptied name dir keeps
      # working.
      :ok = Arca.put(actor, ["aqua", "roles", "notes.txt"], "stray")
      assert :ok = Arca.delete_tree(actor, ["aqua"])
      refute Arca.exists?(actor, ["aqua", "roles", "notes.txt"])
    end
  end

  describe "the staging area is the overlay's own" do
    test "a listing from above never shows it; the same name elsewhere is content", %{
      actor: actor
    } do
      gate_staging!()
      unit = ["components", "catalysts", "local", "staged", "1.0.0"]

      committer =
        Task.async(fn ->
          Arca.Overlay.commit_unit(
            actor,
            unit,
            {:files, [{[@sentinel], ~s({"type":"catalyst"})}, {["a.txt"], "A"}]},
            cap: :exempt
          )
        end)

      assert_receive {:staging, committer_pid}, 10_000

      # A revision is being staged, and no reader of the tree sees it.
      staging = Arca.Storage.UnitLocator.staging_prefix(unit)
      assert {:ok, [_marker]} = Arca.list_recursive(actor, staging)
      assert {:ok, []} = Arca.list_typed(actor, ["components"])
      assert {:ok, []} = Arca.list_recursive(actor, ["components"])
      assert {:ok, []} = Arca.list_recursive(actor, [])
      assert {:ok, %{}} = Arca.Overlay.unit_statuses(actor, "components")
      # Staged bytes are bytes the athanor holds.
      assert {:ok, %{files: 1}} = Arca.usage(actor, ["components"])

      send(committer_pid, :proceed)
      assert {:ok, _written} = Task.await(committer, 30_000)

      assert {:ok, [{"catalysts", :dir}]} =
               Arca.list_typed(actor, ["components"])

      :ok = Arca.put(actor, ["data", ".staging", "mine.txt"], "mine")
      assert {:ok, [{".staging", :dir}]} = Arca.list_typed(actor, ["data"])

      assert {:ok, [["data", ".staging", "mine.txt"]]} =
               Arca.list_recursive(actor, ["data"])
    end
  end

  describe "always-on decorator" do
    test "paths outside the overlaid roots pass through verbatim", %{actor: actor} do
      :ok = Arca.put(actor, ["data", "sub", "file.txt"], "guest bytes")
      :ok = Arca.put(actor, ["threads", "thread_1", "blob.bin"], "blob")

      assert {:ok, "guest bytes"} =
               Arca.get(actor, ["data", "sub", "file.txt"])

      assert {:ok, [{"sub", :dir}]} = Arca.list_typed(actor, ["data"])

      # The whole-athanor walk and tree deletes answer as the configured
      # adapter would — no seed merge outside the overlaid roots.
      assert {:ok, %{files: 2}} = Arca.usage(actor, [])
      assert {:ok, leaves} = Arca.list_recursive(actor, [])
      assert ["data", "sub", "file.txt"] in leaves

      assert :ok = Arca.delete_tree(actor, ["threads"])
      refute Arca.exists?(actor, ["threads", "thread_1", "blob.bin"])
    end

    test "configuring the overlay as the adapter raises instead of recursing", %{actor: actor} do
      original = Application.get_env(:arca, :storage_adapter)
      Application.put_env(:arca, :storage_adapter, Arca.Overlay)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arca, :storage_adapter, original),
          else: Application.delete_env(:arca, :storage_adapter)
      end)

      assert_raise ArgumentError, ~r/decorator/, fn ->
        Arca.get(actor, ["data", "x"])
      end
    end
  end

  describe "seed stays read-only" do
    test "no write reaches the seed side, whoever asks", %{actor: actor} do
      system = %{
        Prima.Actor.system()
        | user_id: "_test",
          athanor_id: actor.athanor_id,
          scope: :athanor
      }

      assert {:error, :seed_read_only} =
               Arca.put(system, ["seed" | @version_dir] ++ ["x.txt"], "x")

      assert {:error, :seed_read_only} =
               Arca.put(actor, ["seed" | @version_dir] ++ ["x.txt"], "x")

      # The internal-write scope exempts the copy's own writes into the
      # athanor, never a write into the seed.
      assert {:error, :seed_read_only} =
               Arca.Overlay.with_internal_writes(fn ->
                 Arca.put(system, ["seed" | @version_dir] ++ ["x.txt"], "x")
               end)
    end
  end

  describe "commit_unit/4 with if_absent: true — create, never replace" do
    @skill_manifest "SKILL.md"

    defp create(actor, unit, bytes, opts \\ []) do
      source =
        case Arca.Storage.locate(unit) do
          {:file, ^unit} -> {:files, [{[], bytes}]}
          {:dir, ^unit, sentinel} -> {:files, [{[sentinel], bytes}]}
        end

      Arca.Overlay.commit_unit(actor, unit, source, [cap: :exempt] ++ opts)
    end

    test "a held shipped copy refuses; a shipped unit not yet pulled is not the athanor's",
         %{actor: actor, seed_dir: seed} do
      role = ship_role!(seed, "a.md", "shipped role")
      scroll_dir = Path.join(seed, "aqua/skills/s")
      File.mkdir_p!(scroll_dir)
      File.write!(Path.join(scroll_dir, @skill_manifest), "shipped scroll")
      scroll = ["aqua", "skills", "s"]

      :ok = Arca.Overlay.pull_shipped(actor, role)
      :ok = Arca.Overlay.pull_shipped(actor, scroll)
      assert {:error, :exists} = create(actor, role, "mine", if_absent: true)
      assert {:error, :exists} = create(actor, scroll, "mine", if_absent: true)
      assert {:ok, "shipped role"} = Arca.get(actor, role)

      assert {:ok, "shipped scroll"} =
               Arca.get(actor, scroll ++ [@skill_manifest])

      # The seed-backed component version the athanor never pulled is not
      # present: a commit lands there, and reads as the shipped copy.
      assert {:ok, _} = create(actor, @version_dir, ~s({"mine":true}), if_absent: true)
      assert Arca.Overlay.unit_status(actor, @version_dir) == {:ok, :shipped}
    end

    test "the athanor's own unit refuses and keeps its bytes; an absent one lands", %{
      actor: actor
    } do
      role = ["aqua", "roles", "b.md"]
      scroll = ["aqua", "skills", "t"]

      assert {:ok, [[]]} = create(actor, role, "first", if_absent: true)
      assert {:ok, [[@skill_manifest]]} = create(actor, scroll, "first scroll", if_absent: true)

      assert {:error, :exists} = create(actor, role, "second", if_absent: true)
      assert {:error, :exists} = create(actor, scroll, "second scroll", if_absent: true)
      assert {:ok, "first"} = Arca.get(actor, role)

      assert {:ok, "first scroll"} =
               Arca.get(actor, scroll ++ [@skill_manifest])

      # Without the option a commit replaces, as it always has.
      assert {:ok, _} = create(actor, role, "second")
      assert {:ok, _} = create(actor, scroll, "second scroll")
      assert {:ok, "second"} = Arca.get(actor, role)

      assert {:ok, "second scroll"} =
               Arca.get(actor, scroll ++ [@skill_manifest])
    end

    test "of concurrent creators of one name, exactly one lands", %{actor: actor} do
      # The question is asked under the unit's draft, so a creator either
      # finds the draft held by another or, holding it, finds the unit
      # there — a probe outside the draft would let several pass it and
      # each replace the last.
      role = ["aqua", "roles", "c.md"]
      scroll = ["aqua", "skills", "u"]

      for unit <- [role, scroll] do
        results =
          1..8
          |> Enum.map(fn i ->
            Task.async(fn -> create(actor, unit, "creator #{i}", if_absent: true) end)
          end)
          |> Task.await_many(30_000)

        assert Enum.count(results, &match?({:ok, _}, &1)) == 1, inspect(results)

        assert Enum.count(results, &(&1 in [{:error, :exists}, {:error, :stale_writer}])) == 7,
               inspect(results)

        assert [_the_one_commit] = journal(actor, unit)
      end
    end
  end

  describe "update/3 — one serialized read-modify-write" do
    @scroll ["aqua", "skills", "u"]
    @manifest @scroll ++ ["SKILL.md"]

    test "a writer that lands between the read and the write is not overwritten", %{actor: actor} do
      {:ok, _} =
        Arca.Overlay.commit_unit(
          actor,
          @scroll,
          {:files, [{["SKILL.md"], "v0"}]},
          cap: :exempt
        )

      test_pid = self()

      editing =
        Task.async(fn ->
          Arca.Overlay.update(actor, @manifest, fn current ->
            # Parks on the first read alone: a retry reads afresh and does
            # not wait for a message the test has already sent.
            if is_nil(Process.put(:parked, true)) do
              send(test_pid, {:read, current, self()})
              receive do: (:proceed -> :ok)
            end

            {:ok, current <> "+edit"}
          end)
        end)

      assert_receive {:read, "v0", editor}, 5_000

      # A commit — a publish, a pull, a reset — lands the unit afresh
      # while the edit is being made. It takes no lock this edit holds.
      {:ok, _} =
        Arca.Overlay.commit_unit(
          actor,
          @scroll,
          {:files, [{["SKILL.md"], "v1"}]},
          cap: :exempt
        )

      send(editor, :proceed)
      assert :ok = Task.await(editing, 30_000)

      # The edit is made over what the commit published. A rewrite of
      # bytes that are no longer at the path is never written over the
      # bytes that are.
      assert {:ok, "v1+edit"} = Arca.get(actor, @manifest)
    end

    @tag :capture_log
    test "an update that keeps losing is a conflict, and writes nothing", %{actor: actor} do
      {:ok, _} =
        Arca.Overlay.commit_unit(
          actor,
          @scroll,
          {:files, [{["SKILL.md"], "v0"}]},
          cap: :exempt
        )

      # A writer that moves the object between every read and its write:
      # no attempt of the bound can land, and the answer says so rather
      # than overwriting what it never read.
      counter = :counters.new(1, [])

      assert {:error, :conflict} =
               Arca.Overlay.update(actor, @manifest, fn current ->
                 :counters.add(counter, 1, 1)
                 n = :counters.get(counter, 1)
                 :ok = Arca.put(actor, @manifest, "moved-#{n}")
                 {:ok, current <> "+edit"}
               end)

      assert {:ok, bytes} = Arca.get(actor, @manifest)
      assert bytes =~ ~r/^moved-\d+$/
      assert :counters.get(counter, 1) > 1
    end

    test "two updates racing on one object keep both edits", %{actor: actor} do
      {:ok, _} =
        Arca.Overlay.commit_unit(
          actor,
          @scroll,
          {:files, [{["SKILL.md"], "v0"}]},
          cap: :exempt
        )

      test_pid = self()

      slow =
        Task.async(fn ->
          Arca.Overlay.update(actor, @manifest, fn current ->
            if is_nil(Process.put(:parked, true)) do
              send(test_pid, {:read, current, self()})
              receive do: (:proceed -> :ok)
            else
              send(test_pid, {:read_again, current})
            end

            {:ok, current <> "+A"}
          end)
        end)

      # Its read is done and its write has not been made. Nothing is held
      # against the other writer: an update takes no lock, and what keeps
      # the two apart is the precondition each write carries.
      assert_receive {:read, "v0", editor}, 5_000

      assert :ok =
               Arca.Overlay.update(actor, @manifest, fn current ->
                 {:ok, current <> "+B"}
               end)

      assert {:ok, "v0+B"} = Arca.get(actor, @manifest)

      send(editor, :proceed)
      assert :ok = Task.await(slow, 30_000)

      # The slow edit's write met bytes it had not read, so it was not
      # made: it read again and was applied to what the other writer left.
      assert_received {:read_again, "v0+B"}
      assert {:ok, "v0+B+A"} = Arca.get(actor, @manifest)
    end

    test "a shipped unit not yet pulled is not there to update; a pulled one edits", %{
      actor: actor,
      seed_dir: seed
    } do
      shipped = Path.join(seed, "aqua/skills/u")
      File.mkdir_p!(shipped)
      File.write!(Path.join(shipped, "SKILL.md"), "shipped scroll")
      File.write!(Path.join(shipped, "reference.md"), "field tables")

      assert {:error, :not_found} =
               Arca.Overlay.update(actor, @manifest, fn _current ->
                 {:ok, "edited"}
               end)

      :ok = Arca.Overlay.pull_shipped(actor, @scroll)

      assert :ok =
               Arca.Overlay.update(actor, @manifest, fn "shipped scroll" ->
                 {:ok, "edited"}
               end)

      assert {:ok, "edited"} = Arca.get(actor, @manifest)

      assert {:ok, "field tables"} =
               Arca.get(actor, @scroll ++ ["reference.md"])

      assert {:ok, %{changed: [["SKILL.md"]]}} =
               Arca.Overlay.diff_unit(actor, @scroll)
    end

    test "nothing at the path, a path no unit covers, and a declining fun write nothing", %{
      actor: actor
    } do
      assert {:error, :not_found} =
               Arca.Overlay.update(actor, @manifest, fn _ -> {:ok, "x"} end)

      refute Arca.exists?(actor, @manifest)

      for path <- [["data", "x.txt"], ["aqua", "roles"], ["aqua", "roles", "notes.txt"]] do
        assert {:error, :not_overlaid} =
                 Arca.Overlay.update(actor, path, fn _ -> {:ok, "x"} end)
      end

      {:ok, _} =
        Arca.Overlay.commit_unit(
          actor,
          @scroll,
          {:files, [{["SKILL.md"], "v0"}]},
          cap: :exempt
        )

      assert {:error, :declined} =
               Arca.Overlay.update(actor, @manifest, fn "v0" ->
                 {:error, :declined}
               end)

      assert {:ok, "v0"} = Arca.get(actor, @manifest)
    end
  end

  describe "replace_subtree/5 — one subtree of a unit, as its next revision" do
    @built ["components", "tinctures", "local", "built", "1.0.0"]
    @first_build [{["assets", "old.js"], "old"}, {["index.html"], "one"}]

    # The subtree as a reader reads it, in path order.
    defp dist(actor) do
      {:ok, pairs} = Arca.read_subtree(actor, @built ++ ["dist"])
      Enum.sort(pairs)
    end

    # What the unit's directory holds on disk, hidden names included: a
    # staged or retired tree left behind would show here.
    defp on_disk(actor) do
      actor |> Arca.Adapters.Local.build_path(@built) |> File.ls!() |> Enum.sort()
    end

    setup %{actor: actor} do
      {:ok, _} =
        Arca.Overlay.commit_unit(
          actor,
          @built,
          {:files,
           [
             {["cyfr-manifest.json"], ~s({"type":"tincture"})},
             {["src", "main.tsx"], "source"},
             {["dist", "index.html"], "one"},
             {["dist", "assets", "old.js"], "old"}
           ]},
          cap: :exempt
        )

      :ok
    end

    test "the subtree is replaced whole and the rest of the unit is untouched", %{actor: actor} do
      assert :ok =
               Arca.Overlay.replace_subtree(
                 actor,
                 @built,
                 ["dist"],
                 [{["index.html"], "two"}, {["assets", "new.js"], "new"}],
                 cap: {:checked, 6}
               )

      assert {:ok, "two"} = Arca.get(actor, @built ++ ["dist", "index.html"])

      assert {:ok, "new"} =
               Arca.get(actor, @built ++ ["dist", "assets", "new.js"])

      assert {:error, :not_found} =
               Arca.get(actor, @built ++ ["dist", "assets", "old.js"])

      assert {:ok, "source"} = Arca.get(actor, @built ++ ["src", "main.tsx"])

      assert {:ok, ~s({"type":"tincture"})} =
               Arca.get(actor, @built ++ ["cyfr-manifest.json"])

      assert on_disk(actor) == ["cyfr-manifest.json", "dist", "src"]

      # A publication like any other: the row moved and the journal grew.
      assert [%{prior_revision: nil, new_revision: first}, %{prior_revision: first}] =
               journal(actor, @built)
    end

    test "a replacement that fails part-way leaves the previous subtree whole and nothing staged",
         %{actor: actor} do
      assert dist(actor) == @first_build

      assert {:error, :disk_full} =
               Arca.Overlay.replace_subtree(
                 actor,
                 @built,
                 ["dist"],
                 [
                   {["index.html"], "two"},
                   {["assets", "new.js"], fn -> {:error, :disk_full} end}
                 ],
                 cap: :exempt
               )

      assert dist(actor) == @first_build
      assert on_disk(actor) == ["cyfr-manifest.json", "dist", "src"]
    end

    test "readers see the previous subtree until the new one is whole, then the new one",
         %{actor: actor} do
      test_pid = self()

      replacing =
        Task.async(fn ->
          Arca.Overlay.replace_subtree(
            actor,
            @built,
            ["dist"],
            [
              {["index.html"], "two"},
              {["assets", "new.js"],
               fn ->
                 send(test_pid, {:staging, self()})

                 receive do
                   :proceed -> {:ok, "new"}
                 end
               end}
            ],
            cap: :exempt
          )
        end)

      # The new index.html is already staged; no reader sees it, or a
      # subtree without the previous build's assets.
      assert_receive {:staging, replacer}, 5_000

      reader = Task.async(fn -> dist(actor) end)
      assert Task.await(reader) == @first_build
      assert {:ok, "one"} = Arca.get(actor, @built ++ ["dist", "index.html"])

      assert {:ok, entries} = Arca.list_typed(actor, @built)

      assert entries |> Enum.map(&elem(&1, 0)) |> Enum.sort() == [
               "cyfr-manifest.json",
               "dist",
               "src"
             ]

      send(replacer, :proceed)
      assert :ok = Task.await(replacing, 30_000)

      assert dist(actor) == [{["assets", "new.js"], "new"}, {["index.html"], "two"}]
    end

    test "repeated replacements leave no stale assets and nothing staged", %{actor: actor} do
      for n <- 1..3 do
        build = [{["assets", "app-#{n}.js"], "js #{n}"}, {["index.html"], "build #{n}"}]

        assert :ok =
                 Arca.Overlay.replace_subtree(actor, @built, ["dist"], build, cap: :exempt)

        assert dist(actor) == build
        assert on_disk(actor) == ["cyfr-manifest.json", "dist", "src"]
      end

      assert {:ok, "source"} = Arca.get(actor, @built ++ ["src", "main.tsx"])
    end

    test "an adapter that cannot swap a tree publishes the subtree all the same", %{actor: actor} do
      original = Application.get_env(:arca, :storage_adapter)
      Application.put_env(:arca, :storage_adapter, Arca.OverlayTest.NoSwapAdapter)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arca, :storage_adapter, original),
          else: Application.delete_env(:arca, :storage_adapter)
      end)

      assert :ok =
               Arca.Overlay.replace_subtree(
                 actor,
                 @built,
                 ["dist"],
                 [{["index.html"], "two"}],
                 cap: :exempt
               )

      assert dist(actor) == [{["index.html"], "two"}]
      assert {:ok, "source"} = Arca.get(actor, @built ++ ["src", "main.tsx"])

      assert {:ok, ~s({"type":"tincture"})} =
               Arca.get(actor, @built ++ ["cyfr-manifest.json"])

      assert Arca.Overlay.unit_status(actor, @built) == {:ok, :own}
    end

    test "a commit that lands while a replacement stages refuses the replacement", %{actor: actor} do
      test_pid = self()

      replacing =
        Task.async(fn ->
          Arca.Overlay.replace_subtree(
            actor,
            @built,
            ["dist"],
            [
              {["index.html"],
               fn ->
                 send(test_pid, {:staging, self()})

                 receive do
                   :proceed -> {:ok, "two"}
                 end
               end}
            ],
            cap: :exempt
          )
        end)

      assert_receive {:staging, replacer}, 5_000

      # The replacement's draft is live, so another writer is refused; once
      # the draft has outlived its lifetime another writer takes it, and
      # the replacement has lost the unit.
      assert {:error, :stale_writer} =
               Arca.Overlay.commit_unit(
                 actor,
                 @built,
                 {:files, [{["cyfr-manifest.json"], "{}"}]},
                 cap: :exempt
               )

      expire_drafts!()

      assert {:ok, _written} =
               Arca.Overlay.commit_unit(
                 actor,
                 @built,
                 {:files, [{["cyfr-manifest.json"], "{}"}]},
                 cap: :exempt
               )

      send(replacer, :proceed)
      assert {:error, :stale_revision} = Task.await(replacing, 30_000)

      # The loser's objects are gone and were never served.
      assert {:ok, "{}"} = Arca.get(actor, @built ++ ["cyfr-manifest.json"])
      refute Arca.exists?(actor, @built ++ ["dist", "index.html"])

      assert {:ok, []} =
               Arca.list_recursive(
                 actor,
                 Arca.Storage.UnitLocator.staging_prefix(@built)
               )
    end

    test "a tree is replaced only inside a unit, never at one, above one or at its sentinel",
         %{actor: actor} do
      for path <- [
            @built,
            @built ++ ["cyfr-manifest.json"],
            ["components", "tinctures", "local", "built"],
            ["aqua", "roles", "a.md"]
          ] do
        assert {:error, :invalid_path} =
                 Arca.replace_tree(actor, path, [{["x"], "x"}], cap: :exempt),
               "#{Enum.join(path, "/")} was replaced"
      end

      assert {:error, :reserved_name} =
               Arca.replace_tree(
                 actor,
                 @built ++ ["dist"],
                 [{["a.tmp.1"], "x"}],
                 cap: :exempt
               )

      assert {:error, :invalid_path} =
               Arca.replace_tree(actor, @built ++ ["dist"], [{[], "x"}], cap: :exempt)

      assert dist(actor) == @first_build

      assert {:ok, ~s({"type":"tincture"})} =
               Arca.get(actor, @built ++ ["cyfr-manifest.json"])
    end

    test "an incomplete unit has nothing to lay a subtree into", %{actor: actor} do
      :ok = Arca.delete_tree(actor, @built)
      :ok = Arca.put(actor, @built ++ ["src", "main.tsx"], "orphan")

      assert {:error, :not_found} =
               Arca.Overlay.replace_subtree(
                 actor,
                 @built,
                 ["dist"],
                 [{["index.html"], "x"}],
                 cap: :exempt
               )

      refute Arca.exists?(actor, @built ++ ["dist", "index.html"])
    end

    test "the sentinel is not a subtree" do
      assert_raise ArgumentError, fn ->
        Arca.Overlay.replace_subtree(
          Sanctum.Context.actor(Sanctum.TestContext.local()),
          @built,
          ["cyfr-manifest.json"],
          [],
          cap: :exempt
        )
      end
    end
  end

  describe "commit_unit/4 — the one way a unit lands" do
    @own_dir ["components", "catalysts", "local", "committed", "1.0.0"]

    test "every caller names a cap" do
      # `cap:` is `Keyword.fetch!`ed on the first line, so omitting it is a
      # KeyError raised after the work is done, not a compile error. That is
      # how every tincture build came to fail at the store step while its
      # own comment said "cap-exempt": in async mode the raise killed the
      # task, so `record_finished` never ran and `build.status` answered
      # "started" for good.
      root = Path.expand("../../../..", __DIR__)

      offenders =
        root
        |> Path.join("apps/*/lib/**/*.ex")
        |> Prima.Test.SourceTree.files!()
        |> Enum.flat_map(fn path ->
          source = File.read!(path)

          # Each call, with the argument list that follows it.
          ~r/Arca\.Overlay\.commit_unit\(/
          |> Regex.split(source, parts: :infinity)
          |> Enum.drop(1)
          |> Enum.with_index()
          |> Enum.reject(fn {tail, _i} ->
            # The options are the last argument; `cap:` appears before the
            # call's closing paren, which for every real call is inside the
            # next ~400 characters.
            tail |> binary_part(0, min(400, byte_size(tail))) |> String.contains?("cap:")
          end)
          |> Enum.map(fn {_tail, i} ->
            "#{Path.relative_to(path, root)} (call ##{i + 1})"
          end)
        end)
        # The definition itself, which names the option rather than passing it.
        |> Enum.reject(&String.starts_with?(&1, "apps/arca/lib/arca/overlay.ex"))

      assert offenders == [], "commit_unit called with no cap: #{inspect(offenders)}"
    end

    test "files source: sentinel lands last; write order is the return", %{actor: actor} do
      files = [
        {[@sentinel], ~s({"type":"catalyst"})},
        {["a.txt"], "A"},
        {["sub", "b.txt"], fn -> {:ok, "B"} end}
      ]

      assert {:ok, written} =
               Arca.Overlay.commit_unit(actor, @own_dir, {:files, files}, cap: :exempt)

      # The sentinel is written last whatever the list order said.
      assert List.last(written) == [@sentinel]
      assert Enum.sort(written) == Enum.sort([["a.txt"], ["sub", "b.txt"], [@sentinel]])
      assert Arca.Overlay.unit_status(actor, @own_dir) == {:ok, :own}
      assert {:ok, "B"} = Arca.get(actor, @own_dir ++ ["sub", "b.txt"])
    end

    test "a mid-list failure rolls the whole unit back — no partial", %{actor: actor} do
      files = [
        {[@sentinel], ~s({"type":"catalyst"})},
        {["a.txt"], "A"},
        {["b.txt"], fn -> {:error, :enospc} end}
      ]

      assert {:error, :enospc} =
               Arca.Overlay.commit_unit(actor, @own_dir, {:files, files}, cap: :exempt)

      assert {:ok, []} = Arca.list_recursive(actor, Enum.take(@own_dir, 4))
      refute Arca.exists?(actor, @own_dir ++ ["a.txt"])
      assert Arca.Overlay.unit_status(actor, @own_dir) == {:ok, :absent}
    end

    test "a dir unit without sentinel bytes refuses before any write", %{actor: actor} do
      assert {:error, :missing_sentinel} =
               Arca.Overlay.commit_unit(
                 actor,
                 @own_dir,
                 {:files, [{["a.txt"], "A"}]},
                 cap: :exempt
               )

      refute Arca.exists?(actor, @own_dir ++ ["a.txt"])
    end

    test "cap refuses before the first write", %{actor: actor} do
      prev = Application.get_env(:sanctum, :caps)
      Application.put_env(:sanctum, :caps, athanor_storage_bytes: 1)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:sanctum, :caps, prev),
          else: Application.delete_env(:sanctum, :caps)

        Arca.Cache.delete_match({:athanor_usage, :_, :_})
      end)

      files = [{[@sentinel], ~s({"type":"catalyst"})}, {["a.txt"], "AAAA"}]

      assert {:error, {:limit_reached, :athanor_storage_bytes, 1}} =
               Arca.Overlay.commit_unit(actor, @own_dir, {:files, files}, cap: {:checked, 4096})

      refute Arca.exists?(actor, @own_dir ++ ["a.txt"])
    end

    test "a commit replaces the unit wholesale — stale files do not survive", %{actor: actor} do
      first = [{[@sentinel], ~s({"v":1})}, {["old.txt"], "OLD"}]

      assert {:ok, _} =
               Arca.Overlay.commit_unit(actor, @own_dir, {:files, first}, cap: :exempt)

      second = [{[@sentinel], ~s({"v":2})}, {["new.txt"], "NEW"}]

      assert {:ok, _} =
               Arca.Overlay.commit_unit(actor, @own_dir, {:files, second}, cap: :exempt)

      refute Arca.exists?(actor, @own_dir ++ ["old.txt"])
      assert {:ok, "NEW"} = Arca.get(actor, @own_dir ++ ["new.txt"])
      assert {:ok, ~s({"v":2})} = Arca.get(actor, @own_dir ++ [@sentinel])
    end

    test "tree source: streams another Arca tree; sentinel: overrides its manifest", %{
      actor: actor
    } do
      src = ["data", "staging"]
      :ok = Arca.put(actor, src ++ ["a.txt"], "A")
      :ok = Arca.put(actor, src ++ [@sentinel], ~s({"stale":true}))

      assert {:ok, written} =
               Arca.Overlay.commit_unit(actor, @own_dir, {:tree, src, []},
                 cap: :exempt,
                 sentinel: ~s({"stamped":true})
               )

      assert List.last(written) == [@sentinel]

      assert {:ok, ~s({"stamped":true})} =
               Arca.get(actor, @own_dir ++ [@sentinel])

      assert {:ok, "A"} = Arca.get(actor, @own_dir ++ ["a.txt"])
    end

    test "a committed unit at a shipped path is the shipped copy — a restore replaces it",
         %{actor: actor} do
      files = [{[@sentinel], ~s({"mine":true})}, {["own.txt"], "MINE"}]

      assert {:ok, _} =
               Arca.Overlay.commit_unit(actor, @version_dir, {:files, files}, cap: :exempt)

      assert Arca.Overlay.unit_status(actor, @version_dir) == {:ok, :shipped}
      assert {:ok, true} = Arca.Overlay.edited?(actor, @version_dir)

      assert :ok = Arca.Overlay.pull_shipped(actor, @version_dir)
      assert {:ok, false} = Arca.Overlay.edited?(actor, @version_dir)
      refute Arca.exists?(actor, @version_dir ++ ["own.txt"])
    end

    test "a file unit is one plain put — sentinel refused", %{actor: actor} do
      agent = ["aqua", "roles", "mine.md"]

      assert {:ok, [[]]} =
               Arca.Overlay.commit_unit(
                 actor,
                 agent,
                 {:files, [{[], "# mine"}]},
                 cap: :exempt
               )

      assert {:ok, "# mine"} = Arca.get(actor, agent)
      assert Arca.Overlay.unit_status(actor, agent) == {:ok, :own}

      assert_raise ArgumentError, ~r/the put is the commit/, fn ->
        Arca.Overlay.commit_unit(actor, agent, {:files, [{[], "x"}]},
          cap: :exempt,
          sentinel: "x"
        )
      end
    end

    test "a non-unit path is a programmer error", %{actor: actor} do
      assert_raise ArgumentError, ~r/needs a unit path/, fn ->
        Arca.Overlay.commit_unit(
          actor,
          ["components", "catalysts"],
          {:files, []},
          cap: :exempt
        )
      end
    end
  end

  describe "a tenant adapter outage propagates — status never lies" do
    # A status surface must not misreport the athanor's own units as
    # shipped, nor a copy as available, during an outage.
    setup %{actor: actor} do
      :ok = Arca.Overlay.pull_shipped(actor, @version_dir)
      :ok = Arca.put(actor, @version_dir ++ ["notes.txt"], "edited")
      assert Arca.Overlay.unit_status(actor, @version_dir) == {:ok, :shipped}

      original = Application.get_env(:arca, :storage_adapter)
      Application.put_env(:arca, :storage_adapter, Arca.OverlayTest.DownAdapter)

      on_exit(fn ->
        if original,
          do: Application.put_env(:arca, :storage_adapter, original),
          else: Application.delete_env(:arca, :storage_adapter)
      end)

      :ok
    end

    test "listings answer the outage", %{actor: actor} do
      assert {:error, :adapter_down} = Arca.list_typed(actor, ["components"])

      assert {:error, :adapter_down} =
               Arca.list_recursive(actor, ["components"])
    end

    test "status surfaces answer the outage, never :available for a copy", %{actor: actor} do
      assert {:error, :adapter_down} =
               Arca.Overlay.unit_status(actor, @version_dir)

      assert {:error, :adapter_down} =
               Arca.Overlay.unit_statuses(actor, "components")

      assert {:error, :adapter_down} =
               Arca.Overlay.pull_shipped(actor, @version_dir)

      assert {:error, :adapter_down} =
               Arca.Overlay.materialize_shipped(actor, "components")
    end
  end

  describe "a partial aqua skill is not a skill" do
    # `compendium/mcp/aqua_tool.ex` reads the tree directly — `list_typed`,
    # `list_recursive`, `get` — so a half-written skill that read as whole
    # would put its instructions in front of the agent.
    #
    # A skill is a DIRECTORY unit whose sentinel is `SKILL.md` itself
    # (`Compendium.AquaPath.locate/1`), which is the load-bearing detail:
    # a crashed write leaves the manifest absent, so there is nothing to
    # read even if the directory lists.
    test "a skill dir whose SKILL.md never landed cannot be read", %{actor: actor} do
      name = "half-written"
      dir = Compendium.AquaPath.skill_dir(name)

      # A crashed `commit_unit`: the body files landed, the sentinel did not.
      :ok =
        Arca.put(actor, dir ++ ["reference.md"], "step one: do the thing")

      # The unit is not complete, and says so rather than passing for one.
      assert {:ok, status} = Arca.Overlay.unit_status(actor, dir)
      refute status == :shipped

      # And the instructions are unreachable: SKILL.md IS the sentinel.
      assert {:error, :not_found} =
               Arca.get(actor, Compendium.AquaPath.skill_manifest(name))
    end

    test "a completed skill reads and lists normally", %{actor: actor} do
      name = "whole-skill"
      dir = Compendium.AquaPath.skill_dir(name)

      {:ok, _} =
        Arca.Overlay.commit_unit(
          actor,
          dir,
          {:files, [{["SKILL.md"], "# Whole"}, {["reference.md"], "detail"}]},
          cap: :exempt
        )

      assert {:ok, "# Whole"} =
               Arca.get(actor, Compendium.AquaPath.skill_manifest(name))

      assert {:ok, :own} = Arca.Overlay.unit_status(actor, dir)
    end
  end
end
