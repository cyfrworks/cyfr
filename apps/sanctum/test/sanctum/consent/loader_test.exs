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

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    ctx = %Context{
      user_id: "loader_test_user",
      athanor_id: "ath_test",
      scope: :athanor,
      permissions: MapSet.new([:execute])
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
          vault_refs: [
            %{vault_entry_id: "vault-source", binding_digest: "sha256:bind-source"},
            %{vault_entry_id: "vault-dest", binding_digest: "sha256:bind-dest"}
          ]
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
      consent(%{
        vault_refs: [%{vault_entry_id: "vault-source", binding_digest: "sha256:bind-source"}]
      })
    )

    assert {:error, {:blob_refs_mismatch, %{blob_only: blob_only, refs_only: []}}} =
             Loader.load_root(ctx, profile, live: live_for(Fixtures.activation()))

    assert blob_only == [{"vault-dest", "sha256:bind-dest"}]
  end

  test "a stored ref the blob does not carry fails closed too", %{ctx: ctx} do
    profile = profile_summary()
    extra = %{vault_entry_id: "vault-ghost", binding_digest: "sha256:bind-ghost"}
    base = consent()
    seed(ctx, profile, %{base | vault_refs: base.vault_refs ++ [extra]})

    assert {:error, {:blob_refs_mismatch, %{blob_only: [], refs_only: refs_only}}} =
             Loader.load_root(ctx, profile, live: live_for(Fixtures.activation()))

    assert refs_only == [{"vault-ghost", "sha256:bind-ghost"}]
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
end
