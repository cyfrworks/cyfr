# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Consent.LoaderTest do
  use ExUnit.Case, async: false

  alias Prima.Authority
  alias Sanctum.Consent.Loader
  alias Sanctum.Context
  alias Sanctum.Test.ConsentFixtures
  alias Prima.JCS
  alias Prima.Test.AuthorityFixtures, as: Fixtures

  setup tags do
    Arca.Test.Sandbox.setup!(tags)

    # A person at Prism: the admission path every case here models but the
    # origin cases below.
    ctx = %Context{
      user_id: "loader_test_user",
      athanor_id: "ath_test",
      scope: :athanor,
      permissions: MapSet.new([:execute]),
      origin: :interactive
    }

    {:ok, ctx: ctx}
  end

  defp profile_summary(overrides \\ %{}) do
    Map.merge(
      %{
        id: "prof-1",
        kind: :owner,
        source_ref: Fixtures.formula_ref(),
        label: "default",
        status: :active
      },
      overrides
    )
  end

  # A binding row of the fixture graph: the formula's edge into the
  # catalyst under `need`, at the entry and digest the blob names.
  defp ref(need, entry_id, digest) do
    %{
      binding_key:
        Prima.Authority.Blob.binding_key(
          Fixtures.formula_ref(),
          "#{Fixtures.catalyst_ref()}|#{need}",
          nil
        ),
      scope: "athanor",
      vault_entry_id: entry_id,
      binding_digest: digest
    }
  end

  defp source_ref, do: ref("source", "vault-source", "sha256:bind-source")
  defp dest_ref, do: ref("dest", "vault-dest", "sha256:bind-dest")

  defp identity(%{binding_key: key, vault_entry_id: id, binding_digest: digest}),
    do: {:entry, "athanor", key, id, digest}

  defp consent(overrides \\ %{}) do
    {:ok, policy_json} = Jason.encode(Fixtures.graph_map())

    merged =
      Map.merge(
        %{
          id: "consent-1",
          revision: 1,
          scope: :versionless,
          pinned_version: "",
          invoke_mode: :open_inert,
          shape_digest: "sha256:shape-1",
          commit_digest: "sha256:commit-1",
          resolved_policy: policy_json,
          activation: Fixtures.activation(),
          vault_refs: [source_ref(), dest_ref()]
        },
        overrides
      )

    # Stamped AFTER the merge, from whatever policy the override left, so a
    # test that swaps the blob still describes a self-consistent row — the
    # loader refuses a mismatch, and every case below is about some other
    # failure. A test that wants the mismatch itself passes `:blob_digest`.
    Map.put_new_lazy(merged, :blob_digest, fn ->
      Prima.JCS.hash_binary(merged.resolved_policy)
    end)
  end

  defp live_for(activation) do
    {:ok, digest} = JCS.hash(activation)

    {:ok,
     %{
       digest: digest,
       graph: activation,
       nodes: Map.new(activation, fn {k, d} -> {k, %{release_digest: d, integrity: :ok}} end)
     }}
  end

  defp seed(ctx, profile, consent) do
    :ok = ConsentFixtures.seed_head!(ctx, profile, consent)
  end

  test "loads a matching consent into a root Authority with its stamp", %{ctx: ctx} do
    profile = profile_summary()
    consent = consent()
    seed(ctx, profile, consent)
    live = live_for(consent.activation)
    {:ok, %{digest: live_digest, graph: _, nodes: _}} = live

    assert {:ok, %Authority{} = auth, stamp} =
             Loader.load_root(ctx, profile, live: live)

    assert auth.profile_id == "prof-1"
    assert auth.consent_id == "consent-1"
    assert auth.cursor == {:bound, Fixtures.formula_ref()}
    assert auth.activation == consent.activation
    assert stamp.activation_digest == live_digest
    assert stamp.activation_graph == consent.activation
  end

  test "an inactive profile is refused, never silently substituted", %{ctx: ctx} do
    for status <- [:needs_consent, :revoked] do
      profile = profile_summary(%{status: status})

      assert {:error, {:profile_unavailable, ^status}} =
               Loader.load_root(ctx, profile, live: live_for(Fixtures.activation()))
    end
  end

  test "a profile without a head consent is refused", %{ctx: ctx} do
    profile = profile_summary()
    :ok = ConsentFixtures.seed_profile!(ctx, profile)

    assert {:error, {:no_head_consent, "prof-1"}} =
             Loader.load_root(ctx, profile, live: live_for(Fixtures.activation()))
  end

  test "the pinned rule holds in both directions", %{ctx: ctx} do
    profile = profile_summary()

    seed(ctx, profile, consent(%{scope: :pinned, pinned_version: ""}))

    assert {:error, {:invalid_consent, :pinned_version}} =
             Loader.load_root(ctx, profile, live: live_for(Fixtures.activation()))

    seed(ctx, profile, consent(%{scope: :versionless, pinned_version: "1.0.0"}))

    assert {:error, {:invalid_consent, :pinned_version}} =
             Loader.load_root(ctx, profile, live: live_for(Fixtures.activation()))
  end

  test "a policy edited in place after the fact fails closed", %{ctx: ctx} do
    profile = profile_summary()

    # Widen the stored blob without touching any digest — a hand edit, a
    # restored backup, or any write path that reaches the column. Before
    # `blob_digest` existed nothing on the row detected this:
    # `commit_digest` covers the decisions, not the bytes, and
    # `check_blob_refs_equality/2` compares vault refs alone. So the loader
    # built an Authority from whatever caps the edit left behind.
    honest = consent()
    tampered = Jason.decode!(honest.resolved_policy)

    widened =
      update_in(tampered, ["nodes"], fn nodes ->
        Map.new(nodes, fn {ref, node} ->
          {ref,
           update_in(node, ["edges"], fn edges ->
             Map.new(edges, fn {key, edge} ->
               {key, Map.put(edge, "egress", %{"domains" => ["*"], "methods" => ["GET"]})}
             end)
           end)}
        end)
      end)

    seed(ctx, profile, %{honest | resolved_policy: Jason.encode!(widened)})

    assert {:error, {:blob_digest_mismatch, _}} =
             Loader.load_root(ctx, profile, live: live_for(Fixtures.activation()))
  end

  test "a consent with no blob digest at all never reaches a load", %{ctx: ctx} do
    profile = profile_summary()

    # The loader's `{:invalid_consent, :blob_digest}` arm is the last of
    # three guards on one fact, and the two below it are why nothing
    # reaches it: the column is NOT NULL, and the one writer refuses a
    # blank digest before the insert rather than storing a revision whose
    # policy nothing can be checked against.
    assert_raise ArgumentError, fn -> seed(ctx, profile, consent(%{blob_digest: nil})) end
    assert_raise ArgumentError, fn -> seed(ctx, profile, consent(%{blob_digest: ""})) end

    # Blanked after the fact — past every writer, straight onto the column
    # — it is a mismatch and not a load: a hash of nothing is not the hash
    # of these bytes.
    seed(ctx, profile, consent())
    :ok = ConsentFixtures.hand_edit_head!(ctx, profile.id, blob_digest: "")

    assert {:error, {:blob_digest_mismatch, ""}} =
             Loader.load_root(ctx, profile, live: live_for(Fixtures.activation()))
  end

  test "a malformed policy blob fails closed", %{ctx: ctx} do
    profile = profile_summary()
    seed(ctx, profile, consent(%{resolved_policy: "{not json"}))

    assert {:error, {:invalid_blob, {:invalid_json, _}}} =
             Loader.load_root(ctx, profile, live: live_for(Fixtures.activation()))
  end

  test "a blob referencing a vault entry absent from the refs fails closed", %{ctx: ctx} do
    profile = profile_summary()

    seed(
      ctx,
      profile,
      consent(%{vault_refs: [source_ref()]})
    )

    assert {:error, {:blob_refs_mismatch, %{blob_only: blob_only, refs_only: []}}} =
             Loader.load_root(ctx, profile, live: live_for(Fixtures.activation()))

    assert blob_only == [identity(dest_ref())]
  end

  test "a stored ref the blob does not carry fails closed too", %{ctx: ctx} do
    profile = profile_summary()
    extra = ref("ghost", "vault-ghost", "sha256:bind-ghost")
    base = consent()
    seed(ctx, profile, %{base | vault_refs: base.vault_refs ++ [extra]})

    assert {:error, {:blob_refs_mismatch, %{blob_only: [], refs_only: refs_only}}} =
             Loader.load_root(ctx, profile, live: live_for(Fixtures.activation()))

    assert refs_only == [identity(extra)]
  end

  test "a row naming the blob's entry under another key, or at another digest, fails closed",
       %{ctx: ctx} do
    profile = profile_summary()

    # The same entry and digest as the blob's dest binding, keyed as a
    # named account: the identity is the binding, never the entry alone.
    moved = %{dest_ref() | binding_key: dest_ref().binding_key <> "x"}
    seed(ctx, profile, consent(%{vault_refs: [source_ref(), moved]}))

    assert {:error, {:blob_refs_mismatch, %{blob_only: [_], refs_only: [_]}}} =
             Loader.load_root(ctx, profile, live: live_for(Fixtures.activation()))

    stale = %{dest_ref() | binding_digest: "sha256:other"}
    seed(ctx, profile, consent(%{vault_refs: [source_ref(), stale]}))

    assert {:error, {:blob_refs_mismatch, %{blob_only: [_], refs_only: [_]}}} =
             Loader.load_root(ctx, profile, live: live_for(Fixtures.activation()))
  end

  test "versionless drift with unknown live shape demands fresh consent", %{ctx: ctx} do
    profile = profile_summary()
    consent = consent()
    seed(ctx, profile, consent)
    drifted = Map.put(consent.activation, Fixtures.formula_ref(), "sha256:act-new")

    assert {:error, {:consent_required, payload}} =
             Loader.load_root(ctx, profile, live: live_for(drifted))

    assert payload == %{profile_id: "prof-1", current_revision: 1, shape_diff: []}
  end

  test "versionless drift with an unchanged shape records the new activation", %{ctx: ctx} do
    profile = profile_summary()
    consent = consent()
    seed(ctx, profile, consent)
    drifted = Map.put(consent.activation, Fixtures.formula_ref(), "sha256:act-new")
    live = live_for(drifted)
    {:ok, %{digest: live_digest}} = live

    assert {:ok, %Authority{} = auth, stamp} =
             Loader.load_root(ctx, profile,
               live: live,
               live_shape_digest: consent.shape_digest
             )

    # Self-invocation must match the running activation.
    assert auth.activation == drifted
    assert stamp.activation_digest == live_digest
    assert stamp.activation_graph == drifted
  end

  test "a tampered node alarms instead of loading", %{ctx: ctx} do
    profile = profile_summary()
    consent = consent()
    seed(ctx, profile, consent)
    {:ok, %{digest: digest, graph: graph, nodes: nodes}} = live_for(consent.activation)

    tampered_nodes =
      Map.put(nodes, Fixtures.catalyst_ref(), %{
        release_digest: consent.activation[Fixtures.catalyst_ref()],
        integrity: :mismatch
      })

    live = {:ok, %{digest: digest, graph: graph, nodes: tampered_nodes}}

    assert {:error, {:integrity_alarm, [ref]}} = Loader.load_root(ctx, profile, live: live)
    assert ref == Fixtures.catalyst_ref()
  end

  test "an unresolved live world is setup_required, not an alarm", %{ctx: ctx} do
    profile = profile_summary()
    seed(ctx, profile, consent())

    assert {:error, {:setup_required, payload}} = Loader.load_root(ctx, profile, [])
    assert payload.profile_id == "prof-1"
    assert payload.node_ref == Fixtures.formula_ref()
    assert payload.reason == :not_resolved
  end

  test "pinned drift on a local source is consent_required (re-pin), never the alarm", %{
    ctx: ctx
  } do
    profile = profile_summary()
    consent = consent(%{scope: :pinned, pinned_version: "1.0.0"})
    seed(ctx, profile, consent)
    drifted = Map.put(consent.activation, Fixtures.formula_ref(), "sha256:act-rebuilt")

    assert {:error, {:consent_required, _}} =
             Loader.load_root(ctx, profile, live: live_for(drifted))
  end

  describe "the origin a run is admitted under" do
    test "a context with no origin, or one the revision does not name, is asked to grant again",
         %{ctx: ctx} do
      profile = profile_summary()
      consent = consent()
      seed(ctx, profile, consent)
      live = live_for(consent.activation)

      for origin <- [nil, :programmatic, :schedule, :webhook] do
        assert {:error,
                {:consent_required,
                 %{profile_id: "prof-1", current_revision: 1, shape_diff: []} = payload}} =
                 Loader.load_root(%{ctx | origin: origin}, profile, live: live)

        # The signal's payload, unchanged: what every surface already reads.
        assert Map.keys(payload) |> Enum.sort() == [:current_revision, :profile_id, :shape_diff]
      end

      assert {:ok, %Authority{}, _stamp} = Loader.load_root(ctx, profile, live: live)
    end

    test "a revision that names an origin admits a run under it", %{ctx: ctx} do
      profile = profile_summary()
      consent = consent(%{admitted_origins: [:interactive, :programmatic]})
      seed(ctx, profile, consent)
      live = live_for(consent.activation)

      assert {:ok, %Authority{}, _} =
               Loader.load_root(%{ctx | origin: :programmatic}, profile, live: live)

      assert {:error, {:consent_required, _}} =
               Loader.load_root(%{ctx | origin: :schedule}, profile, live: live)
    end
  end

  describe "a storage path spelled other than the door reaches it" do
    defp with_paths(paths) do
      graph =
        put_in(
          Fixtures.graph_map(),
          ["nodes", Fixtures.formula_ref(), "edges", "@ingress", "storage"],
          %{"paths" => paths, "actions" => ["read"]}
        )

      {:ok, policy} = Jason.encode(graph)
      consent(%{resolved_policy: policy})
    end

    test "is refused at admission with consent_required, never rewritten", %{ctx: ctx} do
      profile = profile_summary()

      for path <- ["data//secrets/", "data/./secrets/", "data/../secrets/", "data/notes//"] do
        consent = with_paths(["data/ok/", path])
        seed(ctx, profile, consent)

        assert {:error, {:consent_required, %{profile_id: "prof-1", shape_diff: []}}} =
                 Loader.load_root(ctx, profile, live: live_for(consent.activation)),
               "#{path} was admitted"

        # The stored grant is as it was written.
        assert {:ok, %{resolved_policy: stored}} =
                 Arca.ConsentStorage.head_consent(Context.actor(ctx), "prof-1")

        assert stored == consent.resolved_policy
      end
    end

    test "a canonical spelling, a folder and the wildcard load", %{ctx: ctx} do
      profile = profile_summary()
      consent = with_paths(["data/notes/", "data/report.md", "data", "*"])
      seed(ctx, profile, consent)

      assert {:ok, %Authority{}, _} =
               Loader.load_root(ctx, profile, live: live_for(consent.activation))
    end
  end

  describe "an instance entry's row and provided configuration" do
    @inference ~s({"hosts":["api.openai.com"],"methods":["POST"],"paths":["/v1/"],"scheme":"https"})

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
              binding_digest: "sha256:instance",
              audience: "everyone",
              created_by: "usr_admin"
            },
            over
          )
        )

      entry
    end

    defp instance_row(entry, digest) do
      %{
        binding_key: Prima.Authority.Blob.binding_key(Fixtures.formula_ref(), "@ingress", nil),
        scope: "instance",
        instance_entry_id: entry.id,
        binding_digest: digest
      }
    end

    test "an instance row is read live as the person is offered it, held to its digest", %{
      ctx: ctx
    } do
      {person, _user} =
        Sanctum.TestContext.person!(%{
          ctx
          | user_id: "local|local|loader-person",
            authenticated: true,
            auth_method: :oidc
        })

      entry = instance!()

      assert {:instance, id, {:ok, view}} =
               Loader.row_binding(person, %{}, instance_row(entry, "sha256:instance"))

      assert id == entry.id and view.binding_digest == "sha256:instance"

      # Rebound since the row was approved.
      assert {:instance, _, {:error, :binding_went_stale}} =
               Loader.row_binding(person, %{}, instance_row(entry, "sha256:approved-earlier"))

      # No longer offered, then revoked.
      listed = instance!(%{audience: "listed"})

      assert {:instance, _, {:error, :not_offered}} =
               Loader.row_binding(person, %{}, instance_row(listed, "sha256:instance"))

      {:ok, _} =
        Arca.InstanceEntries.revoke(Arca.Test.Actor.platform(), entry.id, "needs_consent")

      assert {:instance, _, {:error, {:entry_unavailable, "revoked"}}} =
               Loader.row_binding(person, %{}, instance_row(entry, "sha256:instance"))
    end

    test "provided configuration names no binding and resolves to itself", %{ctx: ctx} do
      provided = %{
        "provided" => %{
          "destination" => %{"hosts" => ["abc.supabase.co"], "scheme" => "https"},
          "values" => %{"anon_key" => "eyJ-public"},
          "attach" => %{"in" => "header", "name" => "apikey", "template" => "{value}"}
        }
      }

      policy =
        Jason.encode!(%{
          "canonical" => "jcs-1",
          "nodes" => %{
            Fixtures.formula_ref() => %{
              "limits" => Fixtures.limits_map(),
              "edges" => %{"@ingress" => %{}, Fixtures.catalyst_ref() => %{"vault" => provided}}
            },
            Fixtures.catalyst_ref() => %{"limits" => Fixtures.limits_map(), "edges" => %{}}
          }
        })

      profile = profile_summary()
      seed(ctx, profile, consent(%{resolved_policy: policy, vault_refs: []}))

      {:ok, head} = Arca.ConsentStorage.head_consent(Context.actor(ctx), profile.id)
      assert head.vault_refs == []
      assert {:ok, blob} = Loader.admitted_blob(ctx, profile, head)

      {:ok, edge} =
        Prima.Authority.Blob.lookup_edge(
          blob,
          Fixtures.formula_ref(),
          Fixtures.catalyst_ref(),
          ""
        )

      assert %{provided: %{values: %{"anon_key" => "eyJ-public"}}} = edge.vault
    end
  end

  describe "admitted_blob/3, the stored head's own checks" do
    defp head!(ctx, profile) do
      {:ok, head} = Arca.ConsentStorage.head_consent(Context.actor(ctx), profile.id)
      head
    end

    test "answers the blob load_root/3 carries, before the ceiling clamps its limits",
         %{ctx: ctx} do
      profile = profile_summary()
      consent = consent()
      seed(ctx, profile, consent)

      assert {:ok, %Prima.Authority.Blob{} = blob} =
               Loader.admitted_blob(ctx, profile, head!(ctx, profile))

      assert {:ok, %Authority{policy: carried}, _stamp} =
               Loader.load_root(ctx, profile, live: live_for(consent.activation))

      assert carried ==
               Prima.Authority.Blob.clamp(blob, Sanctum.Policy.Ceiling.platform_ceiling())
    end

    test "leaves the run's own origin to load_root/3", %{ctx: ctx} do
      profile = profile_summary()
      consent = consent()
      seed(ctx, profile, consent)
      live = live_for(consent.activation)

      assert {:error, {:consent_required, _}} =
               Loader.load_root(%{ctx | origin: :schedule}, profile, live: live)

      assert {:ok, %Prima.Authority.Blob{}} =
               Loader.admitted_blob(%{ctx | origin: :schedule}, profile, head!(ctx, profile))
    end

    test "refuses each head load_root/3 refuses on the head itself, with its answer",
         %{ctx: ctx} do
      profile = profile_summary()
      honest = consent()

      refused = [
        consent(%{scope: :pinned, pinned_version: ""}),
        consent(%{resolved_policy: "{not json"}),
        %{honest | blob_digest: "sha256:not-these-bytes"},
        consent(%{vault_refs: [source_ref()]}),
        with_paths(["data//secrets/"])
      ]

      for consent <- refused do
        seed(ctx, profile, consent)

        assert {:error, refusal} = Loader.admitted_blob(ctx, profile, head!(ctx, profile))

        assert Loader.load_root(ctx, profile, live: live_for(consent.activation)) ==
                 {:error, refusal}
      end
    end
  end
end
