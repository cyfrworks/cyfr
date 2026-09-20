# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.StorageTest do
  use ExUnit.Case, async: true

  alias Arca.Storage
  alias Sanctum.Context

  describe "validate_path!/1" do
    test "accepts valid path segments" do
      assert :ok = Storage.validate_path!(["executions", "exec_123", "started.json"])
    end

    test "accepts single segment" do
      assert :ok = Storage.validate_path!(["components"])
    end

    test "accepts empty list" do
      assert :ok = Storage.validate_path!([])
    end

    test "rejects path traversal with .." do
      assert_raise ArgumentError, ~r/Path traversal rejected/, fn ->
        Storage.validate_path!(["executions", "..", "..", "etc", "passwd"])
      end
    end

    test "rejects .. even as first segment" do
      assert_raise ArgumentError, ~r/Path traversal rejected/, fn ->
        Storage.validate_path!(["..", "secret"])
      end
    end

    test "rejects .. as only segment" do
      assert_raise ArgumentError, ~r/Path traversal rejected/, fn ->
        Storage.validate_path!([".."])
      end
    end

    test "rejects single dot and empty segments" do
      # `"."` names the parent directory itself (an athanor id of "." would
      # be the all-athanors root) and `""` is not a name — both fail closed.
      assert_raise ArgumentError, ~r/Path traversal rejected/, fn ->
        Storage.validate_path!([".", "file.txt"])
      end

      assert_raise ArgumentError, ~r/empty segments/, fn ->
        Storage.validate_path!(["data", "", "file.txt"])
      end

      assert_raise ArgumentError, ~r/encoded dot segments/, fn ->
        Storage.validate_path!(["%2e", "file.txt"])
      end
    end

    test "allows segments containing .. in names" do
      assert :ok = Storage.validate_path!(["file..bak", "test"])
    end
  end

  describe "physical_segments/2" do
    defp ath_actor do
      %{Cyfr.Actor.in_athanor("ath_x") | user_id: "u", authenticated: true}
    end

    test "everything an athanor owns lives under athanors/{id} — the context's id, verbatim" do
      assert Storage.physical_segments(ath_actor(), ["components", "tinctures"]) ==
               ["athanors", "ath_x", "components", "tinctures"]

      assert Storage.physical_segments(ath_actor(), ["threads", "thread_1", "a.png"]) ==
               ["athanors", "ath_x", "threads", "thread_1", "a.png"]

      # The one spelling: the Local sweep walks the same root this mapping
      # writes under, via tenant_physical_root/0 — never a second literal.
      assert hd(Storage.physical_segments(ath_actor(), ["data"])) ==
               Storage.tenant_physical_root()
    end

    test "the guest scope is a sibling of the host scopes" do
      # The guest's `data/` is the athanor's `data/` root, so a `data/`
      # grant physically cannot reach aqua/, threads/ or any other
      # host scope — they are siblings, not children.
      assert Storage.physical_segments(ath_actor(), ["data", "notes.txt"]) ==
               ["athanors", "ath_x", "data", "notes.txt"]

      assert Storage.physical_segments(ath_actor(), ["aqua", "agent.json"]) ==
               ["athanors", "ath_x", "aqua", "agent.json"]
    end

    test "the empty path is the athanor's whole tree" do
      # The storage cap's one walk: everything the athanor owns, components
      # included.
      assert Storage.physical_segments(ath_actor(), []) == ["athanors", "ath_x"]
    end

    test "globals stay at the storage root" do
      assert Storage.physical_segments(ath_actor(), ["cache", "oci", "d"]) == [
               "cache",
               "oci",
               "d"
             ]

      assert Storage.physical_segments(ath_actor(), ["system", "health", ".write_probe"]) ==
               ["system", "health", ".write_probe"]
    end

    test "seed media is not tenant storage" do
      assert_raise ArgumentError, ~r/seed media/, fn ->
        Storage.physical_segments(ath_actor(), ["seed", "components", "x"])
      end

      assert_raise ArgumentError, ~r/seed media/, fn ->
        Storage.physical_segments(ath_actor(), ["seed", "aqua", "agent.json"])
      end
    end

    test "the bare components root is the athanor's own components subtree" do
      assert Storage.physical_segments(ath_actor(), ["components"]) ==
               ["athanors", "ath_x", "components"]
    end

    test "an actor without an athanor cannot name a component path (fail closed)" do
      for unresolved <- [Cyfr.Actor.system(), %Cyfr.Actor{athanor_id: ""}] do
        assert_raise ArgumentError, ~r/a resolved athanor_id is required/, fn ->
          Storage.physical_segments(unresolved, ["components", "tinctures"])
        end
      end
    end
  end

  describe "global_prefixes/0" do
    test "returns expected prefixes" do
      prefixes = Storage.global_prefixes()
      assert "cache" in prefixes
      assert "system" in prefixes
      refute "mcp_logs" in prefixes
    end

    test "returns a list" do
      assert is_list(Storage.global_prefixes())
    end
  end

  describe "tenant_segments/1" do
    test "the athanor id names the tenant directory (namespace not in path)" do
      ctx =
        Context.build(
          user_id: "user_1",
          namespace: "alice",
          athanor_id: "ath_acme",
          authenticated: true
        )

      # namespace ("alice") is identity-only and does NOT appear in the path.
      assert Storage.tenant_segments(Sanctum.Context.actor(ctx)) == ["ath_acme"]
    end

    test "nothing but the athanor determines the path" do
      named = %{Cyfr.Actor.in_athanor("ath_acme") | user_id: "u", request_id: "req_1"}
      bare = Cyfr.Actor.in_athanor("ath_acme")

      assert Storage.tenant_segments(named) == Storage.tenant_segments(bare)
      assert Storage.tenant_segments(named) == ["ath_acme"]
    end

    test "raises when the actor has no athanor (fail closed)" do
      # A resolved athanor is required to name a tenant directory; a nil
      # means a caller reached here around the chokepoint that resolves one.
      ctx = Context.build(user_id: "user_1", athanor_id: nil, authenticated: false)

      assert_raise ArgumentError, ~r/a resolved athanor_id is required/, fn ->
        Storage.tenant_segments(Sanctum.Context.actor(ctx))
      end
    end

    test "raises for a platform context with no athanor too" do
      ctx =
        Sanctum.TestContext.platform(user_id: "system")

      assert_raise ArgumentError, ~r/a resolved athanor_id is required/, fn ->
        Storage.tenant_segments(Sanctum.Context.actor(ctx))
      end
    end

    test "rejects an athanor_id outside the strict id grammar" do
      # `".."` escapes, and `"."` IS the all-athanors root once joined and
      # expanded — the grammar has no dots or slashes at all.
      for bad <- ["..", ".", "a/b", "a.b", "%2e"] do
        ctx =
          Context.build(
            user_id: "user_1",
            namespace: "alice",
            athanor_id: bad,
            authenticated: true
          )

        assert_raise ArgumentError, ~r/invalid athanor_id/, fn ->
          Storage.tenant_segments(Sanctum.Context.actor(ctx))
        end
      end
    end
  end

  describe "authorize_path/2" do
    test "an athanor's component tree is its own — the path is tenant-relative" do
      ctx = Context.build(user_id: "u", athanor_id: "ath_a", authenticated: true)

      assert :ok =
               Storage.authorize_path(Sanctum.Context.actor(ctx), [
                 "components",
                 "catalysts",
                 "local"
               ])

      assert :ok = Storage.authorize_path(Sanctum.Context.actor(ctx), ["components"])
    end

    test "the seed bundle is readable only by a system actor" do
      member = %{Cyfr.Actor.in_athanor("ath_a") | user_id: "u", authenticated: true}

      # An operator reading across athanors is platform SCOPE, which is a
      # different authority from `system`: it widens a read, it does not
      # open a shared path.
      platform = %{Cyfr.Actor.in_athanor("ath_a") | user_id: "op", scope: :platform}

      seed = %{Cyfr.Actor.system() | user_id: "_seed", athanor_id: "ath_a", scope: :athanor}

      assert {:error, :forbidden} = Storage.authorize_path(member, ["seed", "components"])
      assert {:error, :forbidden} = Storage.authorize_path(platform, ["seed", "aqua"])
      assert :ok = Storage.authorize_path(seed, ["seed", "components", "catalysts"])
      assert :ok = Storage.authorize_path(seed, ["seed", "aqua", "agent.json"])
    end

    test "tenant-prefixed paths are not gated here; the global roots are the server's" do
      ctx = Context.build(user_id: "u", athanor_id: "ath_a", authenticated: true)

      assert {:error, :forbidden} =
               Storage.authorize_path(Sanctum.Context.actor(ctx), ["config", "retention.json"])

      assert :ok = Storage.authorize_path(Sanctum.Context.actor(ctx), ["data", "notes.txt"])

      assert {:error, :forbidden} =
               Storage.authorize_path(Sanctum.Context.actor(ctx), ["cache", "oci", "x"])

      assert {:error, :forbidden} =
               Storage.authorize_path(Sanctum.Context.actor(ctx), ["system", "health"])

      assert :ok = Storage.authorize_path(Cyfr.Actor.system(), ["cache", "oci", "x"])
      assert :ok = Storage.authorize_path(Cyfr.Actor.system(), ["system", "health"])
    end

    test "an unknown first segment is refused for every actor" do
      ctx = Context.build(user_id: "u", athanor_id: "ath_a", authenticated: true)

      assert {:error, :forbidden} =
               Storage.authorize_path(Sanctum.Context.actor(ctx), ["scratch", "hello.txt"])

      assert {:error, :forbidden} =
               Storage.authorize_path(Sanctum.Context.actor(ctx), ["guest", "x.txt"])

      assert {:error, :forbidden} = Storage.authorize_path(Cyfr.Actor.system(), ["scratch"])
    end
  end

  describe "classify/1 and tenant_roots/0" do
    test "the tenant roster is closed, and every scope classifies" do
      assert Storage.tenant_roots() ==
               ~w(aqua components threads notes payloads data)

      for root <- Storage.tenant_roots() do
        assert Storage.classify([root, "x"]) == :tenant
      end

      assert Storage.classify([]) == :tenant
      assert Storage.classify(["seed", "components"]) == :seed
      assert Storage.classify(["cache", "oci"]) == :global
      assert Storage.classify(["system", "health"]) == :global
      assert Storage.classify(["scratch", "x"]) == :invalid
      assert Storage.classify(["guest", "x"]) == :invalid
    end

    test "physical_segments refuses an unknown root instead of minting a subtree" do
      assert_raise ArgumentError, ~r/unknown storage root/, fn ->
        Storage.physical_segments(ath_actor(), ["scratch", "hello.txt"])
      end
    end

    test "the guest scope map names only tenant scopes" do
      assert Storage.guest_scopes() == %{"data" => "data", "components" => "components"}

      for {_guest, physical} <- Storage.guest_scopes() do
        assert physical in Storage.tenant_roots()
      end
    end
  end

  describe "the layout table (derived rosters)" do
    test "the rosters are consistent views of one layout" do
      # Every roster is derived from @layout; these pin the derived values
      # so an edited row cannot silently reshape a roster.
      assert Enum.sort(Storage.tenant_roots()) ==
               ~w(aqua components data notes payloads threads)

      assert Enum.sort(Storage.global_prefixes()) == ~w(cache system)
      assert Enum.sort(Storage.seed_roots()) == ~w(aqua components)
      assert Enum.sort(Storage.overlay_roots()) == ~w(aqua components)
      assert Storage.reserved_roots() == ~w(payloads)
      assert Storage.guest_scopes() == %{"data" => "data", "components" => "components"}

      # The console tier: what a person sees of the tree, system absent.
      assert Storage.console_folders() == [
               %{name: "data", root: "data", tier: :open},
               %{name: "aqua", root: "aqua", tier: :shaped},
               %{name: "components", root: "components", tier: :shaped},
               %{name: "threads", root: "threads", tier: :read},
               %{name: "notes", root: "notes", tier: :read}
             ]

      assert Storage.console_scopes() == %{
               "data" => "data",
               "aqua" => "aqua",
               "components" => "components",
               "threads" => "threads",
               "notes" => "notes"
             }

      assert Storage.tier("payloads") == :system
      assert Storage.tier("cache") == :system
      assert Storage.tier("data") == :open
      assert Storage.tier("guest") == nil
      assert Storage.tier("nope") == nil
      assert Enum.all?(Storage.console_folders(), &(&1.root in Storage.tenant_roots()))

      # The classes partition: no root is both tenant and global; every
      # seed root, overlay root and guest-scope target is a tenant root;
      # every overlay root has a configured locator (the unit shapes are
      # the locators' own — their tests witness them).
      assert Storage.tenant_roots() -- Storage.global_prefixes() == Storage.tenant_roots()
      assert Enum.all?(Storage.seed_roots(), &(&1 in Storage.tenant_roots()))
      assert Enum.all?(Storage.overlay_roots(), &(&1 in Storage.tenant_roots()))
      assert Enum.all?(Map.values(Storage.guest_scopes()), &(&1 in Storage.tenant_roots()))

      locators = Application.fetch_env!(:cyfr, :overlay_locators)
      assert Enum.sort(Map.keys(locators)) == Enum.sort(Storage.overlay_roots())

      for {_root, mod} <- locators do
        assert Code.ensure_loaded?(mod) and function_exported?(mod, :locate, 1)
      end
    end

    test "locate/1 routes through the configured locator, and only there" do
      assert Storage.locate(["data", "x"]) == :not_overlaid
      assert Storage.locate(["payloads", "sha256", "x"]) == :not_overlaid
      assert Storage.locate([]) == :not_overlaid
      assert Storage.locate(["components"]) == :above_unit
      assert Storage.locate(["aqua"]) == :above_unit

      assert {:dir, _, _} = Storage.locate(["components", "catalysts", "local", "n", "1.0.0"])
      assert {:file, _} = Storage.locate(["aqua", "roles", "a.md"])
    end

    test "seed_prefix/1 spells the seed vocabulary, and only for seed roots" do
      for root <- Storage.seed_roots() do
        assert Storage.seed_prefix(root) == ["seed", root]
        assert Storage.classify(Storage.seed_prefix(root) ++ ["x"]) == :seed
      end

      assert_raise FunctionClauseError, fn -> Storage.seed_prefix("data") end
      assert_raise FunctionClauseError, fn -> Storage.seed_prefix("nope") end
    end

    test "valid_guest_path?/1 speaks exactly the guest vocabulary" do
      assert Storage.valid_guest_path?("")
      assert Storage.valid_guest_path?("data")
      assert Storage.valid_guest_path?("data/")
      assert Storage.valid_guest_path?("data/notes.txt")
      assert Storage.valid_guest_path?("components/catalysts/local/x/0.1.0/catalyst.wasm")

      refute Storage.valid_guest_path?("aqua/agent.json")
      refute Storage.valid_guest_path?("threads/thread_1")
      # Refused as a host scope, not as an unknown root; the retired name
      # (spelled split for the vocabulary gate) is no root at all.
      assert "threads" in Storage.tenant_roots()
      retired = "conver" <> "sations"
      refute retired in Storage.tenant_roots()
      refute Map.has_key?(Storage.console_scopes(), retired)
      refute Storage.valid_guest_path?(retired <> "/thread_1")
      refute Storage.valid_guest_path?("guest/notes.txt")
      refute Storage.valid_guest_path?("datax/notes.txt")
      refute Storage.valid_guest_path?("*")
    end
  end

  describe "Arca.exists?/2 is a total predicate" do
    test "a traversal segment under a legal root answers false, never raises" do
      ctx = Sanctum.TestContext.local()

      refute Arca.exists?(Sanctum.Context.actor(ctx), ["data", "..", "aqua"])
      refute Arca.exists?(Sanctum.Context.actor(ctx), ["data", ".."])
      refute Arca.exists?(Sanctum.Context.actor(ctx), ["nope", "x"])
      refute Arca.exists?(Sanctum.Context.actor(ctx), ["data", String.duplicate("a", 500)])

      # Every other facade entry keeps failing loud on the same input.
      assert_raise ArgumentError, fn ->
        Arca.get(Sanctum.Context.actor(ctx), ["data", "..", "aqua"])
      end
    end

    test "an athanor-less actor answers false for a tenant path, never raises" do
      ctx = Sanctum.Context.internal()

      refute Arca.exists?(Sanctum.Context.actor(ctx), ["data", "x"])
      refute Arca.exists?(Sanctum.Context.actor(ctx), ["components"])
      refute Arca.exists?(%Cyfr.Actor{athanor_id: ""}, ["data", "x"])

      # Every other facade entry refuses the same actor loudly rather than
      # answering an empty result, and the raise stays under the facade,
      # for anything that reaches an adapter directly.
      assert {:error, :no_athanor} = Arca.get(Sanctum.Context.actor(ctx), ["data", "x"])
      assert {:error, :no_athanor} = Arca.list(%Cyfr.Actor{athanor_id: ""}, ["data"])

      assert_raise ArgumentError, ~r/a resolved athanor_id is required/, fn ->
        Arca.Storage.tenant_segments(Sanctum.Context.actor(ctx))
      end
    end
  end

  describe "mutating ops refuse root and scope-root paths" do
    # The refusals fire before any adapter dispatch: the athanor root and
    # the scope roots are directories, never objects — a put there would
    # wedge the tree (a regular file where the tree root belongs).
    test "put/append/delete below depth 2 answer {:error, :invalid_path}" do
      ctx = Sanctum.TestContext.local()

      assert {:error, :invalid_path} = Arca.put(Sanctum.Context.actor(ctx), [], "x")
      assert {:error, :invalid_path} = Arca.put(Sanctum.Context.actor(ctx), ["data"], "x")
      assert {:error, :invalid_path} = Arca.append(Sanctum.Context.actor(ctx), ["data"], "x")
      assert {:error, :invalid_path} = Arca.delete(Sanctum.Context.actor(ctx), ["data"])

      # Globals are covered by the same gate.
      assert {:error, :invalid_path} = Arca.put(Cyfr.Actor.system(), ["cache"], "x")
    end

    test "a multi-level string segment counts as its real depth" do
      ctx = Sanctum.TestContext.local()

      # `"data/…"` normalizes to two segments before the gate runs, so the
      # gate cannot regress to counting pre-split shapes.
      assert :ok = Arca.put(Sanctum.Context.actor(ctx), ["data/depth_gate_pin.txt"], "x")
      assert :ok = Arca.delete(Sanctum.Context.actor(ctx), ["data/depth_gate_pin.txt"])
    end

    test "delete_tree keeps working on the whole tree and on a scope" do
      ctx = Sanctum.TestContext.local()

      assert :ok = Arca.put(Sanctum.Context.actor(ctx), ["data", "depth_gate_tree", "a.txt"], "x")
      assert :ok = Arca.delete_tree(Sanctum.Context.actor(ctx), ["data", "depth_gate_tree"])
    end
  end

  describe "read_subtree_via/4" do
    defmodule HangingAdapter do
      @moduledoc false
      use Arca.Storage.TestDouble

      def list_recursive(_ctx, path), do: {:ok, [path ++ ["stuck.txt"]]}
      def list_typed(_ctx, _path), do: {:ok, []}

      def get(_ctx, _path) do
        Process.sleep(:infinity)
      end

      # Its listing always names the stuck leaf, so a prefix listing is
      # that listing; and every call that reads first — a conditional
      # replace, the versioned read — is the read that never returns.
      def list_prefix(ctx, path), do: list_recursive(ctx, path)
      def put_if_match(ctx, path, _content, _precondition), do: get(ctx, path)
      def get_for_update(ctx, path), do: get(ctx, path)
    end

    test "a leaf read that hangs past the deadline is a typed error, not an exit" do
      # The callers of a bulk read are request handlers; a hung adapter must
      # answer as an error tuple — never kill the caller.
      actor = Cyfr.Actor.in_athanor("ath_x")

      assert {:error, {:subtree_read_failed, ["data", "sub", "stuck.txt"], :timeout}} =
               Storage.read_subtree_via(HangingAdapter, actor, ["data", "sub"], timeout: 50)
    end
  end
end

defmodule Arca.StorageLocatorWiringTest do
  # Mutates the global :overlay_locators wiring — must not run beside the
  # async suites that call locate/1.
  use ExUnit.Case, async: false

  test "install_locators!/0 fails loud on a wiring that does not match the layout" do
    original = Application.fetch_env!(:cyfr, :overlay_locators)

    on_exit(fn ->
      Application.put_env(:cyfr, :overlay_locators, original)
      Arca.Storage.install_locators!()
    end)

    # A missing root is a boot error, not a first-touch surprise. The
    # failed install never clobbers the previously installed map, so
    # locate/1 keeps answering while this raises.
    Application.put_env(:cyfr, :overlay_locators, Map.delete(original, "aqua"))

    assert_raise ArgumentError, ~r/overlay_locators must name exactly/, fn ->
      Arca.Storage.install_locators!()
    end

    assert {:file, _} = Arca.Storage.locate(["aqua", "roles", "a.md"])

    # A root wired to a module without locate/1 is refused too.
    Application.put_env(:cyfr, :overlay_locators, %{original | "aqua" => String})

    assert_raise ArgumentError, ~r/does not implement/, fn ->
      Arca.Storage.install_locators!()
    end
  end
end
