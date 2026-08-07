# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Consent.Commit do
  @moduledoc """
  Preview and commit: the two verbs that turn decisions into a revision.

  Preview recomputes everything live, renders what the operator is about
  to approve, and mints the short-lived commit proof — it never consumes
  the plan token, so an operator can change decisions and preview again.

  Commit re-verifies the world from scratch in a fixed order: authorize
  the caller, recompute the live shape, consume the plan token against it,
  recompute the commit digest from fresh vault rows, consume the proof
  against that, then insert with the head CAS and an in-transaction
  binding re-check. Every gap an adversary or a race could use — a new
  release between plan and commit, a `vault.rebind` between preview and
  commit, a concurrent revision — lands on one of those checks and
  surfaces as `consent_conflict`, never as a grant against stale facts.
  """

  alias Sanctum.Consent.Authz
  alias Sanctum.Consent.BlobBuilder
  alias Sanctum.Consent.CommitDigest
  alias Sanctum.Consent.Plan
  alias Sanctum.Consent.Proof
  alias Sanctum.Consent.ShapeDerivation
  alias Sanctum.Consent.ShapeDigest
  alias Sanctum.Context
  alias Sanctum.JCS
  alias Sanctum.VaultReader

  @type decisions :: %{
          required(:ref) => String.t(),
          optional(:label) => String.t(),
          optional(:kind) => :owner | :public,
          optional(:scope) => :versionless | :pinned,
          optional(:invoke_mode) => :open_inert | :edge_only,
          optional(:bindings) => [map()],
          optional(:override) => boolean(),
          optional(:limits) => map()
        }

  # ---------------------------------------------------------------------------
  # Preview
  # ---------------------------------------------------------------------------

  @doc "Recompute live, render the summary, mint the commit proof."
  @spec preview(Context.t(), decisions()) :: {:ok, map()} | {:error, term()}
  def preview(%Context{} = ctx, decisions) do
    with :ok <- Authz.authorize_staging(ctx),
         {:ok, prep} <- prepare(ctx, decisions),
         {:ok, proof} <- mint_commit_proof(ctx, prep) do
      {:ok,
       %{
         commit_digest: prep.commit_digest,
         summary: render_summary(prep),
         proof: proof,
         expected_consent_revision: prep.expected_revision
       }}
    end
  end

  # ---------------------------------------------------------------------------
  # Commit
  # ---------------------------------------------------------------------------

  @doc """
  Commit a consent revision. `params`:

    * `:decisions` — the same decisions previewed
    * `:plan_token` — from `Sanctum.Consent.Plan.plan/2`
    * `:proof` — from `preview/2`
    * `:commit_digest` — what the operator saw and approved
    * `:expected_consent_revision` — the revision plan reported

  `opts[:key_capability]` carries a scoped key's consent capability.
  """
  @spec commit(Context.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def commit(%Context{} = ctx, params, opts \\ []) do
    decisions = Map.get(params, :decisions, %{})

    with {:ok, granted_via} <- authorize(ctx, params, decisions, opts),
         {:ok, prep} <- prepare(ctx, decisions),
         :ok <- check_expected_revision(params, prep),
         :ok <- consume_plan_token(ctx, params, prep),
         :ok <- check_presented_digest(params, prep),
         :ok <- consume_commit_proof(ctx, params, prep),
         {:ok, blob_json, refs} <- build_blob(ctx, prep),
         {:ok, activation_json} <- JCS.encode(prep.activation.graph),
         {:ok, consent} <-
           persist(ctx, prep, blob_json, refs, activation_json, granted_via) do
      reactivate_profile(ctx, prep)

      {:ok,
       %{
         profile_id: consent.profile_id,
         revision: consent.revision,
         commit_digest: prep.commit_digest
       }}
    end
  end

  # ---------------------------------------------------------------------------
  # Preparation — one recomputation shared by preview and commit
  # ---------------------------------------------------------------------------

  defp prepare(ctx, decisions) do
    label = Map.get(decisions, :label, "default")
    kind = Map.get(decisions, :kind, :owner)
    scope = Map.get(decisions, :scope, :versionless)
    invoke_mode = Map.get(decisions, :invoke_mode, default_invoke_mode(kind))

    with {:ok, source_ref} <- Plan.name_ref(Map.get(decisions, :ref, "")),
         {:ok, component} <- Plan.fetch_component(ctx, source_ref),
         {:ok, activation} <- resolve_activation(ctx, component),
         {:ok, shape_input} <- ShapeDerivation.shape_input(ctx, source_ref),
         {:ok, shape_digest} <- shape_for_scope(shape_input, scope, component),
         {:ok, profile_id, expected_revision} <-
           Plan.locate_profile(ctx, source_ref, label, kind),
         {:ok, bindings, entries} <- resolve_bindings(ctx, decisions),
         {:ok, commit_input} <-
           commit_input(shape_digest, kind, invoke_mode, bindings, decisions),
         {:ok, commit_digest} <- CommitDigest.compute(commit_input) do
      {:ok,
       %{
         source_ref: source_ref,
         component: component,
         activation: activation,
         scope: scope,
         kind: kind,
         label: label,
         invoke_mode: invoke_mode,
         shape_digest: shape_digest,
         commit_digest: commit_digest,
         commit_input: commit_input,
         bindings: bindings,
         entries: entries,
         profile_id: profile_id,
         expected_revision: expected_revision,
         override: Map.get(decisions, :override, false)
       }}
    end
  end

  defp default_invoke_mode(:public), do: :edge_only
  defp default_invoke_mode(_), do: :open_inert

  defp resolve_activation(ctx, component) do
    case Compendium.Activation.resolve_verified(ctx, component) do
      {:ok, activation} -> {:ok, activation}
      {:error, reason} -> {:error, {:activation_unresolvable, reason}}
    end
  end

  # Pinned means the activation digest (D7); the version string rides along
  # as the display identity the shape shows.
  defp shape_for_scope(shape_input, :versionless, _component) do
    ShapeDigest.compute(shape_input)
  end

  defp shape_for_scope(shape_input, :pinned, component) do
    shape_input
    |> Map.put(:scope, :pinned)
    |> Map.put(:release_identity, %{
      version: component.version,
      release_digest: component.release_digest || ""
    })
    |> ShapeDigest.compute()
  end

  # Binding digests are ALWAYS derived from the live row here — a caller-
  # supplied digest could pin a consent to a binding the entry no longer
  # has. The unnamed slot is spelled "@ingress"; named needs arrive with
  # the manifest needs block, and an unknown need must fail like §2.7
  # says, not bind somewhere surprising.
  defp resolve_bindings(ctx, decisions) do
    decisions
    |> Map.get(:bindings, [])
    |> Enum.reduce_while({:ok, [], %{}}, fn raw, {:ok, acc, entries} ->
      need = Map.get(raw, :need, "@ingress")

      with :ok <- check_known_need(need),
           {:ok, entry} <- fetch_active_entry(ctx, Map.get(raw, :entry_id)),
           {:ok, digest} <- VaultReader.binding_digest(entry) do
        binding = %{
          need: need,
          entry_id: entry.id,
          binding_digest: digest,
          fields: Map.get(raw, :fields, []),
          scopes: Map.get(raw, :scopes, [])
        }

        {:cont, {:ok, [binding | acc], Map.put(entries, entry.id, entry)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, bindings, entries} -> {:ok, Enum.reverse(bindings), entries}
      error -> error
    end
  end

  defp check_known_need("@ingress"), do: :ok
  defp check_known_need(need), do: {:error, {:unknown_need, need}}

  defp fetch_active_entry(_ctx, nil), do: {:error, {:invalid_binding, :entry_id_required}}

  defp fetch_active_entry(ctx, entry_id) do
    case Arca.VaultStorage.get(ctx.org_id, entry_id) do
      {:ok, %{status: "active"} = entry} -> {:ok, entry}
      {:ok, %{status: status}} -> {:error, {:entry_unavailable, entry_id, status}}
      {:error, reason} -> {:error, {:entry_unavailable, entry_id, reason}}
    end
  end

  defp commit_input(shape_digest, kind, invoke_mode, bindings, decisions) do
    input = %{
      shape_digest: shape_digest,
      kind: kind,
      invoke_mode: invoke_mode,
      bindings: bindings,
      override: Map.get(decisions, :override, false)
    }

    input =
      case Map.get(decisions, :limits) do
        nil -> input
        limits -> Map.put(input, :limits, limits)
      end

    {:ok, input}
  end

  # ---------------------------------------------------------------------------
  # The commit-order checks
  # ---------------------------------------------------------------------------

  defp authorize(ctx, params, decisions, opts) do
    Authz.authorize(ctx, %Authz.Request{
      commit_digest: Map.get(params, :commit_digest),
      override?: Map.get(decisions, :override, false),
      key_capability: Keyword.get(opts, :key_capability)
    })
  end

  defp check_expected_revision(params, prep) do
    expected = Map.get(params, :expected_consent_revision)

    if expected == prep.expected_revision do
      :ok
    else
      conflict(:stale_plan, expected, prep.expected_revision)
    end
  end

  defp consume_plan_token(ctx, params, prep) do
    bindings =
      %{
        kind: :plan,
        commit_digest: prep.shape_digest,
        actor: ctx.user_id,
        org_id: ctx.org_id,
        project_id: ctx.project_id,
        expected_revision: prep.expected_revision
      }
      |> put_present(:profile_id, prep.profile_id)

    case Proof.consume(Map.get(params, :plan_token, ""), bindings) do
      :ok ->
        :ok

      {:error, {:binding_mismatch, :commit_digest}} ->
        # The live shape moved since the plan was staged.
        conflict(:digest_changed, prep.expected_revision, prep.expected_revision)

      {:error, {:binding_mismatch, :expected_revision}} ->
        conflict(:stale_plan, Map.get(params, :expected_consent_revision), prep.expected_revision)

      {:error, reason} ->
        {:error, {:plan_token, reason}}
    end
  end

  defp check_presented_digest(params, prep) do
    presented = Map.get(params, :commit_digest, "")

    if is_binary(presented) and Plug.Crypto.secure_compare(presented, prep.commit_digest) do
      :ok
    else
      # A rebind or policy move between preview and commit lands here: the
      # recomputed digest no longer matches what the operator approved.
      conflict(:digest_changed, prep.expected_revision, prep.expected_revision)
    end
  end

  defp mint_commit_proof(ctx, prep) do
    bindings =
      %{
        kind: :consent_commit,
        commit_digest: prep.commit_digest,
        actor: ctx.user_id,
        org_id: ctx.org_id,
        project_id: ctx.project_id,
        expected_revision: prep.expected_revision
      }
      |> put_present(:profile_id, prep.profile_id)

    Proof.mint(bindings)
  end

  defp consume_commit_proof(ctx, params, prep) do
    bindings =
      %{
        kind: :consent_commit,
        commit_digest: prep.commit_digest,
        actor: ctx.user_id,
        org_id: ctx.org_id,
        project_id: ctx.project_id,
        expected_revision: prep.expected_revision
      }
      |> put_present(:profile_id, prep.profile_id)

    case Proof.consume(Map.get(params, :proof, ""), bindings) do
      :ok ->
        :ok

      {:error, {:binding_mismatch, _field}} ->
        conflict(:digest_changed, prep.expected_revision, prep.expected_revision)

      {:error, reason} ->
        {:error, {:proof, reason}}
    end
  end

  # ---------------------------------------------------------------------------
  # Blob + persistence
  # ---------------------------------------------------------------------------

  defp build_blob(ctx, prep) do
    ingress_binding = Enum.find(prep.bindings, &(&1.need == "@ingress"))

    vault_fn = fn node_key, _row, _manifest ->
      if node_key == prep.source_ref and ingress_binding != nil do
        vault_resource(ingress_binding)
      end
    end

    with {:ok, nodes} <- BlobBuilder.build(ctx, prep.activation.graph, prep.source_ref, vault_fn),
         {:ok, blob_json} <- BlobBuilder.encode(nodes) do
      {:ok, blob_json, BlobBuilder.vault_refs(nodes)}
    end
  end

  defp vault_resource(binding) do
    projection =
      %{}
      |> put_projection("fields", binding.fields)
      |> put_projection("scopes", binding.scopes)

    base = %{"entry_id" => binding.entry_id, "binding_digest" => binding.binding_digest}

    if projection == %{}, do: base, else: Map.put(base, "projection", projection)
  end

  defp put_projection(map, _key, []), do: map
  defp put_projection(map, key, values), do: Map.put(map, key, Enum.sort(values))

  defp persist(ctx, prep, blob_json, refs, activation_json, granted_via) do
    profile_id = prep.profile_id || Emissary.UUID7.generate_id("prof")

    attrs = %{
      org_id: ctx.org_id,
      profile_id: profile_id,
      revision: prep.expected_revision + 1,
      scope: Atom.to_string(prep.scope),
      pinned_version: pinned_version(prep),
      invoke_mode: Atom.to_string(prep.invoke_mode),
      shape_digest: prep.shape_digest,
      commit_digest: prep.commit_digest,
      resolved_policy: blob_json,
      activation: activation_json,
      granted_by: ctx.user_id,
      granted_via: Atom.to_string(granted_via)
    }

    verify = fn -> verify_binding_liveness(ctx, prep) end

    result =
      if prep.profile_id do
        with {:ok, head_id} <- current_head_id(ctx, prep.profile_id) do
          Arca.ConsentStorage.insert_revision(attrs, refs, head_id, verify: verify)
        end
      else
        Arca.ConsentStorage.mint_profile_with_revision(
          %{
            id: profile_id,
            org_id: ctx.org_id,
            project_id: ctx.project_id,
            source_ref: prep.source_ref,
            kind: Atom.to_string(prep.kind),
            label: prep.label,
            status: "active"
          },
          attrs,
          refs,
          verify: verify
        )
      end

    case result do
      {:ok, consent} ->
        {:ok, consent}

      {:error, :head_moved} ->
        actual =
          case Plan.locate_profile(ctx, prep.source_ref, prep.label, prep.kind) do
            {:ok, _id, revision} -> revision
            _ -> prep.expected_revision
          end

        conflict(:race, prep.expected_revision, actual)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp pinned_version(%{scope: :pinned, component: component}), do: component.version
  defp pinned_version(_prep), do: ""

  defp current_head_id(ctx, profile_id) do
    case Arca.ConsentStorage.get_head(ctx.org_id, profile_id) do
      {:ok, head, _refs} -> {:ok, head.id}
      {:error, :no_head} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  # Runs inside the insert transaction: a vault.rebind that landed after
  # prepare must roll the revision back, not ship a consent that is dead
  # on arrival.
  defp verify_binding_liveness(ctx, prep) do
    Enum.reduce_while(prep.bindings, :ok, fn binding, :ok ->
      with {:ok, entry} <- fetch_active_entry(ctx, binding.entry_id),
           {:ok, digest} <- VaultReader.binding_digest(entry),
           true <- Plug.Crypto.secure_compare(digest, binding.binding_digest) do
        {:cont, :ok}
      else
        false -> {:halt, {:error, {:binding_went_stale, binding.entry_id}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # A profile blocked at needs_consent is unblocked by exactly this act —
  # a fresh revision IS the re-consent.
  defp reactivate_profile(ctx, %{profile_id: profile_id}) when is_binary(profile_id) do
    case Arca.ProfileStorage.get(ctx.org_id, profile_id) do
      {:ok, %{status: "needs_consent"}} ->
        Arca.ProfileStorage.set_status(ctx.org_id, profile_id, "active")

      _ ->
        :ok
    end
  end

  defp reactivate_profile(_ctx, _prep), do: :ok

  # ---------------------------------------------------------------------------
  # Rendering + helpers
  # ---------------------------------------------------------------------------

  defp render_summary(prep) do
    header =
      "Grant #{prep.source_ref} — #{prep.kind}, #{prep.scope}, revision #{prep.expected_revision + 1}"

    bindings =
      Enum.map(prep.bindings, fn binding ->
        entry = Map.fetch!(prep.entries, binding.entry_id)

        projected =
          if binding.fields == [], do: "all fields", else: Enum.join(binding.fields, ", ")

        "Uses #{entry.name} (#{projected})"
      end)

    [header | bindings]
  end

  defp conflict(cause, expected, actual) do
    {:error,
     {:consent_conflict, %{expected_revision: expected, actual_revision: actual, cause: cause}}}
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
