# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Providers.Registry do
  @moduledoc """
  Registry tool handlers for the Compendium MCP provider: cyfr.run
  handles, namespaces, push tokens, members, abuse reports, the
  registry's policies and appeals.

  Every operation that speaks for the person at the registry (a handle
  claim, a token mint, a policy acceptance, an appeal, a publisher claim
  and its verification) is one request their live key signs
  (`Compendium.Registry.Client.signed/3`); no identity provider's token is
  ever sent. The token-minting ones (`sync`,
  `verify_publisher`) are confirmed fresh first
  (`Sanctum.RegistryCredentials.confirm_issuance/4`) and store every
  token they are answered. Namespace administration (tokens, members)
  stays under the namespace's stored push token.
  """

  alias Sanctum.Context
  alias Compendium.Providers.Shared
  alias Compendium.Registry.{Client, CredentialStore}

  @identity_mutations ~w(claim_publisher verify_publisher tokens_issue tokens_revoke members_add members_update members_remove sync)

  # The signed operations the `signed_in` tier serves, before a person
  # holds a handle: a key belongs to an athanor and is nobody's registry
  # identity, so their handlers refuse one. The rest declare
  # `consent: :interactive`, which refuses a key at the gate.
  @person_acts ~w(claim_personal legal_accept)

  # Every action that sends a change to the registry — a POST that claims,
  # verifies, mints, adds, updates, accepts, reports or appeals — reaches
  # outside the home and is `external`; a DELETE there (`tokens_revoke`,
  # `members_remove`) is `destructive`. None takes a standing answer
  # (`standing: false`): an assistant's proposal of one is approved one
  # card at a time, and an allow stored before is read as no allow
  # (`Sanctum.ToolGrants`). The reads stay `read`. Every action declares
  # `sources: [:outside]`: whatever it answers, an error body included,
  # the registry wrote.

  @doc false
  # The tool's wire definition — schema and access annotations beside the
  # handler they gate; Compendium.Provider assembles its roster from these.
  def definition do
    alias Prima.{Arg, Operation}

    Operation.tool(
      [
        Operation.new("registry", "sync", "Sync registry tokens", [],
          kind: :external,
          sources: [:outside],
          standing: false,
          consent: :interactive,
          planes: [:external],
          permission: :component_manage
        ),
        Operation.new(
          "registry",
          "claim_personal",
          "Claim personal registry",
          [
            Arg.new("handle", :string,
              required: true,
              description: "The handle to claim at the registry, your personal namespace"
            )
          ],
          auth: :signed_in,
          kind: :external,
          sources: [:outside],
          standing: false,
          planes: [:external, :in_chain]
        ),
        Operation.new(
          "registry",
          "claim_publisher",
          "Claim publisher registry",
          [
            Arg.new("slug", :string,
              required: true,
              description: "Namespace slug (publisher or personal)"
            )
          ],
          kind: :external,
          sources: [:outside],
          standing: false,
          consent: :interactive,
          planes: [:external],
          permission: :component_manage
        ),
        Operation.new(
          "registry",
          "verify_publisher",
          "Verify publisher registry",
          [
            Arg.new("slug", :string,
              required: true,
              description: "Namespace slug (publisher or personal)"
            )
          ],
          kind: :external,
          sources: [:outside],
          standing: false,
          consent: :interactive,
          planes: [:external, :in_chain],
          permission: :component_manage
        ),
        Operation.new(
          "registry",
          "tokens_list",
          "Tokens list registry",
          [
            Arg.new("slug", :string,
              required: true,
              description: "Namespace slug (publisher or personal)"
            )
          ],
          kind: :read,
          sources: [:outside],
          planes: [:external, :in_chain]
        ),
        Operation.new(
          "registry",
          "tokens_issue",
          "Tokens issue registry",
          [
            Arg.new("slug", :string,
              required: true,
              description: "Namespace slug (publisher or personal)"
            ),
            Arg.new("label", :string,
              description: "Human-readable label for the issued push token"
            )
          ],
          kind: :external,
          sources: [:outside],
          standing: false,
          consent: :interactive,
          planes: [:external],
          permission: :component_manage
        ),
        Operation.new(
          "registry",
          "tokens_revoke",
          "Tokens revoke registry",
          [
            Arg.new("slug", :string,
              required: true,
              description: "Namespace slug (publisher or personal)"
            ),
            Arg.new("token_id", :string,
              required: true,
              description: "Token id (for tokens_revoke)"
            )
          ],
          kind: :destructive,
          sources: [:outside],
          standing: false,
          consent: :interactive,
          planes: [:external, :in_chain],
          permission: :component_manage
        ),
        Operation.new(
          "registry",
          "members_list",
          "Members list registry",
          [
            Arg.new("slug", :string,
              required: true,
              description: "Namespace slug (publisher or personal)"
            )
          ],
          kind: :read,
          sources: [:outside],
          planes: [:external, :in_chain]
        ),
        Operation.new(
          "registry",
          "members_add",
          "Members add registry",
          [
            Arg.new("slug", :string,
              required: true,
              description: "Namespace slug (publisher or personal)"
            ),
            Arg.new("target_personal_slug", :string,
              required: true,
              description: "Target user's personal namespace slug (for members_*)"
            ),
            Arg.new("role", :string,
              required: true,
              description: "Member role (for members_add / members_update)",
              enum: ["admin", "member"]
            )
          ],
          kind: :external,
          sources: [:outside],
          standing: false,
          consent: :interactive,
          planes: [:external],
          permission: :component_manage
        ),
        Operation.new(
          "registry",
          "members_update",
          "Members update registry",
          [
            Arg.new("slug", :string,
              required: true,
              description: "Namespace slug (publisher or personal)"
            ),
            Arg.new("target_personal_slug", :string,
              required: true,
              description: "Target user's personal namespace slug (for members_*)"
            ),
            Arg.new("role", :string,
              required: true,
              description: "Member role (for members_add / members_update)",
              enum: ["admin", "member"]
            )
          ],
          kind: :external,
          sources: [:outside],
          standing: false,
          consent: :interactive,
          planes: [:external],
          permission: :component_manage
        ),
        Operation.new(
          "registry",
          "members_remove",
          "Members remove registry",
          [
            Arg.new("slug", :string,
              required: true,
              description: "Namespace slug (publisher or personal)"
            ),
            Arg.new("target_personal_slug", :string,
              required: true,
              description: "Target user's personal namespace slug (for members_*)"
            )
          ],
          kind: :destructive,
          sources: [:outside],
          standing: false,
          consent: :interactive,
          planes: [:external],
          permission: :component_manage
        ),
        Operation.new("registry", "whoami", "Whoami registry", [],
          kind: :read,
          sources: [:outside],
          planes: [:external, :in_chain]
        ),
        Operation.new(
          "registry",
          "get_namespace",
          "Get namespace registry",
          [
            Arg.new("slug", :string,
              required: true,
              description: "Namespace slug (publisher or personal)"
            )
          ],
          kind: :read,
          sources: [:outside],
          planes: [:external, :in_chain]
        ),
        Operation.new(
          "registry",
          "report",
          "Report registry",
          [
            Arg.new("category", :string,
              required: true,
              description: "Abuse category (for report action)",
              enum: [
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
              ]
            ),
            Arg.new("details", :string,
              required: true,
              description: "Report details (for report action; max 4096 chars)"
            ),
            Arg.new("target_namespace", :string,
              description:
                "Namespace being reported (for report action; required if no target_component_ref)"
            ),
            Arg.new("target_component_ref", :string,
              description:
                "Component reference being reported (for report action; required if no target_namespace)"
            )
          ],
          kind: :external,
          sources: [:outside],
          standing: false,
          consent: :interactive,
          planes: [:external, :in_chain]
        ),
        Operation.new(
          "registry",
          "list_my_reports",
          "List my reports registry",
          [
            Arg.new("limit", :integer,
              description: "Max rows to return (list_my_reports; default 50, max 200)"
            ),
            Arg.new("offset", :integer,
              description: "Starting row offset (list_my_reports; default 0)"
            )
          ],
          kind: :read,
          sources: [:outside],
          planes: [:external, :in_chain]
        ),
        Operation.new(
          "registry",
          "legal_page",
          "Legal page registry",
          [
            Arg.new("name", :string,
              required: true,
              description:
                "Policy name (for legal_page action: terms / privacy / aup / content-policy / dmca / cookies / transparency)"
            )
          ],
          auth: :signed_in,
          kind: :read,
          sources: [:outside],
          planes: [:external, :in_chain]
        ),
        Operation.new("registry", "legal_version", "Legal version registry", [],
          auth: :signed_in,
          kind: :read,
          sources: [:outside],
          planes: [:external, :in_chain]
        ),
        Operation.new(
          "registry",
          "legal_accept",
          "Legal accept registry",
          [
            Arg.new("policy_version", :string,
              required: true,
              description: "Policy version string (for legal_accept; obtained via legal_version)"
            )
          ],
          auth: :signed_in,
          kind: :external,
          sources: [:outside],
          standing: false,
          planes: [:external, :in_chain]
        ),
        Operation.new(
          "registry",
          "appeal",
          "Appeal registry",
          [
            Arg.new("action_type", :string,
              required: true,
              description: "Appeal action_type (for appeal action)",
              enum: ["takedown", "ban"]
            ),
            Arg.new("action_ref", :string,
              required: true,
              description:
                "Appeal action_ref — the component's id, or your identifier for a ban (for appeal action)"
            ),
            Arg.new("argument", :string,
              required: true,
              description: "Appeal argument, ≤4000 bytes (for appeal action)"
            )
          ],
          kind: :external,
          sources: [:outside],
          standing: false,
          consent: :interactive,
          planes: [:external, :in_chain]
        )
      ],
      description:
        "cyfr.run registry operations, each a request your identity signs: claim your handle, sync your push tokens, claim and verify a publisher namespace by DNS, accept the registry's policies and file appeals; and manage additional push tokens and members, and inspect registry-side identity. Separate from `session` (local cyfr identity).",
      title: "Registry"
    )
  end

  def handle(%Context{auth_method: :api_key}, %{"action" => action})
      when action in @person_acts do
    {:error,
     {:invalid_argument,
      "registry.#{action} is a person's act — sign in; an API key cannot do it"}}
  end

  def handle(%Context{} = ctx, %{"action" => action} = args)
      when action in @identity_mutations do
    handle_gated(ctx, args)
  end

  def handle(%Context{} = ctx, %{"action" => "whoami"}) do
    case Compendium.Registry.Identity.identity(ctx) do
      {:error, _unavailable} = refusal -> refusal
      identity -> {:ok, identity}
    end
  end

  # A handle claim issues no credential: the registry binds the handle to
  # the identifier the request is signed under and answers it, the same
  # again for a repeat by the same identifier, so a claim whose answer was
  # lost is recorded by the next one.
  def handle(%Context{user_id: user_id} = ctx, %{"action" => "claim_personal", "handle" => handle})
      when is_binary(user_id) do
    with :ok <- valid_handle(handle),
         {:ok, answer} <- Client.signed(user_id, "handle.claim", %{"handle" => handle}),
         :ok <- claimed(answer, handle),
         {:ok, _fresh} <- record_claim(ctx, answer) do
      {:ok, answer}
    else
      {:error, reason} -> refuse(reason)
    end
  end

  def handle(_ctx, %{"action" => "get_namespace", "slug" => slug}) do
    case Compendium.Registry.Client.get_namespace(slug) do
      {:ok, body} -> {:ok, body}
      {:error, err} -> refuse(err)
    end
  end

  def handle(%Context{} = ctx, %{"action" => "tokens_list", "slug" => slug}) do
    with {:ok, bearer} <- Shared.namespace_bearer(ctx, slug),
         {:ok, body} <- Compendium.Registry.Client.list_tokens(slug, bearer) do
      {:ok, body}
    else
      {:error, err} -> refuse(err)
    end
  end

  def handle(%Context{} = ctx, %{"action" => "members_list", "slug" => slug}) do
    with {:ok, bearer} <- Shared.namespace_bearer(ctx, slug),
         {:ok, body} <- Compendium.Registry.Client.list_members(slug, bearer) do
      {:ok, body}
    else
      {:error, err} -> refuse(err)
    end
  end

  # User-side abuse report submission. Auth: any push token belonging to the
  # caller — the head of the caller's stored push tokens. At
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
      {:error, err} -> refuse(err)
    end
  end

  # list_my_reports returns the caller's filed abuse reports from cyfr.run.
  # Resolves any available push token (the same head-of-list choice) and hits
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
      {:error, err} -> refuse(err)
    end
  end

  def handle(_ctx, %{"action" => "legal_page", "name" => name})
      when is_binary(name) and name != "" do
    case Compendium.Registry.Client.get_legal_page(name) do
      {:ok, body} -> {:ok, body}
      {:error, err} -> refuse(err)
    end
  end

  def handle(_ctx, %{"action" => "legal_page"}) do
    {:error,
     {:invalid_argument,
      "name (one of: terms, privacy, aup, content-policy, dmca, cookies, transparency) is required"}}
  end

  def handle(_ctx, %{"action" => "legal_version"}) do
    case Compendium.Registry.Client.get_legal_version() do
      {:ok, body} -> {:ok, body}
      {:error, err} -> refuse(err)
    end
  end

  def handle(%Context{user_id: user_id}, %{
        "action" => "legal_accept",
        "policy_version" => version
      })
      when is_binary(user_id) do
    with :ok <- ensure_present(version, "policy_version"),
         {:ok, answer} <- Client.signed(user_id, "policy.accept", %{"policy_version" => version}) do
      {:ok, answer}
    else
      {:error, reason} -> refuse(reason)
    end
  end

  def handle(%Context{user_id: user_id}, %{"action" => "appeal"} = args)
      when is_binary(user_id) do
    body = Map.take(args, ~w(action_type action_ref argument))

    with :ok <- ensure_present(body["action_type"], "action_type"),
         :ok <- ensure_present(body["action_ref"], "action_ref"),
         :ok <- ensure_present(body["argument"], "argument"),
         {:ok, answer} <- Client.signed(user_id, "appeal.file", body) do
      {:ok, answer}
    else
      {:error, reason} -> refuse(reason)
    end
  end

  def handle(_ctx, %{"action" => action}) when action in ~w(claim_personal legal_accept appeal),
    do: {:error, {:invalid_argument, "authentication required"}}

  # ============================================================================
  # Private helpers
  # ============================================================================

  # Every registry call answers through one seam: a registry's own error
  # becomes its refusal here, and any other reason is the gate's to
  # classify.
  defp refuse(reason), do: {:error, Shared.refusal(reason)}

  defp put_if_int(kw, key, n) when is_integer(n) and n >= 0, do: Keyword.put(kw, key, n)

  defp put_if_int(kw, _key, _), do: kw

  defp valid_handle(handle) do
    if Prima.ComponentRef.valid_personal_slug?(handle),
      do: :ok,
      else: {:error, {:invalid_argument, "That is not a handle the registry takes"}}
  end

  # The claim is the person's namespace from here on, so it lands on their
  # users row, and only while the caller still stands and the answer names
  # their identifier (`Sanctum.SignIn.record_claim/2`): a store that cannot
  # answer, or a remote person whose identity could not be confirmed fresh,
  # is a "try again" and the session stands, and any other standing refusal
  # is a caller no longer signed in. A namespace this server cannot record
  # is a refusal; the handle stays claimed at the registry, and a repeated
  # claim records it.
  defp record_claim(ctx, answer) do
    case Sanctum.SignIn.record_claim(ctx, answer) do
      {:ok, fresh} ->
        {:ok, fresh}

      {:error, reason}
      when reason in [
             :unauthenticated,
             :unavailable,
             :identity_stale,
             :malformed_answer,
             :not_owner
           ] ->
        {:error, reason}

      {:error, :namespace_owned_by_another_identity} ->
        {:error,
         {:conflict,
          "That handle is yours at cyfr.run, but another person on this server already " <>
            "holds that namespace — ask the operator."}}

      {:error, reason} ->
        require Logger

        Logger.error(
          "[Compendium.Providers.Registry] claim_personal: a handle claimed at cyfr.run for " <>
            "#{ctx.user_id} was not recorded locally: #{inspect(reason)}"
        )

        {:error, {:unavailable, "Storage"}}
    end
  end

  # ============================================================================
  # Abuse-report helpers
  # ============================================================================

  defp ensure_present(value, _field) when is_binary(value) and value != "", do: :ok
  defp ensure_present(_, field), do: {:error, {:invalid_argument, "'#{field}' is required"}}

  defp ensure_target(nil, nil),
    do:
      {:error,
       {:invalid_argument, "at least one of target_namespace or target_component_ref required"}}

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
    with {:ok, %Prima.ComponentRef{} = r} <- Prima.ComponentRef.parse(ref),
         :ok <- Shared.ensure_fully_qualified(r),
         {:ok, comp} <-
           Compendium.Registry.Client.get_component(
             Sanctum.system_context(),
             r.type,
             r.namespace,
             r.name,
             r.version
           ) do
      {:ok, comp["id"]}
    end
  end

  # First push token the caller holds — for non-namespace-scoped actions like
  # abuse-report submission: the head of the caller's stored push tokens.
  defp any_push_token(%Sanctum.Context{user_id: user_id} = ctx)
       when is_binary(user_id) and user_id != "" do
    case push_tokens(ctx) do
      {:ok, [%{token: token} | _]} ->
        {:ok, token}

      {:ok, []} ->
        {:error, {:invalid_argument, "no push token available — run `cyfr registry sync`"}}

      {:error, _refused} = refusal ->
        refusal
    end
  end

  defp any_push_token(_), do: {:error, {:invalid_argument, "authentication required"}}

  # The caller's usable push tokens, personal first — the head is the
  # bearer the head-of-list heuristics above pick. A row that cannot be
  # opened refuses as the damaged credential it is, and a store that
  # cannot be read as unavailable: neither picks another bearer.
  defp push_tokens(ctx) do
    registry = Compendium.RegistryHost.canonical_host()

    case Compendium.Registry.CredentialStore.list_for_user(ctx, registry) do
      {:ok, entries} -> Compendium.Registry.CredentialStore.push_tokens(entries)
      {:error, _unreadable} -> {:error, {:unavailable, "Registry credentials"}}
    end
  end

  # ============================================================================
  # Gated identity mutations (dispatched from the @identity_mutations head)
  # ============================================================================

  defp handle_gated(%Context{user_id: user_id}, %{"action" => "claim_publisher", "slug" => slug})
       when is_binary(user_id) do
    case Client.signed(user_id, "publisher.claim", %{"slug" => slug}) do
      {:ok, answer} -> {:ok, answer}
      {:error, reason} -> refuse(reason)
    end
  end

  # The verification mints the founding member's push token, so it is
  # confirmed fresh before the registry is asked, and the token it answers
  # is stored. A repeat of a verification the registry already recorded
  # answers it verified with no token and mints nothing; `sync` then mints
  # the token.
  defp handle_gated(%Context{user_id: user_id} = ctx, %{
         "action" => "verify_publisher",
         "slug" => slug
       })
       when is_binary(user_id) do
    body = %{"slug" => slug, "label" => CredentialStore.wire_label()}

    with {:ok, _host} <- Sanctum.registry_host(),
         :ok <- confirm(ctx, "registry.verify_publisher", body),
         {:ok, answer} <- Client.signed(user_id, "publisher.verify", body),
         {:ok, token} <- verified(answer, slug),
         {:ok, fresh} <- still_standing(ctx),
         :ok <- store_tokens(fresh, List.wrap(token && {slug, token, "admin"})) do
      {:ok, %{slug: slug, token_stored: token != nil}}
    else
      {:error, reason} -> refuse(reason)
    end
  end

  # Every push token the person's namespaces publish with, minted again
  # (`tokens.mint`) under a fresh confirmation and stored, and the personal
  # namespace the registry names recorded. The answer is read whole before
  # anything is written, and names each namespace and never a token.
  defp handle_gated(%Context{user_id: user_id} = ctx, %{"action" => "sync"})
       when is_binary(user_id) do
    label = CredentialStore.wire_label()

    with {:ok, _host} <- Sanctum.registry_host(),
         :ok <- confirm(ctx, "registry.sync", %{"label" => label}),
         {:ok, answer} <- Client.signed(user_id, "tokens.mint", %{"label" => label}),
         {:ok, %{personal: personal, memberships: memberships}} <- minted(answer),
         {:ok, fresh} <- still_standing(ctx),
         :ok <- record_personal(user_id, personal),
         :ok <- store_tokens(fresh, List.wrap(personal) ++ memberships) do
      {:ok,
       %{
         personal_namespace: personal && elem(personal, 0),
         memberships: for({slug, _token, role} <- memberships, do: %{slug: slug, role: role})
       }}
    else
      {:error, reason} -> refuse(reason)
    end
  end

  # A push token outlives the session that asks for it: the issuing is
  # confirmed fresh (`Sanctum.RegistryCredentials.confirm_issuance/4`)
  # once the caller is known to hold the namespace's bearer, and before
  # the registry is asked. The label is settled first, so the preview
  # names the one the token will carry.
  defp handle_gated(%Context{} = ctx, %{"action" => "tokens_issue", "slug" => slug} = args) do
    label = Map.get(args, "label") || Compendium.Registry.CredentialStore.device_label()
    registry = Compendium.RegistryHost.canonical_host()

    with {:ok, bearer} <- Shared.namespace_bearer(ctx, slug),
         :ok <-
           Sanctum.RegistryCredentials.confirm_issuance(ctx, "registry.tokens_issue", registry, %{
             "slug" => slug,
             "label" => label
           }),
         {:ok, body} <- Compendium.Registry.Client.issue_additional_token(slug, bearer, label) do
      {:ok, body}
    else
      {:error, err} -> refuse(err)
    end
  end

  defp handle_gated(%Context{} = ctx, %{
         "action" => "tokens_revoke",
         "slug" => slug,
         "token_id" => token_id
       }) do
    with {:ok, bearer} <- Shared.namespace_bearer(ctx, slug),
         :ok <- Compendium.Registry.Client.revoke_token(slug, token_id, bearer) do
      {:ok, %{revoked: token_id}}
    else
      {:error, err} -> refuse(err)
    end
  end

  defp handle_gated(%Context{} = ctx, %{
         "action" => "members_add",
         "slug" => slug,
         "target_personal_slug" => target,
         "role" => role
       }) do
    with {:ok, bearer} <- Shared.namespace_bearer(ctx, slug),
         {:ok, body} <- Compendium.Registry.Client.add_member(slug, target, role, bearer) do
      {:ok, body}
    else
      {:error, err} -> refuse(err)
    end
  end

  defp handle_gated(%Context{} = ctx, %{
         "action" => "members_update",
         "slug" => slug,
         "target_personal_slug" => target,
         "role" => role
       }) do
    with {:ok, bearer} <- Shared.namespace_bearer(ctx, slug),
         {:ok, body} <- Compendium.Registry.Client.update_member(slug, target, role, bearer) do
      {:ok, body}
    else
      {:error, err} -> refuse(err)
    end
  end

  defp handle_gated(%Context{} = ctx, %{
         "action" => "members_remove",
         "slug" => slug,
         "target_personal_slug" => target
       }) do
    with {:ok, bearer} <- Shared.namespace_bearer(ctx, slug),
         :ok <- Compendium.Registry.Client.remove_member(slug, target, bearer) do
      {:ok, %{removed: target}}
    else
      {:error, err} -> refuse(err)
    end
  end

  defp handle_gated(_ctx, _args), do: {:error, {:invalid_argument, "authentication required"}}

  defp confirm(ctx, operation, arguments) do
    Sanctum.RegistryCredentials.confirm_issuance(
      ctx,
      operation,
      Compendium.RegistryHost.canonical_host(),
      arguments
    )
  end

  # The registry answered after a round trip: the caller's standing is
  # read again before anything is written under it, so a session, key or
  # device revoked meanwhile stores nothing.
  defp still_standing(ctx) do
    case Sanctum.Caller.revalidate_session(ctx) do
      {:ok, fresh} -> {:ok, fresh}
      {:error, reason} when reason in [:unavailable, :identity_stale] -> {:error, reason}
      {:error, _reason} -> {:error, :unauthenticated}
    end
  end

  # The answers that write, each read whole against its shape before
  # anything is written: a key of the wrong type, a token that is no
  # non-empty text or a slug outside its grammar is `:malformed_answer`,
  # and nothing is written. An absent key is the one spelling of none; a
  # null is malformed.

  # `tokens.mint`: `memberships` a list, `personal_namespace` absent when
  # there is none, each entry a namespace, a role and its token.
  defp minted(%{"memberships" => memberships} = answer) when is_list(memberships) do
    with {:ok, personal} <- minted_personal(answer),
         {:ok, memberships} <- minted_memberships(memberships) do
      {:ok, %{personal: personal, memberships: memberships}}
    end
  end

  defp minted(_answer), do: {:error, :malformed_answer}

  defp minted_personal(%{"personal_namespace" => %{"slug" => slug, "token" => token}})
       when is_binary(slug) do
    if Prima.ComponentRef.valid_personal_slug?(slug) and token?(token),
      do: {:ok, {slug, token, "personal"}},
      else: {:error, :malformed_answer}
  end

  defp minted_personal(%{"personal_namespace" => _malformed}), do: {:error, :malformed_answer}
  defp minted_personal(_none), do: {:ok, nil}

  defp minted_memberships(memberships) do
    Enum.reduce_while(memberships, {:ok, []}, fn
      %{"slug" => slug, "role" => role, "token" => token}, {:ok, acc}
      when is_binary(slug) and is_binary(role) and role != "" ->
        if Prima.ComponentRef.validate_namespace(slug) == :ok and token?(token),
          do: {:cont, {:ok, acc ++ [{slug, token, role}]}},
          else: {:halt, {:error, :malformed_answer}}

      _malformed, _acc ->
        {:halt, {:error, :malformed_answer}}
    end)
  end

  # `handle.claim`: the handle asked for and an identifier, which
  # `Sanctum.SignIn.record_claim/2` holds to the caller's own.
  defp claimed(%{"handle" => handle, "identifier" => identifier}, handle)
       when is_binary(identifier),
       do: :ok

  defp claimed(_answer, _handle), do: {:error, :malformed_answer}

  # `publisher.verify`: the namespace asked for, and the founding member's
  # token only when one was minted.
  defp verified(%{"slug" => slug} = answer, slug) do
    case Map.fetch(answer, "token") do
      :error -> {:ok, nil}
      {:ok, token} -> if token?(token), do: {:ok, token}, else: {:error, :malformed_answer}
    end
  end

  defp verified(_answer, _slug), do: {:error, :malformed_answer}

  defp token?(token), do: is_binary(token) and token != ""

  # The personal namespace a mint answers, recorded on the person's row
  # (`Sanctum.SignIn.record_namespace/2`) before its token is stored.
  defp record_personal(_user_id, nil), do: :ok

  defp record_personal(user_id, {slug, _token, _role}) do
    case Sanctum.SignIn.record_namespace(user_id, slug) do
      {:ok, _user} -> :ok
      {:error, :namespace_owned_by_another_identity} -> record_claim_conflict()
      {:error, :not_owner} -> {:error, :not_owner}
      {:error, :invalid_slug} -> {:error, :malformed_answer}
      {:error, _unanswered} -> {:error, {:unavailable, "Storage"}}
    end
  end

  defp record_claim_conflict do
    {:error,
     {:conflict,
      "Your handle at cyfr.run names a namespace another person on this server already " <>
        "holds — ask the operator."}}
  end

  # Each `{slug, token, role}` stored for the caller, each a holder's write
  # (`Arca.RegistryTokenStorage.put/1`). A member whose slot was taken
  # stores nothing more and refuses `:not_owner`; a store that cannot take
  # a token refuses as unavailable, the tokens before it kept, and a sync
  # mints them again.
  defp store_tokens(ctx, entries) do
    registry = Compendium.RegistryHost.canonical_host()

    Enum.reduce_while(entries, :ok, fn {slug, token, role}, :ok ->
      case CredentialStore.put_push_token(ctx, registry, slug, token, role) do
        :ok -> {:cont, :ok}
        {:error, :not_owner} -> {:halt, {:error, :not_owner}}
        {:error, _unstored} -> {:halt, {:error, {:unavailable, "Registry credentials"}}}
      end
    end)
  end
end
