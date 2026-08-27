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
        Storage.validate_path!(["guest", "", "file.txt"])
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
    defp ath_ctx do
      Context.build(user_id: "u", athanor_id: "ath_x", authenticated: true)
    end

    test "everything an athanor owns lives under athanors/{id} — the context's id, verbatim" do
      assert Storage.physical_segments(ath_ctx(), ["components", "tinctures"]) ==
               ["athanors", "ath_x", "components", "tinctures"]

      assert Storage.physical_segments(ath_ctx(), ["conversations", "conv_1", "a.png"]) ==
               ["athanors", "ath_x", "conversations", "conv_1", "a.png"]

      # The one spelling: the Local sweep walks the same root this mapping
      # writes under, via tenant_physical_root/0 — never a second literal.
      assert hd(Storage.physical_segments(ath_ctx(), ["guest"])) ==
               Storage.tenant_physical_root()
    end

    test "the guest scope is a sibling of the host scopes" do
      # Opus.StorageHandler maps the guest contract's `data/` to `guest/` at
      # the boundary, so a `data/` grant physically cannot reach aqua/,
      # conversations/ or any other host scope — they are siblings, not children.
      assert Storage.physical_segments(ath_ctx(), ["guest", "notes.txt"]) ==
               ["athanors", "ath_x", "guest", "notes.txt"]

      assert Storage.physical_segments(ath_ctx(), ["aqua", "agent.json"]) ==
               ["athanors", "ath_x", "aqua", "agent.json"]
    end

    test "the empty path is the athanor's whole tree" do
      # The storage cap's one walk: everything the athanor owns, components
      # included.
      assert Storage.physical_segments(ath_ctx(), []) == ["athanors", "ath_x"]
    end

    test "globals stay at the storage root" do
      assert Storage.physical_segments(ath_ctx(), ["cache", "oci", "d"]) == ["cache", "oci", "d"]

      assert Storage.physical_segments(ath_ctx(), ["system", "health", ".write_probe"]) ==
               ["system", "health", ".write_probe"]
    end

    test "seed media is not tenant storage" do
      assert_raise ArgumentError, ~r/seed media/, fn ->
        Storage.physical_segments(ath_ctx(), ["seed", "components", "x"])
      end

      assert_raise ArgumentError, ~r/seed media/, fn ->
        Storage.physical_segments(ath_ctx(), ["seed", "aqua", "agent.json"])
      end
    end

    test "the bare components root is the athanor's own components subtree" do
      assert Storage.physical_segments(ath_ctx(), ["components"]) ==
               ["athanors", "ath_x", "components"]
    end

    test "a context without an athanor cannot name a component path (fail closed)" do
      ctx = Context.build(user_id: "op", scope: :platform, athanor_id: nil, authenticated: true)

      assert_raise ArgumentError, ~r/a resolved athanor_id is required/, fn ->
        Storage.physical_segments(ctx, ["components", "tinctures"])
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
      assert Storage.tenant_segments(ctx) == ["ath_acme"]
    end

    test "namespace is ignored — the athanor alone determines the path" do
      with_ns =
        Context.build(
          user_id: "u",
          namespace: "alice",
          athanor_id: "ath_acme",
          authenticated: true
        )

      without_ns = Context.build(user_id: "u", athanor_id: "ath_acme", authenticated: true)

      assert Storage.tenant_segments(with_ns) == Storage.tenant_segments(without_ns)
      assert Storage.tenant_segments(with_ns) == ["ath_acme"]
    end

    test "raises when the context has no athanor (fail closed)" do
      # A resolved athanor is required to name a tenant directory; a nil means
      # a caller bypassed the Sanctum.Context.require_tenant! chokepoint.
      ctx = Context.build(user_id: "user_1", athanor_id: nil, authenticated: false)

      assert_raise ArgumentError, ~r/a resolved athanor_id is required/, fn ->
        Storage.tenant_segments(ctx)
      end
    end

    test "raises for a platform context with no athanor too" do
      ctx =
        Context.build(user_id: "system", scope: :platform, athanor_id: nil, authenticated: true)

      assert_raise ArgumentError, ~r/a resolved athanor_id is required/, fn ->
        Storage.tenant_segments(ctx)
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
          Storage.tenant_segments(ctx)
        end
      end
    end
  end

  describe "authorize_path/2" do
    test "an athanor's component tree is its own — the path is tenant-relative" do
      ctx = Context.build(user_id: "u", athanor_id: "ath_a", authenticated: true)
      assert :ok = Storage.authorize_path(ctx, ["components", "catalysts", "local"])
      assert :ok = Storage.authorize_path(ctx, ["components"])
    end

    test "the seed bundle is readable only by server-internal contexts" do
      member = Context.build(user_id: "u", athanor_id: "ath_a", authenticated: true)

      platform =
        Context.build(user_id: "op", scope: :platform, athanor_id: nil, authenticated: true)

      seed = Sanctum.internal_context(user_id: "_seed", athanor_id: "ath_a", scope: :athanor)

      assert {:error, :forbidden} = Storage.authorize_path(member, ["seed", "components"])
      assert {:error, :forbidden} = Storage.authorize_path(platform, ["seed", "aqua"])
      assert :ok = Storage.authorize_path(seed, ["seed", "components", "catalysts"])
      assert :ok = Storage.authorize_path(seed, ["seed", "aqua", "agent.json"])
    end

    test "tenant-prefixed paths are not gated here; the global roots are the server's" do
      ctx = Context.build(user_id: "u", athanor_id: "ath_a", authenticated: true)
      assert {:error, :forbidden} = Storage.authorize_path(ctx, ["config", "retention.json"])
      assert :ok = Storage.authorize_path(ctx, ["guest", "notes.txt"])
      assert {:error, :forbidden} = Storage.authorize_path(ctx, ["cache", "oci", "x"])
      assert {:error, :forbidden} = Storage.authorize_path(ctx, ["system", "health"])
      assert :ok = Storage.authorize_path(Sanctum.system_context(), ["cache", "oci", "x"])
      assert :ok = Storage.authorize_path(Sanctum.system_context(), ["system", "health"])
    end

    test "an unknown first segment is refused for every context" do
      ctx = Context.build(user_id: "u", athanor_id: "ath_a", authenticated: true)
      assert {:error, :forbidden} = Storage.authorize_path(ctx, ["notes", "hello.txt"])
      assert {:error, :forbidden} = Storage.authorize_path(ctx, ["data", "x.txt"])
      assert {:error, :forbidden} = Storage.authorize_path(Sanctum.system_context(), ["notes"])
    end
  end

  describe "classify/1 and tenant_roots/0" do
    test "the tenant roster is closed, and every scope classifies" do
      assert Storage.tenant_roots() ==
               ~w(aqua components conversations guest meta)

      for root <- Storage.tenant_roots() do
        assert Storage.classify([root, "x"]) == :tenant
      end

      assert Storage.classify([]) == :tenant
      assert Storage.classify(["seed", "components"]) == :seed
      assert Storage.classify(["cache", "oci"]) == :global
      assert Storage.classify(["system", "health"]) == :global
      assert Storage.classify(["notes", "x"]) == :invalid
      assert Storage.classify(["data", "x"]) == :invalid
    end

    test "physical_segments refuses an unknown root instead of minting a subtree" do
      assert_raise ArgumentError, ~r/unknown storage root/, fn ->
        Storage.physical_segments(ath_ctx(), ["notes", "hello.txt"])
      end
    end

    test "the guest scope map names only tenant scopes" do
      assert Storage.guest_scopes() == %{"data" => "guest", "components" => "components"}

      for {_guest, physical} <- Storage.guest_scopes() do
        assert physical in Storage.tenant_roots()
      end
    end
  end

  describe "the layout table (derived rosters)" do
    test "the rosters are consistent views of one layout" do
      # Every roster is derived from @layout; these pin the derived values
      # so an edited row cannot silently reshape a roster.
      assert Enum.sort(Storage.tenant_roots()) == ~w(aqua components conversations guest meta)
      assert Enum.sort(Storage.global_prefixes()) == ~w(cache system)
      assert Enum.sort(Storage.seed_roots()) == ~w(aqua components)
      assert Enum.sort(Storage.overlay_roots()) == ~w(aqua components)
      assert Storage.reserved_roots() == ~w(meta)
      assert Storage.guest_scopes() == %{"data" => "guest", "components" => "components"}

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
      assert Storage.locate(["guest", "x"]) == :not_overlaid
      assert Storage.locate(["meta", "origin", "x"]) == :not_overlaid
      assert Storage.locate([]) == :not_overlaid
      assert Storage.locate(["components"]) == :above_unit
      assert Storage.locate(["aqua"]) == :above_unit

      assert {:dir, _, _} = Storage.locate(["components", "catalysts", "local", "n", "1.0.0"])
      assert {:file, _} = Storage.locate(["aqua", "agents", "a.md"])
    end

    test "seed_prefix/1 spells the seed vocabulary, and only for seed roots" do
      for root <- Storage.seed_roots() do
        assert Storage.seed_prefix(root) == ["seed", root]
        assert Storage.classify(Storage.seed_prefix(root) ++ ["x"]) == :seed
      end

      assert_raise FunctionClauseError, fn -> Storage.seed_prefix("guest") end
      assert_raise FunctionClauseError, fn -> Storage.seed_prefix("nope") end
    end

    test "valid_guest_path?/1 speaks exactly the guest vocabulary" do
      assert Storage.valid_guest_path?("")
      assert Storage.valid_guest_path?("data")
      assert Storage.valid_guest_path?("data/")
      assert Storage.valid_guest_path?("data/notes.txt")
      assert Storage.valid_guest_path?("components/catalysts/local/x/0.1.0/catalyst.wasm")

      refute Storage.valid_guest_path?("aqua/agent.json")
      refute Storage.valid_guest_path?("conversations/conv_1")
      refute Storage.valid_guest_path?("guest/notes.txt")
      refute Storage.valid_guest_path?("datax/notes.txt")
      refute Storage.valid_guest_path?("*")
    end
  end

  describe "Arca.exists?/2 is a total predicate" do
    test "a traversal segment under a legal root answers false, never raises" do
      ctx = Sanctum.TestContext.local()

      refute Arca.exists?(ctx, ["guest", "..", "aqua"])
      refute Arca.exists?(ctx, ["guest", ".."])
      refute Arca.exists?(ctx, ["nope", "x"])
      refute Arca.exists?(ctx, ["guest", String.duplicate("a", 500)])

      # Every other facade entry keeps failing loud on the same input.
      assert_raise ArgumentError, fn -> Arca.get(ctx, ["guest", "..", "aqua"]) end
    end

    test "an athanor-less context answers false for a tenant path, never raises" do
      ctx = Sanctum.Context.internal()

      refute Arca.exists?(ctx, ["guest", "x"])
      refute Arca.exists?(ctx, ["components"])

      # Every other facade entry keeps failing loud on the same context —
      # reaching one without an athanor is host-side programmer error.
      assert_raise ArgumentError, ~r/a resolved athanor_id is required/, fn ->
        Arca.get(ctx, ["guest", "x"])
      end
    end
  end

  describe "mutating ops refuse root and scope-root paths" do
    # The refusals fire before any adapter dispatch: the athanor root and
    # the scope roots are directories, never objects — a put there would
    # wedge the tree (a regular file where the tree root belongs).
    test "put/append/delete below depth 2 answer {:error, :invalid_path}" do
      ctx = Sanctum.TestContext.local()

      assert {:error, :invalid_path} = Arca.put(ctx, [], "x")
      assert {:error, :invalid_path} = Arca.put(ctx, ["guest"], "x")
      assert {:error, :invalid_path} = Arca.append(ctx, ["guest"], "x")
      assert {:error, :invalid_path} = Arca.delete(ctx, ["guest"])

      # Globals are covered by the same gate.
      assert {:error, :invalid_path} = Arca.put(Sanctum.Context.internal(), ["cache"], "x")
    end

    test "a multi-level string segment counts as its real depth" do
      ctx = Sanctum.TestContext.local()

      # `"guest/…"` normalizes to two segments before the gate runs, so the
      # gate cannot regress to counting pre-split shapes.
      assert :ok = Arca.put(ctx, ["guest/depth_gate_pin.txt"], "x")
      assert :ok = Arca.delete(ctx, ["guest/depth_gate_pin.txt"])
    end

    test "delete_tree keeps working on the whole tree and on a scope" do
      ctx = Sanctum.TestContext.local()

      assert :ok = Arca.put(ctx, ["guest", "depth_gate_tree", "a.txt"], "x")
      assert :ok = Arca.delete_tree(ctx, ["guest", "depth_gate_tree"])
    end
  end
end
