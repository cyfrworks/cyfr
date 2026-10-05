# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Consent.CommitTest do
  @moduledoc """
  The preview answers a `Prima.ConsentPreview` — typed rows, the origins the
  grant admits and the commit digest binding them — with no prose summary
  beside them; a decision names the origins it admits, `interactive` alone when
  absent, and the revision is written with them; the digest binds the
  origins and the narrowing and never the prose a need gives as its reason.
  """

  use ExUnit.Case, async: false

  alias Prima.ConsentPreview
  alias Sanctum.Consent.Commit
  alias Sanctum.Consent.Plan
  alias Sanctum.Providers.Profile

  @wasm File.read!(Path.join(__DIR__, "../../support/test_wasm/math.wasm"))

  # A catalog that answers as the installed one and counts the tool-action
  # reads `Commit.grant/3` makes. Armed with a function and a count, it runs
  # the function once, just before the read after that count: a revision
  # landing between two of the grant's reads.
  defmodule CountingGrimoire do
    @moduledoc false
    @behaviour Sanctum.Grimoire

    @impl true
    def tool_actions do
      if granting?() do
        count = Process.get({__MODULE__, :count}, 0) + 1
        Process.put({__MODULE__, :count}, count)

        case Process.get({__MODULE__, :armed}) do
          {after_count, fun} when count > after_count ->
            Process.delete({__MODULE__, :armed})
            fun.()

          _not_yet ->
            :ok
        end
      end

      real().tool_actions()
    end

    @impl true
    def action_declaration(name), do: real().action_declaration(name)

    @impl true
    def providers_loaded, do: real().providers_loaded()

    @impl true
    def tool_server_candidates(ctx), do: real().tool_server_candidates(ctx)

    @impl true
    def tool_server_candidate(ctx, name), do: real().tool_server_candidate(ctx, name)

    defp granting? do
      {:current_stacktrace, stack} = Process.info(self(), :current_stacktrace)
      Enum.any?(stack, &match?({Sanctum.Consent.Commit, :grant, 3, _}, &1))
    end

    defp real, do: :persistent_term.get({__MODULE__, :real})
  end

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)

    test_path = Path.join(System.tmp_dir!(), "consent_commit_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    {:ok, ctx: Sanctum.TestContext.local(:prism)}
  end

  @caps %{
    "egress" => %{"domains" => ["api.one.example", "api.two.example"], "methods" => ["GET"]},
    "storage" => %{"paths" => ["data/"], "actions" => ["read", "write"]}
  }

  defp publish!(ctx, name, version \\ "1.0.0", manifest \\ %{"caps" => @caps}) do
    manifest =
      Map.merge(manifest, %{"name" => name, "version" => version, "type" => "reagent"})

    {:ok, component} =
      Compendium.Registry.publish_bytes(ctx, @wasm, %{
        name: name,
        version: version,
        type: "reagent",
        manifest: Jason.encode!(manifest)
      })

    component
  end

  # A tincture row written as the registry holds one, with its release
  # digest, so its activation resolves.
  defp tincture!(ctx, name, declaration) do
    manifest = %{
      "name" => name,
      "type" => "tincture",
      "version" => "1.0.0",
      "publisher" => "local",
      "tincture" => Map.put(declaration, "entry", "index.html")
    }

    digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, name), case: :lower)
    {:ok, release_digest} = Compendium.ReleaseDigest.compute(digest, manifest)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, _} =
      Arca.ComponentStorage.put_component(Sanctum.Context.actor(ctx), %{
        id: "cmp_#{name}_#{System.unique_integer([:positive])}",
        name: name,
        version: "1.0.0",
        component_type: "tincture",
        description: name,
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

    "tincture:local.#{name}"
  end

  # An entry of the athanor: disclosed unless `over` says otherwise, since
  # most of these components read their key themselves, and of the
  # provider `over` names, none by default.
  defp entry!(ctx, fields \\ %{"url" => "https://db.example", "anon_key" => "anon"}, over \\ %{}) do
    {:ok, view} =
      Sanctum.TestContext.create_vault(
        ctx,
        Map.merge(
          %{
            name: "conn-#{System.unique_integer([:positive])}",
            kind: "api_key",
            fields: fields,
            destination: %{"hosts" => ["api.example.com"]},
            disclose: true
          },
          over
        )
      )

    view
  end

  defp walk!(ctx, ref, decisions_over \\ %{}) do
    {:ok, plan} = Plan.plan(ctx, %{ref: ref})
    decisions = Map.merge(%{ref: ref}, decisions_over)
    {:ok, preview} = Commit.preview(ctx, decisions)

    Commit.commit(ctx, %{
      decisions: decisions,
      plan_token: plan.plan_token,
      proof: preview.proof,
      commit_digest: preview.commit_digest,
      expected_consent_revision: plan.expected_consent_revision
    })
  end

  defp document(preview) do
    %{
      "v" => preview.v,
      "rows" => preview.rows,
      "origins" => preview.origins,
      "commit_digest" => preview.commit_digest,
      "removed" => preview.removed
    }
  end

  defp head!(ctx, profile_id) do
    {:ok, head} = Arca.ConsentStorage.head_consent(Sanctum.Context.actor(ctx), profile_id)
    head
  end

  describe "a binding" do
    test "names its scope, its entry's destination, its need's rule and its own key, and its row the rest",
         %{ctx: ctx} do
      attach = %{"in" => "header", "name" => "x-api-key", "template" => "{value}"}

      manifest = %{
        "needs" => %{
          "api_key" => %{
            "type" => "api_key:one.example",
            "reason" => "to call the example API",
            "fields" => ["EXAMPLE_API_KEY"],
            "attach" => attach
          }
        },
        "caps" => @caps
      }

      ref = "reagent:local.commit-binding"
      publish!(ctx, "commit-binding", "1.0.0", manifest)

      entry =
        entry!(ctx, %{"EXAMPLE_API_KEY" => "k"}, %{provider_hint: "one.example", disclose: false})

      {:ok, row} = Arca.VaultStorage.get(Sanctum.Context.actor(ctx), entry.id)
      {:ok, destination} = Sanctum.Consent.BlobBuilder.entry_destination(row)
      decisions = %{ref: ref, bindings: [%{need: "api_key", entry_id: entry.id}]}

      {:ok, preview} = Commit.preview(ctx, decisions)
      key = "#{ref}|@ingress|default"

      # The row for the binding: the person's own entry, standing, the
      # plan's suggestion (the only entry of the need's provider) and no
      # choice, disclosed as its entry is stored.
      assert [%{"values" => values}] = Enum.filter(preview.rows, &(&1["kind"] == "credential"))

      assert Map.take(
               values,
               ~w(source suggested choice_required binding_key lifetime destination)
             ) ==
               %{
                 "source" => "own",
                 "suggested" => true,
                 "choice_required" => false,
                 "binding_key" => key,
                 "lifetime" => %{"kind" => "standing", "until" => nil},
                 "destination" => destination
               }

      assert values["disclosed"] == not row.attach_only
      refute Map.has_key?(values, "connection")

      assert {:ok, %{revision: 1}} = walk!(ctx, ref, %{bindings: decisions.bindings})

      {:ok, [profile]} = Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), ref)
      {:ok, head} = Arca.ConsentStorage.head_consent(Sanctum.Context.actor(ctx), profile.id)
      {:ok, blob} = Prima.Authority.Blob.parse(head.resolved_policy)
      {:ok, ingress} = Prima.Authority.Blob.ingress(blob, ref)

      assert %{scope: "athanor", binding_key: ^key, attach: rule} = ingress.vault
      assert Prima.Manifest.Needs.attach_to_map(rule) == attach
      assert Prima.Destination.to_map(ingress.vault.destination) == destination
    end

    test "for a disclose-only need attaches nothing", %{ctx: ctx} do
      publish!(ctx, "commit-disclose")
      entry = entry!(ctx)
      ref = "reagent:local.commit-disclose"

      assert {:ok, %{revision: 1}} =
               walk!(ctx, ref, %{bindings: [%{need: "@ingress", entry_id: entry.id}]})

      {:ok, [profile]} = Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), ref)
      {:ok, head} = Arca.ConsentStorage.head_consent(Sanctum.Context.actor(ctx), profile.id)
      refute head.resolved_policy =~ ~s("attach")
      {:ok, blob} = Prima.Authority.Blob.parse(head.resolved_policy)

      assert {:ok, %{vault: %{attach: nil, scope: "athanor"}}} =
               Prima.Authority.Blob.ingress(blob, ref)
    end
  end

  describe "the preview" do
    test "answers a ConsentPreview with the commit digest, and no summary", %{ctx: ctx} do
      publish!(ctx, "commit-preview")
      entry = entry!(ctx)
      ref = "reagent:local.commit-preview"

      {:ok, preview} =
        Commit.preview(ctx, %{
          ref: ref,
          bindings: [%{need: "@ingress", entry_id: entry.id, fields: ["url"]}]
        })

      assert {:ok, %ConsentPreview{} = decoded} = ConsentPreview.decode(document(preview))
      assert decoded.commit_digest == preview.commit_digest
      assert decoded.origins == [:interactive]
      assert preview.origins == ["interactive"]

      # The rows are the preview: no prose summary rides beside them, and
      # the answer is the document, the proof and the expected revision.
      refute Map.has_key?(preview, :summary)

      assert Map.keys(preview) |> Enum.sort() ==
               [:commit_digest, :expected_consent_revision, :origins, :proof, :removed, :rows, :v]

      assert is_binary(preview.proof)
      assert preview.expected_consent_revision == 0

      rows = Enum.group_by(decoded.rows, &{&1.kind, &1.node}, & &1.values)

      # The credential names the edge it rides: the source's own ingress,
      # where the entry may go, and that the component reads it, as a
      # manifest declaring no need does; it is the plan's suggestion, the
      # one entry that can meet the slot.
      assert rows[{:credential, ref}] == [
               %{
                 "name" => entry.name,
                 "edge" => "@ingress",
                 "fields" => ["url"],
                 "scopes" => [],
                 "destination" => %{"hosts" => ["api.example.com"], "scheme" => "https"},
                 "disclosed" => true,
                 "source" => "own",
                 "suggested" => true,
                 "choice_required" => false,
                 "binding_key" => "#{ref}|@ingress|default",
                 "lifetime" => %{"kind" => "standing", "until" => nil}
               }
             ]

      assert rows[{:egress, ref}] == [
               %{
                 "domains" => ["api.one.example", "api.two.example"],
                 "methods" => ["GET"],
                 "schemes" => ["https"],
                 "private_ips" => []
               }
             ]

      assert rows[{:storage, ref}] == [%{"paths" => ["data/"], "actions" => ["read", "write"]}]
      assert [%{"timeout" => _}] = rows[{:limits, ref}]
      refute Enum.any?(decoded.rows, & &1.narrowed)
    end

    test "two previews of the same decisions answer the same rows and the same digest",
         %{ctx: ctx} do
      publish!(ctx, "commit-same")

      decisions = %{
        ref: "reagent:local.commit-same",
        origins: [:programmatic, :interactive],
        subset: %{
          "reagent:local.commit-same" => %{"egress" => %{"domains" => ["api.one.example"]}}
        }
      }

      {:ok, one} = Commit.preview(ctx, decisions)
      {:ok, two} = Commit.preview(ctx, decisions)

      assert one.rows == two.rows
      assert one.commit_digest == two.commit_digest
      assert one.origins == ["interactive", "programmatic"]

      # The same decisions spelled in another order are the same decisions.
      {:ok, reordered} =
        Commit.preview(ctx, %{decisions | origins: [:interactive, :programmatic]})

      assert reordered.commit_digest == one.commit_digest
    end

    test "a reworded need reason leaves the rows and the digest as they were", %{ctx: ctx} do
      needs = fn reason ->
        %{
          "needs" => %{
            "api_key" => %{
              "type" => "api_key:example.com",
              "reason" => reason,
              "fields" => ["EXAMPLE_API_KEY"]
            }
          },
          "caps" => @caps
        }
      end

      ref = "reagent:local.commit-reason"
      publish!(ctx, "commit-reason", "1.0.0", needs.("to call the example API"))
      entry = entry!(ctx, %{"EXAMPLE_API_KEY" => "k"}, %{provider_hint: "example.com"})
      decisions = %{ref: ref, bindings: [%{need: "api_key", entry_id: entry.id}]}
      {:ok, before} = Commit.preview(ctx, decisions)

      publish!(ctx, "commit-reason", "1.0.1", needs.("so the forecast can reach the API"))
      Arca.Cache.delete_match(:_)
      {:ok, later} = Commit.preview(ctx, decisions)

      assert later.commit_digest == before.commit_digest
      assert later.rows == before.rows
    end

    test "the origins and the narrowing each move the digest", %{ctx: ctx} do
      publish!(ctx, "commit-moves")
      ref = "reagent:local.commit-moves"

      {:ok, plain} = Commit.preview(ctx, %{ref: ref})
      {:ok, admitted} = Commit.preview(ctx, %{ref: ref, origins: [:interactive, :schedule]})

      {:ok, narrowed} =
        Commit.preview(ctx, %{
          ref: ref,
          subset: %{ref => %{"storage" => %{"actions" => ["read"]}}}
        })

      digests = Enum.map([plain, admitted, narrowed], & &1.commit_digest)
      assert length(Enum.uniq(digests)) == 3

      # Naming the default explicitly is the same decision as naming none.
      {:ok, explicit} = Commit.preview(ctx, %{ref: ref, origins: [:interactive]})
      assert explicit.commit_digest == plain.commit_digest
    end

    test "a tincture's declarations are rows of its preview", %{ctx: ctx} do
      ref =
        tincture!(ctx, "commit-frame", %{
          "frame" => %{"capabilities" => ["fullscreen"], "background" => true},
          "streams" => [%{"name" => "mcp_servers.changes"}],
          "actions" => ["execution.list"]
        })

      {:ok, preview} = Commit.preview(ctx, %{ref: ref})
      {:ok, decoded} = ConsentPreview.decode(document(preview))
      rows = Enum.group_by(decoded.rows, &{&1.kind, &1.node})

      assert [%{values: %{"background" => true, "capabilities" => ["fullscreen"]}}] =
               rows[{:frame, ref}]

      assert [%{values: %{"name" => "mcp_servers.changes"}}] = rows[{:streams, ref}]
      assert [%{values: %{"actions" => ["execution.list"]}}] = rows[{:system_actions, ref}]
      refute Enum.any?(decoded.rows, & &1.narrowed)
    end
  end

  describe "origins" do
    test "a revision is written with the origins its decision named", %{ctx: ctx} do
      publish!(ctx, "commit-origins")
      ref = "reagent:local.commit-origins"

      assert {:ok, %{profile_id: profile_id}} =
               walk!(ctx, ref, %{origins: [:webhook, :programmatic, :interactive]})

      assert head!(ctx, profile_id).admitted_origins == [:interactive, :programmatic, :webhook]
    end

    test "a decision that names none admits interactive alone", %{ctx: ctx} do
      publish!(ctx, "commit-default")

      assert {:ok, %{profile_id: profile_id}} = walk!(ctx, "reagent:local.commit-default")
      assert head!(ctx, profile_id).admitted_origins == [:interactive]
    end

    test "an origins list that is empty, repeats one or names an unknown origin is refused",
         %{ctx: ctx} do
      publish!(ctx, "commit-bad-origins")
      ref = "reagent:local.commit-bad-origins"

      for origins <- [[], [:interactive, :interactive], [:cli], ["interactive"], :interactive] do
        assert {:error, {:invalid_argument, why}} =
                 Commit.preview(ctx, %{ref: ref, origins: origins}),
               "#{inspect(origins)} was accepted"

        assert why =~ "origins"
      end

      # Through the provider, a wire spelling outside the enum is refused too.
      for spellings <- [[], ["cli"], ["interactive", "interactive"]] do
        assert {:error, {:invalid_argument, _why}} =
                 Profile.handle(ctx, %{
                   "action" => "preview",
                   "decisions" => %{"ref" => ref, "origins" => spellings}
                 })
      end
    end

    test "a proof minted for one set of origins does not commit another", %{ctx: ctx} do
      publish!(ctx, "commit-bound")
      ref = "reagent:local.commit-bound"
      {:ok, plan} = Plan.plan(ctx, %{ref: ref})
      {:ok, preview} = Commit.preview(ctx, %{ref: ref})

      assert {:error, {:consent_conflict, %{cause: :digest_changed}}} =
               Commit.commit(ctx, %{
                 decisions: %{ref: ref, origins: [:interactive, :programmatic]},
                 plan_token: plan.plan_token,
                 proof: preview.proof,
                 commit_digest: preview.commit_digest,
                 expected_consent_revision: plan.expected_consent_revision
               })
    end

    test "the provider carries origins and a narrowing to the walk", %{ctx: ctx} do
      publish!(ctx, "commit-wire")
      ref = "reagent:local.commit-wire"

      assert {:ok, preview} =
               Profile.handle(ctx, %{
                 "action" => "preview",
                 "decisions" => %{
                   "ref" => ref,
                   "origins" => ["programmatic", "interactive"],
                   "subset" => %{ref => %{"egress" => %{"domains" => ["api.two.example"]}}}
                 }
               })

      assert preview.origins == ["interactive", "programmatic"]

      assert [%{"values" => %{"domains" => ["api.two.example"]}, "narrowed" => true}] =
               Enum.filter(preview.rows, &(&1["kind"] == "egress"))

      # The answer crosses the wire as JSON.
      assert {:ok, _json} = Jason.encode(preview)
    end
  end

  describe "the simple grant" do
    test "re-issues the head's origins and its narrowing with the new binding", %{ctx: ctx} do
      publish!(ctx, "commit-grant")
      ref = "reagent:local.commit-grant"
      entry = entry!(ctx)

      assert {:ok, %{profile_id: profile_id, revision: 1}} =
               walk!(ctx, ref, %{
                 origins: [:interactive, :programmatic],
                 subset: %{
                   ref => %{
                     "egress" => %{"domains" => ["api.one.example"]},
                     "limits" => %{"timeout" => "30s"}
                   }
                 }
               })

      assert {:ok, %{revision: 2}} =
               Commit.grant(ctx, %{
                 profile_id: profile_id,
                 bindings: [%{need: "@ingress", entry_id: entry.id}],
                 expected_consent_revision: 1
               })

      head = head!(ctx, profile_id)
      assert head.admitted_origins == [:interactive, :programmatic]
      assert Enum.any?(head.vault_refs, &(&1.vault_entry_id == entry.id))

      {:ok, blob} = Jason.decode(head.resolved_policy)
      ingress = blob["nodes"][ref]["edges"]["@ingress"]
      assert ingress["egress"]["domains"] == ["api.one.example"]
      assert blob["nodes"][ref]["limits"]["timeout"] == "30s"
    end

    test "a revision landing while a narrowed head is re-issued refuses the grant and stands",
         %{ctx: ctx} do
      real = Sanctum.Grimoire.impl!()
      :persistent_term.put({CountingGrimoire, :real}, real)
      Sanctum.Grimoire.install!(CountingGrimoire)

      on_exit(fn ->
        Sanctum.Grimoire.install!(real)
        :persistent_term.erase({CountingGrimoire, :real})
      end)

      entry = entry!(ctx)
      binding = [%{need: "@ingress", entry_id: entry.id}]

      # How many catalog reads one walk of a grant takes: a head no
      # narrowing touched is walked once.
      publish!(ctx, "commit-grant-twin")
      {:ok, %{profile_id: twin}} = walk!(ctx, "reagent:local.commit-grant-twin")
      Process.put({CountingGrimoire, :count}, 0)

      assert {:ok, _} =
               Commit.grant(ctx, %{
                 profile_id: twin,
                 bindings: binding,
                 expected_consent_revision: 1
               })

      one_walk = Process.get({CountingGrimoire, :count})
      assert one_walk > 0

      publish!(ctx, "commit-grant-race")
      ref = "reagent:local.commit-grant-race"

      {:ok, %{profile_id: profile_id, revision: 1}} =
        walk!(ctx, ref, %{
          origins: [:interactive, :programmatic],
          subset: %{ref => %{"egress" => %{"domains" => ["api.one.example"]}}}
        })

      # The person's next decision lands as the grant starts its second walk,
      # the one that re-issues the head's narrowing.
      Process.put({CountingGrimoire, :count}, 0)

      Process.put(
        {CountingGrimoire, :armed},
        {one_walk,
         fn ->
           {:ok, %{revision: 2}} =
             walk!(ctx, ref, %{
               origins: [:interactive],
               subset: %{ref => %{"egress" => %{"domains" => []}}}
             })
         end}
      )

      # Refused by the second walk's fence: the revision it read is the one
      # that landed, not the one presented.
      assert {:error,
              {:consent_conflict, %{cause: :stale_plan, expected_revision: 1, actual_revision: 2}}} =
               Commit.grant(ctx, %{
                 profile_id: profile_id,
                 bindings: binding,
                 expected_consent_revision: 1
               })

      # The race fired, and the person's revision stands unwidened.
      refute Process.get({CountingGrimoire, :armed})
      head = head!(ctx, profile_id)
      assert head.revision == 2
      assert head.admitted_origins == [:interactive]
      {:ok, blob} = Jason.decode(head.resolved_policy)
      assert blob["nodes"][ref]["edges"]["@ingress"]["egress"]["domains"] == []
    end

    test "a head no narrowing touched is re-issued whole", %{ctx: ctx} do
      publish!(ctx, "commit-grant-whole")
      ref = "reagent:local.commit-grant-whole"
      entry = entry!(ctx)

      {:ok, %{profile_id: profile_id}} = walk!(ctx, ref)

      assert {:ok, %{revision: 2}} =
               Commit.grant(ctx, %{
                 profile_id: profile_id,
                 bindings: [%{need: "@ingress", entry_id: entry.id}],
                 expected_consent_revision: 1
               })

      head = head!(ctx, profile_id)
      assert head.admitted_origins == [:interactive]
      {:ok, blob} = Jason.decode(head.resolved_policy)

      assert blob["nodes"][ref]["edges"]["@ingress"]["egress"]["domains"] ==
               ["api.one.example", "api.two.example"]
    end
  end

  describe "an OAuth binding's scopes" do
    @mail_needs %{
      "needs" => %{
        "mail" => %{
          "type" => "oauth:google",
          "reason" => "to read your mail",
          "required" => true,
          "scopes" => ["gmail.readonly"]
        }
      },
      "caps" => @caps
    }

    defp oauth_entry!(ctx, scopes) do
      {:ok, view} =
        Sanctum.TestContext.create_vault(ctx, %{
          name: "mail-#{System.unique_integer([:positive])}",
          kind: "oauth",
          provider_hint: "google",
          oauth: %{"access_token" => "t"},
          oauth_scopes: scopes,
          destination: %{"hosts" => ["gmail.googleapis.com"]},
          # The mail need declares no attach rule: the component reads its
          # token itself.
          disclose: true
        })

      view
    end

    test "a consent narrowing scopes on a candidate that cannot be narrowed is refused at commit",
         %{ctx: ctx} do
      ref = "reagent:local.commit-narrow"
      publish!(ctx, "commit-narrow", "1.0.0", @mail_needs)
      entry = oauth_entry!(ctx, ["gmail.readonly", "gmail.send"])

      # The need's own scopes, and the same narrowing named outright, are
      # fewer than the entry holds, and Google's preset does not attenuate
      # a refresh: no preview offers it.
      narrowed = [
        %{ref: ref, bindings: [%{need: "mail", entry_id: entry.id}]},
        %{ref: ref, bindings: [%{need: "mail", entry_id: entry.id, scopes: ["gmail.readonly"]}]}
      ]

      for decisions <- narrowed do
        assert {:error, :scope_not_attenuable} = Commit.preview(ctx, decisions)
      end

      # The entry's scopes whole are what may be granted; a commit that
      # presents that proof for the narrowed decisions is refused, and no
      # revision is written.
      whole = %{
        ref: ref,
        bindings: [%{need: "mail", entry_id: entry.id, scopes: ["gmail.send", "gmail.readonly"]}]
      }

      {:ok, plan} = Plan.plan(ctx, %{ref: ref})
      {:ok, preview} = Commit.preview(ctx, whole)

      for decisions <- narrowed do
        assert {:error, :scope_not_attenuable} =
                 Commit.commit(ctx, %{
                   decisions: decisions,
                   plan_token: plan.plan_token,
                   proof: preview.proof,
                   commit_digest: preview.commit_digest,
                   expected_consent_revision: plan.expected_consent_revision
                 })
      end

      assert {:ok, []} = Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), ref)

      # A granted profile is held to the same rule when a binding is granted
      # to it later.
      assert {:ok, %{profile_id: profile_id, revision: 1}} =
               Commit.commit(ctx, %{
                 decisions: whole,
                 plan_token: plan.plan_token,
                 proof: preview.proof,
                 commit_digest: preview.commit_digest,
                 expected_consent_revision: plan.expected_consent_revision
               })

      assert {:error, :scope_not_attenuable} =
               Commit.grant(ctx, %{
                 profile_id: profile_id,
                 bindings: [%{need: "mail", entry_id: entry.id}],
                 expected_consent_revision: 1
               })

      assert head!(ctx, profile_id).revision == 1
    end

    test "a projection naming a scope the entry lacks is refused as the reader refuses it",
         %{ctx: ctx} do
      ref = "reagent:local.commit-lacks"
      publish!(ctx, "commit-lacks", "1.0.0", @mail_needs)
      entry = oauth_entry!(ctx, ["gmail.send"])

      assert {:error, {:scope_projection_unsatisfiable, ["gmail.readonly"]}} =
               Commit.preview(ctx, %{ref: ref, bindings: [%{need: "mail", entry_id: entry.id}]})
    end

    test "a projection naming exactly the entry's scopes is granted", %{ctx: ctx} do
      ref = "reagent:local.commit-exact"
      publish!(ctx, "commit-exact", "1.0.0", @mail_needs)
      entry = oauth_entry!(ctx, ["gmail.readonly"])

      assert {:ok, %{revision: 1}} =
               walk!(ctx, ref, %{bindings: [%{need: "mail", entry_id: entry.id}]})
    end
  end

  describe "a public profile's staging" do
    test "answers what it would grant as rows, with the origins it would admit", %{ctx: ctx} do
      publish!(ctx, "commit-publish")
      {:ok, %{profile_id: owner}} = walk!(ctx, "reagent:local.commit-publish")

      assert {:ok, staged} = Commit.stage_publish(ctx, %{profile_id: owner})
      assert staged.origins == ["interactive"]
      refute Map.has_key?(staged, :summary)

      # A public profile writes nothing durable unless asked: read alone.
      assert [%{"values" => %{"actions" => ["read"]}}] =
               Enum.filter(staged.rows, &(&1["kind"] == "storage"))
    end

    test "keeps a standing binding of the athanor's entry, and refuses what it cannot carry",
         %{ctx: ctx} do
      ref = "reagent:local.commit-public"
      publish!(ctx, "commit-public", "1.0.0", keyed_manifest())

      bind = fn bindings ->
        {:ok, %{profile_id: owner}} = walk!(ctx, ref, %{bindings: bindings})
        Commit.stage_publish(ctx, %{profile_id: owner, need_ids: ["@ingress"]})
      end

      standing = key!(ctx)
      assert {:ok, _staged} = bind.([%{need: "api_key", entry_id: standing.id}])

      assert {:error, {:invalid_argument, once}} =
               bind.([%{need: "api_key", entry_id: standing.id, lifetime: %{kind: "once"}}])

      assert once =~ "once"

      assert {:error, {:invalid_argument, named}} =
               bind.([
                 %{need: "api_key", entry_id: standing.id},
                 %{need: "api_key", entry_id: key!(ctx).id, name: "Second"}
               ])

      assert named =~ "named accounts"

      {person, _user} = Sanctum.TestContext.person!(ctx)
      offered = instance!()

      {:ok, %{profile_id: owner}} =
        walk!(person, ref, %{bindings: [%{need: "api_key", instance_entry_id: offered.id}]})

      assert {:error, {:invalid_argument, instance}} =
               Commit.stage_publish(person, %{profile_id: owner, need_ids: ["@ingress"]})

      assert instance =~ "instance entry is offered to people"
    end
  end

  # ===========================================================================
  # Matching, instance entries, named accounts and lifetimes
  # ===========================================================================

  @attach %{"in" => "header", "name" => "Authorization", "template" => "Bearer {value}"}
  @inference ~s({"hosts":["api.openai.com"],"methods":["POST"],"paths":["/v1/"],"scheme":"https"})

  # A component whose one need attaches an openai.com key.
  defp keyed_manifest(over \\ %{}) do
    %{
      "needs" => %{
        "api_key" =>
          Map.merge(
            %{
              "type" => "api_key:openai.com",
              "reason" => "to call the model",
              "fields" => ["OPENAI_API_KEY"],
              "attach" => @attach
            },
            over
          )
      },
      "caps" => %{"egress" => %{"domains" => ["api.openai.com"], "methods" => ["POST"]}}
    }
  end

  # An attach-only openai.com key of the athanor's.
  defp key!(ctx, over \\ %{}) do
    entry!(
      ctx,
      %{"OPENAI_API_KEY" => "sk-#{System.unique_integer([:positive])}"},
      Map.merge(%{provider_hint: "openai.com", disclose: false}, over)
    )
  end

  defp instance!(over \\ %{}) do
    {:ok, entry} =
      Arca.InstanceEntries.put(
        Arca.Test.Actor.platform(),
        Map.merge(
          %{
            name: "instance-#{System.unique_integer([:positive])}",
            kind: "api_key",
            provider_hint: "openai.com",
            field_names: ~s(["OPENAI_API_KEY"]),
            destination: @inference,
            sealed_payload: "sealed",
            binding_digest: "sha256:instance-#{System.unique_integer([:positive])}",
            audience: "everyone",
            created_by: "usr_admin"
          },
          over
        )
      )

    entry
  end

  defp rows_by_key(ctx, profile_id) do
    Map.new(head!(ctx, profile_id).vault_refs, &{&1.binding_key, &1})
  end

  defp in_hours(hours) do
    DateTime.utc_now()
    |> DateTime.add(hours * 3600, :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  # A source depending on two components that each attach an openai.com
  # key: two dependency edges an entry may be chosen for.
  defp two_deps!(ctx) do
    for dep <- ~w(commit-dep-a commit-dep-b), do: publish!(ctx, dep, "1.0.0", keyed_manifest())

    publish!(ctx, "commit-two", "1.0.0", %{
      "dependencies" => %{
        "static" => [
          %{"ref" => "reagent:local.commit-dep-a"},
          %{"ref" => "reagent:local.commit-dep-b"}
        ]
      }
    })

    "reagent:local.commit-two"
  end

  describe "matching and lifetimes" do
    test "matching and binding lifetimes are committed per edge without implicit disclosure",
         %{ctx: ctx} do
      ref = "reagent:local.commit-matched"
      publish!(ctx, "commit-matched", "1.0.0", keyed_manifest())
      default = key!(ctx)
      first = key!(ctx)
      second = key!(ctx)
      other_provider = key!(ctx, %{provider_hint: "anthropic.com"})

      # An entry of another provider meets no need of openai.com.
      assert {:error, {:provider_mismatch, "api_key"}} =
               Commit.preview(ctx, %{
                 ref: ref,
                 bindings: [%{need: "api_key", entry_id: other_provider.id}]
               })

      # The need attaches: an attach-only entry meets it, and stays
      # attach-only.
      until = in_hours(1)

      bindings = [
        %{need: "api_key", entry_id: default.id},
        %{
          need: "api_key",
          entry_id: first.id,
          name: "Supabase 1",
          lifetime: %{kind: "until", until: until}
        },
        %{need: "api_key", entry_id: second.id, name: "Supabase 2", lifetime: %{kind: "once"}}
      ]

      {:ok, preview} = Commit.preview(ctx, %{ref: ref, bindings: bindings})
      credentials = for %{"kind" => "credential", "values" => v} <- preview.rows, do: v

      assert Enum.map(credentials, &{&1["binding_key"], &1["lifetime"], &1["disclosed"]})
             |> Enum.sort() == [
               {"#{ref}|@ingress|default", %{"kind" => "standing", "until" => nil}, false},
               {"#{ref}|@ingress|name:Supabase 1", %{"kind" => "until", "until" => until}, false},
               {"#{ref}|@ingress|name:Supabase 2", %{"kind" => "once", "until" => nil}, false}
             ]

      assert Enum.sort(for v <- credentials, v["connection"], do: v["connection"]) ==
               ["Supabase 1", "Supabase 2"]

      assert {:ok, %{profile_id: profile_id}} = walk!(ctx, ref, %{bindings: bindings})

      # Each binding is its own row under its own key, with its lifetime.
      rows = rows_by_key(ctx, profile_id)

      assert %{lifetime_kind: "standing", expires_at: nil, vault_entry_id: id} =
               rows["#{ref}|@ingress|default"]

      assert id == default.id

      assert %{lifetime_kind: "until", expires_at: %DateTime{} = expires} =
               rows["#{ref}|@ingress|name:Supabase 1"]

      assert DateTime.to_iso8601(DateTime.truncate(expires, :second)) == until
      assert %{lifetime_kind: "once"} = rows["#{ref}|@ingress|name:Supabase 2"]

      # The blob carries the default as the edge's vault and each account
      # under its name, by the need's rule; no lifetime rides the blob.
      {:ok, blob} = Prima.Authority.Blob.parse(head!(ctx, profile_id).resolved_policy)
      {:ok, ingress} = Prima.Authority.Blob.ingress(blob, ref)
      assert ingress.vault.entry_id == default.id
      assert Map.keys(ingress.vault.named) |> Enum.sort() == ["Supabase 1", "Supabase 2"]
      assert Prima.Manifest.Needs.attach_to_map(ingress.vault.attach) == @attach
      refute head!(ctx, profile_id).resolved_policy =~ "once"

      # One entry chosen for two dependency edges under two lifetimes is
      # two rows under two keys.
      two = two_deps!(ctx)

      {:ok, %{profile_id: two_id}} =
        walk!(ctx, two, %{
          selections: [
            %{dep: "reagent:local.commit-dep-a", entry_id: default.id, lifetime: %{kind: "once"}},
            %{
              dep: "reagent:local.commit-dep-b",
              entry_id: default.id,
              lifetime: %{kind: "until", until: until}
            }
          ]
        })

      two_rows = rows_by_key(ctx, two_id)

      assert %{lifetime_kind: "once", vault_entry_id: a} =
               two_rows["#{two}|reagent:local.commit-dep-a|default"]

      assert %{lifetime_kind: "until", vault_entry_id: b} =
               two_rows["#{two}|reagent:local.commit-dep-b|default"]

      assert a == default.id and b == default.id

      # A need the component reads itself takes a disclosed entry: an
      # attach-only one is refused, never disclosed by the binding.
      publish!(ctx, "commit-reads", "1.0.0", %{
        "needs" => %{
          "api_key" => %{
            "type" => "api_key:openai.com",
            "reason" => "to read the key",
            "fields" => ["OPENAI_API_KEY"]
          }
        }
      })

      assert {:error, {:disclosure_refused, "api_key"}} =
               Commit.preview(ctx, %{
                 ref: "reagent:local.commit-reads",
                 bindings: [%{need: "api_key", entry_id: default.id}]
               })

      {:ok, row} = Arca.VaultStorage.get(Sanctum.Context.actor(ctx), default.id)
      assert row.attach_only
    end

    test "a disclose: true need takes a disclosed entry alone", %{ctx: ctx} do
      publish!(ctx, "commit-discloses", "1.0.0", keyed_manifest(%{"disclose" => true}))
      ref = "reagent:local.commit-discloses"

      assert {:error, {:disclosure_refused, "api_key"}} =
               Commit.preview(ctx, %{
                 ref: ref,
                 bindings: [%{need: "api_key", entry_id: key!(ctx).id}]
               })

      disclosed = key!(ctx, %{disclose: true})

      assert {:ok, _} =
               Commit.preview(ctx, %{
                 ref: ref,
                 bindings: [%{need: "api_key", entry_id: disclosed.id}]
               })
    end

    test "one need's default and named accounts: two defaults, a repeated name, an account " <>
           "beside no default and a second need are refused",
         %{ctx: ctx} do
      ref = "reagent:local.commit-slots"
      publish!(ctx, "commit-slots", "1.0.0", keyed_manifest())
      [a, b] = [key!(ctx), key!(ctx)]

      for bindings <- [
            [%{need: "api_key", entry_id: a.id}, %{need: "api_key", entry_id: b.id}],
            [
              %{need: "api_key", entry_id: a.id},
              %{need: "api_key", entry_id: a.id, name: "Work"},
              %{need: "api_key", entry_id: b.id, name: "work"}
            ],
            [%{need: "api_key", entry_id: a.id, name: "Work"}],
            [%{need: "api_key", entry_id: a.id, name: "has|pipe"}]
          ] do
        assert {:error, {:invalid_argument, why}} =
                 Commit.preview(ctx, %{ref: ref, bindings: bindings}),
               "#{inspect(bindings)} was accepted"

        assert why =~ "api_key"
      end

      # Neither or both of an entry and an instance entry.
      for binding <- [
            %{need: "api_key"},
            %{need: "api_key", entry_id: a.id, instance_entry_id: "ine_x"}
          ] do
        assert {:error, {:invalid_argument, why}} =
                 Commit.preview(ctx, %{ref: ref, bindings: [binding]})

        assert why =~ "exactly one of entry_id and instance_entry_id"
      end
    end

    test "a lifetime is standing, until within a day, or once; anything else is refused",
         %{ctx: ctx} do
      ref = "reagent:local.commit-lifetime"
      publish!(ctx, "commit-lifetime", "1.0.0", keyed_manifest())
      key = key!(ctx)
      binding = fn lifetime -> [%{need: "api_key", entry_id: key.id, lifetime: lifetime}] end

      for {lifetime, fragment} <- [
            {%{kind: "until", until: in_hours(-1)}, "not after now"},
            {%{kind: "until", until: in_hours(25)}, "more than 24 hours"},
            {%{kind: "until"}, "without its instant"},
            {%{kind: "until", until: "tomorrow"}, "RFC 3339"},
            {%{kind: "until", until: "2026-10-04T12:00:00+02:00"}, "RFC 3339"},
            {%{kind: "once", until: in_hours(1)}, "an until for a once"},
            {%{kind: "forever"}, "standing, until or once"},
            {%{kind: "standing", extra: 1}, "only a kind and an until"},
            {"once", "not a record"}
          ] do
        assert {:error, {:invalid_argument, why}} =
                 Commit.preview(ctx, %{ref: ref, bindings: binding.(lifetime)}),
               "#{inspect(lifetime)} was accepted"

        assert why =~ "The binding for api_key"
        assert why =~ fragment, "#{inspect(lifetime)}: #{why}"
      end

      assert {:error, {:invalid_argument, _}} =
               Commit.preview(ctx, %{
                 ref: ref,
                 bindings: [%{need: "api_key", entry_id: key.id, renew: "yes"}]
               })

      # +00:00 is UTC too.
      utc = String.replace_suffix(in_hours(2), "Z", "+00:00")

      assert {:ok, _} =
               Commit.preview(ctx, %{ref: ref, bindings: binding.(%{kind: "until", until: utc})})
    end

    test "an until that passes between preview and commit is refused at commit", %{ctx: ctx} do
      ref = "reagent:local.commit-passing"
      publish!(ctx, "commit-passing", "1.0.0", keyed_manifest())
      key = key!(ctx)

      soon =
        DateTime.utc_now()
        |> DateTime.add(3, :second)
        |> DateTime.to_iso8601()

      decisions = %{
        ref: ref,
        bindings: [%{need: "api_key", entry_id: key.id, lifetime: %{kind: "until", until: soon}}]
      }

      {:ok, plan} = Plan.plan(ctx, %{ref: ref})
      {:ok, preview} = Commit.preview(ctx, decisions)

      {:ok, passed, 0} = DateTime.from_iso8601(soon)

      Prima.Test.Wait.wait_until(
        fn -> DateTime.compare(DateTime.utc_now(), passed) == :gt end,
        5_000,
        "the until to pass"
      )

      assert {:error, {:invalid_argument, why}} =
               Commit.commit(ctx, %{
                 decisions: decisions,
                 plan_token: plan.plan_token,
                 proof: preview.proof,
                 commit_digest: preview.commit_digest,
                 expected_consent_revision: plan.expected_consent_revision
               })

      assert why =~ "not after now"
    end

    test "a once account is consumed apart from its neighbours, carried across a revision " <>
           "and renewed only when the decision says so",
         %{ctx: ctx} do
      ref = "reagent:local.commit-once"
      publish!(ctx, "commit-once", "1.0.0", keyed_manifest())
      [default, one, two, three] = for _ <- 1..4, do: key!(ctx)
      actor = Sanctum.Context.actor(ctx)

      bindings = [
        %{need: "api_key", entry_id: default.id},
        %{need: "api_key", entry_id: one.id, name: "Supabase 1", lifetime: %{kind: "once"}},
        %{need: "api_key", entry_id: two.id, name: "Supabase 2", lifetime: %{kind: "once"}}
      ]

      {:ok, %{profile_id: profile}} = walk!(ctx, ref, %{bindings: bindings})
      first_head = head!(ctx, profile)
      one_key = "#{ref}|@ingress|name:Supabase 1"
      two_key = "#{ref}|@ingress|name:Supabase 2"

      # The second consumed by one root: the first is still consumable,
      # another root is refused the second, and the default is no once.
      assert :ok =
               Arca.ConsentStorage.consume_once(actor, profile, first_head.id, two_key, "exec_a")

      assert {:error, :already_consumed} =
               Arca.ConsentStorage.consume_once(actor, profile, first_head.id, two_key, "exec_b")

      assert :ok =
               Arca.ConsentStorage.consume_once(actor, profile, first_head.id, one_key, "exec_b")

      assert {:error, :not_once} =
               Arca.ConsentStorage.consume_once(
                 actor,
                 profile,
                 first_head.id,
                 "#{ref}|@ingress|default",
                 "exec_a"
               )

      # A revision that adds a third account carries the consumed ones.
      third = %{need: "api_key", entry_id: three.id, name: "Supabase 3"}
      {:ok, %{revision: 2}} = walk!(ctx, ref, %{bindings: bindings ++ [third]})
      second_head = head!(ctx, profile)
      rows = rows_by_key(ctx, profile)

      assert rows[two_key].consumed_by_root == "exec_a"
      assert rows[one_key].consumed_by_root == "exec_b"
      assert rows["#{ref}|@ingress|name:Supabase 3"].consumed_by_root == nil

      # The superseded revision admits no consumption, whether or not it
      # consumed before, and the new head's carried row stays consumed.
      assert {:error, :superseded} =
               Arca.ConsentStorage.consume_once(actor, profile, first_head.id, two_key, "exec_a")

      assert {:error, :already_consumed} =
               Arca.ConsentStorage.consume_once(actor, profile, second_head.id, two_key, "exec_c")

      # A revision marking the second renew makes it consumable again,
      # and leaves the first as it was.
      renewed =
        Enum.map(bindings ++ [third], fn
          %{name: "Supabase 2"} = binding -> Map.put(binding, :renew, true)
          binding -> binding
        end)

      {:ok, %{revision: 3}} = walk!(ctx, ref, %{bindings: renewed})
      third_head = head!(ctx, profile)
      rows = rows_by_key(ctx, profile)

      assert rows[two_key].consumed_by_root == nil
      assert rows[one_key].consumed_by_root == "exec_b"

      assert :ok =
               Arca.ConsentStorage.consume_once(actor, profile, third_head.id, two_key, "exec_c")
    end

    test "a root pinned to a superseded revision is no longer intact", %{ctx: ctx} do
      ref = "reagent:local.commit-pinned"
      publish!(ctx, "commit-pinned", "1.0.0", keyed_manifest())
      once = key!(ctx)
      bindings = [%{need: "api_key", entry_id: once.id, lifetime: %{kind: "once"}}]
      {:ok, %{profile_id: profile_id}} = walk!(ctx, ref, %{bindings: bindings})

      {:ok, [profile]} = Arca.ConsentStorage.profiles(Sanctum.Context.actor(ctx), ref)
      {:ok, component} = Compendium.Registry.get_latest(ctx, "commit-pinned", "local", "reagent")
      {:ok, live} = Compendium.Activation.resolve_verified(ctx, component)
      {:ok, authority, _} = Sanctum.Consent.Loader.load_root(ctx, profile, live: {:ok, live})

      assert Sanctum.Consent.Loader.pinned_intact?(ctx, authority)

      {:ok, %{revision: 2}} =
        walk!(ctx, ref, %{bindings: bindings, origins: [:interactive, :programmatic]})

      refute Sanctum.Consent.Loader.pinned_intact?(ctx, authority)

      assert {:error, :superseded} =
               Arca.ConsentStorage.consume_once(
                 Sanctum.Context.actor(ctx),
                 profile_id,
                 authority.consent_id,
                 "#{ref}|@ingress|default",
                 "exec_late"
               )
    end

    test "a commit differing from its preview only by renew fails the digest check", %{ctx: ctx} do
      ref = "reagent:local.commit-renew"
      publish!(ctx, "commit-renew", "1.0.0", keyed_manifest())
      key = key!(ctx)
      binding = %{need: "api_key", entry_id: key.id, lifetime: %{kind: "once"}}

      {:ok, plan} = Plan.plan(ctx, %{ref: ref})
      {:ok, preview} = Commit.preview(ctx, %{ref: ref, bindings: [binding]})

      assert {:error, {:consent_conflict, %{cause: :digest_changed}}} =
               Commit.commit(ctx, %{
                 decisions: %{ref: ref, bindings: [Map.put(binding, :renew, true)]},
                 plan_token: plan.plan_token,
                 proof: preview.proof,
                 commit_digest: preview.commit_digest,
                 expected_consent_revision: plan.expected_consent_revision
               })
    end
  end

  # An app declaring two needs of its own: `api_key`, an openai.com key,
  # and `other_key`, the same need again (`identical`) or an anthropic.com
  # key, so that each head binding's entry tells which need it was for.
  defp two_own_needs!(ctx, name, identical?) do
    other =
      if identical?,
        do: keyed_manifest()["needs"]["api_key"],
        else: %{
          "type" => "api_key:anthropic.com",
          "reason" => "to call the other model",
          "fields" => ["ANTHROPIC_API_KEY"],
          "attach" => @attach
        }

    publish!(ctx, name, "1.0.0", put_in(keyed_manifest(), ["needs", "other_key"], other))
    "reagent:local.#{name}"
  end

  defp anthropic_key!(ctx) do
    entry!(
      ctx,
      %{"ANTHROPIC_API_KEY" => "sk-ant-#{System.unique_integer([:positive])}"},
      %{provider_hint: "anthropic.com", disclose: false}
    )
  end

  # A commit of `decisions` on a fresh plan, presenting `digest` with the
  # proof of the preview just taken.
  defp commit_presenting(ctx, ref, decisions, digest) do
    {:ok, plan} = Plan.plan(ctx, %{ref: ref})
    {:ok, preview} = Commit.preview(ctx, Map.put(decisions, :ref, ref))

    Commit.commit(ctx, %{
      decisions: Map.put(decisions, :ref, ref),
      plan_token: plan.plan_token,
      proof: preview.proof,
      commit_digest: digest,
      expected_consent_revision: plan.expected_consent_revision
    })
  end

  describe "the app's own calls carry one need's credentials" do
    test "one grant binding two of the app's needs is refused, naming them and the remedy",
         %{ctx: ctx} do
      ref = two_own_needs!(ctx, "commit-probe-both", false)
      [a, c] = [key!(ctx), key!(ctx)]
      [d, b] = [anthropic_key!(ctx), anthropic_key!(ctx)]

      both = [
        %{need: "api_key", entry_id: a.id},
        %{need: "api_key", entry_id: c.id, name: "Work"},
        %{need: "other_key", entry_id: d.id},
        %{need: "other_key", entry_id: b.id, name: "Work"}
      ]

      sentence =
        "The app's own calls carry one need's credentials: bind api_key or other_key, not both"

      assert {:error, {:invalid_argument, ^sentence} = reason} =
               Commit.preview(ctx, %{ref: ref, bindings: both})

      assert PrismWeb.Ops.error_message(reason) == sentence

      # Three needs: bind one of them.
      three =
        keyed_manifest()
        |> put_in(["needs", "other_key"], keyed_manifest()["needs"]["api_key"])
        |> put_in(["needs", "third_key"], keyed_manifest()["needs"]["api_key"])

      publish!(ctx, "commit-probe-three", "1.0.0", three)

      assert {:error,
              {:invalid_argument,
               "The app's own calls carry one need's credentials: " <>
                 "bind one of api_key, other_key or third_key"}} =
               Commit.preview(ctx, %{
                 ref: "reagent:local.commit-probe-three",
                 bindings: [
                   %{need: "third_key", entry_id: a.id},
                   %{need: "api_key", entry_id: c.id},
                   %{need: "other_key", entry_id: a.id, name: "Work"}
                 ]
               })
    end

    test "a grant for another need lists the bindings it removes, and the digest covers them",
         %{ctx: ctx} do
      ref = two_own_needs!(ctx, "commit-probe-other", false)
      [a, c] = [key!(ctx), key!(ctx)]
      [d, b] = [anthropic_key!(ctx), anthropic_key!(ctx)]

      first = %{
        bindings: [
          %{need: "api_key", entry_id: a.id},
          %{need: "api_key", entry_id: c.id, name: "Work"}
        ]
      }

      second = %{
        bindings: [
          %{need: "other_key", entry_id: d.id},
          %{need: "other_key", entry_id: b.id, name: "Work"}
        ]
      }

      # What the second grant previews with no head to remove from.
      {:ok, unheaded} = Commit.preview(ctx, Map.put(second, :ref, ref))
      assert unheaded.removed == []

      {:ok, %{profile_id: profile}} = walk!(ctx, ref, first)
      {:ok, preview} = Commit.preview(ctx, Map.put(second, :ref, ref))

      assert preview.removed == [
               %{
                 "binding_key" => "#{ref}|@ingress|default",
                 "node" => ref,
                 "edge" => "@ingress",
                 "need" => "api_key",
                 "entry_id" => a.id,
                 "name" => a.name,
                 "source" => "own"
               },
               %{
                 "binding_key" => "#{ref}|@ingress|name:Work",
                 "node" => ref,
                 "edge" => "@ingress",
                 "need" => "api_key",
                 "connection" => "Work",
                 "entry_id" => c.id,
                 "name" => c.name,
                 "source" => "own"
               }
             ]

      assert {:ok, decoded} = ConsentPreview.decode(document(preview))
      assert ConsentPreview.encode(decoded)["removed"] == preview.removed

      # The digest covers the removals: the second grant's digest taken
      # without them is refused, and nothing is written.
      refute preview.commit_digest == unheaded.commit_digest

      assert {:error, {:consent_conflict, %{cause: :digest_changed}}} =
               commit_presenting(ctx, ref, second, unheaded.commit_digest)

      assert head!(ctx, profile).revision == 1

      assert {:ok, %{revision: 2}} = walk!(ctx, ref, second)

      assert Map.new(rows_by_key(ctx, profile), fn {key, row} -> {key, row.vault_entry_id} end) ==
               %{"#{ref}|@ingress|default" => d.id, "#{ref}|@ingress|name:Work" => b.id}
    end

    test "needs that cannot be told apart are compared by key: a key set again is a changed " <>
           "row, a key left out is removed with no need",
         %{ctx: ctx} do
      ref = two_own_needs!(ctx, "commit-probe-same", true)
      [a, c, p, d, b] = for _ <- 1..5, do: key!(ctx)

      first = %{
        bindings: [
          %{need: "api_key", entry_id: a.id},
          %{need: "api_key", entry_id: c.id, name: "Work"},
          %{need: "api_key", entry_id: p.id, name: "Personal"}
        ]
      }

      second = %{
        bindings: [
          %{need: "other_key", entry_id: d.id},
          %{need: "other_key", entry_id: b.id, name: "Work"}
        ]
      }

      {:ok, unheaded} = Commit.preview(ctx, Map.put(second, :ref, ref))
      {:ok, %{profile_id: profile}} = walk!(ctx, ref, first)
      {:ok, preview} = Commit.preview(ctx, Map.put(second, :ref, ref))

      # The default and Work are set again: their rows carry the new
      # entries, and neither is listed as removed.
      rows =
        for %{"kind" => "credential", "values" => values} <- preview.rows,
            into: %{},
            do: {values["binding_key"], values["name"]}

      assert rows == %{"#{ref}|@ingress|default" => d.name, "#{ref}|@ingress|name:Work" => b.name}

      # Personal is left out: removed by its key, its need not told.
      assert preview.removed == [
               %{
                 "binding_key" => "#{ref}|@ingress|name:Personal",
                 "node" => ref,
                 "edge" => "@ingress",
                 "need" => nil,
                 "connection" => "Personal",
                 "entry_id" => p.id,
                 "name" => p.name,
                 "source" => "own"
               }
             ]

      refute preview.commit_digest == unheaded.commit_digest

      assert {:error, {:consent_conflict, %{cause: :digest_changed}}} =
               commit_presenting(ctx, ref, second, unheaded.commit_digest)

      assert {:ok, %{revision: 2}} = walk!(ctx, ref, second)

      assert Map.new(rows_by_key(ctx, profile), fn {key, row} -> {key, row.vault_entry_id} end) ==
               %{"#{ref}|@ingress|default" => d.id, "#{ref}|@ingress|name:Work" => b.id}
    end

    test "a same-need re-grant that removes nothing names no removal, and hashes as with none",
         %{ctx: ctx} do
      ref = two_own_needs!(ctx, "commit-probe-again", false)
      [a, a2, c] = [key!(ctx), key!(ctx), key!(ctx)]

      first = [
        %{need: "api_key", entry_id: a.id},
        %{need: "api_key", entry_id: c.id, name: "Work"}
      ]

      # The default's entry changes under the same key and need.
      again = %{bindings: [%{need: "api_key", entry_id: a2.id} | tl(first)]}

      {:ok, unheaded} = Commit.preview(ctx, Map.put(again, :ref, ref))
      {:ok, _} = walk!(ctx, ref, %{bindings: first})
      {:ok, preview} = Commit.preview(ctx, Map.put(again, :ref, ref))

      assert preview.removed == []
      assert preview.commit_digest == unheaded.commit_digest

      assert [a2.name] ==
               for(
                 %{"kind" => "credential", "values" => %{"binding_key" => key} = values} <-
                   preview.rows,
                 key == "#{ref}|@ingress|default",
                 do: values["name"]
               )

      assert {:ok, %{revision: 2}} = walk!(ctx, ref, again)
    end

    test "a grant, which no preview stands before, answers with the bindings it removed, as " <>
           "a preview of it over the same head lists them",
         %{ctx: ctx} do
      ref = two_own_needs!(ctx, "commit-grant-other", false)
      [a, c] = [key!(ctx), key!(ctx)]
      [d, b] = [anthropic_key!(ctx), anthropic_key!(ctx)]

      first = [
        %{need: "api_key", entry_id: a.id},
        %{need: "api_key", entry_id: c.id, name: "Work"}
      ]

      second = [
        %{need: "other_key", entry_id: d.id},
        %{need: "other_key", entry_id: b.id, name: "Work"}
      ]

      {:ok, %{profile_id: profile}} = walk!(ctx, ref, %{bindings: first})
      {:ok, preview} = Commit.preview(ctx, %{ref: ref, bindings: second})

      assert {:ok, %{revision: 2, removed: removed}} =
               Commit.grant(ctx, %{
                 profile_id: profile,
                 bindings: second,
                 expected_consent_revision: 1
               })

      assert removed == preview.removed

      assert removed == [
               %{
                 "binding_key" => "#{ref}|@ingress|default",
                 "node" => ref,
                 "edge" => "@ingress",
                 "need" => "api_key",
                 "entry_id" => a.id,
                 "name" => a.name,
                 "source" => "own"
               },
               %{
                 "binding_key" => "#{ref}|@ingress|name:Work",
                 "node" => ref,
                 "edge" => "@ingress",
                 "need" => "api_key",
                 "connection" => "Work",
                 "entry_id" => c.id,
                 "name" => c.name,
                 "source" => "own"
               }
             ]
    end

    test "a same-need grant answers that it removed nothing, as a preview of it lists", %{
      ctx: ctx
    } do
      ref = two_own_needs!(ctx, "commit-grant-same", false)
      [a, c] = [key!(ctx), key!(ctx)]

      first = [
        %{need: "api_key", entry_id: a.id},
        %{need: "api_key", entry_id: c.id, name: "Work"}
      ]

      # The two entries change places under the same keys and need.
      again = [
        %{need: "api_key", entry_id: c.id},
        %{need: "api_key", entry_id: a.id, name: "Work"}
      ]

      {:ok, %{profile_id: profile}} = walk!(ctx, ref, %{bindings: first})
      {:ok, preview} = Commit.preview(ctx, %{ref: ref, bindings: again})
      assert preview.removed == []

      assert {:ok, %{revision: 2, removed: []}} =
               Commit.grant(ctx, %{
                 profile_id: profile,
                 bindings: again,
                 expected_consent_revision: 1
               })

      assert Map.new(rows_by_key(ctx, profile), fn {key, row} -> {key, row.vault_entry_id} end) ==
               %{"#{ref}|@ingress|default" => c.id, "#{ref}|@ingress|name:Work" => a.id}
    end
  end

  describe "instance entries" do
    setup %{ctx: ctx} do
      {person, _user} = Sanctum.TestContext.person!(ctx)
      {:ok, person: person}
    end

    # A component of the person's own: the install media does not ship it.
    defp custom!(ctx, name) do
      {:ok, _} =
        Compendium.Registry.publish_bytes(ctx, @wasm, %{
          name: name,
          version: "1.0.0",
          type: "reagent",
          manifest:
            Jason.encode!(
              Map.merge(keyed_manifest(), %{
                "name" => name,
                "type" => "reagent",
                "version" => "1.0.0"
              })
            )
        })

      "reagent:local.#{name}"
    end

    # A component the install media ships, unmodified.
    defp shipped!(ctx, name) do
      Cyfr.Test.SeedBundle.isolate!()

      {:ok, _} =
        Arca.Test.UnitFixtures.ship_and_register!(ctx, "reagent", "local", name, "1.0.0",
          manifest:
            Map.merge(keyed_manifest(), %{
              "name" => name,
              "type" => "reagent",
              "version" => "1.0.0",
              "publisher" => "local"
            }),
          wasm: @wasm
        )

      "reagent:local.#{name}"
    end

    defp bind_instance(person, ref, entry),
      do:
        Commit.preview(person, %{
          ref: ref,
          bindings: [%{need: "api_key", instance_entry_id: entry.id}]
        })

    # A revoke of `entry_id` landing as the revision's transaction commits:
    # armed once the revision's binding rows are written, run at the
    # transaction's commit. The commit is logged after the connection is
    # checked in, so the revoke runs wholly after the revision and before
    # anything the commit does next.
    def revoke_on_commit(_event, _measurements, meta, %{test: test, entry_id: entry_id}) do
      if self() == test do
        cond do
          meta[:source] == "consent_vault_refs" and
              String.starts_with?(meta[:query] || "", "INSERT") ->
            Process.put(:a0_refs_written, true)

          Process.get(:a0_refs_written) == true and meta[:query] == "commit" ->
            Process.delete(:a0_refs_written)

            revoked =
              Task.async(fn ->
                Arca.InstanceEntries.revoke(Arca.Test.Actor.platform(), entry_id, "needs_consent")
              end)
              |> Task.await(30_000)

            Process.put(:a0_revoked, revoked)

          true ->
            :ok
        end
      end
    end

    test "is bound as a source of its own, scoped instance, and its row names it", %{
      person: person
    } do
      ref = custom!(person, "commit-instance")
      offered = instance!()

      {:ok, preview} = bind_instance(person, ref, offered)

      assert [%{"values" => values}] = Enum.filter(preview.rows, &(&1["kind"] == "credential"))
      assert values["source"] == "instance"
      assert values["disclosed"] == false
      assert values["name"] == offered.name
      assert values["suggested"] == true

      {:ok, %{profile_id: profile_id}} =
        walk!(person, ref, %{bindings: [%{need: "api_key", instance_entry_id: offered.id}]})

      assert [%{scope: "instance", instance_entry_id: id, vault_entry_id: nil}] =
               head!(person, profile_id).vault_refs

      assert id == offered.id
    end

    test "any admits a person's own component; shipped admits only the unmodified shipped one",
         %{person: person} do
      custom = custom!(person, "commit-custom")
      shipped = shipped!(person, "commit-shipped")
      any = instance!(%{component_policy: "any"})
      only_shipped = instance!(%{component_policy: "shipped"})

      assert {:ok, _} = bind_instance(person, custom, any)
      assert {:ok, _} = bind_instance(person, shipped, any)
      assert {:ok, _} = bind_instance(person, shipped, only_shipped)

      assert {:error, {:component_not_admitted, "api_key"}} =
               bind_instance(person, custom, only_shipped)
    end

    test "a policy tightened after preview is read again at commit", %{person: person} do
      ref = custom!(person, "commit-tightened")
      entry = instance!(%{component_policy: "any"})
      decisions = %{ref: ref, bindings: [%{need: "api_key", instance_entry_id: entry.id}]}

      {:ok, plan} = Plan.plan(person, %{ref: ref})
      {:ok, preview} = Commit.preview(person, decisions)

      :ok =
        Arca.InstanceEntries.set_component_policy(
          Arca.Test.Actor.platform(),
          entry.id,
          "any",
          "shipped"
        )

      assert {:error, {:component_not_admitted, "api_key"}} =
               Commit.commit(person, %{
                 decisions: decisions,
                 plan_token: plan.plan_token,
                 proof: preview.proof,
                 commit_digest: preview.commit_digest,
                 expected_consent_revision: plan.expected_consent_revision
               })
    end

    test "an entry not offered to the person, not active, of another provider, or bound " <>
           "where the component reads the value, is refused",
         %{person: person} do
      ref = custom!(person, "commit-refusals")

      listed = instance!(%{audience: "listed"})
      assert {:error, {:not_offered, "api_key"}} = bind_instance(person, ref, listed)

      revoked = instance!()

      {:ok, _} =
        Arca.InstanceEntries.revoke(Arca.Test.Actor.platform(), revoked.id, "needs_consent")

      assert {:error, {:entry_unavailable, id, "revoked"}} = bind_instance(person, ref, revoked)
      assert id == revoked.id

      other = instance!(%{provider_hint: "anthropic.com"})
      assert {:error, {:provider_mismatch, "api_key"}} = bind_instance(person, ref, other)

      publish!(person, "commit-instance-reads", "1.0.0", keyed_manifest(%{"disclose" => true}))

      assert {:error, {:disclosure_refused, "api_key"}} =
               bind_instance(person, "reagent:local.commit-instance-reads", instance!())
    end

    test "a revoke landing as a revision commits blocks the profile, and the commit never " <>
           "unblocks it after",
         %{person: person} do
      ref = custom!(person, "commit-revoke-race")
      entry = instance!()
      bindings = [%{need: "api_key", instance_entry_id: entry.id}]
      {:ok, %{profile_id: profile_id, revision: 1}} = walk!(person, ref, %{bindings: bindings})

      handler = {__MODULE__, :revoke_on_commit, System.unique_integer([:positive])}

      :ok =
        :telemetry.attach(handler, [:arca, :repo, :query], &__MODULE__.revoke_on_commit/4, %{
          test: self(),
          entry_id: entry.id
        })

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, %{revision: 2}} =
               walk!(person, ref, %{bindings: bindings, origins: [:interactive, :programmatic]})

      :telemetry.detach(handler)

      # The revoke saw the new head and blocked its profile.
      assert {:ok, affected} = Process.get(:a0_revoked)
      assert {person.athanor_id, profile_id} in affected
      assert [%{instance_entry_id: id}] = head!(person, profile_id).vault_refs
      assert id == entry.id

      # And the block stands: nothing after the revision unblocks it.
      assert {:ok, %{status: "needs_consent"}} =
               Arca.ProfileStorage.get(Sanctum.Context.actor(person), profile_id)
    end
  end

  describe "selections and provided configuration" do
    test "an entry chosen for a dependency's need is held to that need", %{ctx: ctx} do
      two = two_deps!(ctx)

      # Another provider's entry, a need it does not declare, and a
      # label beside an entry are refused.
      assert {:error, {:provider_mismatch, "api_key"}} =
               Commit.preview(ctx, %{
                 ref: two,
                 selections: [
                   %{
                     dep: "reagent:local.commit-dep-a",
                     entry_id: key!(ctx, %{provider_hint: "anthropic.com"}).id
                   }
                 ]
               })

      assert {:error, {:unknown_need, "other"}} =
               Commit.preview(ctx, %{
                 ref: two,
                 selections: [
                   %{dep: "reagent:local.commit-dep-a", entry_id: key!(ctx).id, need: "other"}
                 ]
               })

      assert {:error, {:invalid_argument, _}} =
               Commit.preview(ctx, %{
                 ref: two,
                 selections: [
                   %{dep: "reagent:local.commit-dep-a", entry_id: key!(ctx).id, label: "default"}
                 ]
               })

      # The edge carries the entry under the need's rule and projection.
      key = key!(ctx)

      {:ok, %{profile_id: profile_id}} =
        walk!(ctx, two, %{selections: [%{dep: "reagent:local.commit-dep-a", entry_id: key.id}]})

      {:ok, blob} = Prima.Authority.Blob.parse(head!(ctx, profile_id).resolved_policy)

      {:ok, edge} =
        Prima.Authority.Blob.lookup_edge(blob, two, "reagent:local.commit-dep-a", "")

      assert %{entry_id: id, scope: "athanor", projection: %{fields: ["OPENAI_API_KEY"]}} =
               edge.vault

      assert id == key.id
      assert Prima.Manifest.Needs.attach_to_map(edge.vault.attach) == @attach
    end

    test "a grant re-issues the head's entry selection with the lifetime its row holds", %{
      ctx: ctx
    } do
      two = two_deps!(ctx)
      key = key!(ctx)

      {:ok, %{profile_id: profile_id}} =
        walk!(ctx, two, %{
          selections: [
            %{dep: "reagent:local.commit-dep-a", entry_id: key.id, lifetime: %{kind: "once"}}
          ]
        })

      key_a = "#{two}|reagent:local.commit-dep-a|default"
      head = head!(ctx, profile_id)

      :ok =
        Arca.ConsentStorage.consume_once(
          Sanctum.Context.actor(ctx),
          profile_id,
          head.id,
          key_a,
          "exec_grant"
        )

      assert {:ok, %{revision: 2}} =
               Commit.grant(ctx, %{
                 profile_id: profile_id,
                 bindings: [],
                 expected_consent_revision: 1
               })

      rows = rows_by_key(ctx, profile_id)

      assert %{lifetime_kind: "once", consumed_by_root: "exec_grant", vault_entry_id: id} =
               rows[key_a]

      assert id == key.id
    end

    test "a need the app provides takes no selection, and an edge it would fill twice is " <>
           "refused",
         %{ctx: ctx} do
      publish!(ctx, "commit-db", "1.0.0", %{
        "needs" => %{
          "database" => %{
            "type" => "api_key:supabase.co",
            "reason" => "to reach the database",
            "fields" => ["anon_key"],
            "attach" => %{"in" => "header", "name" => "apikey", "template" => "{value}"}
          },
          "admin" => %{
            "type" => "api_key:supabase.co",
            "reason" => "to administer it",
            "fields" => ["service_key"],
            "attach" => %{"in" => "header", "name" => "x-admin", "template" => "{value}"}
          }
        }
      })

      provided = %{
        "destination" => %{"hosts" => ["abc.supabase.co"]},
        "values" => %{"anon_key" => "eyJ-public"}
      }

      app = fn name, needs ->
        publish!(ctx, name, "1.0.0", %{
          "dependencies" => %{"static" => [%{"ref" => "reagent:local.commit-db"}]},
          "provides" => %{"reagent:local.commit-db" => needs}
        })

        "reagent:local.#{name}"
      end

      ref = app.("commit-app", %{"database" => provided})
      supabase = key!(ctx, %{provider_hint: "supabase.co"})

      assert {:error, {:invalid_argument, why}} =
               Commit.preview(ctx, %{
                 ref: ref,
                 selections: [
                   %{dep: "reagent:local.commit-db", entry_id: supabase.id, need: "database"}
                 ]
               })

      assert why ==
               "reagent:local.commit-db's need database is provided by this app; it takes no selection"

      assert {:error, {:invalid_argument, why}} =
               Commit.preview(ctx, %{
                 ref: ref,
                 selections: [
                   %{dep: "reagent:local.commit-db", entry_id: supabase.id, need: "admin"}
                 ]
               })

      assert why ==
               "reagent:local.commit-db takes one credential on its edge; this app provides database and admin"

      # Provided alone, the edge carries the configuration, shown as the
      # publisher's, and writes no row.
      {:ok, preview} = Commit.preview(ctx, %{ref: ref})

      assert [%{"values" => values}] =
               Enum.filter(preview.rows, &(&1["kind"] == "credential"))

      assert values == %{
               "name" => "database",
               "edge" => "reagent:local.commit-db",
               "fields" => ["anon_key"],
               "scopes" => [],
               "destination" => %{"hosts" => ["abc.supabase.co"], "scheme" => "https"},
               "source" => "provided",
               "disclosed" => true,
               "suggested" => false,
               "choice_required" => false,
               "binding_key" => "#{ref}|reagent:local.commit-db|default",
               "lifetime" => %{"kind" => "standing", "until" => nil}
             }

      {:ok, %{profile_id: profile_id}} = walk!(ctx, ref)
      assert head!(ctx, profile_id).vault_refs == []

      # Two needs provided for one dependency would fill its edge twice.
      twice = app.("commit-app-twice", %{"database" => provided, "admin" => provided})

      assert {:error, {:invalid_argument, why}} = Commit.preview(ctx, %{ref: twice})
      assert why =~ "takes one credential on its edge"
    end

    test "an optional pin that is not installed is skipped as the activation skips it, while " <>
           "another path reaches its component",
         %{ctx: ctx} do
      publish!(ctx, "opt-c", "1.0.0", %{"caps" => @caps})
      publish!(ctx, "opt-b", "1.0.0", %{"dependencies" => %{"static" => ["reagent:local.opt-c"]}})

      publish!(ctx, "opt-s", "1.0.0", %{
        "dependencies" => %{
          "static" => [
            %{"ref" => "reagent:local.opt-c:9.9.9", "optional" => true},
            %{"ref" => "reagent:local.opt-b"}
          ]
        }
      })

      assert {:ok, %{unresolved: nil}} = Plan.plan(ctx, %{ref: "reagent:local.opt-s"})
      assert {:ok, _preview} = Commit.preview(ctx, %{ref: "reagent:local.opt-s"})
    end

    test "a public twin of an owner whose grant names a node the source's release no longer " <>
           "runs is refused in words, and granted again it publishes",
         %{ctx: ctx} do
      publish!(ctx, "tw-d", "1.0.0", %{"caps" => @caps})
      publish!(ctx, "tw-s", "1.0.0", %{"dependencies" => %{"static" => ["reagent:local.tw-d"]}})
      {:ok, %{profile_id: owner}} = walk!(ctx, "reagent:local.tw-s")

      publish!(ctx, "tw-s", "2.0.0", %{"caps" => @caps})

      assert {:error, {:invalid_argument, why}} =
               Commit.stage_publish(ctx, %{profile_id: owner})

      assert why ==
               "The owner profile's grant names reagent:local.tw-d, which this release of " <>
                 "reagent:local.tw-s no longer runs; grant the owner profile again, then publish"

      {:ok, %{profile_id: ^owner}} = walk!(ctx, "reagent:local.tw-s")
      assert {:ok, _staged} = Commit.stage_publish(ctx, %{profile_id: owner})
    end

    test "a dependency its app pins is asked for and granted what the pinned release asks, " <>
           "never the newest's",
         %{ctx: ctx} do
      publish!(ctx, "pin-caps", "1.0.0", %{
        "caps" => %{"egress" => %{"domains" => ["v1.example.com"]}}
      })

      publish!(ctx, "pin-caps", "2.0.0", %{
        "caps" => %{"egress" => %{"domains" => ["v2.example.com"]}}
      })

      publish!(ctx, "pin-caps-app", "1.0.0", %{
        "dependencies" => %{"static" => [%{"ref" => "reagent:local.pin-caps:1.0.0"}]}
      })

      ref = "reagent:local.pin-caps-app"
      dep = "reagent:local.pin-caps"

      egress = fn rows ->
        for %{"node" => ^dep, "kind" => "egress"} = row <- rows, do: row["values"]["domains"]
      end

      # The ask the plan shows and the grant the preview shows are the
      # pinned release's.
      {:ok, plan} = Plan.plan(ctx, %{ref: ref})
      assert egress.(plan.rows) == [["v1.example.com"]]

      {:ok, preview} = Commit.preview(ctx, %{ref: ref})
      assert egress.(preview.rows) == [["v1.example.com"]]

      # And the grant the revision holds on the edge into it.
      {:ok, %{profile_id: profile_id}} = walk!(ctx, ref)
      {:ok, blob} = Prima.Authority.Blob.parse(head!(ctx, profile_id).resolved_policy)
      {:ok, edge} = Prima.Authority.Blob.lookup_edge(blob, ref, dep, "")
      assert Prima.Authority.Blob.Edge.domains(edge) == ["v1.example.com"]
    end

    test "a dependency its app pins is read at the pinned release: its needs, what the app " <>
           "provides for it and the rule it attaches by",
         %{ctx: ctx} do
      db = fn version, header ->
        publish!(ctx, "pin-db", version, %{
          "needs" => %{
            "database" => %{
              "type" => "api_key:supabase.co",
              "reason" => "to reach the database",
              "fields" => ["anon_key"],
              "attach" => %{"in" => "header", "name" => header, "template" => "{value}"}
            }
          }
        })
      end

      # The release the app pins attaches by `apikey`; the newer one, by
      # another header.
      db.("1.0.0", "apikey")
      db.("2.0.0", "x-newer")

      provided = %{
        "destination" => %{"hosts" => ["abc.supabase.co"]},
        "values" => %{"anon_key" => "eyJ-public"}
      }

      publish!(ctx, "pin-app", "1.0.0", %{
        "dependencies" => %{"static" => [%{"ref" => "reagent:local.pin-db:1.0.0"}]},
        "provides" => %{"reagent:local.pin-db:1.0.0" => %{"database" => provided}}
      })

      ref = "reagent:local.pin-app"

      {:ok, plan} = Plan.plan(ctx, %{ref: ref})

      assert [%{dep: "reagent:local.pin-db", needs: [need]}] = plan.dependency_needs
      assert %{need: "database", source: "provided"} = need

      {:ok, preview} = Commit.preview(ctx, %{ref: ref})

      assert [%{"values" => %{"name" => "database", "source" => "provided"}}] =
               Enum.filter(preview.rows, &(&1["kind"] == "credential"))

      # The edge attaches the pinned release's rule, never the newest's.
      {:ok, %{profile_id: profile_id}} = walk!(ctx, ref)
      {:ok, blob} = Prima.Authority.Blob.parse(head!(ctx, profile_id).resolved_policy)
      {:ok, edge} = Prima.Authority.Blob.lookup_edge(blob, ref, "reagent:local.pin-db", "")
      assert %{provided: %{attach: %{name: "apikey"}}} = edge.vault

      # A newer release that declares no such need: the pinned one still
      # has it, so the plan answers it as provided and the preview shows it.
      publish!(ctx, "pin-gone", "1.0.0", %{
        "needs" => %{
          "database" => %{
            "type" => "api_key:supabase.co",
            "reason" => "to reach the database",
            "fields" => ["anon_key"],
            "attach" => %{"in" => "header", "name" => "apikey", "template" => "{value}"}
          }
        }
      })

      publish!(ctx, "pin-gone", "2.0.0", %{})

      publish!(ctx, "pin-gone-app", "1.0.0", %{
        "dependencies" => %{"static" => [%{"ref" => "reagent:local.pin-gone:1.0.0"}]},
        "provides" => %{"reagent:local.pin-gone:1.0.0" => %{"database" => provided}}
      })

      gone_app = "reagent:local.pin-gone-app"
      {:ok, plan} = Plan.plan(ctx, %{ref: gone_app})

      assert [%{dep: "reagent:local.pin-gone", needs: [%{need: "database", source: "provided"}]}] =
               plan.dependency_needs

      refute Enum.any?(plan.warnings, &(&1 =~ "declares no such need"))

      {:ok, preview} = Commit.preview(ctx, %{ref: gone_app})

      assert [%{"values" => %{"name" => "database", "source" => "provided"}}] =
               Enum.filter(preview.rows, &(&1["kind"] == "credential"))
    end
  end

  # ===========================================================================
  # Named accounts on a dependency's edge
  # ===========================================================================

  describe "named accounts on a dependency's edge" do
    @dep_a "reagent:local.commit-dep-a"

    # A source whose dependency declares two credential needs, each
    # attaching a supabase.co key by its own header.
    defp two_needs!(ctx) do
      publish!(ctx, "commit-named-db", "1.0.0", %{
        "needs" => %{
          "database" => %{
            "type" => "api_key:supabase.co",
            "reason" => "to reach the database",
            "fields" => ["anon_key"],
            "attach" => %{"in" => "header", "name" => "apikey", "template" => "{value}"}
          },
          "admin" => %{
            "type" => "api_key:supabase.co",
            "reason" => "to administer it",
            "fields" => ["service_key"],
            "attach" => %{"in" => "header", "name" => "x-admin", "template" => "{value}"}
          }
        }
      })

      publish!(ctx, "commit-named-app", "1.0.0", %{
        "dependencies" => %{"static" => [%{"ref" => "reagent:local.commit-named-db"}]}
      })

      {"reagent:local.commit-named-app", "reagent:local.commit-named-db"}
    end

    defp supabase!(ctx, field),
      do:
        entry!(ctx, %{field => "k-#{System.unique_integer([:positive])}"}, %{
          provider_hint: "supabase.co",
          disclose: false
        })

    test "a default entry and named accounts bind one edge, each a row under its own key, " <>
           "each previewed as its account",
         %{ctx: ctx} do
      two = two_deps!(ctx)
      [default, work, home] = for _ <- 1..3, do: key!(ctx)
      until = in_hours(1)

      selections = [
        %{dep: @dep_a, entry_id: default.id},
        %{dep: @dep_a, entry_id: work.id, name: "Work", lifetime: %{kind: "once"}},
        %{dep: @dep_a, entry_id: home.id, name: "Home", lifetime: %{kind: "until", until: until}}
      ]

      {:ok, preview} = Commit.preview(ctx, %{ref: two, selections: selections})
      credentials = for %{"kind" => "credential", "values" => v} <- preview.rows, do: v

      assert Enum.map(credentials, &{&1["binding_key"], &1["connection"], &1["lifetime"]})
             |> Enum.sort() == [
               {"#{two}|#{@dep_a}|default", nil, %{"kind" => "standing", "until" => nil}},
               {"#{two}|#{@dep_a}|name:Home", "Home", %{"kind" => "until", "until" => until}},
               {"#{two}|#{@dep_a}|name:Work", "Work", %{"kind" => "once", "until" => nil}}
             ]

      {:ok, %{profile_id: profile_id}} = walk!(ctx, two, %{selections: selections})
      rows = rows_by_key(ctx, profile_id)

      assert %{vault_entry_id: default_id, lifetime_kind: "standing"} =
               rows["#{two}|#{@dep_a}|default"]

      assert %{vault_entry_id: work_id, lifetime_kind: "once"} =
               rows["#{two}|#{@dep_a}|name:Work"]

      assert %{vault_entry_id: home_id, lifetime_kind: "until"} =
               rows["#{two}|#{@dep_a}|name:Home"]

      assert {default_id, work_id, home_id} == {default.id, work.id, home.id}

      {:ok, blob} = Prima.Authority.Blob.parse(head!(ctx, profile_id).resolved_policy)
      {:ok, edge} = Prima.Authority.Blob.lookup_edge(blob, two, @dep_a, "")
      assert edge.vault.entry_id == default.id

      assert %{"Work" => %{entry_id: ^work_id}, "Home" => %{entry_id: ^home_id}} =
               edge.vault.named

      assert Prima.Manifest.Needs.attach_to_map(edge.vault.named["Work"].attach) == @attach
    end

    test "a named selection is refused where it names a label, sits beside no default or a " <>
           "lent default, repeats a name, or is for another need than the default's",
         %{ctx: ctx} do
      two = two_deps!(ctx)
      [default, work, other] = for _ <- 1..3, do: key!(ctx)
      refused = fn selections -> Commit.preview(ctx, %{ref: two, selections: selections}) end

      # A named account names an entry; a label, or nothing, lends.
      for named <- [
            %{dep: @dep_a, label: "default", name: "Work"},
            %{dep: @dep_a, name: "Work"}
          ] do
        assert {:error, {:invalid_argument, why}} =
                 refused.([%{dep: @dep_a, entry_id: default.id}, named])

        assert why ==
                 "The selection of #{@dep_a} names the account Work by a profile's label; a " <>
                   "named account names an entry"
      end

      assert {:error, {:invalid_argument, why}} =
               refused.([%{dep: @dep_a, entry_id: work.id, name: "Work"}])

      assert why ==
               "The selections of #{@dep_a} name accounts beside no default; one selection of " <>
                 "#{@dep_a} names no account"

      # The dependency's own profile lends a key; an account beside it is
      # refused, since a named account sits beside an entry chosen here.
      {:ok, _lender} = walk!(ctx, @dep_a, %{bindings: [%{need: "api_key", entry_id: other.id}]})

      assert {:error, {:invalid_argument, why}} =
               refused.([
                 %{dep: @dep_a, label: "default"},
                 %{dep: @dep_a, entry_id: work.id, name: "Work"}
               ])

      assert why ==
               "The selections of #{@dep_a} name accounts beside a key its default profile " <>
                 "lends; a named account sits beside a default entry chosen here"

      # One name twice, by case.
      assert {:error, {:invalid_argument, why}} =
               refused.([
                 %{dep: @dep_a, entry_id: default.id},
                 %{dep: @dep_a, entry_id: work.id, name: "Work"},
                 %{dep: @dep_a, entry_id: other.id, name: "work"}
               ])

      assert why =~ "The selections of #{@dep_a} name the account "
      assert why =~ " twice; each names its own"

      # An account name the binding key cannot carry.
      assert {:error, {:invalid_argument, why}} =
               refused.([
                 %{dep: @dep_a, entry_id: default.id},
                 %{dep: @dep_a, entry_id: work.id, name: "has|pipe"}
               ])

      assert why ==
               "The selection of #{@dep_a} names an account that is not 1 to 128 bytes of text " <>
                 "without a | or a control character"

      # An edge carries one need's credentials.
      {app, db} = two_needs!(ctx)

      assert {:error, {:invalid_argument, why}} =
               Commit.preview(ctx, %{
                 ref: app,
                 selections: [
                   %{dep: db, entry_id: supabase!(ctx, "anon_key").id, need: "database"},
                   %{
                     dep: db,
                     entry_id: supabase!(ctx, "service_key").id,
                     need: "admin",
                     name: "Admin"
                   }
                 ]
               })

      assert why ==
               "The selections of #{db} name accounts for admin beside a default for " <>
                 "database; an edge carries one need's credentials"
    end

    test "a named selection is held to its need: a provided need, another provider, an " <>
           "instance entry not offered",
         %{ctx: ctx} do
      publish!(ctx, "commit-named-provided-db", "1.0.0", %{
        "needs" => %{
          "database" => %{
            "type" => "api_key:supabase.co",
            "reason" => "to reach the database",
            "fields" => ["anon_key"],
            "attach" => %{"in" => "header", "name" => "apikey", "template" => "{value}"}
          }
        }
      })

      db = "reagent:local.commit-named-provided-db"

      publish!(ctx, "commit-named-provided", "1.0.0", %{
        "dependencies" => %{"static" => [%{"ref" => db}]},
        "provides" => %{
          db => %{
            "database" => %{
              "destination" => %{"hosts" => ["abc.supabase.co"]},
              "values" => %{"anon_key" => "eyJ-public"}
            }
          }
        }
      })

      assert {:error, {:invalid_argument, why}} =
               Commit.preview(ctx, %{
                 ref: "reagent:local.commit-named-provided",
                 selections: [
                   %{dep: db, entry_id: supabase!(ctx, "anon_key").id, name: "Work"}
                 ]
               })

      assert why == "#{db}'s need database is provided by this app; it takes no selection"

      two = two_deps!(ctx)
      default = %{dep: @dep_a, entry_id: key!(ctx).id}

      accounts = fn preview ->
        for %{"kind" => "credential", "values" => %{"connection" => account} = values} <-
              preview.rows,
            do: {account, values["source"]}
      end

      assert {:error, {:provider_mismatch, "api_key"}} =
               Commit.preview(ctx, %{
                 ref: two,
                 selections: [
                   default,
                   %{
                     dep: @dep_a,
                     entry_id: key!(ctx, %{provider_hint: "anthropic.com"}).id,
                     name: "Work"
                   }
                 ]
               })

      # An entry of the need's provider is taken as the account.
      {:ok, preview} =
        Commit.preview(ctx, %{
          ref: two,
          selections: [default, %{dep: @dep_a, entry_id: key!(ctx).id, name: "Work"}]
        })

      assert accounts.(preview) == [{"Work", "own"}]

      {person, _user} = Sanctum.TestContext.person!(ctx)
      person_two = two_deps!(person)
      person_default = %{dep: @dep_a, entry_id: key!(person).id}
      listed = instance!(%{audience: "listed"})

      assert {:error, {:not_offered, "api_key"}} =
               Commit.preview(person, %{
                 ref: person_two,
                 selections: [
                   person_default,
                   %{dep: @dep_a, instance_entry_id: listed.id, name: "Work"}
                 ]
               })

      # One offered to the person is.
      {:ok, preview} =
        Commit.preview(person, %{
          ref: person_two,
          selections: [
            person_default,
            %{dep: @dep_a, instance_entry_id: instance!().id, name: "Work"}
          ]
        })

      assert accounts.(preview) == [{"Work", "instance"}]
    end

    test "a named once is consumed apart from its default, carried across a revision and a " <>
           "grant, and renewed only when the decision says so",
         %{ctx: ctx} do
      two = two_deps!(ctx)
      [default, work] = [key!(ctx), key!(ctx)]
      actor = Sanctum.Context.actor(ctx)

      selections = [
        %{dep: @dep_a, entry_id: default.id},
        %{dep: @dep_a, entry_id: work.id, name: "Work", lifetime: %{kind: "once"}}
      ]

      {:ok, %{profile_id: profile}} = walk!(ctx, two, %{selections: selections})
      first = head!(ctx, profile)
      work_key = "#{two}|#{@dep_a}|name:Work"

      assert :ok = Arca.ConsentStorage.consume_once(actor, profile, first.id, work_key, "exec_a")

      # A revision that keeps it carries the consumption.
      {:ok, %{revision: 2}} =
        walk!(ctx, two, %{selections: selections, origins: [:interactive, :programmatic]})

      assert rows_by_key(ctx, profile)[work_key].consumed_by_root == "exec_a"

      assert {:error, :already_consumed} =
               Arca.ConsentStorage.consume_once(
                 actor,
                 profile,
                 head!(ctx, profile).id,
                 work_key,
                 "exec_b"
               )

      # So does a grant, which re-issues the head's named selection.
      assert {:ok, %{revision: 3}} =
               Commit.grant(ctx, %{
                 profile_id: profile,
                 bindings: [],
                 expected_consent_revision: 2
               })

      rows = rows_by_key(ctx, profile)

      assert %{lifetime_kind: "once", consumed_by_root: "exec_a", vault_entry_id: id} =
               rows[work_key]

      assert id == work.id
      assert %{vault_entry_id: default_id} = rows["#{two}|#{@dep_a}|default"]
      assert default_id == default.id

      # Renewed, it is consumable again.
      renewed =
        Enum.map(selections, fn
          %{name: "Work"} = selection -> Map.put(selection, :renew, true)
          selection -> selection
        end)

      {:ok, %{revision: 4}} = walk!(ctx, two, %{selections: renewed})
      assert rows_by_key(ctx, profile)[work_key].consumed_by_root == nil

      assert :ok =
               Arca.ConsentStorage.consume_once(
                 actor,
                 profile,
                 head!(ctx, profile).id,
                 work_key,
                 "exec_c"
               )
    end

    test "a commit differing from its preview only by a selection's name fails the digest " <>
           "check",
         %{ctx: ctx} do
      two = two_deps!(ctx)
      [default, work] = [key!(ctx), key!(ctx)]
      named = %{dep: @dep_a, entry_id: work.id, name: "Work"}
      previewed = %{ref: two, selections: [%{dep: @dep_a, entry_id: default.id}, named]}

      {:ok, plan} = Plan.plan(ctx, %{ref: two})
      {:ok, preview} = Commit.preview(ctx, previewed)

      assert {:error, {:consent_conflict, %{cause: :digest_changed}}} =
               Commit.commit(ctx, %{
                 decisions: %{
                   previewed
                   | selections: [%{dep: @dep_a, entry_id: default.id}, %{named | name: "Home"}]
                 },
                 plan_token: plan.plan_token,
                 proof: preview.proof,
                 commit_digest: preview.commit_digest,
                 expected_consent_revision: plan.expected_consent_revision
               })
    end
  end
end

defmodule Sanctum.Consent.CommitRebindRaceTest do
  @moduledoc """
  A commit binding an entry of the athanor's own and a rebind of that
  entry, on real connections outside the sandbox. The commit holds its
  transaction open once its rows are written, its digests read again and
  its head advanced; the rebind started then lands after the revision,
  never between its digest re-read and its commit, and its block of the
  new profile stands.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Sanctum.Consent.Commit
  alias Sanctum.Consent.Plan

  @wasm File.read!(Path.join(__DIR__, "../../support/test_wasm/math.wasm"))
  @attach %{"in" => "header", "name" => "Authorization", "template" => "Bearer {value}"}
  @inference %{
    "hosts" => ["api.openai.com"],
    "methods" => ["POST"],
    "paths" => ["/v1/"],
    "scheme" => "https"
  }

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Arca.Repo, fun)

  setup do
    Arca.Cache.init()
    n = System.unique_integer([:positive])
    athanor = "ath_commit_race_#{n}"
    test_path = Path.join(System.tmp_dir!(), "consent_commit_race_#{n}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    unboxed(fn ->
      Arca.Test.Actor.ensure_athanor_row(athanor, name: "Commit race #{n}", slug: "race-#{n}")
    end)

    on_exit(fn ->
      unboxed(fn ->
        {:ok, _} = Arca.TenantTables.delete_all_for(Prima.Actor.in_athanor(athanor))
        Arca.Repo.delete_all(from(a in Arca.Schemas.Athanor, where: a.id == ^athanor))
      end)

      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    ctx = Sanctum.TestContext.via(%{Sanctum.TestContext.local() | athanor_id: athanor}, :prism)
    {:ok, ctx: ctx}
  end

  # A component whose one need attaches an openai.com key.
  defp publish!(ctx, name) do
    manifest = %{
      "name" => name,
      "version" => "1.0.0",
      "type" => "reagent",
      "needs" => %{
        "api_key" => %{
          "type" => "api_key:openai.com",
          "reason" => "to call the model",
          "fields" => ["OPENAI_API_KEY"],
          "attach" => @attach
        }
      },
      "caps" => %{"egress" => %{"domains" => ["api.openai.com"], "methods" => ["POST"]}}
    }

    {:ok, _} =
      Compendium.Registry.publish_bytes(ctx, @wasm, %{
        name: name,
        version: "1.0.0",
        type: "reagent",
        manifest: Jason.encode!(manifest)
      })

    "reagent:local.#{name}"
  end

  # An attach-only openai.com key of the athanor's, at the digest its
  # binding derives.
  defp key!(ctx) do
    {:ok, destination} = Sanctum.Vault.destination_text(@inference)

    attrs = %{
      name: "race-key-#{System.unique_integer([:positive])}",
      kind: "api_key",
      provider_hint: "openai.com",
      field_names: ~s(["OPENAI_API_KEY"]),
      oauth_endpoints: nil,
      oauth_scopes: nil,
      destination: destination,
      attach_only: true,
      sealed_payload: "sealed"
    }

    {:ok, digest} = Sanctum.VaultReader.binding_digest(attrs)

    {:ok, entry} =
      Arca.VaultStorage.put(Sanctum.Context.actor(ctx), Map.put(attrs, :binding_digest, digest))

    entry
  end

  # Holds the committing process inside its transaction once the head has
  # advanced: after its binding rows are written and its digests read
  # again, before the transaction commits. Runs once, in the process that
  # marked itself the committer.
  def hold_commit(_event, _measurements, meta, %{test: test}) do
    if Process.get(:race_committer) == true do
      cond do
        meta[:source] == "consent_vault_refs" and
            String.starts_with?(meta[:query] || "", "INSERT") ->
          Process.put(:race_refs_written, true)

        Process.get(:race_refs_written) == true and meta[:source] == "profiles" and
            String.starts_with?(meta[:query] || "", "UPDATE") ->
          Process.delete(:race_refs_written)
          send(test, {:holding, self()})

          receive do
            :go -> :ok
          end

        true ->
          :ok
      end
    end
  end

  test "a rebind racing a commit that binds the entry lands after the revision, and its " <>
         "block stands",
       %{ctx: ctx} do
    {entry, decisions, plan, preview} =
      unboxed(fn ->
        ref = publish!(ctx, "commit-rebind-race")
        entry = key!(ctx)
        decisions = %{ref: ref, bindings: [%{need: "api_key", entry_id: entry.id}]}
        {:ok, plan} = Plan.plan(ctx, %{ref: ref})
        {:ok, preview} = Commit.preview(ctx, decisions)
        {entry, decisions, plan, preview}
      end)

    handler = {__MODULE__, :hold_commit, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach(handler, [:arca, :repo, :query], &__MODULE__.hold_commit/4, %{
        test: self()
      })

    on_exit(fn -> :telemetry.detach(handler) end)

    committer =
      Task.async(fn ->
        Process.put(:race_committer, true)

        unboxed(fn ->
          Commit.commit(ctx, %{
            decisions: decisions,
            plan_token: plan.plan_token,
            proof: preview.proof,
            commit_digest: preview.commit_digest,
            expected_consent_revision: plan.expected_consent_revision
          })
        end)
      end)

    assert_receive {:holding, holder}, 15_000

    test = self()

    rebinder =
      Task.async(fn ->
        unboxed(fn ->
          if postgres?(), do: send(test, {:backend, backend_pid()})

          Sanctum.Vault.rebind(ctx, %{
            id: entry.id,
            destination: Map.put(@inference, "paths", ["/v2/"])
          })
        end)
      end)

    # The entry is held by the revision: the rebind waits on it.
    if postgres?() do
      assert_receive {:backend, backend}, 15_000
      await_lock_wait(backend)
    else
      refute Task.yield(rebinder, 300), "the rebind landed inside the revision"
    end

    send(holder, :go)
    assert {:ok, %{profile_id: profile_id, revision: 1}} = Task.await(committer, 30_000)
    assert {:ok, %{affected: affected, binding_digest: moved}} = Task.await(rebinder, 30_000)
    :telemetry.detach(handler)

    # The rebind saw the new head and blocked its profile, and the block
    # stands over a head still bound at the digest it approved.
    assert profile_id in affected

    {status, refs} =
      unboxed(fn ->
        {:ok, profile} = Arca.ProfileStorage.get(Sanctum.Context.actor(ctx), profile_id)
        {:ok, head} = Arca.ConsentStorage.head_consent(Sanctum.Context.actor(ctx), profile_id)
        {profile.status, head.vault_refs}
      end)

    assert status == "needs_consent"
    assert [%{vault_entry_id: id, binding_digest: bound}] = refs
    assert id == entry.id
    assert bound == entry.binding_digest and bound != moved
  end

  # The backend of the current connection, so another can watch it wait.
  defp backend_pid do
    %{rows: [[pid]]} = Arca.Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  # Holds until `pid`'s backend waits on a lock: an observed state, bounded
  # by `tries`, never a timing. Only PostgreSQL shows one; SQLite's
  # immediate transaction waits for the one writer and has none to show.
  defp await_lock_wait(pid, tries \\ 500)

  defp await_lock_wait(_pid, 0), do: flunk("the waiting backend never waited on a lock")

  defp await_lock_wait(pid, tries) do
    %{rows: rows} =
      unboxed(fn ->
        Arca.Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [pid])
      end)

    if rows == [["Lock"]] do
      :ok
    else
      Process.sleep(20)
      await_lock_wait(pid, tries - 1)
    end
  end

  defp postgres?, do: Arca.Repo.adapter() == Ecto.Adapters.Postgres
end
