# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.ProfileGrantsTest do
  @moduledoc """
  `profile.grants`: the grants of the caller's athanor whose head
  revision reaches one domain, storage path or vault entry, read as each
  enforcement point would admit it, so no grant shows wider or narrower
  than it runs. Only an active profile's head counts, a head the loader
  refuses outright reaches nothing, a lender that cannot be read or does
  not decode refuses the read, every edge counts (a borrowed entry among
  them), at most a thousand heads are read, and a read never reaches past
  the caller's athanor.

  A grant naming one account in two spellings is refused naming both,
  with nothing written, through `profile.preview` and `profile.grant`
  alike: the home decides which names are one account, whatever Unicode
  tables the caller folded names by. The command line sends
  `profile.plan`, `profile.preview` and `profile.commit`: preview and
  commit, which carry the bindings, reach the slot check in
  `Sanctum.Consent.Commit` that `profile.grant` reaches, and the command
  line meets the refusal first at `profile.preview`.
  """

  use ExUnit.Case, async: false

  require Ecto.Query

  alias Sanctum.Consent.Commit
  alias Sanctum.Consent.Loader
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

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

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

  # `entry_id` bound on `node`'s `edge`: the athanor's own entry, keyed
  # where it sits.
  defp vault(entry_id, node, edge),
    do: %{
      "vault" => %{
        "entry_id" => entry_id,
        "binding_digest" => "sha256:binding",
        "scope" => "athanor",
        "binding_key" => Prima.Authority.Blob.binding_key(node, edge, nil),
        "destination" => %{"hosts" => ["api.example.com"], "scheme" => "https"},
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
          admitted_origins: Keyword.get(opts, :origins, [:interactive]),
          vault_refs: Keyword.get(opts, :vault_refs, [])
        }
      )

    id
  end

  defp grant!(ctx, name), do: grant!(ctx, name, policy("reagent:local.#{name}", %{}))

  defp ids(%{grants: grants}), do: Enum.map(grants, & &1.profile_id)

  # The revision's row for `entry` bound on `node`'s `edge`.
  defp entry_ref(node, edge, entry),
    do: %{
      binding_key: Prima.Authority.Blob.binding_key(node, edge, nil),
      scope: "athanor",
      vault_entry_id: entry,
      binding_digest: "sha256:binding"
    }

  # The lender: `@dep`'s own profile, binding `entry` on its ingress.
  defp lender!(ctx, entry, opts \\ []) do
    ref = entry_ref(@dep, "@ingress", entry)

    grant!(
      ctx,
      "grants-dep",
      policy(@dep, vault(entry, @dep, "@ingress")),
      [vault_refs: [ref]] ++ opts
    )
  end

  # A borrower: its edge to `@dep` selects `@dep`'s profile through
  # `selection` (`via`), and grants a domain beside it. Its revision's row
  # for that edge names the label it borrows and the digest it pins.
  defp borrower!(ctx, name, %{"via" => via} = selection, opts \\ []) do
    ref = "reagent:local.#{name}"
    edge = Map.put(egress(["borrow.example"]), "vault", selection)

    row = %{
      binding_key: Prima.Authority.Blob.binding_key(ref, borrowed_edge(), nil),
      scope: "athanor",
      via_label: via["label"],
      binding_digest: via["binding_digest"]
    }

    grant!(ctx, name, policy(ref, %{}, %{"key" => edge}), [vault_refs: [row]] ++ opts)
  end

  defp borrowed_edge, do: Prima.Authority.Blob.edge_key(@dep, "key")

  defp set_profile!(ctx, id, changes) do
    {1, _} =
      Arca.Repo.update_all(
        Ecto.Query.from(p in Arca.Schemas.Profile,
          where: p.athanor_id == ^ctx.athanor_id and p.id == ^id
        ),
        set: changes
      )
  end

  # `table` stops answering once the heads are read whole (their
  # `consent_vault_refs`, the last read of `Arca.ConsentStorage.active_heads/2`,
  # which names `consent_id` among the heads it reads), before any head
  # is loaded.
  defp away_after_heads!(table, consent_id) do
    test = self()
    handler = "profile-grants-away-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:arca, :repo, :query],
        fn _event, _measurements, meta, _config ->
          if self() == test and meta[:source] == "consent_vault_refs" and
               Enum.any?(meta[:params] || [], &(&1 == consent_id or names?(&1, consent_id))) do
            :telemetry.detach(handler)
            Arca.Repo.query!("ALTER TABLE #{table} RENAME TO #{table}_unavailable")
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp names?(ids, consent_id) when is_list(ids), do: consent_id in ids
  defp names?(_param, _consent_id), do: false

  # What `Sanctum.Consent.Loader.load_root/3` carries on the borrower's
  # edge to `@dep` when its profile runs under `origin`.
  defp loaded_vault(ctx, name, origin) do
    ref = "reagent:local.#{name}"
    activation = %{ref => "sha256:act"}
    {:ok, digest} = Prima.JCS.hash(activation)

    live =
      {:ok,
       %{
         digest: digest,
         graph: activation,
         nodes: %{ref => %{release_digest: "sha256:act", integrity: :ok}}
       }}

    profile = %{
      id: "prof_#{name}",
      kind: :owner,
      source_ref: ref,
      label: "default",
      status: :active
    }

    {:ok, authority, _stamp} =
      Loader.load_root(%{ctx | origin: origin}, profile, live: live, live_shape_digest: nil)

    authority.policy.nodes[ref].edges[borrowed_edge()].vault
  end

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

    test "an exact file reaches the one file it names, and beside a folder is not under it",
         %{ctx: ctx} do
      file =
        grant!(ctx, "g-file-only", policy("reagent:local.g-file-only", storage(["data/a.md"])))

      folder =
        grant!(ctx, "g-folder", policy("reagent:local.g-folder", storage(["data/secrets/"])))

      assert {:ok, %{grants: [%{profile_id: ^file}]}} = grants(ctx, %{"path" => "data/a.md"})
      assert {:ok, %{grants: []}} = grants(ctx, %{"path" => "data/a.md/b"})
      assert {:ok, %{grants: [%{profile_id: ^folder}]}} = grants(ctx, %{"path" => "data/secrets"})
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

      assert {:ok, %{resource: %{value: "cache/x"}, grants: [], count: 0, truncated: false}} =
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

      bound =
        grant!(
          ctx,
          "g-bound",
          policy("reagent:local.g-bound", vault(entry, "reagent:local.g-bound", "@ingress")),
          vault_refs: [entry_ref("reagent:local.g-bound", "@ingress", entry)]
        )

      lent =
        grant!(
          ctx,
          "g-lent",
          policy("reagent:local.g-lent", %{}, %{
            "key" => vault(entry, "reagent:local.g-lent", borrowed_edge())
          }),
          vault_refs: [entry_ref("reagent:local.g-lent", borrowed_edge(), entry)]
        )

      # References and blob disagree: the loader refuses such a revision,
      # so it reaches nothing through the entry.
      _refs_only =
        grant!(ctx, "g-refs-only", policy("reagent:local.g-refs-only", %{}),
          vault_refs: [entry_ref("reagent:local.g-refs-only", "@ingress", entry)]
        )

      _blob_only =
        grant!(
          ctx,
          "g-blob-only",
          policy(
            "reagent:local.g-blob-only",
            vault(entry, "reagent:local.g-blob-only", "@ingress")
          )
        )

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
      ref = entry_ref("reagent:local.g-theirs-vault", "@ingress", entry)

      _theirs =
        grant!(
          theirs,
          "g-theirs-vault",
          policy(
            "reagent:local.g-theirs-vault",
            vault(entry, "reagent:local.g-theirs-vault", "@ingress")
          ),
          vault_refs: [ref]
        )

      assert {:ok, %{count: 1}} = grants(theirs, %{"entry_id" => entry})

      assert grants(ctx, %{"entry_id" => entry}) ==
               {:error, {:not_found, "Vault entry", entry}}

      assert grants(ctx, %{"entry_id" => "vlt_nowhere"}) ==
               {:error, {:not_found, "Vault entry", "vlt_nowhere"}}
    end

    test "is reached by a borrower whose selection the loader resolves to its lender's entry",
         %{ctx: ctx} do
      entry = "vlt_lent_#{System.unique_integer([:positive])}"
      lender = lender!(ctx, entry)
      borrower = borrower!(ctx, "g-borrower", %{"via" => %{"label" => "default"}})

      # The loader carries the lender's entry on the borrower's edge.
      assert %{entry_id: ^entry, lender: %{profile_id: ^lender}} =
               loaded_vault(ctx, "g-borrower", :interactive)

      assert {:ok, answer} = grants(ctx, %{"entry_id" => entry})
      assert ids(answer) == Enum.sort([lender, borrower])
      by_id = Map.new(answer.grants, &{&1.profile_id, &1})

      # The borrower's row says it borrows, and through which label.
      assert by_id[borrower].admitted_origins == ["interactive"]
      assert [%{node: "reagent:local.g-borrower", vault: vault} = edge] = by_id[borrower].edges
      assert edge.edge == borrowed_edge()

      assert vault == %{
               entry_id: entry,
               binding_digest: "sha256:binding",
               projection: %{fields: ["api_key"], scopes: []},
               lender: %{label: "default", profile_id: lender}
             }

      # The lender's own reference borrows from no one.
      assert [%{edge: "@ingress", vault: own}] = by_id[lender].edges
      refute Map.has_key?(own, :lender)
    end

    test "a borrower leaves the read when its lender is revoked", %{ctx: ctx} do
      entry = "vlt_revoked_#{System.unique_integer([:positive])}"
      lender = lender!(ctx, entry)
      borrower = borrower!(ctx, "g-borrower-revoked", %{"via" => %{"label" => "default"}})

      assert {:ok, answer} = grants(ctx, %{"entry_id" => entry})
      assert ids(answer) == Enum.sort([lender, borrower])

      assert {:ok, %{status: "revoked"}} =
               Grimoire.call_external("profile", ctx, %{
                 "action" => "revoke",
                 "profile_id" => lender
               })

      assert {:ok, %{grants: [], count: 0}} = grants(ctx, %{"entry_id" => entry})

      # The borrower still runs, and still reaches what it holds itself.
      assert {:ok, answer} = grants(ctx, %{"domain" => "borrow.example"})
      assert ids(answer) == [borrower]
    end

    test "a borrower whose selection resolves to nothing does not reach the entry",
         %{ctx: ctx} do
      entry = "vlt_narrowed_#{System.unique_integer([:positive])}"
      lender = lender!(ctx, entry)

      # A projection asking only for a field the lender does not grant.
      _narrowed =
        borrower!(ctx, "g-narrowed", %{
          "via" => %{"label" => "default"},
          "projection" => %{"fields" => ["other_field"]}
        })

      # A pinned binding the lender no longer holds, and a label it is not.
      _moved =
        borrower!(ctx, "g-moved", %{
          "via" => %{"label" => "default", "binding_digest" => "sha256:other"}
        })

      _unlabelled = borrower!(ctx, "g-unlabelled", %{"via" => %{"label" => "work"}})

      assert {:ok, answer} = grants(ctx, %{"entry_id" => entry})
      assert ids(answer) == [lender]
    end

    # A lender the read cannot read is no grant that reaches nothing: the
    # read is refused in a sentence of its own, never answered short. The
    # store stops answering once the heads are read, so only the lender's
    # read meets the outage.
    @tag :capture_log
    test "a borrower whose lender cannot be read or does not decode refuses the read",
         %{ctx: ctx} do
      entry = "vlt_unread_#{System.unique_integer([:positive])}"
      lender = lender!(ctx, entry)
      _borrower = borrower!(ctx, "g-unread", %{"via" => %{"label" => "default"}})
      assert {:ok, %{count: 2}} = grants(ctx, %{"entry_id" => entry})

      for table <- ~w(profiles consents) do
        away_after_heads!(table, "cons_g-unread")

        assert {:error, {:lender_unavailable, @dep} = reason} =
                 grants(ctx, %{"entry_id" => entry}),
               table

        assert %Prima.Refusal{
                 class: :unavailable,
                 message: "A profile that lends a key here cannot be read right now — try again."
               } = Grimoire.Error.classify(reason)

        Arca.Repo.query!("ALTER TABLE #{table}_unavailable RENAME TO #{table}")
      end

      damaged =
        "A profile that lends a key here is damaged and cannot lend its key — " <>
          "revoke profile #{lender} and grant it again."

      :ok = ConsentFixtures.hand_edit_head!(ctx, lender, scope: "sideways")

      assert {:error, {:lender_corrupt, @dep, ^lender} = reason} =
               grants(ctx, %{"entry_id" => entry})

      assert %Prima.Refusal{class: :corrupt, message: ^damaged} = Grimoire.Error.classify(reason)

      :ok = ConsentFixtures.hand_edit_head!(ctx, lender, scope: "versionless")
      set_profile!(ctx, lender, kind: "sideways")

      assert {:error, {:lender_corrupt, @dep, ^lender} = reason} =
               grants(ctx, %{"entry_id" => entry})

      assert %Prima.Refusal{class: :corrupt, message: ^damaged} = Grimoire.Error.classify(reason)
    end

    test "a borrower reaches the entry only under an origin its lender admits", %{ctx: ctx} do
      entry = "vlt_origins_#{System.unique_integer([:positive])}"
      lender = lender!(ctx, entry, origins: [:schedule])
      via = %{"via" => %{"label" => "default"}}

      # Its load under `interactive`, the first origin it admits, is
      # refused; under `schedule` the key is lent.
      both = borrower!(ctx, "g-both", via, origins: [:interactive, :schedule])
      _neither = borrower!(ctx, "g-neither", via, origins: [:interactive, :programmatic])

      assert {:ok, answer} = grants(ctx, %{"entry_id" => entry})
      assert ids(answer) == Enum.sort([lender, both])

      # The row names the origins its own revision admits.
      assert %{admitted_origins: ["interactive", "schedule"]} =
               Enum.find(answer.grants, &(&1.profile_id == both))

      # The lender refuses every load of the other, so it reaches nothing
      # at all, its own domain included.
      assert {:ok, answer} = grants(ctx, %{"domain" => "borrow.example"})
      assert ids(answer) == [both]
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

    test "a head the loader refuses outright reaches nothing, through any resource",
         %{ctx: ctx} do
      # A storage path spelled other than the door reaches it: the loader
      # asks for the grant again rather than run it.
      ref = "reagent:local.g-unusable"
      edge = Map.merge(egress(["refused.example"]), storage(["data//secrets/"]))
      unusable = grant!(ctx, "g-unusable", policy(ref, edge))
      profile = %{id: unusable, kind: :owner, source_ref: ref, label: "default", status: :active}

      assert {:error, {:consent_required, %{profile_id: ^unusable}}} =
               Loader.load_root(%{ctx | origin: :interactive}, profile)

      # References the blob does not carry, and a pinned revision that names
      # no version, each over a canonical path: refused by the loader before
      # any run all the same.
      canonical = Map.merge(egress(["refused.example"]), storage(["data/secrets/"]))
      entry = "vlt_refused_#{System.unique_integer([:positive])}"

      _mismatched =
        grant!(ctx, "g-mismatched", policy("reagent:local.g-mismatched", canonical),
          vault_refs: [entry_ref("reagent:local.g-mismatched", "@ingress", entry)]
        )

      invalid = grant!(ctx, "g-invalid", policy("reagent:local.g-invalid", canonical))
      ConsentFixtures.hand_edit_head!(ctx, invalid, scope: "pinned")

      for args <- [
            %{"domain" => "refused.example"},
            %{"path" => "data/secrets/key.txt"},
            %{"entry_id" => entry}
          ] do
        assert {:ok, %{grants: [], count: 0}} = grants(ctx, args), inspect(args)
      end
    end

    test "reads at most a thousand heads, and says when the athanor holds more", %{ctx: ctx} do
      reaching = fn n ->
        name = "g-cap-" <> String.pad_leading(Integer.to_string(n), 4, "0")
        grant!(ctx, name, policy("reagent:local.#{name}", egress(["cap.example"])))
      end

      Enum.each(1..1_000, reaching)

      assert {:ok, %{count: 1_000, truncated: false}} = grants(ctx, %{"domain" => "cap.example"})

      # One more, last in profile-id order, is past the bound.
      last = reaching.(1_001)

      assert {:ok, %{count: 1_000, truncated: true} = answer} =
               grants(ctx, %{"domain" => "cap.example"})

      refute last in ids(answer)
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

  # An app of `ctx`'s athanor whose own calls carry one credential need,
  # granted through the walk with a default entry: its profile, and that
  # entry and two more of its provider.
  defp granted_app!(ctx, name) do
    manifest = %{
      "name" => name,
      "version" => "1.0.0",
      "type" => "reagent",
      "needs" => %{
        "api_key" => %{
          "type" => "api_key:example.com",
          "reason" => "to call the example API",
          "fields" => ["KEY"]
        }
      },
      "caps" => %{"egress" => %{"domains" => ["api.example.com"]}}
    }

    {:ok, _component} =
      Compendium.Registry.publish_bytes(ctx, @wasm, %{
        name: name,
        version: "1.0.0",
        type: "reagent",
        manifest: Jason.encode!(manifest)
      })

    [default, one, other] =
      for label <- ["default", "one", "other"] do
        {:ok, view} =
          Sanctum.TestContext.create_vault(ctx, %{
            name: "#{name} #{label}",
            kind: "api_key",
            provider_hint: "example.com",
            fields: %{"KEY" => "k-#{name}-#{label}"},
            destination: %{"hosts" => ["api.example.com"]},
            disclose: true
          })

        view
      end

    ref = "reagent:local." <> name
    decisions = %{ref: ref, bindings: [%{need: "api_key", entry_id: default.id}]}
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

    %{ref: ref, profile_id: profile_id, default: default, one: one, other: other}
  end

  # `profile.grant` of `name`'s app, its own calls bound to a default and
  # to `a` and `b` beside it, refused naming both spellings, with the head
  # as it was.
  defp refuses_two_spellings(ctx, name, a, b) do
    app = granted_app!(ctx, name)
    actor = Sanctum.Context.actor(ctx)
    {:ok, head} = Arca.ConsentStorage.head_consent(actor, app.profile_id)

    assert Grimoire.call_external("profile", ctx, %{
             "action" => "grant",
             "profile_id" => app.profile_id,
             "expected_consent_revision" => head.revision,
             "bindings" => [
               %{"need" => "api_key", "entry_id" => app.default.id},
               %{"need" => "api_key", "entry_id" => app.one.id, "name" => a},
               %{"need" => "api_key", "entry_id" => app.other.id, "name" => b}
             ]
           }) ==
             {:error,
              "The bindings for api_key name one account twice, as \"#{a}\" and \"#{b}\": " <>
                "names that differ only in letter case are the same account. Bind it once, " <>
                "under one of the two."}

    assert {:ok, %{id: id, revision: revision}} =
             Arca.ConsentStorage.head_consent(actor, app.profile_id)

    assert {id, revision} == {head.id, head.revision}
  end

  describe "profile.preview naming one account in two spellings" do
    # Where the command line meets the refusal first: `cyfr profile grant`
    # sends profile.plan, profile.preview and profile.commit, and preview
    # and commit, which carry the bindings, reach the slot check in
    # `Sanctum.Consent.Commit` that profile.grant reaches. A command line
    # folding on Unicode tables older than the home's sends `Ꟍ Work` and
    # `ꟍ work` as two accounts.
    test "is refused naming both, and nothing is written", %{ctx: ctx} do
      app = granted_app!(ctx, "preview-twice-unicode")
      actor = Sanctum.Context.actor(ctx)
      {:ok, head} = Arca.ConsentStorage.head_consent(actor, app.profile_id)

      assert Grimoire.call_external("profile", ctx, %{
               "action" => "preview",
               "decisions" => %{
                 "ref" => app.ref,
                 "bindings" => [
                   %{"need" => "api_key", "entry_id" => app.default.id},
                   %{"need" => "api_key", "entry_id" => app.one.id, "name" => "Ꟍ Work"},
                   %{"need" => "api_key", "entry_id" => app.other.id, "name" => "ꟍ work"}
                 ]
               }
             }) ==
               {:error,
                "The bindings for api_key name one account twice, as \"Ꟍ Work\" and " <>
                  "\"ꟍ work\": names that differ only in letter case are the same account. " <>
                  "Bind it once, under one of the two."}

      assert {:ok, %{id: id, revision: revision}} =
               Arca.ConsentStorage.head_consent(actor, app.profile_id)

      assert {id, revision} == {head.id, head.revision}
    end
  end

  describe "profile.grant naming one account in two spellings" do
    # The same slot check, reached through profile.grant: two accounts to
    # a command line folding on older tables, one to the home.
    test "is refused naming both, a letter only newer tables fold included, and the head stands",
         %{ctx: ctx} do
      refuses_two_spellings(ctx, "grant-twice-unicode", "Ꟍ Work", "ꟍ work")
    end

    test "is refused naming both, in ASCII, and the head stands", %{ctx: ctx} do
      refuses_two_spellings(ctx, "grant-twice-ascii", "Work", "work")
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
