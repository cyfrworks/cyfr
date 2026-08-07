# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.MCP.ProfileTool do
  @moduledoc """
  Profile tool handlers for the Sanctum MCP provider — the consent walk
  over `Sanctum.Consent.{Plan,Commit}` plus thin list/revoke.

  The §4.3 error payloads cross this boundary verbatim in the
  `tag: {json}` convention the execution surface already speaks. A
  key-authenticated commit loads its consent capability from the key
  row itself — callers never supply their own capability.
  """

  alias Sanctum.Consent.Commit
  alias Sanctum.Consent.Plan
  alias Sanctum.Consent.Source
  alias Sanctum.Context

  def handle(%Context{} = ctx, %{"action" => "plan", "ref" => ref} = args) do
    with {:ok, kind} <- kind(args) do
      params =
        %{ref: ref, kind: kind}
        |> put_present(:label, args["label"])

      case Plan.plan(ctx, params) do
        {:ok, plan} -> {:ok, plan}
        {:error, reason} -> {:error, fmt(reason)}
      end
    end
  end

  def handle(_ctx, %{"action" => "plan"}) do
    {:error, "plan requires ref"}
  end

  def handle(%Context{} = ctx, %{"action" => "preview", "decisions" => decisions})
      when is_map(decisions) do
    with {:ok, decoded} <- decode_decisions(decisions) do
      case Commit.preview(ctx, decoded) do
        {:ok, preview} -> {:ok, preview}
        {:error, reason} -> {:error, fmt(reason)}
      end
    end
  end

  def handle(_ctx, %{"action" => "preview"}) do
    {:error, "preview requires decisions"}
  end

  def handle(%Context{} = ctx, %{"action" => "commit", "decisions" => decisions} = args)
      when is_map(decisions) do
    with {:ok, decoded} <- decode_decisions(decisions),
         {:ok, capability} <- key_capability(ctx) do
      params = %{
        decisions: decoded,
        plan_token: args["plan_token"] || "",
        proof: args["proof"] || "",
        commit_digest: args["commit_digest"] || "",
        expected_consent_revision: args["expected_consent_revision"]
      }

      case Commit.commit(ctx, params, key_capability: capability) do
        {:ok, result} -> {:ok, Map.put(result, :status, "committed")}
        {:error, reason} -> {:error, fmt(reason)}
      end
    end
  end

  def handle(_ctx, %{"action" => "commit"}) do
    {:error,
     "commit requires decisions, plan_token, proof, commit_digest and expected_consent_revision"}
  end

  def handle(%Context{} = ctx, %{"action" => "publish", "profile_id" => profile_id} = args) do
    params = %{
      profile_id: profile_id,
      need_ids: Map.get(args, "need_ids", []),
      durable_storage: args["durable_storage"] == true
    }

    case Commit.stage_publish(ctx, params) do
      {:ok, staged} -> {:ok, staged}
      {:error, reason} -> {:error, fmt(reason)}
    end
  end

  def handle(_ctx, %{"action" => "publish"}) do
    {:error, "publish requires profile_id (the owner profile to publish from)"}
  end

  def handle(%Context{} = ctx, %{"action" => "list", "ref" => ref}) do
    with :ok <- Sanctum.Consent.Authz.authorize_staging(ctx),
         {:ok, source_ref} <- Plan.name_ref(ref),
         {:ok, profiles} <- Source.impl().profiles(ctx, source_ref) do
      enriched =
        Enum.map(profiles, fn profile ->
          revision =
            case Source.impl().head_consent(ctx, profile.id) do
              {:ok, consent} -> consent.revision
              _ -> nil
            end

          Map.put(profile, :head_revision, revision)
        end)

      {:ok, %{profiles: enriched}}
    else
      {:error, reason} -> {:error, fmt(reason)}
    end
  end

  def handle(_ctx, %{"action" => "list"}) do
    {:error, "list requires ref"}
  end

  def handle(%Context{} = ctx, %{"action" => "revoke", "profile_id" => profile_id}) do
    with {:ok, :interactive} <- Sanctum.Consent.Authz.authorize_interactive(ctx),
         :ok <- Arca.ProfileStorage.set_status(ctx.org_id, profile_id, "revoked") do
      {:ok, %{status: "revoked", profile_id: profile_id}}
    else
      {:error, reason} -> {:error, fmt(reason)}
    end
  end

  def handle(_ctx, %{"action" => "revoke"}) do
    {:error, "revoke requires profile_id"}
  end

  def handle(_ctx, _args) do
    {:error, "Invalid profile action. Use: plan, preview, commit, publish, list, revoke"}
  end

  # ---------------------------------------------------------------------------
  # Decisions decoding — string-keyed wire shape → the Commit vocabulary
  # ---------------------------------------------------------------------------

  defp decode_decisions(raw) do
    with {:ok, kind} <- kind(raw),
         {:ok, scope} <- enum(raw, "scope", %{"versionless" => :versionless, "pinned" => :pinned}),
         {:ok, invoke_mode} <-
           enum(raw, "invoke_mode", %{"open_inert" => :open_inert, "edge_only" => :edge_only}),
         {:ok, bindings} <- decode_bindings(Map.get(raw, "bindings", [])),
         {:ok, tool_servers} <- decode_tool_servers(Map.get(raw, "tool_servers", [])) do
      decisions =
        %{ref: raw["ref"] || "", kind: kind, bindings: bindings, tool_servers: tool_servers}
        |> put_present(:label, raw["label"])
        |> put_present(:scope, scope)
        |> put_present(:invoke_mode, invoke_mode)
        |> put_present(:limits, raw["limits"])
        |> Map.put(:override, raw["override"] == true)
        |> maybe_publish_passthrough(raw)

      {:ok, decisions}
    end
  end

  # A staged publish round-trips its decisions through the same wire shape.
  defp maybe_publish_passthrough(decisions, raw) do
    case raw["publish_from"] do
      profile_id when is_binary(profile_id) and profile_id != "" ->
        decisions
        |> Map.put(:publish_from, profile_id)
        |> Map.put(:need_ids, List.wrap(raw["need_ids"]))
        |> Map.put(:durable_storage, raw["durable_storage"] == true)

      _ ->
        decisions
    end
  end

  defp decode_tool_servers(list) when is_list(list) do
    decoded =
      Enum.map(list, fn grant ->
        %{server_name: grant["server_name"]}
        |> put_present(:tool_patterns, grant["tool_patterns"])
      end)

    {:ok, decoded}
  end

  defp decode_tool_servers(_), do: {:error, "tool_servers must be a list"}

  defp decode_bindings(list) when is_list(list) do
    decoded =
      Enum.map(list, fn binding ->
        %{
          need: Map.get(binding, "need", "@ingress"),
          entry_id: binding["entry_id"],
          fields: Map.get(binding, "fields", []),
          scopes: Map.get(binding, "scopes", [])
        }
      end)

    {:ok, decoded}
  end

  defp decode_bindings(_), do: {:error, "bindings must be a list"}

  defp kind(args) do
    enum(args, "kind", %{"owner" => :owner, "public" => :public})
    |> case do
      {:ok, nil} -> {:ok, :owner}
      other -> other
    end
  end

  defp enum(args, key, mapping) do
    case Map.get(args, key) do
      nil ->
        {:ok, nil}

      value when is_map_key(mapping, value) ->
        {:ok, Map.fetch!(mapping, value)}

      other ->
        {:error,
         "#{key} must be one of #{Enum.join(Map.keys(mapping), ", ")}, got: #{inspect(other)}"}
    end
  end

  # A key-authenticated caller's capability comes from its own key row —
  # never from the request.
  defp key_capability(%Context{auth_method: :api_key} = ctx) do
    Sanctum.ApiKey.consent_capability(ctx, ctx.api_key_id)
  end

  defp key_capability(_ctx), do: {:ok, nil}

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # ---------------------------------------------------------------------------
  # Error rendering — §4.3 payloads verbatim in the tag: json convention
  # ---------------------------------------------------------------------------

  defp fmt({:consent_conflict, payload}), do: "consent_conflict: " <> Jason.encode!(payload)
  defp fmt({:setup_required, payload}), do: "setup_required: " <> Jason.encode!(payload)
  defp fmt({:consent_required, payload}), do: "consent_required: " <> Jason.encode!(payload)
  defp fmt({:restart_required, payload}), do: "restart_required: " <> Jason.encode!(payload)

  defp fmt({:plan_token, reason}),
    do: "plan_token_invalid: #{inspect(reason)} — re-run plan to stage fresh facts"

  defp fmt({:proof, reason}),
    do: "proof_invalid: #{inspect(reason)} — re-run preview to mint a fresh proof"

  defp fmt({:surface_not_permitted, method}),
    do: "consent_class_required: this surface (#{method}) cannot consent"

  defp fmt(:guest_plane), do: "consent_class_required: guest-plane contexts cannot consent"
  defp fmt(:no_capability), do: "consent_class_required: this key carries no consent capability"

  defp fmt(:capability_digest_mismatch),
    do: "consent_class_required: the key's capability pins a different commit digest"

  defp fmt(:capability_expired), do: "consent_class_required: the key's capability has expired"

  defp fmt(:override_requires_interactive),
    do: "consent_class_required: overrides are always interactive"

  defp fmt({:unknown_need, need}),
    do: "unknown_need: #{inspect(need)} — this component declares no such need"

  defp fmt({:entry_unavailable, id, status}),
    do: "entry_unavailable: #{id} is #{inspect(status)}"

  defp fmt({:component_not_found, _reason}), do: "component_not_found"
  defp fmt({:invalid_ref, reason}), do: "invalid_ref: #{reason}"
  defp fmt(reason), do: inspect(reason)
end
