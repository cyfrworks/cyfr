# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Providers.Vault do
  @moduledoc """
  Vault tool handlers for the Sanctum MCP provider — thin argument
  mapping over `Sanctum.Vault`, which owns every rule. External plane
  only: guests have no enumeration API and no vault verbs. `list`
  answers the living entries beside the athanor's default per provider,
  an object keyed by provider hint naming one entry by id, and
  `set_default` makes one of the athanor's entries, or an instance entry
  offered to the caller, a provider's default: what a consent suggests,
  binding nothing. `status`
  answers each living entry's name, kind, status, created and updated
  times and whether a consent binds it, under no consent class, and never
  a value or a field.

  Material flows one way: `create` and `rotate` accept field values,
  nothing ever returns them. Every entry names its `destination`, where
  its material may go, and is attach-only unless `disclose` is true:
  `create` requires the destination, `authorize` requires it of a new
  entry, and `rebind` moves it, its disclosure or its field schema.
  """

  alias Sanctum.Context

  require Logger
  require Prima.ConsentSignal
  require Sanctum.Issuance
  alias Sanctum.Vault

  @doc false
  # The tool's wire definition — schema and access annotations beside the
  # handler they gate; Sanctum.Provider assembles its roster from these.
  def definition do
    alias Prima.{Arg, Operation}
    # Mutations are interactive-consent surfaces (OIDC sessions only,
    # by owner decision — no permission conjunct); list admits the
    # staging class so keys can enumerate entries.
    destination = fn opts ->
      Arg.new(
        "destination",
        {:record,
         [
           Arg.new("hosts", {:array, Arg.new(nil, :string)},
             required: true,
             min: 1,
             max: Prima.Destination.max_entries(),
             description: "Hosts the material may go to: exact names, or *. and a name"
           ),
           Arg.new("scheme", :string,
             enum: ["http", "https"],
             description: "https unless http is stated"
           ),
           Arg.new("port", :integer,
             min: 1,
             max: 65_535,
             description: "The port; the scheme's default when absent"
           ),
           Arg.new("methods", {:array, Arg.new(nil, :string, enum: Prima.Destination.methods())},
             min: 1,
             description: "HTTP methods admitted; any when absent"
           ),
           Arg.new("paths", {:array, Arg.new(nil, :string)},
             min: 1,
             max: Prima.Destination.max_entries(),
             description: "Path prefixes admitted, each beginning with /; any when absent"
           )
         ]},
        opts
      )
    end

    disclose = fn description ->
      Arg.new("disclose", :boolean, default: false, description: description)
    end

    Operation.tool(
      [
        Operation.new("vault", "list", "List vault", [],
          kind: :read,
          planes: [:external],
          consent: :staging
        ),
        Operation.new(
          "vault",
          "status",
          "Vault entry status",
          [],
          kind: :read,
          planes: [:external]
        ),
        Operation.new(
          "vault",
          "set_default",
          "Set the default entry of a provider",
          [
            Arg.new("provider_hint", :string,
              required: true,
              description: "The provider whose default this becomes (e.g. 'openai.com')"
            ),
            Arg.new("entry_id", :string,
              description:
                "An entry of the athanor (vlt_…); name exactly one of entry_id and " <>
                  "instance_entry_id"
            ),
            Arg.new("instance_entry_id", :string,
              description:
                "An instance entry offered to you (ine_…); name exactly one of entry_id and " <>
                  "instance_entry_id"
            )
          ],
          kind: :write,
          planes: [:external],
          consent: :interactive
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
            ),
            destination.(
              required: true,
              description: "Binding field: where the material may go — required, never defaulted"
            ),
            disclose.(
              "Binding field: true lets a component read the fields; " <>
                "otherwise they are never handed to a component"
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
            destination.(description: "Binding field: where the material may go"),
            Arg.new("disclose", :boolean,
              description:
                "Binding field: true lets a component read the fields; false makes the " <>
                  "entry attach-only"
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
              description:
                "Scopes to authorize: a new entry's, or a re-authorization's (the one way " <>
                  "an entry's scopes change)"
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
               ]},
              description:
                "A new entry's endpoints, for a provider with no preset; fixed once created"
            ),
            destination.(
              description:
                "A new entry's destination, where its token may go — required for a new entry"
            ),
            disclose.(
              "A new entry's disclosure: true lets a component be dispensed its token; " <>
                "otherwise it is never handed to a component"
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
    # consent flow may see each living entry's metadata (`entry_view`,
    # never material) and the athanor's default per provider. The registry gate already applies consent:
    # :staging from the annotation — this arm is deliberate defense in
    # depth for direct callers of the handler. The entries and their
    # defaults answer together or not at all.
    with :ok <- Sanctum.Consent.Authz.authorize_staging(ctx),
         {:ok, entries} <- Vault.list(ctx),
         {:ok, defaults} <- Vault.defaults(ctx) do
      {:ok, %{entries: entries, defaults: defaults}}
    else
      {:error, reason} -> {:error, fmt(reason)}
    end
  end

  # Each living entry's name, kind, status, created and updated times and
  # whether a consent binds it: a read of standing that carries no
  # material and no field.
  def handle(%Context{} = ctx, %{"action" => "status"}) do
    case Vault.status(ctx) do
      {:ok, entries} -> {:ok, %{entries: Enum.map(entries, &status_json/1)}}
      {:error, reason} -> {:error, fmt(reason)}
    end
  end

  # The default a consent suggests for a provider: one of the athanor's
  # entries or an offered instance entry. It binds nothing.
  def handle(%Context{} = ctx, %{"action" => "set_default"} = args) do
    params =
      %{provider_hint: args["provider_hint"]}
      |> Prima.MapUtil.put_present(:entry_id, args["entry_id"])
      |> Prima.MapUtil.put_present(:instance_entry_id, args["instance_entry_id"])

    case Vault.set_default(ctx, params) do
      {:ok, default} -> {:ok, %{status: "default_set", default: default}}
      {:error, reason} -> {:error, fmt(reason)}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "create", "name" => name, "kind" => kind} = args) do
    params =
      %{name: name, kind: kind, fields: Map.get(args, "fields", %{})}
      |> Prima.MapUtil.put_present(:provider_hint, args["provider_hint"])
      |> Prima.MapUtil.put_present(:oauth_endpoints, args["oauth_endpoints"])
      |> Prima.MapUtil.put_present(:oauth_scopes, args["oauth_scopes"])
      |> Prima.MapUtil.put_present(:destination, args["destination"])
      |> Prima.MapUtil.put_present(:disclose, args["disclose"])

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
  # existing oauth entry (+ optional `oauth_scopes`, the scopes it is
  # re-granted for); `name` + `provider_hint` + `destination` (+ optional
  # `oauth_scopes` / `oauth_endpoints` / `disclose`) mints a new one on
  # completion. Endpoints named beside an `id` go to the grant, which
  # refuses them: an entry's endpoints are fixed, and dropping them would
  # answer a request other than the one made. A destination or a
  # disclosure beside an `id` is refused here for the same reason: an
  # existing entry's are moved by `rebind`.
  def handle(%Context{} = ctx, %{"action" => "authorize"} = args) do
    params =
      case args do
        %{"id" => id} when is_binary(id) ->
          if Map.has_key?(args, "destination") or Map.has_key?(args, "disclose") do
            :rebind_fields
          else
            %{entry_id: id}
            |> Prima.MapUtil.put_present(:endpoints, args["oauth_endpoints"])
            |> Prima.MapUtil.put_present(:scopes, args["oauth_scopes"])
          end

        %{"name" => name, "provider_hint" => provider} ->
          %{
            name: name,
            provider: provider,
            scopes: Map.get(args, "oauth_scopes", []),
            endpoints: args["oauth_endpoints"]
          }
          |> Prima.MapUtil.put_present(:destination, args["destination"])
          |> Prima.MapUtil.put_present(:disclose, args["disclose"])

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
          "authorize requires id (re-auth) or name + provider_hint + destination " <>
            "(new connection)"}}

      :rebind_fields ->
        {:error,
         {:invalid_argument,
          "destination and disclose name a new entry's; change an existing entry's with rebind"}}

      {:error, reason} ->
        {:error, fmt(reason)}
    end
  end

  def handle(%Context{} = ctx, %{"action" => "rebind", "id" => id} = args) do
    # The declaration names no OAuth endpoints or scopes; a caller that
    # hands them to the handler past it is refused for them by the vault
    # (`:endpoints_immutable`, `:scopes_need_reauthorization`), never
    # answered as though it had asked for less.
    params =
      %{id: id}
      |> Prima.MapUtil.put_present(:oauth_endpoints, args["oauth_endpoints"])
      |> Prima.MapUtil.put_present(:oauth_scopes, args["oauth_scopes"])
      |> Prima.MapUtil.put_present(:field_names, args["field_names"])
      |> Prima.MapUtil.put_present(:destination, args["destination"])
      |> Prima.MapUtil.put_present(:disclose, args["disclose"])

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
    {:error, Prima.Provider.invalid_action("vault", action_enum())}
  end

  # ---------------------------------------------------------------------------

  defp status_json(entry) do
    %{
      id: entry.id,
      name: entry.name,
      kind: entry.kind,
      status: entry.status,
      created_at: iso8601(entry.created_at),
      updated_at: iso8601(entry.updated_at),
      bound: entry.bound
    }
  end

  defp iso8601(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp iso8601(_absent), do: nil

  defp fmt({:surface_not_permitted, method}) do
    "consent_class_required: vault mutations need an interactive (:oidc) session, got #{method}"
  end

  defp fmt(:guest_plane),
    do: "consent_class_required: guest-plane contexts cannot reach the vault"

  # A credential entry's own answers (`Sanctum.Consent.Authz`) pass as they
  # are: the confirmation signal, whose id the surface confirms, and the
  # refusals the decision gives.
  defp fmt({tag, payload} = signal) when Prima.ConsentSignal.is_signal(tag, payload), do: signal
  defp fmt(reason) when reason in [:identity_stale, :missing_tenant], do: reason
  defp fmt({:conflict, message} = conflict) when is_binary(message), do: conflict

  defp fmt(:name_taken), do: "name_taken: a living entry already holds that name"

  defp fmt(:payload_conflict),
    do: "payload_conflict: re-read the entry and retry with its revision"

  defp fmt(:schema_change_requires_rebind),
    do: "schema_change_requires_rebind: rotate keeps the field schema; use rebind to change it"

  defp fmt(:oauth_pointer_requires_reauth),
    do: "oauth_pointer_requires_reauth: re-authorize the provider to convert this entry"

  defp fmt(:not_found), do: "not_found"

  defp fmt({:invalid_argument, message} = refusal) when is_binary(message), do: refusal

  defp fmt({:provider_mismatch, hint}) when is_binary(hint),
    do: "provider_mismatch: the entry is not of the provider #{hint}"

  defp fmt(:not_offered), do: "not_offered: that instance entry is not offered to you"

  # The caller's standing, refused where the entry is written
  # (`Sanctum.Issuance`, held from a paired device): a standing refusal in
  # its own sentence, never an unavailable store.
  defp fmt(reason) when Sanctum.Issuance.standing_refusal?(reason),
    do: Sanctum.Issuance.standing_refusal(reason)

  defp fmt(:name_required), do: "name_required: an entry needs a name"

  defp fmt(:destination_required),
    do:
      "destination_required: an entry names where its material may go " <>
        "(destination: hosts, and optionally scheme, port, methods and paths)"

  defp fmt({:invalid_destination, reason}),
    do: "invalid_destination: " <> destination_refusal(reason)

  defp fmt(:invalid_disclose), do: "invalid_disclose: disclose is true or false"

  defp fmt(:no_binding_changes),
    do: "no_binding_changes: rebind needs at least one field to change"

  defp fmt(:binding_moved),
    do: "binding_moved: the entry was rebound since you read it; re-read and retry"

  defp fmt({:entry_unavailable, status}),
    do: "entry_unavailable: the entry is #{status}"

  # An OAuth entry's endpoints, fixed when it is created
  # (`Sanctum.Vault.OAuth`): refusals of the request's own shape, each in
  # its own sentence, never an unavailable vault.
  defp fmt(:endpoints_immutable),
    do:
      "endpoints_immutable: an OAuth entry's endpoints are fixed when it is created; " <>
        "create a new entry for other endpoints"

  defp fmt(:endpoints_preset_conflict),
    do:
      "endpoints_preset_conflict: this provider's endpoints are preset; " <>
        "leave oauth_endpoints out"

  defp fmt(:endpoints_required),
    do:
      "endpoints_required: this provider has no preset; " <>
        "oauth_endpoints must name an authorize_url and a token_url"

  defp fmt(:endpoints_must_use_https),
    do: "endpoints_must_use_https: an authorize_url and a token_url must both use https://"

  defp fmt({:reserved_extra_param, name}) when is_binary(name),
    do:
      "reserved_extra_param: extra_params may not set #{inspect(name)}, " <>
        "which the authorization flow sets itself"

  defp fmt(:scopes_need_reauthorization),
    do:
      "scopes_need_reauthorization: an OAuth entry's scopes are the ones its token was " <>
        "granted for; re-authorize the entry (authorize with its id and the new oauth_scopes)"

  defp fmt(:provider_required),
    do: "provider_required: an OAuth entry names its provider in provider_hint"

  defp fmt(:scopes_required),
    do:
      "scopes_required: a re-authorization names at least one scope, " <>
        "or leaves oauth_scopes out to keep the entry's"

  # A reason this tool has no sentence for is not rendered here: a typed
  # refusal travels as data and each surface says it in its own words
  # (the external wire, the console, the in-chain guest view). What the
  # vault still owns is the sanitizing — an internal reason on THIS
  # surface can carry credential material, and a renderer that inspects
  # an unknown term would spell it out — so the term is logged sanitized
  # and bounded here, and what leaves is one word carrying none of it.
  defp fmt(reason) do
    Logger.warning(
      "[Sanctum.Providers.Vault] unrenderable reason: " <>
        inspect(Prima.Sanitizer.sanitize(reason), limit: 20, printable_limit: 200)
    )

    {:unavailable, "Vault"}
  end

  # The destination grammar's refusal, in fixed words: the offending value
  # is the caller's own input and is not repeated back.
  defp destination_refusal(:hosts_required), do: "it names at least one host"
  defp destination_refusal(:not_a_map), do: "it is an object"
  defp destination_refusal({:unknown_key, _key}), do: "it names an unknown member"
  defp destination_refusal({:invalid_host, _host}), do: "a host is outside the domain grammar"
  defp destination_refusal({:invalid_scheme, _}), do: "the scheme is http or https"
  defp destination_refusal({:invalid_port, _}), do: "the port is 1 to 65535"
  defp destination_refusal({:invalid_method, _}), do: "a method is outside the HTTP vocabulary"
  defp destination_refusal({:invalid_path, _}), do: "a path is outside the path grammar"
  defp destination_refusal({:invalid_list, field}), do: "#{field} is a list"
  defp destination_refusal({:empty, field}), do: "#{field}, when present, is not empty"
  defp destination_refusal({:too_many, field}), do: "#{field} names too many entries"
  defp destination_refusal({:required, field}), do: "#{field} is required"
  defp destination_refusal(_other), do: "it is outside the destination grammar"

  defp action_enum, do: Prima.Provider.action_enum(definition())
end
