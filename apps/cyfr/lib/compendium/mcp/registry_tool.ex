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

  # Namespace, token and member mutations wield the operator's registry
  # identity (the CredentialStore bearer keyed by ctx.user_id) against
  # cyfr.run. Bootstrap actions (probe, claim_personal, get_namespace)
  # stay ungated: they run before a session exists and authenticate via
  # the IdP access token carried in args.
  @identity_mutations ~w(claim_publisher verify_publisher tokens_issue tokens_revoke members_add members_update members_remove)

  # A push or a registry mutation is a person's act under their own
  # namespace; an API key belongs to an athanor and is nobody's registry
  # identity, so it never wields one.
  @person_only @identity_mutations ++ ~w(report legal_accept appeal)

  @doc false
  # The tool's wire definition — schema and access annotations beside the
  # handler they gate; Compendium.MCP assembles its roster from these.
  def definition do
    %{
      name: "registry",
      title: "Registry",
      description:
        "cyfr.run registry identity and namespace operations: probe for tokens, claim a personal " <>
          "or publisher namespace, verify DNS ownership, manage additional push tokens and members, " <>
          "and inspect registry-side identity. Separate from `session` (local cyfr identity).",
      annotations: %{
        readOnlyHint: false,
        destructiveHint: false,
        actions: %{
          # Bootstrap/spec reads stay open (they run before a session
          # exists per the cyfr.run spec); identity mutations mirror
          # RegistryTool's gate.
          # The bootstrap a first sign-in still has ahead of it: a session
          # exists but the claim gate is not passed — these serve it.
          "probe" => %{kind: :execute, planes: [:external, :in_chain], auth: :signed_in},
          "claim_personal" => %{
            kind: :write,
            planes: [:external, :in_chain],
            auth: :signed_in
          },
          "claim_publisher" => %{
            kind: :write,
            planes: [:external],
            permission: :component_manage
          },
          "verify_publisher" => %{
            kind: :write,
            planes: [:external, :in_chain],
            permission: :component_manage
          },
          "tokens_list" => %{kind: :read, planes: [:external, :in_chain]},
          "tokens_issue" => %{kind: :write, planes: [:external], permission: :component_manage},
          "tokens_revoke" => %{
            kind: :write,
            planes: [:external, :in_chain],
            permission: :component_manage
          },
          "members_list" => %{kind: :read, planes: [:external, :in_chain]},
          "members_add" => %{kind: :write, planes: [:external], permission: :component_manage},
          "members_update" => %{
            kind: :write,
            planes: [:external],
            permission: :component_manage
          },
          "members_remove" => %{
            kind: :write,
            planes: [:external],
            permission: :component_manage
          },
          "whoami" => %{kind: :read, planes: [:external, :in_chain]},
          "get_namespace" => %{kind: :read, planes: [:external, :in_chain]},
          "report" => %{kind: :write, planes: [:external, :in_chain]},
          "list_my_reports" => %{kind: :read, planes: [:external, :in_chain]},
          "legal_page" => %{kind: :read, planes: [:external, :in_chain], auth: :signed_in},
          "legal_version" => %{kind: :read, planes: [:external, :in_chain], auth: :signed_in},
          "legal_accept" => %{kind: :write, planes: [:external, :in_chain], auth: :signed_in},
          "appeal" => %{kind: :write, planes: [:external, :in_chain]}
        }
      },
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => [
              "probe",
              "claim_personal",
              "claim_publisher",
              "verify_publisher",
              "tokens_list",
              "tokens_issue",
              "tokens_revoke",
              "members_list",
              "members_add",
              "members_update",
              "members_remove",
              "whoami",
              "get_namespace",
              "report",
              "list_my_reports",
              "legal_page",
              "legal_version",
              "legal_accept",
              "appeal"
            ],
            "description" => "Registry action to perform"
          },
          "provider" => %{
            "type" => "string",
            "enum" => ["github", "google"],
            "description" => "OAuth provider (for probe / claim_personal)"
          },
          "access_token" => %{
            "type" => "string",
            "description" =>
              "IdP access token (for probe / claim_personal). Used once to prove provider identity."
          },
          "label" => %{
            "type" => "string",
            "description" => "Human-readable label for the issued push token"
          },
          "username" => %{
            "type" => "string",
            "description" => "Desired personal-namespace slug (for claim_personal)"
          },
          "slug" => %{
            "type" => "string",
            "description" => "Namespace slug (publisher or personal)"
          },
          "token_id" => %{
            "type" => "string",
            "description" => "Token id (for tokens_revoke)"
          },
          "target_personal_slug" => %{
            "type" => "string",
            "description" => "Target user's personal namespace slug (for members_*)"
          },
          "role" => %{
            "type" => "string",
            "enum" => ["admin", "member"],
            "description" => "Member role (for members_add / members_update)"
          },
          # report action params
          "category" => %{
            "type" => "string",
            "enum" => [
              "impersonation",
              "malware",
              "dmca",
              "spam",
              "other",
              "csam",
              "objectionable",
              "ip_infringement",
              "security",
              "policy_violation",
              "ncii"
            ],
            "description" => "Abuse category (for report action)"
          },
          "target_namespace" => %{
            "type" => "string",
            "description" =>
              "Namespace being reported (for report action; required if no target_component_ref)"
          },
          "target_component_ref" => %{
            "type" => "string",
            "description" =>
              "Component reference being reported (for report action; required if no target_namespace)"
          },
          "details" => %{
            "type" => "string",
            "description" => "Report details (for report action; max 4096 chars)"
          },
          # list_my_reports pagination
          "limit" => %{
            "type" => "integer",
            "description" => "Max rows to return (list_my_reports; default 50, max 200)"
          },
          "offset" => %{
            "type" => "integer",
            "description" => "Starting row offset (list_my_reports; default 0)"
          },
          # legal_page / legal_accept
          "name" => %{
            "type" => "string",
            "description" =>
              "Policy name (for legal_page action: terms / privacy / aup / content-policy / dmca / cookies / transparency)"
          },
          "policy_version" => %{
            "type" => "string",
            "description" =>
              "Policy version string (for legal_accept; obtained via legal_version)"
          },
          "id_token" => %{
            "type" => "string",
            "description" => "OIDC id_token (for legal_accept / appeal when provider=oidcc)"
          },
          "action_type" => %{
            "type" => "string",
            "enum" => ["takedown", "ban"],
            "description" => "Appeal action_type (for appeal action)"
          },
          "action_ref" => %{
            "type" => "string",
            "description" =>
              "Appeal action_ref — component UUID or '<provider>|<subject>' (for appeal action)"
          },
          "argument" => %{
            "type" => "string",
            "description" => "Appeal argument, ≤4000 chars (for appeal action)"
          }
        },
        "required" => ["action"]
      }
    }
  end

  def handle(%Context{auth_method: :api_key}, %{"action" => action})
      when action in @person_only do
    {:error, "registry.#{action} is a person's act — sign in; an API key cannot do it"}
  end

  def handle(%Context{} = ctx, %{"action" => action} = args)
      when action in @identity_mutations do
    handle_gated(ctx, args)
  end

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
        # does server-side during the device-flow path; for codex
        # post-legal_accept flows that re-call probe directly, this writes
        # the same locally-cached credentials.
        body_with_warnings = maybe_store_probe_credentials(ctx, body)
        {:ok, body_with_warnings}

      {:error, %Compendium.OCI.Errors{reason: :policy_acceptance_required} = err} ->
        # Server bumped the bundled policy version between the user's last
        # acceptance and this re-probe (race on the codex post-accept
        # path). Surface the same structured shape DeviceFlow.probe_after_session/3
        # emits so clients can route back into the clickwrap UI without
        # parsing string errors.
        {:ok,
         %{
           "needs_policy_acceptance" => true,
           "required_policy_version" => Compendium.OCI.Errors.required_version(err),
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
    registry = Compendium.RegistryHost.canonical_host()

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

  # A claim made by a signed-in person is their identity from here on: it
  # lands on their users row (`Sanctum.SignIn.record_namespace/2`) and the
  # push token is cached best-effort. A claim from a session that is still
  # ahead of its own claim counts too — that is exactly when the CLI makes
  # it. Returns the body unchanged, or with a `"local_store_failed": true`
  # marker when the token could not be cached, so the CLI can say so.
  defp maybe_store_personal_credential(%Context{user_id: user_id}, body)
       when is_binary(user_id) and user_id != "" do
    slug = body["slug"]

    if is_binary(slug) do
      case Sanctum.SignIn.record_namespace(user_id, slug) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          require Logger

          Logger.warning(
            "[Compendium.MCP] claim_personal: namespace #{slug} not recorded for #{user_id}: " <>
              inspect(reason)
          )
      end

      registry = Compendium.RegistryHost.canonical_host()

      case Compendium.Registry.CredentialStore.put_push_token(
             user_id,
             registry,
             slug,
             body["token"],
             "personal"
           ) do
        :ok -> body
        :skipped -> body
        {:error, _} -> Map.put(body, "local_store_failed", true)
      end
    else
      body
    end
  end

  defp maybe_store_personal_credential(_ctx, body), do: body

  # A probe made by a signed-in person records their namespace and caches
  # every push token in the answer (`Sanctum.SignIn.absorb_probe/2`) —
  # the CLI's post-legal-accept re-probe and `cyfr whoami` land here.
  # Annotates the body with `"credential_store_warnings": [slugs]` when a
  # put fails — partial failure is non-fatal, each namespace is independent.
  defp maybe_store_probe_credentials(%Context{user_id: user_id}, body)
       when is_binary(user_id) and user_id != "" do
    case Sanctum.SignIn.absorb_probe(user_id, body) do
      [] -> body
      warnings -> Map.put(body, "credential_store_warnings", warnings)
    end
  end

  defp maybe_store_probe_credentials(_ctx, body), do: body

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
    registry = Compendium.RegistryHost.canonical_host()

    case Compendium.Registry.CredentialStore.list_for_user(user_id, registry) do
      [%{type: :push_token, token: token} | _] when is_binary(token) -> {:ok, token}
      _ -> {:error, "no push token available — run `cyfr login` to authenticate"}
    end
  end

  defp any_push_token(_), do: {:error, "authentication required"}
  # ============================================================================
  # Gated identity mutations (dispatched from the @identity_mutations head)
  # ============================================================================

  defp handle_gated(%Context{} = ctx, %{"action" => "claim_publisher", "slug" => slug}) do
    with {:ok, bearer} <- personal_bearer(ctx),
         {:ok, body} <- Compendium.Registry.Client.claim_publisher_namespace(slug, bearer) do
      {:ok, body}
    else
      {:error, err} -> {:error, Shared.to_error_string(err)}
    end
  end

  defp handle_gated(_ctx, %{"action" => "claim_publisher"}) do
    {:error, "registry.claim_publisher requires 'slug'"}
  end

  defp handle_gated(%Context{} = ctx, %{"action" => "verify_publisher", "slug" => slug}) do
    with {:ok, bearer} <- personal_bearer(ctx),
         {:ok, body} <- Compendium.Registry.Client.verify_publisher_namespace(slug, bearer) do
      {:ok, body}
    else
      {:error, err} -> {:error, Shared.to_error_string(err)}
    end
  end

  defp handle_gated(_ctx, %{"action" => "verify_publisher"}) do
    {:error, "registry.verify_publisher requires 'slug'"}
  end

  defp handle_gated(%Context{} = ctx, %{"action" => "tokens_issue", "slug" => slug} = args) do
    label = Map.get(args, "label")

    with {:ok, bearer} <- Shared.namespace_bearer(ctx, slug),
         {:ok, body} <- Compendium.Registry.Client.issue_additional_token(slug, bearer, label) do
      {:ok, body}
    else
      {:error, err} -> {:error, Shared.to_error_string(err)}
    end
  end

  defp handle_gated(_ctx, %{"action" => "tokens_issue"}) do
    {:error, "registry.tokens_issue requires 'slug'"}
  end

  defp handle_gated(_ctx, %{"action" => "tokens_revoke"}) do
    {:error, "registry.tokens_revoke requires 'slug' and 'token_id'"}
  end

  defp handle_gated(_ctx, %{"action" => "members_add"}) do
    {:error, "registry.members_add requires 'slug', 'target_personal_slug', and 'role'"}
  end

  defp handle_gated(_ctx, %{"action" => "members_update"}) do
    {:error, "registry.members_update requires 'slug', 'target_personal_slug', and 'role'"}
  end

  defp handle_gated(_ctx, %{"action" => "members_remove"}) do
    {:error, "registry.members_remove requires 'slug' and 'target_personal_slug'"}
  end

  # User-side abuse report submission. Auth: any push token belonging to the
  # caller — resolved via the same first-push-token heuristic as probe. At
  # least one of target_namespace or target_component_ref must be set.
end
