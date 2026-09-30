# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.ProfileGrantsTest do
  @moduledoc """
  `profile.grants`: the grants of the caller's athanor whose head
  revision reaches one domain, storage path or vault entry, read as each
  enforcement point would admit it, so no grant shows wider or narrower
  than it runs. Only an active profile's head counts, every edge counts,
  and a read never reaches past the caller's athanor.
  """

  use ExUnit.Case, async: false

  alias Sanctum.Consent.Commit
  alias Sanctum.Consent.Plan
  alias Sanctum.Test.ConsentFixtures

  @wasm File.read!(Path.join(__DIR__, "../../support/test_wasm/math.wasm"))

  @limits %{
    "timeout" => "1m",
    "max_memory_bytes" => 67_108_864,
    "max_request_size" => 1_048_576,
    "max_response_size" => 5_242_880,
    "rate_limit" => %{"requests" => 100, "window" => "1m"},
    "max_concurrent_tasks" => 5,
    "batch_timeout" => "1m"
  }

  @dep "reagent:local.grants-dep"

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "profile_grants_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    {mine, theirs} = Sanctum.TestContext.two_contexts()
    {:ok, ctx: mine, theirs: theirs}
  end

  defp grants(ctx, args),
    do: Grimoire.call_external("profile", ctx, Map.put(args, "action", "grants"))

  defp egress(domains, methods \\ ["GET"], schemes \\ ["https"]),
    do: %{
      "egress" => %{
        "domains" => domains,
        "methods" => methods,
        "schemes" => schemes,
        "private_ips" => []
      }
    }

  defp storage(paths, actions \\ ["read"]),
    do: %{"storage" => %{"paths" => paths, "actions" => actions}}

  defp vault(entry_id),
    do: %{
      "vault" => %{
        "entry_id" => entry_id,
        "binding_digest" => "sha256:binding",
        "projection" => %{"fields" => ["api_key"], "scopes" => []}
      }
    }

  # A head revision whose source node's ingress edge grants `ingress`, and
  # whose other edges (each to `@dep`, keyed by need) grant theirs.
  defp policy(ref, ingress, dep_edges \\ %{}) do
    edges =
      dep_edges
      |> Map.new(fn {need, edge} -> {Prima.Authority.Blob.edge_key(@dep, need), edge} end)
      |> Map.put("@ingress", ingress)

    nodes = %{ref => %{"limits" => @limits, "edges" => edges}}

    nodes =
      if dep_edges == %{},
        do: nodes,
        else: Map.put(nodes, @dep, %{"limits" => @limits, "edges" => %{}})

    Jason.encode!(%{"canonical" => "jcs-1", "nodes" => nodes})
  end

  defp grant!(ctx, name, policy, opts \\ []) do
    id = "prof_#{name}"
    ref = "reagent:local.#{name}"

    :ok =
      ConsentFixtures.seed_head!(
        ctx,
        %{id: id, source_ref: ref, kind: :owner, status: Keyword.get(opts, :status, :active)},
        %{
          id: "cons_#{name}",
          revision: 1,
          scope: :versionless,
          shape_digest: "sha256:shape-#{name}",
          commit_digest: "sha256:commit-#{name}",
          resolved_policy: policy,
          activation: %{ref => "sha256:act"},
          vault_refs: Keyword.get(opts, :vault_refs, [])
        }
      )

    id
  end

  defp grant!(ctx, name), do: grant!(ctx, name, policy("reagent:local.#{name}", %{}))

  defp ids(%{grants: grants}), do: Enum.map(grants, & &1.profile_id)

  describe "a domain" do
    test "is reached as egress pins a host, wildcards included, on every edge", %{ctx: ctx} do
      pattern =
        grant!(ctx, "g-pattern", policy("reagent:local.g-pattern", egress(["*.a.example"])))

      dependency =
        grant!(
          ctx,
          "g-dependency",
          policy("reagent:local.g-dependency", %{}, %{"api" => egress(["API.a.example"])})
        )

      _elsewhere =
        grant!(ctx, "g-elsewhere", policy("reagent:local.g-elsewhere", egress(["b.example"])))

      assert {:ok, answer} = grants(ctx, %{"domain" => "api.a.example"})
      assert answer.resource == %{kind: "domain", value: "api.a.example"}
      assert answer.count == 2
      assert ids(answer) == Enum.sort([pattern, dependency])

      by_id = Map.new(answer.grants, &{&1.profile_id, &1})

      assert %{
               source_ref: "reagent:local.g-pattern",
               kind: "owner",
               label: "default",
               consent_id: "cons_g-pattern",
               revision: 1,
               edges: [
                 %{
                   node: "reagent:local.g-pattern",
                   edge: "@ingress",
                   egress: %{domains: ["*.a.example"], methods: ["GET"], schemes: ["https"]}
                 }
               ]
             } = by_id[pattern]

      assert [%{node: "reagent:local.g-dependency", edge: @dep <> "|api"}] =
               by_id[dependency].edges

      # The pattern names every host below it and not the domain itself.
      assert {:ok, %{grants: [], count: 0}} = grants(ctx, %{"domain" => "a.example"})
    end

    test "needs a method and a scheme, since egress admits nothing without them", %{ctx: ctx} do
      _no_method =
        grant!(ctx, "g-no-method", policy("reagent:local.g-no-method", egress(["c.example"], [])))

      _no_scheme =
        grant!(
          ctx,
          "g-no-scheme",
          policy("reagent:local.g-no-scheme", egress(["c.example"], ["GET"], []))
        )

      whole = grant!(ctx, "g-whole", policy("reagent:local.g-whole", egress(["c.example"])))

      assert {:ok, answer} = grants(ctx, %{"domain" => "c.example"})
      assert ids(answer) == [whole]
    end
  end

  describe "a storage path" do
    test "is reached as the storage door reads a grant, with an action", %{ctx: ctx} do
      notes = grant!(ctx, "g-notes", policy("reagent:local.g-notes", storage(["data/notes/"])))
      everything = grant!(ctx, "g-all", policy("reagent:local.g-all", storage(["*"], ["list"])))

      _no_action =
        grant!(ctx, "g-no-action", policy("reagent:local.g-no-action", storage(["data/"], [])))

      _file = grant!(ctx, "g-file", policy("reagent:local.g-file", storage(["data/notes.md"])))

      # Read as the doors read it: relative to the root, empty segments
      # trimmed.
      assert {:ok, answer} = grants(ctx, %{"path" => "/data//notes/today.md"})
      assert answer.resource == %{kind: "path", value: "data/notes/today.md"}
      assert ids(answer) == Enum.sort([notes, everything])

      assert %{edges: [%{storage: %{paths: ["data/notes/"], actions: ["read"]}}]} =
               Enum.find(answer.grants, &(&1.profile_id == notes))

      # The bare folder a prefix names is a path that prefix admits.
      assert {:ok, answer} = grants(ctx, %{"path" => "data/notes"})
      assert ids(answer) == Enum.sort([notes, everything])

      assert {:ok, answer} = grants(ctx, %{"path" => "data/other.md"})
      assert ids(answer) == [everything]
    end

    test "is reached through a pattern spelled with an empty segment, as the door reaches it",
         %{ctx: ctx} do
      # The door serves data/secrets/key.txt through the guest's spelling
      # data//secrets/key.txt, which this pattern admits as written.
      id =
        grant!(ctx, "g-doubled", policy("reagent:local.g-doubled", storage(["data//secrets/"])))

      assert {:ok, %{grants: [%{profile_id: ^id} = grant]}} =
               grants(ctx, %{"path" => "data/secrets/key.txt"})

      # The grant is shown as it is held.
      assert [%{storage: %{paths: ["data//secrets/"]}}] = grant.edges

      # The same file named with the doubled spelling, and the bare folder.
      for path <- ["data//secrets//key.txt", "data/secrets"] do
        assert {:ok, %{grants: [%{profile_id: ^id}]}} = grants(ctx, %{"path" => path}), path
      end

      # A doubled exact path reaches the one file it names.
      file =
        grant!(
          ctx,
          "g-doubled-file",
          policy("reagent:local.g-doubled-file", storage(["data//a.md"]))
        )

      assert {:ok, %{grants: [%{profile_id: ^file}]}} = grants(ctx, %{"path" => "data/a.md"})
      assert {:ok, %{grants: []}} = grants(ctx, %{"path" => "data/a.md/b"})

      # Beside the folder is not under it.
      assert {:ok, %{grants: []}} = grants(ctx, %{"path" => "data/secretsheet.md"})
    end

    test "a pattern the door refuses every spelling under reaches nothing", %{ctx: ctx} do
      for {name, pattern} <- [
            {"g-dotdot", "data/../secrets/"},
            {"g-encoded", "data/%2e%2e/secrets/"},
            {"g-absolute", "/data/secrets/"},
            {"g-backslash", "data\\secrets/"}
          ] do
        grant!(ctx, name, policy("reagent:local.#{name}", storage([pattern])))
      end

      for path <- ["data/secrets/key.txt", "secrets/key.txt", "data/x"] do
        assert {:ok, %{grants: [], count: 0}} = grants(ctx, %{"path" => path}), path
      end
    end

    test "outside every guest scope answers empty, and an unsafe one is refused", %{ctx: ctx} do
      _everything = grant!(ctx, "g-all-2", policy("reagent:local.g-all-2", storage(["*"])))

      assert {:ok, %{resource: %{value: "cache/x"}, grants: [], count: 0}} =
               grants(ctx, %{"path" => "cache/x"})

      for path <- ["data/../system/x", "data/%2e%2e/x", "/", "//"] do
        assert {:error, {:invalid_argument, "grants: path " <> _}} =
                 grants(ctx, %{"path" => path}),
               path
      end
    end
  end

  describe "a vault entry" do
    test "is reached by its id among the revision's vault references", %{ctx: ctx} do
      entry = "vlt_grants_#{System.unique_integer([:positive])}"
      ref = %{vault_entry_id: entry, binding_digest: "sha256:binding"}

      bound =
        grant!(ctx, "g-bound", policy("reagent:local.g-bound", vault(entry)), vault_refs: [ref])

      lent =
        grant!(
          ctx,
          "g-lent",
          policy("reagent:local.g-lent", %{}, %{"key" => vault(entry)}),
          vault_refs: [ref]
        )

      # References and blob disagree: the loader refuses such a revision,
      # so it reaches nothing through the entry.
      _refs_only =
        grant!(ctx, "g-refs-only", policy("reagent:local.g-refs-only", %{}), vault_refs: [ref])

      _blob_only = grant!(ctx, "g-blob-only", policy("reagent:local.g-blob-only", vault(entry)))

      assert {:ok, answer} = grants(ctx, %{"entry_id" => entry})
      assert answer.resource == %{kind: "entry_id", value: entry}
      assert ids(answer) == Enum.sort([bound, lent])

      assert %{
               edges: [
                 %{
                   edge: "@ingress",
                   vault: %{
                     entry_id: ^entry,
                     binding_digest: "sha256:binding",
                     projection: %{fields: ["api_key"], scopes: []}
                   }
                 }
               ]
             } = Enum.find(answer.grants, &(&1.profile_id == bound))

      # An entry of this athanor that no grant references reaches nothing.
      idle = "vlt_idle_#{System.unique_integer([:positive])}"
      ConsentFixtures.ensure_entry!(ctx, %{vault_entry_id: idle, binding_digest: nil})
      assert {:ok, %{grants: [], count: 0}} = grants(ctx, %{"entry_id" => idle})
    end

    test "of another athanor, or of none, is refused as unknown", %{ctx: ctx, theirs: theirs} do
      entry = "vlt_theirs_#{System.unique_integer([:positive])}"
      ref = %{vault_entry_id: entry, binding_digest: "sha256:binding"}

      _theirs =
        grant!(theirs, "g-theirs-vault", policy("reagent:local.g-theirs-vault", vault(entry)),
          vault_refs: [ref]
        )

      assert {:ok, %{count: 1}} = grants(theirs, %{"entry_id" => entry})

      assert grants(ctx, %{"entry_id" => entry}) ==
               {:error, {:not_found, "Vault entry", entry}}

      assert grants(ctx, %{"entry_id" => "vlt_nowhere"}) ==
               {:error, {:not_found, "Vault entry", "vlt_nowhere"}}
    end
  end

  describe "which grants count" do
    test "only an active profile's: a revoked or waiting one is absent", %{ctx: ctx} do
      reaching = policy("reagent:local.g-active", egress(["d.example"]))
      active = grant!(ctx, "g-active", reaching)

      _revoked =
        grant!(ctx, "g-revoked", policy("reagent:local.g-revoked", egress(["d.example"])),
          status: :revoked
        )

      _waiting =
        grant!(ctx, "g-waiting", policy("reagent:local.g-waiting", egress(["d.example"])),
          status: :needs_consent
        )

      assert {:ok, answer} = grants(ctx, %{"domain" => "d.example"})
      assert ids(answer) == [active]

      # Revoked through the tool: gone from the read at once.
      assert {:ok, %{status: "revoked"}} =
               Grimoire.call_external("profile", ctx, %{
                 "action" => "revoke",
                 "profile_id" => active
               })

      assert {:ok, %{grants: [], count: 0}} = grants(ctx, %{"domain" => "d.example"})
    end

    test "a revision whose policy fails its digest or does not parse reaches nothing",
         %{ctx: ctx} do
      tampered =
        grant!(ctx, "g-tampered", policy("reagent:local.g-tampered", egress(["e.example"])))

      ConsentFixtures.hand_edit_head!(ctx, tampered,
        resolved_policy: policy("reagent:local.g-tampered", egress(["*"]))
      )

      _unparsed = grant!(ctx, "g-unparsed", Jason.encode!(%{"canonical" => "jcs-1"}))

      assert {:ok, %{grants: [], count: 0}} = grants(ctx, %{"domain" => "e.example"})
    end

    test "never another athanor's", %{ctx: ctx, theirs: theirs} do
      theirs_id =
        grant!(theirs, "g-theirs", policy("reagent:local.g-theirs", egress(["f.example"])))

      assert {:ok, %{grants: [], count: 0}} = grants(ctx, %{"domain" => "f.example"})
      assert {:ok, answer} = grants(theirs, %{"domain" => "f.example"})
      assert ids(answer) == [theirs_id]
    end

    test "a narrowed grant reaches only its narrowing, and shows the origins it admits",
         %{ctx: ctx} do
      ref = "reagent:local.grants-narrow"

      {:ok, _component} =
        Compendium.Registry.publish_bytes(ctx, @wasm, %{
          name: "grants-narrow",
          version: "1.0.0",
          type: "reagent",
          manifest:
            Jason.encode!(%{
              "name" => "grants-narrow",
              "version" => "1.0.0",
              "type" => "reagent",
              "caps" => %{
                "egress" => %{
                  "domains" => ["api.one.example", "api.two.example"],
                  "methods" => ["GET"],
                  "schemes" => ["https"]
                },
                "storage" => %{"paths" => ["data/"], "actions" => ["read"]}
              }
            })
        })

      subset = %{
        ref => %{
          "egress" => %{"domains" => ["api.one.example"]},
          "storage" => %{"paths" => ["data/reports/"]}
        }
      }

      decisions = %{ref: ref, subset: subset, origins: [:programmatic, :interactive]}
      {:ok, plan} = Plan.plan(ctx, %{ref: ref})
      {:ok, preview} = Commit.preview(ctx, decisions)

      {:ok, %{profile_id: profile_id}} =
        Commit.commit(ctx, %{
          decisions: decisions,
          plan_token: plan.plan_token,
          proof: preview.proof,
          commit_digest: preview.commit_digest,
          expected_consent_revision: plan.expected_consent_revision
        })

      assert {:ok, %{grants: [grant]}} = grants(ctx, %{"domain" => "api.one.example"})
      assert grant.profile_id == profile_id
      assert grant.admitted_origins == ["interactive", "programmatic"]
      assert [%{egress: %{domains: ["api.one.example"]}}] = grant.edges

      # What the narrowing dropped, no grant reaches.
      assert {:ok, %{grants: []}} = grants(ctx, %{"domain" => "api.two.example"})
      assert {:ok, %{grants: []}} = grants(ctx, %{"path" => "data/other.md"})

      assert {:ok, %{grants: [%{profile_id: ^profile_id}]}} =
               grants(ctx, %{"path" => "data/reports/q3.md"})
    end
  end

  describe "the arguments" do
    test "name exactly one resource, as a non-empty string, and a domain names a host",
         %{ctx: ctx} do
      _any = grant!(ctx, "g-args")

      for args <- [
            %{},
            %{"domain" => "a.example", "path" => "data/a"},
            %{"path" => "data/a", "entry_id" => "vlt_1"}
          ] do
        assert grants(ctx, args) ==
                 {:error,
                  {:invalid_argument, "grants names exactly one of domain, path, entry_id"}},
               inspect(args)
      end

      assert {:error, {:invalid_argument, "grants: domain must be a non-empty string"}} =
               grants(ctx, %{"domain" => ""})

      for pattern <- ["*.a.example", "*"] do
        assert grants(ctx, %{"domain" => pattern}) ==
                 {:error, {:invalid_argument, "grants: domain names one host, never a pattern"}}
      end
    end

    test "the read is a person's, never a guest's" do
      guest = %{Sanctum.TestContext.local() | plane: :guest}

      assert {:error, _refused} =
               Sanctum.Providers.Profile.handle(guest, %{
                 "action" => "grants",
                 "domain" => "a.example"
               })
    end
  end
end
