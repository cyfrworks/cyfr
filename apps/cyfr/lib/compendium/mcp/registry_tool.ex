# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.MCP.RegistryTool do
  @moduledoc """
  Registry tool handlers for the Compendium MCP provider — cyfr.run
  identity/namespace operations (probe, claim, tokens, members, abuse
  reports, legal, appeals).

  Extracted from `Compendium.MCP`; behaviour preserved exactly.
  """

  alias Sanctum.Context
  alias Compendium.MCP.Shared

  def handle(%Context{} = ctx, %{"action" => "whoami"}) do
    {:ok, Compendium.Registry.Identity.identity(ctx)}
  end

  def handle(
        ctx,
        %{"action" => "probe", "provider" => provider, "access_token" => access_token} = args
      ) do
    label = Map.get(args, "label")

    case Compendium.Registry.Client.probe_identity(provider, access_token, label) do
      {:ok, body} ->
        # Persist returned push tokens into CredentialStore for authenticated
        # callers. Mirrors what Sanctum.Auth.DeviceFlow.probe_after_session/3
        # does server-side during the device-flow path; for codex/porta
        # post-legal_accept flows that re-call probe directly, this writes
        # the same locally-cached credentials.
        body_with_warnings = maybe_store_probe_credentials(ctx, body)
        {:ok, body_with_warnings}

      {:error, %Compendium.OCI.Errors{reason: :policy_acceptance_required} = err} ->
        # Server bumped the bundled policy version between the user's last
        # acceptance and this re-probe (race on the codex/porta post-accept
        # path). Surface the same structured shape DeviceFlow.probe_after_session/3
        # emits so clients can route back into the clickwrap UI without
        # parsing string errors.
        {:ok,
         %{
           "needs_policy_acceptance" => true,
           "required_policy_version" => required_policy_version(err),
           "needs_personal_namespace" => false
         }}

      {:error, err} ->
        {:error, Shared.to_error_string(err)}
    end
  end

  def handle(_ctx, %{"action" => "probe"}) do
    {:error, "registry.probe requires 'provider' and 'access_token'"}
  end

  def handle(
        %Context{} = ctx,
        %{
          "action" => "claim_personal",
          "username" => username,
          "provider" => provider,
          "access_token" => access_token
        } = args
      ) do
    label = Map.get(args, "label")

    case Compendium.Registry.Client.claim_personal_namespace(
           username,
           provider,
           access_token,
           label
         ) do
      {:ok, body} ->
        # When the caller reached us with an authenticated cyfr session, persist
        # the returned push token to CredentialStore keyed by the session's
        # user_id. On unauthenticated bootstrap calls (e.g. raw MCP with no
        # Bearer / no hydrated Sanctum session), skip storage — the client
        # must subsequently call /v1/identity/probe after establishing a
        # session to provision the credential locally.
        body_with_warning = maybe_store_personal_credential(ctx, body)
        {:ok, body_with_warning}

      {:error, err} ->
        {:error, Shared.to_error_string(err)}
    end
  end

  def handle(_ctx, %{"action" => "claim_personal"}) do
    {:error, "registry.claim_personal requires 'username', 'provider', and 'access_token'"}
  end

  def handle(%Context{} = ctx, %{"action" => "claim_publisher", "slug" => slug}) do
    with {:ok, bearer} <- personal_bearer(ctx),
         {:ok, body} <- Compendium.Registry.Client.claim_publisher_namespace(slug, bearer) do
      {:ok, body}
    else
      {:error, err} -> {:error, Shared.to_error_string(err)}
    end
  end

  def handle(_ctx, %{"action" => "claim_publisher"}) do
    {:error, "registry.claim_publisher requires 'slug'"}
  end

  def handle(%Context{} = ctx, %{"action" => "verify_publisher", "slug" => slug}) do
    with {:ok, bearer} <- personal_bearer(ctx),
         {:ok, body} <- Compendium.Registry.Client.verify_publisher_namespace(slug, bearer) do
      {:ok, body}
    else
      {:error, err} -> {:error, Shared.to_error_string(err)}
    end
  end

  def handle(_ctx, %{"action" => "verify_publisher"}) do
    {:error, "registry.verify_publisher requires 'slug'"}
  end

  def handle(_ctx, %{"action" => "get_namespace", "slug" => slug}) do
    case Compendium.Registry.Client.get_namespace(slug) do
      {:ok, body} -> {:ok, body}
      {:error, err} -> {:error, Shared.to_error_string(err)}
    end
  end

  def handle(_ctx, %{"action" => "get_namespace"}) do
    {:error, "registry.get_namespace requires 'slug'"}
  end

  def handle(%Context{} = ctx, %{"action" => "tokens_list", "slug" => slug}) do
    with {:ok, bearer} <- Shared.namespace_bearer(ctx, slug),
         {:ok, body} <- Compendium.Registry.Client.list_tokens(slug, bearer) do
      {:ok, body}
    else
      {:error, err} -> {:error, Shared.to_error_string(err)}
    end
  end

  def handle(_ctx, %{"action" => "tokens_list"}) do
    {:error, "registry.tokens_list requires 'slug'"}
  end

  def handle(%Context{} = ctx, %{"action" => "tokens_issue", "slug" => slug} = args) do
    label = Map.get(args, "label")

    with {:ok, bearer} <- Shared.namespace_bearer(ctx, slug),
         {:ok, body} <- Compendium.Registry.Client.issue_additional_token(slug, bearer, label) do
      {:ok, body}
    else
      {:error, err} -> {:error, Shared.to_error_string(err)}
    end
  end

  def handle(_ctx, %{"action" => "tokens_issue"}) do
    {:error, "registry.tokens_issue requires 'slug'"}
  end

  def handle(%Context{} = ctx, %{
        "action" => "tokens_revoke",
        "slug" => slug,
        "token_id" => token_id
      }) do
    with {:ok, bearer} <- Shared.namespace_bearer(ctx, slug),
         :ok <- Compendium.Registry.Client.revoke_token(slug, token_id, bearer) do
      {:ok, %{revoked: token_id}}
    else
      {:error, err} -> {:error, Shared.to_error_string(err)}
    end
  end

  def handle(_ctx, %{"action" => "tokens_revoke"}) do
    {:error, "registry.tokens_revoke requires 'slug' and 'token_id'"}
  end

  def handle(%Context{} = ctx, %{"action" => "members_list", "slug" => slug}) do
    with {:ok, bearer} <- Shared.namespace_bearer(ctx, slug),
         {:ok, body} <- Compendium.Registry.Client.list_members(slug, bearer) do
      {:ok, body}
    else
      {:error, err} -> {:error, Shared.to_error_string(err)}
    end
  end

  def handle(_ctx, %{"action" => "members_list"}) do
    {:error, "registry.members_list requires 'slug'"}
  end

  def handle(%Context{} = ctx, %{
        "action" => "members_add",
        "slug" => slug,
        "target_personal_slug" => target,
        "role" => role
      }) do
    with {:ok, bearer} <- Shared.namespace_bearer(ctx, slug),
         {:ok, body} <- Compendium.Registry.Client.add_member(slug, target, role, bearer) do
      {:ok, body}
    else
      {:error, err} -> {:error, Shared.to_error_string(err)}
    end
  end

  def handle(_ctx, %{"action" => "members_add"}) do
    {:error, "registry.members_add requires 'slug', 'target_personal_slug', and 'role'"}
  end

  def handle(%Context{} = ctx, %{
        "action" => "members_update",
        "slug" => slug,
        "target_personal_slug" => target,
        "role" => role
      }) do
    with {:ok, bearer} <- Shared.namespace_bearer(ctx, slug),
         {:ok, body} <- Compendium.Registry.Client.update_member(slug, target, role, bearer) do
      {:ok, body}
    else
      {:error, err} -> {:error, Shared.to_error_string(err)}
    end
  end

  def handle(_ctx, %{"action" => "members_update"}) do
    {:error, "registry.members_update requires 'slug', 'target_personal_slug', and 'role'"}
  end

  def handle(%Context{} = ctx, %{
        "action" => "members_remove",
        "slug" => slug,
        "target_personal_slug" => target
      }) do
    with {:ok, bearer} <- Shared.namespace_bearer(ctx, slug),
         :ok <- Compendium.Registry.Client.remove_member(slug, target, bearer) do
      {:ok, %{removed: target}}
    else
      {:error, err} -> {:error, Shared.to_error_string(err)}
    end
  end

  def handle(_ctx, %{"action" => "members_remove"}) do
    {:error, "registry.members_remove requires 'slug' and 'target_personal_slug'"}
  end

  # User-side abuse report submission. Auth: any push token belonging to the
  # caller — resolved via the same first-push-token heuristic as probe. At
  # least one of target_namespace or target_component_ref must be set.
  def handle(%Context{} = ctx, %{"action" => "report"} = args) do
    category = Map.get(args, "category", "")
    target_namespace = Map.get(args, "target_namespace")
    target_component_ref = Map.get(args, "target_component_ref")
    details = Map.get(args, "details", "")

    with :ok <- ensure_present(category, "category"),
         :ok <- ensure_present(details, "details"),
         :ok <- ensure_target(target_namespace, target_component_ref),
         {:ok, component_id} <- resolve_component_id(target_component_ref),
         {:ok, bearer} <- any_push_token(ctx),
         {:ok, body} <-
           Compendium.Registry.Client.create_abuse_report(
             category,
             target_namespace,
             component_id,
             details,
             bearer
           ) do
      {:ok, body}
    else
      {:error, err} -> {:error, Shared.to_error_string(err)}
    end
  end

  # list_my_reports returns the caller's filed abuse reports from cyfr.run.
  # Resolves any available push token (same heuristic as `probe`) and hits
  # GET /v1/abuse-reports/mine. Pagination via optional limit/offset.
  def handle(%Context{} = ctx, %{"action" => "list_my_reports"} = args) do
    opts =
      []
      |> put_if_int(:limit, Map.get(args, "limit"))
      |> put_if_int(:offset, Map.get(args, "offset"))

    with {:ok, bearer} <- any_push_token(ctx),
         {:ok, body} <- Compendium.Registry.Client.list_my_reports(bearer, opts) do
      {:ok, body}
    else
      {:error, err} -> {:error, Shared.to_error_string(err)}
    end
  end

  def handle(_ctx, %{"action" => "legal_page", "name" => name})
      when is_binary(name) and name != "" do
    case Compendium.Registry.Client.get_legal_page(name) do
      {:ok, body} -> {:ok, body}
      {:error, err} -> {:error, Shared.to_error_string(err)}
    end
  end

  def handle(_ctx, %{"action" => "legal_page"}) do
    {:error,
     "name (one of: terms, privacy, aup, content-policy, dmca, cookies, transparency) is required"}
  end

  def handle(_ctx, %{"action" => "legal_version"}) do
    case Compendium.Registry.Client.get_legal_version() do
      {:ok, body} -> {:ok, body}
      {:error, err} -> {:error, Shared.to_error_string(err)}
    end
  end

  def handle(_ctx, %{"action" => "legal_accept"} = args) do
    provider = Map.get(args, "provider", "")
    access_token = Map.get(args, "access_token", "")
    id_token = Map.get(args, "id_token", "")
    policy_version = Map.get(args, "policy_version", "")

    with :ok <- ensure_present(provider, "provider"),
         :ok <- ensure_present(policy_version, "policy_version"),
         :ok <- ensure_appeal_token(provider, access_token, id_token),
         {:ok, body} <-
           Compendium.Registry.Client.accept_policies(
             provider,
             access_token,
             id_token,
             policy_version
           ) do
      {:ok, body}
    else
      {:error, err} -> {:error, Shared.to_error_string(err)}
    end
  end

  def handle(_ctx, %{"action" => "appeal"} = args) do
    provider = Map.get(args, "provider", "")
    access_token = Map.get(args, "access_token", "")
    id_token = Map.get(args, "id_token", "")
    action_type = Map.get(args, "action_type", "")
    action_ref = Map.get(args, "action_ref", "")
    argument = Map.get(args, "argument", "")

    with :ok <- ensure_present(provider, "provider"),
         :ok <- ensure_present(action_type, "action_type"),
         :ok <- ensure_present(action_ref, "action_ref"),
         :ok <- ensure_present(argument, "argument"),
         :ok <- ensure_appeal_token(provider, access_token, id_token),
         {:ok, body} <-
           Compendium.Registry.Client.create_appeal(
             provider,
             access_token,
             id_token,
             action_type,
             action_ref,
             argument
           ) do
      {:ok, body}
    else
      {:error, err} -> {:error, Shared.to_error_string(err)}
    end
  end

  def handle(_ctx, %{"action" => action}) do
    {:error, "Unknown registry action: #{action}"}
  end

  def handle(_ctx, _args) do
    {:error, "registry action is required"}
  end

  # ============================================================================
  # Private helpers
  # ============================================================================

  defp put_if_int(kw, key, n) when is_integer(n) and n >= 0, do: Keyword.put(kw, key, n)

  defp put_if_int(kw, key, s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n >= 0 -> Keyword.put(kw, key, n)
      _ -> kw
    end
  end

  defp put_if_int(kw, _key, _), do: kw

  # Find the user's personal-namespace bearer, used for actions that require
  # a user identity proof (claim_publisher, verify_publisher).
  defp personal_bearer(%Context{user_id: user_id}) when is_binary(user_id) and user_id != "" do
    registry = Compendium.Registry.canonical_host()

    case Compendium.Registry.CredentialStore.list_for_user(user_id, registry) do
      [%{type: :push_token, token: token, namespace: slug} | _] when is_binary(token) ->
        if String.contains?(slug, "."),
          do:
            {:error, "no personal-namespace bearer found — claim your personal namespace first"},
          else: {:ok, token}

      _ ->
        {:error, "no push token available — run `cyfr login` to authenticate"}
    end
  end

  defp personal_bearer(_), do: {:error, "authentication required"}

  # Persists the push token returned by claim_personal into CredentialStore
  # when the caller is authenticated. Returns the body unchanged on success,
  # or with a `"local_store_failed": true` marker on DB/encrypt failure so
  # the CLI can surface a warning.
  defp maybe_store_personal_credential(%Context{authenticated: true, user_id: user_id}, body)
       when is_binary(user_id) and user_id != "" do
    slug = body["slug"]
    token = body["token"]

    if is_binary(slug) and is_binary(token) do
      registry = Compendium.Registry.canonical_host()

      cred = %{
        type: :push_token,
        token: token,
        namespace: slug,
        role: "personal",
        issued_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        label: Compendium.Registry.Client.device_label()
      }

      case Compendium.Registry.CredentialStore.put(user_id, registry, slug, cred) do
        :ok ->
          body

        {:error, reason} ->
          require Logger

          Logger.warning(
            "[Compendium.MCP] claim_personal CredentialStore.put failed for " <>
              "#{user_id}/#{slug}: #{inspect(reason)} — orphan cyfr.run token " <>
              "will be reaped server-side after 365 days"
          )

          Map.put(body, "local_store_failed", true)
      end
    else
      body
    end
  end

  defp maybe_store_personal_credential(_ctx, body), do: body

  # Persists every push token from a registry.probe response into the
  # caller's local CredentialStore. Used by the post-legal_accept re-probe
  # flow (codex/porta) so the cached credentials are populated without a
  # separate session.* round-trip. Mirrors
  # Sanctum.Auth.DeviceFlow.store_probe_results/4 (the device-flow path
  # that runs at OAuth completion).
  #
  # Annotates the body with `"credential_store_warnings": [slugs]` when any
  # individual put fails — partial failure is non-fatal (each namespace
  # is independent), and surfaces as a soft warning the client can show.
  defp maybe_store_probe_credentials(%Context{authenticated: true, user_id: user_id}, body)
       when is_binary(user_id) and user_id != "" do
    require Logger

    registry = Compendium.Registry.canonical_host()
    label = Compendium.Registry.Client.device_label()

    personal = body["personal_namespace"]
    memberships = body["memberships"] || []

    personal_warning =
      case personal do
        %{"slug" => slug, "token" => token}
        when is_binary(slug) and is_binary(token) ->
          cred = %{
            type: :push_token,
            token: token,
            namespace: slug,
            role: "personal",
            issued_at: DateTime.utc_now() |> DateTime.to_iso8601(),
            label: label
          }

          case Compendium.Registry.CredentialStore.put(user_id, registry, slug, cred) do
            :ok ->
              nil

            {:error, reason} ->
              Logger.warning(
                "[Compendium.MCP] probe CredentialStore.put failed (personal) " <>
                  "#{user_id}/#{slug}: #{inspect(reason)}"
              )

              slug
          end

        _ ->
          nil
      end

    membership_warnings =
      memberships
      |> Enum.map(fn m ->
        slug = m["slug"]
        token = m["token"]
        role = m["role"] || "member"

        if is_binary(slug) and is_binary(token) do
          cred = %{
            type: :push_token,
            token: token,
            namespace: slug,
            role: role,
            issued_at: DateTime.utc_now() |> DateTime.to_iso8601(),
            label: label
          }

          case Compendium.Registry.CredentialStore.put(user_id, registry, slug, cred) do
            :ok ->
              nil

            {:error, reason} ->
              Logger.warning(
                "[Compendium.MCP] probe CredentialStore.put failed (member) " <>
                  "#{user_id}/#{slug}: #{inspect(reason)}"
              )

              slug
          end
        else
          nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    warnings =
      [personal_warning | membership_warnings] |> Enum.reject(&is_nil/1)

    if warnings == [] do
      body
    else
      Map.put(body, "credential_store_warnings", warnings)
    end
  end

  defp maybe_store_probe_credentials(_ctx, body), do: body

  # Lifts `required_version` out of an Errors struct's detail. The detail
  # shape depends on which builder produced the error:
  #   - Errors.from_response/3 puts {required_version: v} directly into detail
  #   - Errors.from_api_response/3 wraps it: %{operation: op, original_detail: %{required_version: v}}
  # Both keying styles (atom + string) are checked. Mirrors the extraction
  # logic in Sanctum.Auth.DeviceFlow.probe_after_session/3.
  defp required_policy_version(%Compendium.OCI.Errors{detail: detail}),
    do: dig_required_version(detail)

  defp dig_required_version(%{required_version: v}) when is_binary(v), do: v
  defp dig_required_version(%{"required_version" => v}) when is_binary(v), do: v
  defp dig_required_version(%{original_detail: inner}), do: dig_required_version(inner)
  defp dig_required_version(%{"original_detail" => inner}), do: dig_required_version(inner)
  defp dig_required_version(_), do: nil

  # ============================================================================
  # Abuse-report + admin helpers
  # ============================================================================

  defp ensure_present(value, _field) when is_binary(value) and value != "", do: :ok
  defp ensure_present(_, field), do: {:error, "'#{field}' is required"}

  # Closed-platform appeals: provider determines which token field carries
  # the credential. github/google use access_token; oidcc uses id_token.
  defp ensure_appeal_token("oidcc", _access, id) when is_binary(id) and id != "", do: :ok

  defp ensure_appeal_token("oidcc", _access, _id),
    do: {:error, "'id_token' is required for oidcc"}

  defp ensure_appeal_token(_provider, access, _id) when is_binary(access) and access != "",
    do: :ok

  defp ensure_appeal_token(_provider, _access, _id),
    do: {:error, "'access_token' is required"}

  defp ensure_target(nil, nil),
    do: {:error, "at least one of target_namespace or target_component_ref required"}

  defp ensure_target("", ""), do: ensure_target(nil, nil)
  defp ensure_target(nil, ""), do: ensure_target(nil, nil)
  defp ensure_target("", nil), do: ensure_target(nil, nil)
  defp ensure_target(_, _), do: :ok

  # MCP report action accepts a component ref (user-friendly). Server wants a
  # UUID. We resolve via the index — GET /v1/components/:type/:slug/:name/:ver.
  # Nil ref is fine (namespace-only report); empty string same.
  defp resolve_component_id(nil), do: {:ok, nil}
  defp resolve_component_id(""), do: {:ok, nil}

  defp resolve_component_id(ref) when is_binary(ref) do
    with {:ok, %Sanctum.ComponentRef{} = r} <- Sanctum.ComponentRef.parse(ref),
         :ok <- Shared.ensure_fully_qualified(r),
         {:ok, comp} <-
           Compendium.Registry.Client.get_component(
             Sanctum.system_context(),
             r.type,
             r.namespace,
             r.name,
             r.version
           ) do
      {:ok, comp["id"] || comp[:id]}
    end
  end

  # First push token the caller holds — for non-namespace-scoped actions like
  # abuse-report submission. Same head-of-list heuristic used by probe.
  defp any_push_token(%Sanctum.Context{user_id: user_id})
       when is_binary(user_id) and user_id != "" do
    registry = Compendium.Registry.canonical_host()

    case Compendium.Registry.CredentialStore.list_for_user(user_id, registry) do
      [%{type: :push_token, token: token} | _] when is_binary(token) -> {:ok, token}
      _ -> {:error, "no push token available — run `cyfr login` to authenticate"}
    end
  end

  defp any_push_token(_), do: {:error, "authentication required"}
end
