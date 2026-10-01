# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Consent.CommitTest do
  @moduledoc """
  The preview answers a `Prima.ConsentPreview` — typed rows, the origins the
  grant admits and the commit digest binding them — beside the summary
  lines; a decision names the origins it admits, `interactive` alone when
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

  setup do
    Arca.Cache.init()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "consent_commit_#{:rand.uniform(1_000_000)}")
    original_base_path = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:arca, :base_path, original_base_path),
        else: Application.delete_env(:arca, :base_path)
    end)

    {:ok, ctx: Sanctum.TestContext.local()}
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

  defp entry!(ctx, fields \\ %{"url" => "https://db.example", "anon_key" => "anon"}) do
    {:ok, view} =
      Sanctum.TestContext.create_vault(ctx, %{
        name: "conn-#{System.unique_integer([:positive])}",
        kind: "api_key",
        fields: fields
      })

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
      "commit_digest" => preview.commit_digest
    }
  end

  defp head!(ctx, profile_id) do
    {:ok, head} = Arca.ConsentStorage.head_consent(Sanctum.Context.actor(ctx), profile_id)
    head
  end

  describe "the preview" do
    test "answers a ConsentPreview with the commit digest, beside the summary", %{ctx: ctx} do
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

      # The summary stays beside the rows, and the proof beside both.
      assert is_list(preview.summary) and Enum.all?(preview.summary, &is_binary/1)
      assert is_binary(preview.proof)
      assert preview.expected_consent_revision == 0

      rows = Enum.group_by(decoded.rows, &{&1.kind, &1.node}, & &1.values)

      # The credential names the edge it rides: the source's own ingress.
      assert rows[{:credential, ref}] == [
               %{"name" => entry.name, "edge" => "@ingress", "fields" => ["url"], "scopes" => []}
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
      entry = entry!(ctx, %{"EXAMPLE_API_KEY" => "k"})
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

  describe "a public profile's staging" do
    test "answers what it would grant as rows, with the origins it would admit", %{ctx: ctx} do
      publish!(ctx, "commit-publish")
      {:ok, %{profile_id: owner}} = walk!(ctx, "reagent:local.commit-publish")

      assert {:ok, staged} = Commit.stage_publish(ctx, %{profile_id: owner})
      assert staged.origins == ["interactive"]
      assert is_list(staged.summary)

      # A public profile writes nothing durable unless asked: read alone.
      assert [%{"values" => %{"actions" => ["read"]}}] =
               Enum.filter(staged.rows, &(&1["kind"] == "storage"))
    end
  end
end
