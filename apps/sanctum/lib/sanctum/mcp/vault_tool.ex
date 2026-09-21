# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.MCP.VaultTool do
  @moduledoc """
  Vault tool handlers for the Sanctum MCP provider — thin argument
  mapping over `Sanctum.Vault`, which owns every rule. External plane
  only: guests have no enumeration API and no vault verbs.

  Material flows one way: `create` and `rotate` accept field values,
  nothing ever returns them.
  """

  alias Sanctum.Context

  require Logger
  alias Sanctum.Vault

  @doc false
  # The tool's wire definition — schema and access annotations beside the
  # handler they gate; Sanctum.MCP assembles its roster from these.
  def definition do
    alias Cyfr.Ops.{Arg, Operation}
    # Mutations are interactive-consent surfaces (OIDC sessions only,
    # by owner decision — no permission conjunct); list admits the
    # staging class so keys can enumerate entries.
    Operation.tool(
      [
        Operation.new("vault", "list", "List vault", [],
          kind: :read,
          planes: [:external],
          consent: :staging
        ),
        Operation.new(
          "vault",
          "create",
          "Create vault",
          [
            Arg.new("name", :string,
              required: true,
              description: "Entry label — unique among living entries in the tenant"
            ),
            Arg.new("kind", :string,
              required: true,
              description: "What the entry holds",
              enum: ["api_key", "oauth", "bundle"]
            ),
            Arg.new("fields", {:map, Arg.new(nil, :string)},
              description: "Secret material as name → value; names mirror field_names"
            ),
            Arg.new("provider_hint", :string,
              description: "Immutable provider tag (e.g. 'google'); set at create only"
            ),
            Arg.new("oauth_scopes", {:array, Arg.new(nil, :string)},
              description: "Binding field: scopes this credential was authorized for"
            ),
            Arg.new(
              "oauth_endpoints",
              {:record,
               [
                 Arg.new("authorize_url", :string),
                 Arg.new("token_url", :string),
                 Arg.new("provider", :string),
                 Arg.new("auth_style", :string, enum: ["params", "header"]),
                 Arg.new("extra_params", {:map, Arg.new(nil, :string)})
               ]}
            )
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "vault",
          "rename",
          "Rename vault",
          [
            Arg.new("id", :string, required: true, description: "Vault entry id (vlt_…)"),
            Arg.new("name", :string,
              required: true,
              description: "Entry label — unique among living entries in the tenant"
            )
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "vault",
          "rotate",
          "Rotate vault",
          [
            Arg.new("id", :string, required: true, description: "Vault entry id (vlt_…)"),
            Arg.new("fields", {:map, Arg.new(nil, :string)},
              required: true,
              description: "Secret material as name → value; names mirror field_names"
            ),
            Arg.new("expected_payload_rev", :integer,
              required: true,
              description: "CAS token for rotate — the revision the caller last saw"
            )
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "vault",
          "rebind",
          "Rebind vault",
          [
            Arg.new("id", :string, required: true, description: "Vault entry id (vlt_…)"),
            Arg.new("field_names", {:array, Arg.new(nil, :string)},
              description: "Binding field: the material's field schema (rebind only)"
            ),
            Arg.new("oauth_scopes", {:array, Arg.new(nil, :string)},
              description: "Binding field: scopes this credential was authorized for"
            ),
            Arg.new(
              "oauth_endpoints",
              {:record,
               [
                 Arg.new("authorize_url", :string),
                 Arg.new("token_url", :string),
                 Arg.new("provider", :string),
                 Arg.new("auth_style", :string, enum: ["params", "header"]),
                 Arg.new("extra_params", {:map, Arg.new(nil, :string)})
               ]}
            )
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "vault",
          "authorize",
          "Authorize vault",
          [
            Arg.new("id", :string, description: "Vault entry id (vlt_…)"),
            Arg.new("name", :string,
              description: "Entry label — unique among living entries in the tenant"
            ),
            Arg.new("provider_hint", :string,
              description: "Immutable provider tag (e.g. 'google'); set at create only"
            ),
            Arg.new("oauth_scopes", {:array, Arg.new(nil, :string)},
              description: "Binding field: scopes this credential was authorized for"
            ),
            Arg.new(
              "oauth_endpoints",
              {:record,
               [
                 Arg.new("authorize_url", :string),
                 Arg.new("token_url", :string),
                 Arg.new("provider", :string),
                 Arg.new("auth_style", :string, enum: ["params", "header"]),
                 Arg.new("extra_params", {:map, Arg.new(nil, :string)})
               ]}
            )
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "vault",
          "revoke",
          "Revoke vault",
          [Arg.new("id", :string, required: true, description: "Vault entry id (vlt_…)")],
          kind: :destructive,
          planes: [:external],
          consent: :interactive
        ),
        Operation.new(
          "vault",
          "delete",
          "Delete vault",
          [Arg.new("id", :string, required: true, description: "Vault entry id (vlt_…)")],
          kind: :destructive,
          planes: [:external],
          consent: :interactive
        )
      ],
      description:
        "Manage vault entries — the operator's credentials, shared across profiles through consent edges. Material is sealed at rest and never read back; rotate replaces material without re-consent, rebind changes what the credential talks to and blocks affected profiles until re-consented.",
      title: "Vault"
    )
  end

  def handle(%Context{} = ctx, %{"action" => "list"}) do
    # Enumeration is operator data: the same surfaces that can walk the
    # consent flow may see connection names, nothing else. The registry
    # gate already applies consent: :staging from the annotation — this
    # arm is deliberate defense in depth for direct callers of the handler.
    with :ok <- Sanctum.Consent.Authz.authorize_staging(ctx),
         {:ok, entries} <- Vault.list(ctx) do
      {:ok, %{entries: entries}}
    else
      {:error, reason} -> {:error, fmt(reason)}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "create", "name" => name, "kind" => kind} = args) do
    params =
      %{name: name, kind: kind, fields: Map.get(args, "fields", %{})}
      |> Cyfr.MapUtil.put_present(:provider_hint, args["provider_hint"])
      |> Cyfr.MapUtil.put_present(:oauth_endpoints, args["oauth_endpoints"])
      |> Cyfr.MapUtil.put_present(:oauth_scopes, args["oauth_scopes"])

    case Vault.create(ctx, params) do
      {:ok, view} -> {:ok, %{entry: view}}
      {:error, reason} -> {:error, fmt(reason)}
    end
  end

  def handle(_ctx, %{"action" => "create"}) do
    {:error, {:invalid_argument, "create requires name and kind (api_key | oauth | bundle)"}}
  end

  def handle(%Context{} = ctx, %{"action" => "rename", "id" => id, "name" => name}) do
    case Vault.rename(ctx, id, name) do
      :ok -> {:ok, %{status: "renamed", id: id, name: name}}
      {:error, reason} -> {:error, fmt(reason)}
    end
  end

  def handle(_ctx, %{"action" => "rename"}) do
    {:error, {:invalid_argument, "rename requires id and name"}}
  end

  def handle(%Context{} = ctx, %{
        "action" => "rotate",
        "id" => id,
        "fields" => fields,
        "expected_payload_rev" => expected
      })
      when is_map(fields) and is_integer(expected) do
    case Vault.rotate(ctx, %{id: id, fields: fields, expected_payload_rev: expected}) do
      {:ok, new_rev} -> {:ok, %{status: "rotated", id: id, payload_rev: new_rev}}
      {:error, reason} -> {:error, fmt(reason)}
    end
  end

  def handle(_ctx, %{"action" => "rotate"}) do
    {:error,
     {:invalid_argument, "rotate requires id, fields and expected_payload_rev (the CAS token)"}}
  end

  # Start a browser OAuth grant for a vault entry: `id` re-authorizes an
  # existing oauth entry; `name` + `provider_hint` (+ optional
  # `oauth_scopes` / `oauth_endpoints`) mints a new one on completion.
  def handle(%Context{} = ctx, %{"action" => "authorize"} = args) do
    params =
      case args do
        %{"id" => id} when is_binary(id) ->
          %{entry_id: id}

        %{"name" => name, "provider_hint" => provider} ->
          %{
            name: name,
            provider: provider,
            scopes: Map.get(args, "oauth_scopes", []),
            endpoints: args["oauth_endpoints"]
          }

        _ ->
          :invalid
      end

    with %{} <- params,
         {:ok, result} <- Sanctum.Vault.OAuthGrant.authorize_url(ctx, params) do
      {:ok, %{url: result.url, state: result.state}}
    else
      :invalid ->
        {:error,
         {:invalid_argument,
          "authorize requires id (re-auth) or name + provider_hint (new connection)"}}

      {:error, reason} ->
        {:error, fmt(reason)}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "rebind", "id" => id} = args) do
    params =
      %{id: id}
      |> Cyfr.MapUtil.put_present(:oauth_endpoints, args["oauth_endpoints"])
      |> Cyfr.MapUtil.put_present(:oauth_scopes, args["oauth_scopes"])
      |> Cyfr.MapUtil.put_present(:field_names, args["field_names"])

    case Vault.rebind(ctx, params) do
      {:ok, result} -> {:ok, Map.put(result, :status, "rebound")}
      {:error, reason} -> {:error, fmt(reason)}
    end
  end

  def handle(_ctx, %{"action" => "rebind"}) do
    {:error, {:invalid_argument, "rebind requires id and at least one binding field"}}
  end

  def handle(%Context{} = ctx, %{"action" => "revoke", "id" => id}) do
    case Vault.revoke(ctx, id) do
      {:ok, result} -> {:ok, Map.put(result, :status, "revoked")}
      {:error, reason} -> {:error, fmt(reason)}
    end
  end

  def handle(_ctx, %{"action" => "revoke"}) do
    {:error, {:invalid_argument, "revoke requires id"}}
  end

  def handle(%Context{} = ctx, %{"action" => "delete", "id" => id}) do
    case Vault.delete(ctx, id) do
      :ok -> {:ok, %{status: "deleted", id: id}}
      {:error, reason} -> {:error, fmt(reason)}
    end
  end

  def handle(_ctx, %{"action" => "delete"}) do
    {:error, {:invalid_argument, "delete requires id"}}
  end

  def handle(_ctx, _args) do
    {:error, Cyfr.Ops.Provider.invalid_action("vault", action_enum())}
  end

  # ---------------------------------------------------------------------------

  defp fmt({:surface_not_permitted, method}) do
    "consent_class_required: vault mutations need an interactive (:oidc) session, got #{method}"
  end

  defp fmt(:guest_plane),
    do: "consent_class_required: guest-plane contexts cannot reach the vault"

  defp fmt(:name_taken), do: "name_taken: a living entry already holds that name"

  defp fmt(:payload_conflict),
    do: "payload_conflict: re-read the entry and retry with its revision"

  defp fmt(:schema_change_requires_rebind),
    do: "schema_change_requires_rebind: rotate keeps the field schema; use rebind to change it"

  defp fmt(:oauth_pointer_requires_reauth),
    do: "oauth_pointer_requires_reauth: re-authorize the provider to convert this entry"

  defp fmt(:not_found), do: "not_found"

  defp fmt(:name_required), do: "name_required: an entry needs a name"

  defp fmt(:no_binding_changes),
    do: "no_binding_changes: rebind needs at least one field to change"

  defp fmt(:binding_moved),
    do: "binding_moved: the entry was rebound since you read it; re-read and retry"

  defp fmt({:entry_unavailable, status}),
    do: "entry_unavailable: the entry is #{status}"

  # A reason this tool has no sentence for is not rendered here: a typed
  # refusal travels as data and each surface says it in its own words
  # (the external wire, the console, the in-chain guest view). What the
  # vault still owns is the sanitizing — an internal reason on THIS
  # surface can carry credential material, and a renderer that inspects
  # an unknown term would spell it out — so the term is logged sanitized
  # and bounded here, and what leaves is one word carrying none of it.
  defp fmt(reason) do
    Logger.warning(
      "[VaultTool] unrenderable reason: " <>
        inspect(Cyfr.Sanitizer.sanitize(reason), limit: 20, printable_limit: 200)
    )

    {:unavailable, "Vault"}
  end

  defp action_enum, do: Cyfr.Ops.Provider.action_enum(definition())
end
