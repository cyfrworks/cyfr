# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.OverlayTest.FailingCopyAdapter do
  @moduledoc false
  use Arca.Storage.TestDouble

  # Fails the materialization mid-copy: the wasm binary never lands.
  def put(_ctx, _path, "WASM-BYTES"), do: {:error, :enospc}
  def put(ctx, path, content), do: Arca.Adapters.Local.put(ctx, path, content)
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

  def put(ctx, path, content) do
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

    Arca.Adapters.Local.put(ctx, path, content)
  end
end

defmodule Arca.OverlayTest.NoSwapAdapter do
  @moduledoc false
  # A tenant adapter that exports no `replace_tree/3` — an object store's
  # shape. Everything else answers as the Local adapter does.
  use Arca.Storage.TestDouble
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
  def list_prefix(ctx, path), do: list_recursive(ctx, path)
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

  # The athanor's own unit, landed the one way a unit lands.
  defp own_unit!(ctx, unit, completion, files \\ []) do
    source =
      case Arca.Storage.locate(unit) do
        {:file, ^unit} -> {:files, [{[], completion}]}
        {:dir, ^unit, sentinel} -> {:files, [{[sentinel], completion} | files]}
      end

    {:ok, _written} = Arca.Overlay.commit_unit(ctx, unit, source, cap: :exempt)
    :ok
  end

  defp journal(ctx, unit) do
    {root, key} = Arca.Storage.UnitLocator.unit_key(unit)
    {:ok, commits} = Arca.StorageUnits.journal(Sanctum.Context.actor(ctx), root, key)
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
    Application.put_env(:cyfr, :storage_adapter, Arca.OverlayTest.GatedStagingAdapter)

    on_exit(fn ->
      Arca.OverlayTest.GatedStagingAdapter.disarm()
      Application.put_env(:cyfr, :storage_adapter, Arca.Adapters.Local)
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

    test "a junk shape under components/ is plain storage — never a unit", %{ctx: ctx} do
      # Only the grammar mints a unit: no lock, no status entry for a
      # shape the domain would never name.
      junk = ["components", "junk", "a", "b", "not-semver"]
      assert Arca.Storage.locate(junk ++ ["file.txt"]) == :above_unit

      :ok = Arca.put(ctx, junk ++ ["file.txt"], "stray")

      assert Arca.Overlay.unit_status(ctx, junk) == {:ok, :absent}
      assert {:ok, statuses} = Arca.Overlay.unit_statuses(ctx, "components")
      refute Map.has_key?(statuses, junk)
    end
  end

  describe "the athanor's tree answers alone" do
    test "a shipped unit the athanor has not pulled is invisible to every reader — and available",
         %{ctx: ctx} do
      assert {:error, :not_found} = Arca.get(ctx, @version_dir ++ [@sentinel])
      refute Arca.exists?(ctx, @version_dir ++ ["catalyst.wasm"])
      assert {:ok, []} = Arca.list_typed(ctx, ["components"])
      assert {:ok, []} = Arca.list_recursive(ctx, ["components"])
      assert {:ok, %{files: 0, bytes: 0}} = Arca.usage(ctx, ["components"])

      # What the seed ships is a fact the status surfaces still answer.
      assert Arca.Overlay.unit_status(ctx, @version_dir) == {:ok, :available}
      assert {:ok, %{@version_dir => :available}} = Arca.Overlay.unit_statuses(ctx, "components")
      assert {:ok, [@version_dir]} = Arca.Overlay.shipped_units("components")
    end

    test "a path outside the seeded roots is untouched", %{ctx: ctx} do
      assert {:error, :not_found} = Arca.get(ctx, ["data", "nope.txt"])
      refute Arca.exists?(ctx, ["data", "nope.txt"])
      assert {:ok, []} = Arca.Overlay.shipped_units("data")
    end
  end

  describe "pulling what ships" do
    test "pull_shipped/2 copies the unit whole — droppings excluded, sentinel last, uncapped",
         %{ctx: ctx} do
      prev = Application.get_env(:cyfr, :caps)
      Application.put_env(:cyfr, :caps, athanor_storage_bytes: 5)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:cyfr, :caps, prev),
          else: Application.delete_env(:cyfr, :caps)

        Arca.Cache.delete_match({:athanor_usage, :_, :_})
      end)

      Arca.Cache.init()
      Arca.Cache.delete_match({:athanor_usage, :_, :_})

      # Shipped media lands whatever the cap says.
      assert :ok = Arca.Overlay.pull_shipped(ctx, @version_dir)

      assert {:ok, "WASM-BYTES"} = Arca.get(ctx, @version_dir ++ ["catalyst.wasm"])
      assert {:ok, "fn main() {}"} = Arca.get(ctx, @version_dir ++ ["src", "lib.rs"])
      assert Arca.Adapters.Local.exists?(ctx, @version_dir ++ [@sentinel])
      refute Arca.exists?(ctx, @version_dir ++ ["src", "target", "junk.o"])

      # The copy is real tenant bytes now — the cap sees it.
      assert {:ok, %{files: files, bytes: bytes}} = Arca.usage(ctx, ["components"])
      assert files >= 3
      assert bytes > 0

      assert Arca.Overlay.unit_status(ctx, @version_dir) == {:ok, :shipped}

      # A member's own write is still capped.
      assert {:error, {:limit_reached, :athanor_storage_bytes, 5}} =
               Arca.put(ctx, @version_dir ++ ["notes.txt"], "hi")
    end

    test "materialize_shipped/2 copies every available unit and leaves the rest alone", %{
      ctx: ctx,
      seed_dir: seed
    } do
      v2 = ship_version!(seed, "bundled", "2.0.0", "V2")
      own = ["components", "catalysts", "local", "brand-new", "0.1.0"]
      :ok = Arca.put(ctx, own ++ ["catalyst.wasm"], "NEW")

      assert {:ok, copied} = Arca.Overlay.materialize_shipped(ctx, "components")
      assert Enum.sort(copied) == Enum.sort([@version_dir, v2])

      {:ok, statuses} = Arca.Overlay.unit_statuses(ctx, "components")
      assert %{@version_dir => :shipped, ^v2 => :shipped, ^own => :own} = statuses

      # Edits survive a second fill: only what is still available is copied.
      :ok = Arca.put(ctx, @version_dir ++ ["notes.txt"], "edited")
      assert {:ok, []} = Arca.Overlay.materialize_shipped(ctx, "components")
      assert {:ok, "edited"} = Arca.get(ctx, @version_dir ++ ["notes.txt"])
    end

    test "a pull replaces whatever stands at a shipped path", %{ctx: ctx, seed_dir: seed} do
      # A crashed copy: some files, no sentinel. It reads as available, and
      # the next pull replaces it whole.
      :ok = Arca.put(ctx, @version_dir ++ ["src", "lib.rs"], "fn pwned() {}")
      assert Arca.Overlay.unit_status(ctx, @version_dir) == {:ok, :available}
      assert :ok = Arca.Overlay.pull_shipped(ctx, @version_dir)
      assert {:ok, "fn main() {}"} = Arca.get(ctx, @version_dir ++ ["src", "lib.rs"])

      # A complete unit the athanor wrote at a path a release ships is the
      # shipped copy from then on: a pull puts the shipped bytes there.
      mine = ["components", "catalysts", "local", "mine", "1.0.0"]
      :ok = own_unit!(ctx, mine, ~s({"mine":true}))
      _ = ship_version!(seed, "mine", "1.0.0", "SHIPPED")
      assert Arca.Overlay.unit_status(ctx, mine) == {:ok, :shipped}
      assert :ok = Arca.Overlay.pull_shipped(ctx, mine)
      assert {:ok, ~s({"type":"catalyst"})} = Arca.get(ctx, mine ++ [@sentinel])
      assert {:ok, "SHIPPED"} = Arca.get(ctx, mine ++ ["catalyst.wasm"])

      # What the seed does not ship cannot be pulled; a non-unit path is a
      # programmer error the verb refuses typed.
      absent = ["components", "catalysts", "local", "nope", "9.9.9"]
      assert {:error, :not_shipped} = Arca.Overlay.pull_shipped(ctx, absent)
      assert {:error, :not_a_unit} = Arca.Overlay.pull_shipped(ctx, @version_dir ++ ["src"])
      assert {:error, :not_overlaid} = Arca.Overlay.pull_shipped(ctx, ["components"])
      assert {:error, :not_overlaid} = Arca.Overlay.pull_shipped(ctx, ["data", "x"])
    end

    test "a failed copy rolls back — nothing lingers, and the healed pull lands", %{ctx: ctx} do
      original = Application.get_env(:cyfr, :storage_adapter)
      Application.put_env(:cyfr, :storage_adapter, Arca.OverlayTest.FailingCopyAdapter)

      on_exit(fn ->
        if original,
          do: Application.put_env(:cyfr, :storage_adapter, original),
          else: Application.delete_env(:cyfr, :storage_adapter)
      end)

      assert {:error, :enospc} = Arca.Overlay.pull_shipped(ctx, @version_dir)

      refute Arca.Adapters.Local.exists?(ctx, @version_dir ++ ["src", "lib.rs"])
      assert Arca.Overlay.unit_status(ctx, @version_dir) == {:ok, :available}

      Application.put_env(:cyfr, :storage_adapter, original || Arca.Adapters.Local)
      assert :ok = Arca.Overlay.pull_shipped(ctx, @version_dir)
      assert Arca.Overlay.unit_status(ctx, @version_dir) == {:ok, :shipped}
    end

    test "a seed unit without its sentinel is broken install media — the pull refuses", %{
      ctx: ctx,
      seed_dir: seed
    } do
      stray = Path.join([seed, "components", "catalysts", "local", "stray", "1.0.0"])
      File.mkdir_p!(stray)
      File.write!(Path.join(stray, "catalyst.wasm"), "STRAY")

      assert {:error, {:materialize_failed, :seed_sentinel_missing}} =
               Arca.Overlay.pull_shipped(ctx, [
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
         %{ctx: ctx} do
      :ok = Arca.Overlay.pull_shipped(ctx, @version_dir)
      :ok = Arca.put(ctx, @version_dir ++ ["notes.txt"], "hi")

      assert {:ok, "hi"} = Arca.get(ctx, @version_dir ++ ["notes.txt"])
      assert Arca.Overlay.unit_status(ctx, @version_dir) == {:ok, :shipped}
      assert {:ok, true} = Arca.Overlay.edited?(ctx, @version_dir)

      fresh = ["components", "catalysts", "local", "brand-new", "0.1.0"]
      :ok = Arca.put(ctx, fresh ++ ["catalyst.wasm"], "NEW")
      assert {:ok, [{"catalyst.wasm", :file}]} = Arca.list_typed(ctx, fresh)
      assert Arca.Overlay.unit_status(ctx, fresh) == {:ok, :own}
    end

    test "a forged magic-string context carries no exemption", %{ctx: ctx} do
      :ok = Arca.Overlay.pull_shipped(ctx, @version_dir)

      shaped =
        Sanctum.internal_context(user_id: "_overlay", athanor_id: ctx.athanor_id, scope: :athanor)

      assert {:error, :bundled} = Arca.delete_tree(shaped, @version_dir)
      assert Arca.exists?(ctx, @version_dir ++ ["catalyst.wasm"])
    end
  end

  describe "deletes" do
    test "a shipped copy refuses deletion whole — inside it, a delete is an edit", %{
      ctx: ctx,
      seed_dir: seed
    } do
      :ok = Arca.Overlay.pull_shipped(ctx, @version_dir)

      assert {:error, :bundled} = Arca.delete_tree(ctx, @version_dir)
      assert Arca.exists?(ctx, @version_dir ++ ["catalyst.wasm"])

      assert :ok = Arca.delete(ctx, @version_dir ++ ["catalyst.wasm"])
      refute Arca.exists?(ctx, @version_dir ++ ["catalyst.wasm"])
      assert Arca.Overlay.unit_status(ctx, @version_dir) == {:ok, :shipped}
      assert {:ok, %{removed: [["catalyst.wasm"]]}} = Arca.Overlay.diff_unit(ctx, @version_dir)

      role = ship_role!(seed, "a.md", "shipped")
      :ok = Arca.Overlay.pull_shipped(ctx, role)
      assert {:error, :bundled} = Arca.delete(ctx, role)
      assert {:ok, "shipped"} = Arca.get(ctx, role)
    end

    test "the athanor's own unit deletes plainly", %{ctx: ctx} do
      own = ["components", "catalysts", "local", "brand-new", "0.1.0"]
      :ok = Arca.put(ctx, own ++ [@sentinel], ~s({"type":"catalyst"}))
      assert Arca.Overlay.unit_status(ctx, own) == {:ok, :own}

      assert :ok = Arca.delete_tree(ctx, own)
      assert Arca.Overlay.unit_status(ctx, own) == {:ok, :absent}
    end

    test "above the shadow unit, deletes touch only the athanor's own tree", %{ctx: ctx} do
      # Nothing held: the tree delete is a no-op on tenant bytes and is not
      # refused — the unit-level refusal is for shipped copies.
      assert :ok = Arca.delete_tree(ctx, ["components"])
      assert {:ok, [@version_dir]} = Arca.Overlay.shipped_units("components")
    end
  end

  describe "unit status and drift" do
    test "unit_status/2 tells the four states apart", %{ctx: ctx, seed_dir: seed} do
      assert Arca.Overlay.unit_status(ctx, @version_dir) == {:ok, :available}

      :ok = Arca.Overlay.pull_shipped(ctx, @version_dir)
      assert Arca.Overlay.unit_status(ctx, @version_dir) == {:ok, :shipped}

      # An edit does not change whose unit it is.
      :ok = Arca.put(ctx, @version_dir ++ ["notes.txt"], "edited")
      assert Arca.Overlay.unit_status(ctx, @version_dir) == {:ok, :shipped}

      own = ["components", "catalysts", "local", "brand-new", "0.1.0"]
      :ok = Arca.put(ctx, own ++ ["catalyst.wasm"], "NEW")
      assert Arca.Overlay.unit_status(ctx, own) == {:ok, :own}

      # The athanor's own complete unit at a path a later release ships
      # is a shipped copy from then on.
      mine = ["components", "catalysts", "local", "mine", "1.0.0"]
      :ok = own_unit!(ctx, mine, ~s({"type":"catalyst"}))
      assert Arca.Overlay.unit_status(ctx, mine) == {:ok, :own}
      _ = ship_version!(seed, "mine", "1.0.0", "SHIPPED")
      assert Arca.Overlay.unit_status(ctx, mine) == {:ok, :shipped}

      absent = ["components", "catalysts", "local", "nope", "9.9.9"]
      assert Arca.Overlay.unit_status(ctx, absent) == {:ok, :absent}

      # Longer paths answer for their unit; non-overlaid roots are :absent.
      assert Arca.Overlay.unit_status(ctx, @version_dir ++ ["notes.txt"]) == {:ok, :shipped}
      assert Arca.Overlay.unit_status(ctx, ["data", "x"]) == {:ok, :absent}
    end

    test "unit_statuses/2 answers the whole root in two listings, matching unit_status/2",
         %{ctx: ctx, seed_dir: seed} do
      own = ["components", "catalysts", "local", "brand-new", "0.1.0"]
      :ok = Arca.put(ctx, own ++ ["catalyst.wasm"], "NEW")

      assert {:ok, %{@version_dir => :available, ^own => :own}} =
               Arca.Overlay.unit_statuses(ctx, "components")

      :ok = Arca.Overlay.pull_shipped(ctx, @version_dir)
      v2 = ship_version!(seed, "bundled", "2.0.0", "V2")
      :ok = Arca.Overlay.pull_shipped(ctx, v2)
      :ok = Arca.put(ctx, v2 ++ ["notes.txt"], "edited")
      v3 = ship_version!(seed, "bundled", "3.0.0", "V3")

      {:ok, statuses} = Arca.Overlay.unit_statuses(ctx, "components")

      assert %{@version_dir => :shipped, ^v2 => :shipped, ^v3 => :available, ^own => :own} =
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
      :ok = Arca.Overlay.pull_shipped(ctx, @version_dir)

      assert {:ok, %{added: [], removed: [], changed: []}} =
               Arca.Overlay.diff_unit(ctx, @version_dir)

      :ok = Arca.put(ctx, @version_dir ++ ["catalyst.wasm"], "EDITED")
      :ok = Arca.put(ctx, @version_dir ++ ["extra.txt"], "extra")

      assert {:ok, %{added: [["extra.txt"]], removed: [], changed: [["catalyst.wasm"]]}} =
               Arca.Overlay.diff_unit(ctx, @version_dir)
    end

    test "a file-shaped unit diffs by its bytes — an edited agent is never 'pristine'", %{
      ctx: ctx,
      seed_dir: seed
    } do
      file = ship_role!(seed, "a.md", "shipped body")
      :ok = Arca.Overlay.pull_shipped(ctx, file)
      assert {:ok, %{added: [], removed: [], changed: []}} = Arca.Overlay.diff_unit(ctx, file)

      :ok = Arca.put(ctx, file, "edited body")
      assert {:ok, %{added: [], removed: [], changed: [[]]}} = Arca.Overlay.diff_unit(ctx, file)
      assert {:ok, true} = Arca.Overlay.edited?(ctx, file)
      assert Arca.Overlay.unit_status(ctx, file) == {:ok, :shipped}

      # A restore brings the shipped bytes back.
      assert :ok = Arca.Overlay.pull_shipped(ctx, file)
      assert {:ok, "shipped body"} = Arca.get(ctx, file)
      assert {:ok, false} = Arca.Overlay.edited?(ctx, file)
    end
  end

  describe "the revert verbs" do
    test "pull_shipped/2 restores a held copy whatever was written into it", %{
      ctx: ctx,
      seed_dir: seed
    } do
      :ok = Arca.Overlay.pull_shipped(ctx, @version_dir)
      :ok = Arca.put(ctx, @version_dir ++ ["catalyst.wasm"], "EDITED")
      :ok = Arca.put(ctx, @version_dir ++ ["notes.txt"], "note")
      assert {:ok, true} = Arca.Overlay.edited?(ctx, @version_dir)

      assert :ok = Arca.Overlay.pull_shipped(ctx, @version_dir)
      assert {:ok, false} = Arca.Overlay.edited?(ctx, @version_dir)
      assert {:ok, "WASM-BYTES"} = Arca.get(ctx, @version_dir ++ ["catalyst.wasm"])
      refute Arca.exists?(ctx, @version_dir ++ ["notes.txt"])

      # Restoring an unedited copy changes nothing and answers the same.
      assert :ok = Arca.Overlay.pull_shipped(ctx, @version_dir)

      # The athanor's own work has nothing shipped to restore to.
      own = ["components", "catalysts", "local", "brand-new", "0.1.0"]
      :ok = Arca.put(ctx, own ++ ["catalyst.wasm"], "NEW")
      assert {:error, :not_shipped} = Arca.Overlay.pull_shipped(ctx, own)
      assert {:ok, "NEW"} = Arca.get(ctx, own ++ ["catalyst.wasm"])

      # A shipped unit the athanor does not hold is copied in — the same
      # verb is the pull.
      v2 = ship_version!(seed, "bundled", "2.0.0", "V2")
      assert :ok = Arca.Overlay.pull_shipped(ctx, v2)
      assert {:ok, "V2"} = Arca.get(ctx, v2 ++ ["catalyst.wasm"])
    end

    test "drop_unit/2 deletes the athanor's own work and refuses a shipped copy", %{
      ctx: ctx,
      seed_dir: seed
    } do
      # Own work with nothing underneath is simply gone.
      own = ["components", "catalysts", "local", "brand-new", "0.1.0"]
      :ok = Arca.put(ctx, own ++ ["catalyst.wasm"], "NEW")
      assert {:ok, :deleted} = Arca.Overlay.drop_unit(ctx, own)
      assert Arca.Overlay.unit_status(ctx, own) == {:ok, :absent}

      # A shipped copy — edited or not, and whoever wrote it — is restored,
      # never deleted.
      :ok = Arca.Overlay.pull_shipped(ctx, @version_dir)
      assert {:error, :bundled} = Arca.Overlay.drop_unit(ctx, @version_dir)
      :ok = Arca.put(ctx, @version_dir ++ ["notes.txt"], "edited")
      assert {:error, :bundled} = Arca.Overlay.drop_unit(ctx, @version_dir)

      mine = ["components", "catalysts", "local", "mine", "1.0.0"]
      :ok = own_unit!(ctx, mine, ~s({"mine":true}))
      _ = ship_version!(seed, "mine", "1.0.0", "SHIPPED")
      assert {:error, :bundled} = Arca.Overlay.drop_unit(ctx, mine)

      # What the athanor does not hold is not found; outside the units is
      # not a unit.
      v2 = ship_version!(seed, "bundled", "2.0.0", "V2")
      assert {:error, :not_found} = Arca.Overlay.drop_unit(ctx, v2)
      assert {:error, :not_found} = Arca.Overlay.drop_unit(ctx, own)
      assert {:error, :not_overlaid} = Arca.Overlay.drop_unit(ctx, ["components"])
    end
  end

  describe "a shipped path is a shipped unit, whoever wrote it" do
    test "a unit the athanor created BEFORE a release shipped it becomes the shipped copy", %{
      ctx: ctx,
      seed_dir: seed
    } do
      mine = ["components", "catalysts", "local", "mine", "1.0.0"]
      :ok = own_unit!(ctx, mine, ~s({"type":"catalyst"}), [{["catalyst.wasm"], "MY-WASM"}])
      assert Arca.Overlay.unit_status(ctx, mine) == {:ok, :own}
      assert :ok = Arca.delete_tree(ctx, mine)
      assert Arca.Overlay.unit_status(ctx, mine) == {:ok, :absent}

      :ok = own_unit!(ctx, mine, ~s({"type":"catalyst"}), [{["catalyst.wasm"], "MY-WASM"}])

      # A later release ships the same name and version. The bytes stay
      # until a restore replaces them; the unit reads shipped and edited,
      # and no longer deletes.
      _ = ship_version!(seed, "mine", "1.0.0", "SHIPPED-WASM")

      assert {:ok, "MY-WASM"} = Arca.get(ctx, mine ++ ["catalyst.wasm"])
      assert Arca.Overlay.unit_status(ctx, mine) == {:ok, :shipped}
      assert {:ok, %{^mine => :shipped}} = Arca.Overlay.unit_statuses(ctx, "components")
      assert {:ok, true} = Arca.Overlay.edited?(ctx, mine)
      assert {:error, :bundled} = Arca.delete_tree(ctx, mine)

      assert :ok = Arca.Overlay.pull_shipped(ctx, mine)
      assert {:ok, "SHIPPED-WASM"} = Arca.get(ctx, mine ++ ["catalyst.wasm"])
    end

    test "file-shaped units follow the same rule", %{ctx: ctx, seed_dir: seed} do
      shipped = ship_role!(seed, "shipped.md", "shipped body")
      :ok = Arca.Overlay.pull_shipped(ctx, shipped)
      assert Arca.Overlay.unit_status(ctx, shipped) == {:ok, :shipped}

      :ok = Arca.put(ctx, shipped, "edited body")
      assert Arca.Overlay.unit_status(ctx, shipped) == {:ok, :shipped}
      assert {:ok, true} = Arca.Overlay.edited?(ctx, shipped)

      # An agent the athanor wrote first is a shipped copy once a release
      # ships the same name: it no longer deletes, and a restore replaces it.
      mine = ["aqua", "roles", "mine.md"]
      :ok = own_unit!(ctx, mine, "my body")
      assert Arca.Overlay.unit_status(ctx, mine) == {:ok, :own}
      _ = ship_role!(seed, "mine.md", "shipped later")

      assert Arca.Overlay.unit_status(ctx, mine) == {:ok, :shipped}
      assert {:error, :bundled} = Arca.delete(ctx, mine)
      assert :ok = Arca.Overlay.pull_shipped(ctx, mine)
      assert {:ok, "shipped later"} = Arca.get(ctx, mine)
    end
  end

  describe "copies, commits and edits, with no lock between them" do
    test "concurrent pulls of two units both land", %{ctx: ctx, seed_dir: seed} do
      v2 = ship_version!(seed, "bundled", "2.0.0", "V2")

      [a, b] =
        Task.await_many([
          Task.async(fn -> Arca.Overlay.pull_shipped(ctx, @version_dir) end),
          Task.async(fn -> Arca.Overlay.pull_shipped(ctx, v2) end)
        ])

      assert a == :ok
      assert b == :ok

      {:ok, statuses} = Arca.Overlay.unit_statuses(ctx, "components")
      assert statuses[@version_dir] == :shipped
      assert statuses[v2] == :shipped
    end

    test "while a commit stages, readers keep the previous revision and an edit does not wait",
         %{ctx: ctx} do
      :ok = own_unit!(ctx, @version_dir, ~s({"v":1}), [{["old.txt"], "OLD"}])
      gate_staging!()

      committer =
        Task.async(fn ->
          Arca.Overlay.commit_unit(
            ctx,
            @version_dir,
            {:files, [{[@sentinel], ~s({"v":2})}, {["fresh.txt"], "fresh"}]},
            cap: :exempt
          )
        end)

      assert_receive {:staging, committer_pid}, 10_000

      # Nothing of the staged revision is served, and the unit still reads
      # as it did: the row has not moved.
      assert {:ok, ~s({"v":1})} = Arca.get(ctx, @version_dir ++ [@sentinel])
      assert {:ok, "OLD"} = Arca.get(ctx, @version_dir ++ ["old.txt"])
      refute Arca.exists?(ctx, @version_dir ++ ["fresh.txt"])
      assert Arca.Overlay.unit_status(ctx, @version_dir) == {:ok, :shipped}
      assert [_first] = journal(ctx, @version_dir)

      # An edit of the served revision lands at once: nothing holds the unit.
      assert :ok = Arca.put(ctx, @version_dir ++ ["late.txt"], "late")

      send(committer_pid, :proceed)
      assert {:ok, _written} = Task.await(committer, 30_000)

      # The commit replaced the unit whole: the new revision and nothing of
      # the one it replaced, the edit of that revision included.
      assert {:ok, ~s({"v":2})} = Arca.get(ctx, @version_dir ++ [@sentinel])
      assert {:ok, "fresh"} = Arca.get(ctx, @version_dir ++ ["fresh.txt"])
      refute Arca.exists?(ctx, @version_dir ++ ["old.txt"])
      refute Arca.exists?(ctx, @version_dir ++ ["late.txt"])
      assert [_first, _second] = journal(ctx, @version_dir)
    end

    test "a second writer is refused while a draft is live, and lands once it is given back",
         %{ctx: ctx} do
      gate_staging!()
      unit = ["components", "catalysts", "local", "contended", "1.0.0"]

      source = fn body ->
        {:files, [{[@sentinel], ~s({"type":"catalyst"})}, {["a.txt"], body}]}
      end

      first =
        Task.async(fn -> Arca.Overlay.commit_unit(ctx, unit, source.("A"), cap: :exempt) end)

      assert_receive {:staging, first_pid}, 10_000

      assert {:error, :stale_writer} =
               Arca.Overlay.commit_unit(ctx, unit, source.("B"), cap: :exempt)

      send(first_pid, :proceed)
      assert {:ok, _written} = Task.await(first, 30_000)
      assert {:ok, "A"} = Arca.get(ctx, unit ++ ["a.txt"])

      assert {:ok, _written} = Arca.Overlay.commit_unit(ctx, unit, source.("B"), cap: :exempt)
      assert {:ok, "B"} = Arca.get(ctx, unit ++ ["a.txt"])
      assert [%{prior_revision: nil}, %{prior_revision: prior}] = journal(ctx, unit)
      assert is_binary(prior)
    end

    test "concurrent edits of one copy keep every acknowledged write", %{ctx: ctx} do
      :ok = Arca.Overlay.pull_shipped(ctx, @version_dir)
      writers = 8

      results =
        1..writers
        |> Enum.map(fn i ->
          Task.async(fn -> {i, Arca.put(ctx, @version_dir ++ ["w#{i}.txt"], "body-#{i}")} end)
        end)
        |> Task.await_many(30_000)

      acknowledged = for {i, :ok} <- results, do: i

      assert length(acknowledged) == writers,
             "some writes did not return :ok: #{inspect(results)}"

      for i <- acknowledged do
        assert {:ok, "body-#{i}"} == Arca.get(ctx, @version_dir ++ ["w#{i}.txt"]),
               "w#{i}.txt was acknowledged and then lost"
      end

      assert {:ok, "WASM-BYTES"} = Arca.get(ctx, @version_dir ++ ["catalyst.wasm"])
      assert Arca.Overlay.unit_status(ctx, @version_dir) == {:ok, :shipped}
    end

    test "a unit dropped inside a commit's window is not published by that commit", %{ctx: ctx} do
      # `component.delete` and the publish rollback both reach
      # `Arca.delete_tree` on a version dir. A dir with NO seed behind it,
      # so "gone" reads `:absent` and nothing else.
      dir = ["components", "catalysts", "local", "race-target", "1.0.0"]
      gate_staging!()

      committer =
        Task.async(fn ->
          Arca.Overlay.commit_unit(
            ctx,
            dir,
            {:files, [{[@sentinel], ~s({"type":"catalyst"})}, {["a.txt"], "A"}]},
            cap: :exempt
          )
        end)

      assert_receive {:staging, committer_pid}, 10_000
      assert :ok = Arca.delete_tree(ctx, dir)
      send(committer_pid, :proceed)

      # The drop retired the row the commit staged against, so the commit
      # is refused and leaves nothing: no served object, no staged one.
      assert {:error, :missing_unit} = Task.await(committer, 30_000)
      assert Arca.Overlay.unit_status(ctx, dir) == {:ok, :absent}
      refute Arca.exists?(ctx, dir ++ [@sentinel])
      refute Arca.exists?(ctx, dir ++ ["a.txt"])
      assert {:ok, []} = Arca.list_recursive(ctx, Arca.Storage.UnitLocator.staging_prefix(dir))
      assert journal(ctx, dir) == []
    end

    test "a tree delete above units is refused while a unit stands beneath it", %{
      ctx: ctx,
      seed_dir: seed
    } do
      role = ship_role!(seed, "a.md", "shipped")
      :ok = Arca.Overlay.pull_shipped(ctx, role)
      :ok = Arca.put(ctx, role, "edited")

      # The wholesale form would clear units without retiring their rows;
      # a populated tree refuses at every level above the unit, and the
      # unit stands — a caller walks its units and drops them one at a
      # time, each with its row.
      assert {:error, :above_unit} = Arca.delete_tree(ctx, ["aqua"])
      assert {:error, :above_unit} = Arca.delete_tree(ctx, ["aqua", "roles"])
      assert {:ok, "edited"} = Arca.get(ctx, role)

      # The internal-write scope keeps the wholesale form.
      assert :ok = Arca.Overlay.with_internal_writes(fn -> Arca.delete_tree(ctx, ["aqua"]) end)
      assert Arca.Overlay.unit_status(ctx, role) == {:ok, :available}
    end

    test "a tree above units holding no unit deletes plainly", %{ctx: ctx} do
      # Plain storage a unit grammar never claims — nothing a lock would
      # cover, so the tidy the registry does on an emptied name dir keeps
      # working.
      :ok = Arca.put(ctx, ["aqua", "roles", "notes.txt"], "stray")
      assert :ok = Arca.delete_tree(ctx, ["aqua"])
      refute Arca.exists?(ctx, ["aqua", "roles", "notes.txt"])
    end
  end

  describe "the staging area is the overlay's own" do
    test "a listing from above never shows it; the same name elsewhere is content", %{ctx: ctx} do
      gate_staging!()
      unit = ["components", "catalysts", "local", "staged", "1.0.0"]

      committer =
        Task.async(fn ->
          Arca.Overlay.commit_unit(
            ctx,
            unit,
            {:files, [{[@sentinel], ~s({"type":"catalyst"})}, {["a.txt"], "A"}]},
            cap: :exempt
          )
        end)

      assert_receive {:staging, committer_pid}, 10_000

      # A revision is being staged, and no reader of the tree sees it.
      staging = Arca.Storage.UnitLocator.staging_prefix(unit)
      assert {:ok, [_marker]} = Arca.list_recursive(ctx, staging)
      assert {:ok, []} = Arca.list_typed(ctx, ["components"])
      assert {:ok, []} = Arca.list_recursive(ctx, ["components"])
      assert {:ok, []} = Arca.list_recursive(ctx, [])
      assert {:ok, %{}} = Arca.Overlay.unit_statuses(ctx, "components")
      # Staged bytes are bytes the athanor holds.
      assert {:ok, %{files: 1}} = Arca.usage(ctx, ["components"])

      send(committer_pid, :proceed)
      assert {:ok, _written} = Task.await(committer, 30_000)
      assert {:ok, [{"catalysts", :dir}]} = Arca.list_typed(ctx, ["components"])

      :ok = Arca.put(ctx, ["data", ".staging", "mine.txt"], "mine")
      assert {:ok, [{".staging", :dir}]} = Arca.list_typed(ctx, ["data"])
      assert {:ok, [["data", ".staging", "mine.txt"]]} = Arca.list_recursive(ctx, ["data"])
    end
  end

  describe "always-on decorator" do
    test "paths outside the overlaid roots pass through verbatim", %{ctx: ctx} do
      :ok = Arca.put(ctx, ["data", "sub", "file.txt"], "guest bytes")
      :ok = Arca.put(ctx, ["threads", "thread_1", "blob.bin"], "blob")

      assert {:ok, "guest bytes"} = Arca.get(ctx, ["data", "sub", "file.txt"])
      assert {:ok, [{"sub", :dir}]} = Arca.list_typed(ctx, ["data"])

      # The whole-athanor walk and tree deletes answer as the configured
      # adapter would — no seed merge outside the overlaid roots.
      assert {:ok, %{files: 2}} = Arca.usage(ctx, [])
      assert {:ok, leaves} = Arca.list_recursive(ctx, [])
      assert ["data", "sub", "file.txt"] in leaves

      assert :ok = Arca.delete_tree(ctx, ["threads"])
      refute Arca.exists?(ctx, ["threads", "thread_1", "blob.bin"])
    end

    test "configuring the overlay as the adapter raises instead of recursing", %{ctx: ctx} do
      original = Application.get_env(:cyfr, :storage_adapter)
      Application.put_env(:cyfr, :storage_adapter, Arca.Overlay)

      on_exit(fn ->
        if original,
          do: Application.put_env(:cyfr, :storage_adapter, original),
          else: Application.delete_env(:cyfr, :storage_adapter)
      end)

      assert_raise ArgumentError, ~r/decorator/, fn -> Arca.get(ctx, ["data", "x"]) end
    end
  end

  describe "seed stays read-only" do
    test "no write reaches the seed side, whoever asks", %{ctx: ctx} do
      system =
        Sanctum.internal_context(user_id: "_test", athanor_id: ctx.athanor_id, scope: :athanor)

      assert {:error, :seed_read_only} =
               Arca.put(system, ["seed" | @version_dir] ++ ["x.txt"], "x")

      assert {:error, :seed_read_only} = Arca.put(ctx, ["seed" | @version_dir] ++ ["x.txt"], "x")

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

    defp create(ctx, unit, bytes, opts \\ []) do
      source =
        case Arca.Storage.locate(unit) do
          {:file, ^unit} -> {:files, [{[], bytes}]}
          {:dir, ^unit, sentinel} -> {:files, [{[sentinel], bytes}]}
        end

      Arca.Overlay.commit_unit(ctx, unit, source, [cap: :exempt] ++ opts)
    end

    test "a held shipped copy refuses; a shipped unit not yet pulled is not the athanor's",
         %{ctx: ctx, seed_dir: seed} do
      role = ship_role!(seed, "a.md", "shipped role")
      scroll_dir = Path.join(seed, "aqua/skills/s")
      File.mkdir_p!(scroll_dir)
      File.write!(Path.join(scroll_dir, @skill_manifest), "shipped scroll")
      scroll = ["aqua", "skills", "s"]

      :ok = Arca.Overlay.pull_shipped(ctx, role)
      :ok = Arca.Overlay.pull_shipped(ctx, scroll)
      assert {:error, :exists} = create(ctx, role, "mine", if_absent: true)
      assert {:error, :exists} = create(ctx, scroll, "mine", if_absent: true)
      assert {:ok, "shipped role"} = Arca.get(ctx, role)
      assert {:ok, "shipped scroll"} = Arca.get(ctx, scroll ++ [@skill_manifest])

      # The seed-backed component version the athanor never pulled is not
      # present: a commit lands there, and reads as the shipped copy.
      assert {:ok, _} = create(ctx, @version_dir, ~s({"mine":true}), if_absent: true)
      assert Arca.Overlay.unit_status(ctx, @version_dir) == {:ok, :shipped}
    end

    test "the athanor's own unit refuses and keeps its bytes; an absent one lands", %{ctx: ctx} do
      role = ["aqua", "roles", "b.md"]
      scroll = ["aqua", "skills", "t"]

      assert {:ok, [[]]} = create(ctx, role, "first", if_absent: true)
      assert {:ok, [[@skill_manifest]]} = create(ctx, scroll, "first scroll", if_absent: true)

      assert {:error, :exists} = create(ctx, role, "second", if_absent: true)
      assert {:error, :exists} = create(ctx, scroll, "second scroll", if_absent: true)
      assert {:ok, "first"} = Arca.get(ctx, role)
      assert {:ok, "first scroll"} = Arca.get(ctx, scroll ++ [@skill_manifest])

      # Without the option a commit replaces, as it always has.
      assert {:ok, _} = create(ctx, role, "second")
      assert {:ok, _} = create(ctx, scroll, "second scroll")
      assert {:ok, "second"} = Arca.get(ctx, role)
      assert {:ok, "second scroll"} = Arca.get(ctx, scroll ++ [@skill_manifest])
    end

    test "of concurrent creators of one name, exactly one lands", %{ctx: ctx} do
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
            Task.async(fn -> create(ctx, unit, "creator #{i}", if_absent: true) end)
          end)
          |> Task.await_many(30_000)

        assert Enum.count(results, &match?({:ok, _}, &1)) == 1, inspect(results)

        assert Enum.count(results, &(&1 in [{:error, :exists}, {:error, :stale_writer}])) == 7,
               inspect(results)

        assert [_the_one_commit] = journal(ctx, unit)
      end
    end
  end

  describe "update/3 — one serialized read-modify-write" do
    @scroll ["aqua", "skills", "u"]
    @manifest @scroll ++ ["SKILL.md"]

    test "a queued update reads what the one before it wrote", %{ctx: ctx} do
      {:ok, _} =
        Arca.Overlay.commit_unit(ctx, @scroll, {:files, [{["SKILL.md"], "v0"}]}, cap: :exempt)

      test_pid = self()

      first =
        Task.async(fn ->
          Arca.Overlay.update(ctx, @manifest, fn current ->
            send(test_pid, {:read, self()})

            receive do
              :proceed -> {:ok, current <> "+A"}
            end
          end)
        end)

      assert_receive {:read, first_pid}, 5_000

      second =
        Task.async(fn ->
          Arca.Overlay.update(ctx, @manifest, fn current ->
            send(test_pid, {:second_read, current})
            {:ok, current <> "+B"}
          end)
        end)

      # The second update does not read while the first holds the unit.
      refute_receive {:second_read, _}, 200

      send(first_pid, :proceed)
      assert :ok = Task.await(first, 30_000)
      assert :ok = Task.await(second, 30_000)

      # Serialised: the second read "v0+A", not the "v0" it would have read
      # beside the first — and nothing was lost.
      assert_received {:second_read, "v0+A"}
      assert {:ok, "v0+A+B"} = Arca.get(ctx, @manifest)
    end

    test "a shipped unit not yet pulled is not there to update; a pulled one edits", %{
      ctx: ctx,
      seed_dir: seed
    } do
      shipped = Path.join(seed, "aqua/skills/u")
      File.mkdir_p!(shipped)
      File.write!(Path.join(shipped, "SKILL.md"), "shipped scroll")
      File.write!(Path.join(shipped, "reference.md"), "field tables")

      assert {:error, :not_found} =
               Arca.Overlay.update(ctx, @manifest, fn _current -> {:ok, "edited"} end)

      :ok = Arca.Overlay.pull_shipped(ctx, @scroll)

      assert :ok =
               Arca.Overlay.update(ctx, @manifest, fn "shipped scroll" -> {:ok, "edited"} end)

      assert {:ok, "edited"} = Arca.get(ctx, @manifest)
      assert {:ok, "field tables"} = Arca.get(ctx, @scroll ++ ["reference.md"])
      assert {:ok, %{changed: [["SKILL.md"]]}} = Arca.Overlay.diff_unit(ctx, @scroll)
    end

    test "nothing at the path, a path no unit covers, and a declining fun write nothing", %{
      ctx: ctx
    } do
      assert {:error, :not_found} = Arca.Overlay.update(ctx, @manifest, fn _ -> {:ok, "x"} end)
      refute Arca.exists?(ctx, @manifest)

      for path <- [["data", "x.txt"], ["aqua", "roles"], ["aqua", "roles", "notes.txt"]] do
        assert {:error, :not_overlaid} = Arca.Overlay.update(ctx, path, fn _ -> {:ok, "x"} end)
      end

      {:ok, _} =
        Arca.Overlay.commit_unit(ctx, @scroll, {:files, [{["SKILL.md"], "v0"}]}, cap: :exempt)

      assert {:error, :declined} =
               Arca.Overlay.update(ctx, @manifest, fn "v0" -> {:error, :declined} end)

      assert {:ok, "v0"} = Arca.get(ctx, @manifest)
    end
  end

  describe "replace_subtree/5 — one subtree of a unit, as its next revision" do
    @built ["components", "tinctures", "local", "built", "1.0.0"]
    @first_build [{["assets", "old.js"], "old"}, {["index.html"], "one"}]

    # The subtree as a reader reads it, in path order.
    defp dist(ctx) do
      {:ok, pairs} = Arca.read_subtree(ctx, @built ++ ["dist"])
      Enum.sort(pairs)
    end

    # What the unit's directory holds on disk, hidden names included: a
    # staged or retired tree left behind would show here.
    defp on_disk(ctx) do
      ctx |> Arca.Adapters.Local.build_path(@built) |> File.ls!() |> Enum.sort()
    end

    setup %{ctx: ctx} do
      {:ok, _} =
        Arca.Overlay.commit_unit(
          ctx,
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

    test "the subtree is replaced whole and the rest of the unit is untouched", %{ctx: ctx} do
      assert :ok =
               Arca.Overlay.replace_subtree(
                 ctx,
                 @built,
                 ["dist"],
                 [{["index.html"], "two"}, {["assets", "new.js"], "new"}],
                 cap: {:checked, 6}
               )

      assert {:ok, "two"} = Arca.get(ctx, @built ++ ["dist", "index.html"])
      assert {:ok, "new"} = Arca.get(ctx, @built ++ ["dist", "assets", "new.js"])
      assert {:error, :not_found} = Arca.get(ctx, @built ++ ["dist", "assets", "old.js"])
      assert {:ok, "source"} = Arca.get(ctx, @built ++ ["src", "main.tsx"])
      assert {:ok, ~s({"type":"tincture"})} = Arca.get(ctx, @built ++ ["cyfr-manifest.json"])
      assert on_disk(ctx) == ["cyfr-manifest.json", "dist", "src"]

      # A publication like any other: the row moved and the journal grew.
      assert [%{prior_revision: nil, new_revision: first}, %{prior_revision: first}] =
               journal(ctx, @built)
    end

    test "a replacement that fails part-way leaves the previous subtree whole and nothing staged",
         %{ctx: ctx} do
      assert dist(ctx) == @first_build

      assert {:error, :disk_full} =
               Arca.Overlay.replace_subtree(
                 ctx,
                 @built,
                 ["dist"],
                 [
                   {["index.html"], "two"},
                   {["assets", "new.js"], fn -> {:error, :disk_full} end}
                 ],
                 cap: :exempt
               )

      assert dist(ctx) == @first_build
      assert on_disk(ctx) == ["cyfr-manifest.json", "dist", "src"]
    end

    test "readers see the previous subtree until the new one is whole, then the new one",
         %{ctx: ctx} do
      test_pid = self()

      replacing =
        Task.async(fn ->
          Arca.Overlay.replace_subtree(
            ctx,
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

      reader = Task.async(fn -> dist(ctx) end)
      assert Task.await(reader) == @first_build
      assert {:ok, "one"} = Arca.get(ctx, @built ++ ["dist", "index.html"])

      assert {:ok, entries} = Arca.list_typed(ctx, @built)

      assert entries |> Enum.map(&elem(&1, 0)) |> Enum.sort() == [
               "cyfr-manifest.json",
               "dist",
               "src"
             ]

      send(replacer, :proceed)
      assert :ok = Task.await(replacing, 30_000)

      assert dist(ctx) == [{["assets", "new.js"], "new"}, {["index.html"], "two"}]
    end

    test "repeated replacements leave no stale assets and nothing staged", %{ctx: ctx} do
      for n <- 1..3 do
        build = [{["assets", "app-#{n}.js"], "js #{n}"}, {["index.html"], "build #{n}"}]

        assert :ok = Arca.Overlay.replace_subtree(ctx, @built, ["dist"], build, cap: :exempt)

        assert dist(ctx) == build
        assert on_disk(ctx) == ["cyfr-manifest.json", "dist", "src"]
      end

      assert {:ok, "source"} = Arca.get(ctx, @built ++ ["src", "main.tsx"])
    end

    test "an adapter that cannot swap a tree publishes the subtree all the same", %{ctx: ctx} do
      original = Application.get_env(:cyfr, :storage_adapter)
      Application.put_env(:cyfr, :storage_adapter, Arca.OverlayTest.NoSwapAdapter)

      on_exit(fn ->
        if original,
          do: Application.put_env(:cyfr, :storage_adapter, original),
          else: Application.delete_env(:cyfr, :storage_adapter)
      end)

      assert :ok =
               Arca.Overlay.replace_subtree(ctx, @built, ["dist"], [{["index.html"], "two"}],
                 cap: :exempt
               )

      assert dist(ctx) == [{["index.html"], "two"}]
      assert {:ok, "source"} = Arca.get(ctx, @built ++ ["src", "main.tsx"])
      assert {:ok, ~s({"type":"tincture"})} = Arca.get(ctx, @built ++ ["cyfr-manifest.json"])
      assert Arca.Overlay.unit_status(ctx, @built) == {:ok, :own}
    end

    test "a commit that lands while a replacement stages refuses the replacement", %{ctx: ctx} do
      test_pid = self()

      replacing =
        Task.async(fn ->
          Arca.Overlay.replace_subtree(
            ctx,
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
               Arca.Overlay.commit_unit(ctx, @built, {:files, [{["cyfr-manifest.json"], "{}"}]},
                 cap: :exempt
               )

      expire_drafts!()

      assert {:ok, _written} =
               Arca.Overlay.commit_unit(ctx, @built, {:files, [{["cyfr-manifest.json"], "{}"}]},
                 cap: :exempt
               )

      send(replacer, :proceed)
      assert {:error, :stale_revision} = Task.await(replacing, 30_000)

      # The loser's objects are gone and were never served.
      assert {:ok, "{}"} = Arca.get(ctx, @built ++ ["cyfr-manifest.json"])
      refute Arca.exists?(ctx, @built ++ ["dist", "index.html"])
      assert {:ok, []} = Arca.list_recursive(ctx, Arca.Storage.UnitLocator.staging_prefix(@built))
    end

    test "a tree is replaced only inside a unit, never at one, above one or at its sentinel",
         %{ctx: ctx} do
      for path <- [
            @built,
            @built ++ ["cyfr-manifest.json"],
            ["components", "tinctures", "local", "built"],
            ["aqua", "roles", "a.md"]
          ] do
        assert {:error, :invalid_path} =
                 Arca.replace_tree(ctx, path, [{["x"], "x"}], cap: :exempt),
               "#{Enum.join(path, "/")} was replaced"
      end

      assert {:error, :reserved_name} =
               Arca.replace_tree(ctx, @built ++ ["dist"], [{["a.tmp.1"], "x"}], cap: :exempt)

      assert {:error, :invalid_path} =
               Arca.replace_tree(ctx, @built ++ ["dist"], [{[], "x"}], cap: :exempt)

      assert dist(ctx) == @first_build
      assert {:ok, ~s({"type":"tincture"})} = Arca.get(ctx, @built ++ ["cyfr-manifest.json"])
    end

    test "an incomplete unit has nothing to lay a subtree into", %{ctx: ctx} do
      :ok = Arca.delete_tree(ctx, @built)
      :ok = Arca.put(ctx, @built ++ ["src", "main.tsx"], "orphan")

      assert {:error, :not_found} =
               Arca.Overlay.replace_subtree(ctx, @built, ["dist"], [{["index.html"], "x"}],
                 cap: :exempt
               )

      refute Arca.exists?(ctx, @built ++ ["dist", "index.html"])
    end

    test "the sentinel is not a subtree" do
      assert_raise ArgumentError, fn ->
        Arca.Overlay.replace_subtree(
          Sanctum.TestContext.local(),
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
        |> Cyfr.Test.SourceTree.files!()
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
        |> Enum.reject(&String.starts_with?(&1, "apps/cyfr/lib/arca/overlay.ex"))

      assert offenders == [], "commit_unit called with no cap: #{inspect(offenders)}"
    end

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

    test "a mid-list failure rolls the whole unit back — no partial", %{ctx: ctx} do
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
      src = ["data", "staging"]
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

    test "a committed unit at a shipped path is the shipped copy — a restore replaces it",
         %{ctx: ctx} do
      files = [{[@sentinel], ~s({"mine":true})}, {["own.txt"], "MINE"}]

      assert {:ok, _} =
               Arca.Overlay.commit_unit(ctx, @version_dir, {:files, files}, cap: :exempt)

      assert Arca.Overlay.unit_status(ctx, @version_dir) == {:ok, :shipped}
      assert {:ok, true} = Arca.Overlay.edited?(ctx, @version_dir)

      assert :ok = Arca.Overlay.pull_shipped(ctx, @version_dir)
      assert {:ok, false} = Arca.Overlay.edited?(ctx, @version_dir)
      refute Arca.exists?(ctx, @version_dir ++ ["own.txt"])
    end

    test "a file unit is one plain put — sentinel refused", %{ctx: ctx} do
      agent = ["aqua", "roles", "mine.md"]

      assert {:ok, [[]]} =
               Arca.Overlay.commit_unit(ctx, agent, {:files, [{[], "# mine"}]}, cap: :exempt)

      assert {:ok, "# mine"} = Arca.get(ctx, agent)
      assert Arca.Overlay.unit_status(ctx, agent) == {:ok, :own}

      assert_raise ArgumentError, ~r/the put is the commit/, fn ->
        Arca.Overlay.commit_unit(ctx, agent, {:files, [{[], "x"}]},
          cap: :exempt,
          sentinel: "x"
        )
      end
    end

    test "a non-unit path is a programmer error", %{ctx: ctx} do
      assert_raise ArgumentError, ~r/needs a unit path/, fn ->
        Arca.Overlay.commit_unit(ctx, ["components", "catalysts"], {:files, []}, cap: :exempt)
      end
    end
  end

  describe "a tenant adapter outage propagates — status never lies" do
    # A status surface must not misreport the athanor's own units as
    # shipped, nor a copy as available, during an outage.
    setup %{ctx: ctx} do
      :ok = Arca.Overlay.pull_shipped(ctx, @version_dir)
      :ok = Arca.put(ctx, @version_dir ++ ["notes.txt"], "edited")
      assert Arca.Overlay.unit_status(ctx, @version_dir) == {:ok, :shipped}

      original = Application.get_env(:cyfr, :storage_adapter)
      Application.put_env(:cyfr, :storage_adapter, Arca.OverlayTest.DownAdapter)

      on_exit(fn ->
        if original,
          do: Application.put_env(:cyfr, :storage_adapter, original),
          else: Application.delete_env(:cyfr, :storage_adapter)
      end)

      :ok
    end

    test "listings answer the outage", %{ctx: ctx} do
      assert {:error, :adapter_down} = Arca.list_typed(ctx, ["components"])
      assert {:error, :adapter_down} = Arca.list_recursive(ctx, ["components"])
    end

    test "status surfaces answer the outage, never :available for a copy", %{ctx: ctx} do
      assert {:error, :adapter_down} = Arca.Overlay.unit_status(ctx, @version_dir)
      assert {:error, :adapter_down} = Arca.Overlay.unit_statuses(ctx, "components")
      assert {:error, :adapter_down} = Arca.Overlay.pull_shipped(ctx, @version_dir)
      assert {:error, :adapter_down} = Arca.Overlay.materialize_shipped(ctx, "components")
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
    test "a skill dir whose SKILL.md never landed cannot be read", %{ctx: ctx} do
      name = "half-written"
      dir = Compendium.AquaPath.skill_dir(name)

      # A crashed `commit_unit`: the body files landed, the sentinel did not.
      :ok = Arca.put(ctx, dir ++ ["reference.md"], "step one: do the thing")

      # The unit is not complete, and says so rather than passing for one.
      assert {:ok, status} = Arca.Overlay.unit_status(ctx, dir)
      refute status == :shipped

      # And the instructions are unreachable: SKILL.md IS the sentinel.
      assert {:error, :not_found} =
               Arca.get(ctx, Compendium.AquaPath.skill_manifest(name))
    end

    test "a completed skill reads and lists normally", %{ctx: ctx} do
      name = "whole-skill"
      dir = Compendium.AquaPath.skill_dir(name)

      {:ok, _} =
        Arca.Overlay.commit_unit(
          ctx,
          dir,
          {:files, [{["SKILL.md"], "# Whole"}, {["reference.md"], "detail"}]},
          cap: :exempt
        )

      assert {:ok, "# Whole"} = Arca.get(ctx, Compendium.AquaPath.skill_manifest(name))
      assert {:ok, :own} = Arca.Overlay.unit_status(ctx, dir)
    end
  end
end
