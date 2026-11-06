# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Providers.Registry do
  @moduledoc """
  Registry tool handlers for the Compendium MCP provider: a person's
  namespaces at cyfr.run, push tokens, members, abuse reports, the
  registry's policies and appeals. A person's name is claimed where their
  account is made, at the account pages.

  Every operation that speaks for the person at the registry (a token
  mint, a policy acceptance, an appeal, a publisher claim and its
  verification) is one request a key of their account signs; this CYFR
  holds none, so each is refused (`Compendium.Registry.Client.signed/3`)
  before anything is sent. *Not built yet:* such a request signed by the
  person's device or by their passkey at the account pages. Namespace
  administration (tokens, members) stays under the namespace's stored
  push token.
  """

  alias Sanctum.Context
  alias Compendium.Providers.Shared
  alias Compendium.Registry.{Client, CredentialStore}

  @identity_mutations ~w(claim_publisher verify_publisher tokens_issue tokens_revoke members_add members_update members_remove sync)

  # The signed operations the `signed_in` tier serves, before a person
  # holds a name: a key belongs to an athanor and is nobody's registry
  # identity, so their handlers refuse one. The rest declare
  # `consent: :interactive`, which refuses a key at the gate.
  @person_acts ~w(legal_accept)

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
        "cyfr.run registry operations, each a request your identity signs: sync your push tokens, claim and verify a publisher namespace by DNS, accept the registry's policies and file appeals; and manage additional push tokens and members, and inspect registry-side identity. Separate from `session` (local cyfr identity).",
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
    case ensure_present(version, "policy_version") do
      :ok -> signed(user_id, "policy.accept", %{"policy_version" => version})
      {:error, reason} -> refuse(reason)
    end
  end

  def handle(%Context{user_id: user_id}, %{"action" => "appeal"} = args)
      when is_binary(user_id) do
    body = Map.take(args, ~w(action_type action_ref argument))

    with :ok <- ensure_present(body["action_type"], "action_type"),
         :ok <- ensure_present(body["action_ref"], "action_ref"),
         :ok <- ensure_present(body["argument"], "argument") do
      signed(user_id, "appeal.file", body)
    else
      {:error, reason} -> refuse(reason)
    end
  end

  def handle(_ctx, %{"action" => action}) when action in ~w(legal_accept appeal),
    do: {:error, {:invalid_argument, "authentication required"}}

  # ============================================================================
  # Private helpers
  # ============================================================================

  # Every registry call answers through one seam: a registry's own error
  # becomes its refusal here, and any other reason is the gate's to
  # classify.
  defp refuse(reason), do: {:error, Shared.refusal(reason)}

  # A request a key of the person's account signs, which this CYFR
  # cannot make (`Compendium.Registry.Client.signed/3`).
  defp signed(user_id, operation, body) do
    {:error, reason} = Client.signed(user_id, operation, body)
    refuse(reason)
  end

  defp put_if_int(kw, key, n) when is_integer(n) and n >= 0, do: Keyword.put(kw, key, n)

  defp put_if_int(kw, _key, _), do: kw

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
       when is_binary(user_id),
       do: signed(user_id, "publisher.claim", %{"slug" => slug})

  # The verification would mint the founding member's push token, and
  # the sync every push token of the person's namespaces: each is a
  # request a key of the person's account signs.
  defp handle_gated(%Context{user_id: user_id}, %{
         "action" => "verify_publisher",
         "slug" => slug
       })
       when is_binary(user_id) do
    case Sanctum.registry_host() do
      {:ok, _host} ->
        signed(user_id, "publisher.verify", %{
          "slug" => slug,
          "label" => CredentialStore.wire_label()
        })

      {:error, reason} ->
        refuse(reason)
    end
  end

  defp handle_gated(%Context{user_id: user_id}, %{"action" => "sync"})
       when is_binary(user_id) do
    case Sanctum.registry_host() do
      {:ok, _host} -> signed(user_id, "tokens.mint", %{"label" => CredentialStore.wire_label()})
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
end
