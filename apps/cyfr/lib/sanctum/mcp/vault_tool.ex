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
  alias Sanctum.Vault

  @doc false
  # The tool's wire definition — schema and access annotations beside the
  # handler they gate; Sanctum.MCP assembles its roster from these.
  def definition do
    %{
      name: "vault",
      title: "Vault Connections",
      description:
        "Manage vault entries (Connections) — the operator's credentials, shared across " <>
          "profiles through consent edges. Material is sealed at rest and never read back; " <>
          "rotate replaces material without re-consent, rebind changes what the credential " <>
          "talks to and blocks affected profiles until re-consented.",
      annotations: %{
        readOnlyHint: false,
        destructiveHint: true,
        actions: %{
          # Mutations are interactive-consent surfaces (OIDC sessions only,
          # by owner decision — no permission conjunct); list admits the
          # staging class so keys can enumerate entries.
          "list" => %{kind: :read, planes: [:external], consent: :staging},
          "create" => %{kind: :write, planes: [:external], consent: :interactive},
          "rename" => %{kind: :write, planes: [:external], consent: :interactive},
          "rotate" => %{kind: :write, planes: [:external], consent: :interactive},
          "rebind" => %{kind: :write, planes: [:external], consent: :interactive},
          "authorize" => %{kind: :write, planes: [:external], consent: :interactive},
          "revoke" => %{kind: :destructive, planes: [:external], consent: :interactive},
          "delete" => %{kind: :destructive, planes: [:external], consent: :interactive}
        }
      },
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "action" => %{
            "type" => "string",
            "enum" => [
              "list",
              "create",
              "rename",
              "rotate",
              "rebind",
              "authorize",
              "revoke",
              "delete"
            ],
            "description" => "Action to perform"
          },
          "id" => %{"type" => "string", "description" => "Vault entry id (vlt_…)"},
          "name" => %{
            "type" => "string",
            "description" => "Connection label — unique among living entries in the tenant"
          },
          "kind" => %{
            "type" => "string",
            "enum" => ["api_key", "oauth", "bundle"],
            "description" => "What the entry holds"
          },
          "provider_hint" => %{
            "type" => "string",
            "description" => "Immutable provider tag (e.g. 'google'); set at create only"
          },
          "fields" => %{
            "type" => "object",
            "description" => "Secret material as name → value; names mirror field_names"
          },
          "expected_payload_rev" => %{
            "type" => "integer",
            "description" => "CAS token for rotate — the revision the caller last saw"
          },
          "oauth_endpoints" => %{
            "type" => "object",
            "description" => "Binding field: token endpoint etc. Changing it is a rebind."
          },
          "oauth_scopes" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Binding field: scopes this credential was authorized for"
          },
          "field_names" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Binding field: the material's field schema (rebind only)"
          }
        },
        "required" => ["action"]
      }
    }
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
    {:error, "create requires name and kind (api_key | oauth | bundle)"}
  end

  def handle(%Context{} = ctx, %{"action" => "rename", "id" => id, "name" => name}) do
    case Vault.rename(ctx, id, name) do
      :ok -> {:ok, %{status: "renamed", id: id, name: name}}
      {:error, reason} -> {:error, fmt(reason)}
    end
  end

  def handle(_ctx, %{"action" => "rename"}) do
    {:error, "rename requires id and name"}
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
    {:error, "rotate requires id, fields and expected_payload_rev (the CAS token)"}
  end

  # Start a browser OAuth grant for a Connection: `id` re-authorizes an
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
        {:error, "authorize requires id (re-auth) or name + provider_hint (new connection)"}

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
    {:error, "rebind requires id and at least one binding field"}
  end

  def handle(%Context{} = ctx, %{"action" => "revoke", "id" => id}) do
    case Vault.revoke(ctx, id) do
      {:ok, result} -> {:ok, Map.put(result, :status, "revoked")}
      {:error, reason} -> {:error, fmt(reason)}
    end
  end

  def handle(_ctx, %{"action" => "revoke"}) do
    {:error, "revoke requires id"}
  end

  def handle(%Context{} = ctx, %{"action" => "delete", "id" => id}) do
    case Vault.delete(ctx, id) do
      :ok -> {:ok, %{status: "deleted", id: id}}
      {:error, reason} -> {:error, fmt(reason)}
    end
  end

  def handle(_ctx, %{"action" => "delete"}) do
    {:error, "delete requires id"}
  end

  def handle(_ctx, _args) do
    {:error, Emissary.MCP.ToolProvider.invalid_action("vault", action_enum())}
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
  defp fmt(reason), do: inspect(reason)

  defp action_enum, do: get_in(definition(), [:input_schema, "properties", "action", "enum"])
end
