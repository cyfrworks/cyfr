# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ApiKey do
  @moduledoc """
  API key management for CYFR.

  Provides an interface for creating, retrieving, and managing API keys.
  Keys are stored via `Arca.ApiKeyStorage` (through MCP boundary).
  The actual key value is never stored — only a SHA-256 hash for validation
  lookups and a 12-char prefix for redacted display.

  There is one kind of key, `cyfr_sk_`, acting as the person who made it
  in the athanor it was made in. What it may do is fixed when it is made
  and never changed: its permissions, ticked from a preset (`presets/0`),
  and optionally the named tools it may run (`tools`), each a component
  named without its version. Left without tools, it runs any tool its
  person granted. Both live in the stored `scope` list: a tool's name
  always holds a `:` and a permission never does, and a name outside the
  permission vocabulary never reaches the key's context
  (`context_from_metadata/1`), so only `admit_tool/2` reads the tools.

  ## Usage

      ctx = Sanctum.TestContext.local()

      {:ok, %{api_key: "cyfr_sk_...", name: "deploy"}} =
        Sanctum.ApiKey.create(ctx, %{name: "deploy", scope: ["execute"], tools: ["c:local.ship"]})

      {:ok, [%{name: "deploy", scope: ["execute"], tools: ["catalyst:local.ship"]}]} =
        Sanctum.ApiKey.list(ctx)

      {:ok, %{name: "deploy", scope: [...]}} =
        Sanctum.ApiKey.validate("cyfr_sk_...", client_ip: "192.168.1.10")

  ## Storage

  Keys are stored via `Arca.ApiKeyStorage`.
  """

  require Logger

  alias Sanctum.Context

  # Each permission a key may hold, in the order a person reads them, by
  # what it lets the key do. The wildcard is none of them: no key holds
  # it. `Sanctum.Atoms` declares the vocabulary; a test holds the two
  # equal.
  @permissions [
    {"execute", "Run tools"},
    {"component_read", "Read components"},
    {"storage_read", "Read files, runs and logs"},
    {"component_manage", "Build and publish components"},
    {"storage_write", "Write files"},
    {"admin", "Manage keys, webhooks and programs"},
    {"vault_read", "List OAuth clients"}
  ]
  @permission_names Enum.map(@permissions, &elem(&1, 0))

  @run ["execute", "component_read", "storage_read"]

  # The first is what a key made without permissions holds.
  @presets [
    {"Run tools and read their runs", @run},
    {"Build components", @run ++ ["component_manage", "storage_write"]},
    {"Manage keys and webhooks", ["admin"]}
  ]

  # ============================================================================
  # Public API
  # ============================================================================

  @doc "The permissions a key may hold, each with what it lets the key do, in reading order."
  @spec permissions() :: [{String.t(), String.t()}]
  def permissions, do: @permissions

  @doc """
  The presets a person ticks a key's permissions from, each its name and
  its permissions; the first is what a key made without permissions holds.
  """
  @spec presets() :: [{String.t(), [String.t()]}]
  def presets, do: @presets

  @doc """
  Create a new API key: a credential that outlives the session that
  mints it, so its issuance is a sensitive change (`credential_issuance`),
  decided here.

  ## Options

  - `:name` - Required. Human-readable name for the key.
  - `:scope` - Its permissions (`permissions/0`); absent or empty, the
    first preset's. A name outside them is `{:error, {:unknown_permission, name}}`.
  - `:tools` - The tools it may run, each a component reference without
    its version (`c:local.ship`); absent or empty, any tool its person
    granted. One that is not such a reference is
    `{:error, {:invalid_tool, name}}`.
  - `:ip_allowlist` - List of allowed IPs/CIDRs (e.g., ["192.168.1.0/24", "10.0.0.1"])
  """
  def create(ctx, opts, issuance \\ [])

  def create(%Context{} = ctx, %{name: name} = opts, issuance)
      when is_binary(name) and is_list(issuance) do
    # What the key may do is checked before a confirmation is asked: a
    # request that could make no key asks for none.
    with :ok <- tenant(ctx),
         {:ok, scope_list} <- permissions_of(Map.get(opts, :scope)),
         {:ok, tools} <- tools_of(Map.get(opts, :tools)),
         :ok <-
           Sanctum.Consent.Authz.confirm(ctx, :credential_issuance, %{
             operation: "key.create",
             arguments: opts,
             resource: name
           }),
         {:ok, expectation} <- Sanctum.Issuance.expectation(ctx, issuance) do
      create_validated(ctx, name, scope_list, tools, Map.put(opts, :expectation, expectation))
    end
  end

  def create(_ctx, _opts, _issuance), do: {:error, "name is required"}

  defp tenant(ctx) do
    case Context.tenant_ok(ctx) do
      {:error, :missing_tenant} -> {:error, :athanor_required}
      :ok -> :ok
    end
  end

  defp create_validated(ctx, name, scope_list, tools, opts) do
    with {:ok, capability_json} <-
           validate_consent_capability(ctx, Map.get(opts, :consent_capability)) do
      create_key(ctx, name, scope_list, tools, Map.put(opts, :capability_json, capability_json))
    end
  end

  # Minting a consent capability requires interactive consent authority.
  # The capability binds an exact commit digest and requires an expiry.
  defp validate_consent_capability(_ctx, nil), do: {:ok, nil}

  defp validate_consent_capability(ctx, %{commit_digest: digest, expires_at: expires_at})
       when is_binary(digest) do
    with {:ok, :interactive} <- Sanctum.Consent.Authz.authorize_interactive(ctx),
         :ok <- check_digest_shape(digest),
         {:ok, expiry} <- parse_expiry(expires_at) do
      {:ok,
       Jason.encode!(%{
         "consent" => %{
           "commit_digest" => digest,
           "expires_at" => DateTime.to_iso8601(expiry)
         }
       })}
    end
  end

  defp validate_consent_capability(_ctx, _other), do: {:error, :invalid_consent_capability}

  defp check_digest_shape("sha256:" <> rest) when byte_size(rest) == 64, do: :ok
  defp check_digest_shape(_), do: {:error, :invalid_consent_capability}

  defp parse_expiry(%DateTime{} = dt), do: check_future(dt)

  defp parse_expiry(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> check_future(dt)
      _ -> {:error, :invalid_consent_capability}
    end
  end

  defp parse_expiry(_), do: {:error, :invalid_consent_capability}

  defp check_future(dt) do
    if DateTime.compare(dt, DateTime.utc_now()) == :gt do
      {:ok, dt}
    else
      {:error, :capability_already_expired}
    end
  end

  defp create_key(ctx, name, scope_list, tools, opts) do
    key = generate_key()
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    ip_allowlist = Map.get(opts, :ip_allowlist)
    athanor_id = athanor!(ctx)

    # An unencodable allowlist must not become a key: `safe_encode/1`'s "[]"
    # fallback is fail-closed for `scope` (no permissions) but fail-OPEN
    # here, because `validate/2` reads an empty allowlist as "no IP
    # restriction" — the restriction the operator asked for would silently
    # not exist.
    with {:ok, allowlist_json} <- encode_allowlist(ip_allowlist) do
      attrs = %{
        name: name,
        key_hash: hash_key(key),
        key_prefix: String.slice(key, 0, 12),
        scope: safe_encode(scope_list ++ tools),
        ip_allowlist: allowlist_json,
        capability: Map.get(opts, :capability_json),
        created_by: ctx.user_id,
        athanor_id: athanor_id
      }

      store_key(attrs, Map.fetch!(opts, :expectation), key, name, scope_list, tools, now)
    end
  end

  defp encode_allowlist(nil), do: {:ok, nil}

  # The shape is checked here, not only that it encodes. `ip_allowed?/2`
  # matches binary entries only, and the MCP input validator checks
  # `type: array` without descending into `items`, so a key stored with
  # `"ip_allowlist": [1, 2]` would raise on every later `validate/2`: a
  # 500 on the authentication path and a key that can never be used.
  defp encode_allowlist(ip_allowlist) when is_list(ip_allowlist) do
    if Enum.all?(ip_allowlist, &is_binary/1) do
      case Jason.encode(ip_allowlist) do
        {:ok, json} -> {:ok, json}
        {:error, _} -> {:error, :invalid_ip_allowlist}
      end
    else
      {:error, :invalid_ip_allowlist}
    end
  end

  defp encode_allowlist(_), do: {:error, :invalid_ip_allowlist}

  # Written in the issuance transaction: the creator and the athanor
  # locked and reread at the generations the context read, the athanor
  # still the creator's own and the credential the creator
  # holds still live (`Sanctum.Issuance`).
  defp store_key(attrs, expectation, key, name, scope_list, tools, now) do
    case Arca.ApiKeyStorage.create_key(attrs,
           lock: Sanctum.Issuance.lock(expectation),
           verify: Sanctum.Issuance.verify(expectation)
         ) do
      :ok ->
        {:ok, %{api_key: key, name: name, scope: scope_list, tools: tools, created_at: now}}

      {:error, :already_exists} ->
        # The unique index is partial (WHERE NOT revoked), so a violation
        # always means an ACTIVE key holds the name; a revoked key reserves
        # none.
        {:error, :already_exists}

      error ->
        error
    end
  end

  @doc """
  The consent capability carried by a key, in the shape
  `Sanctum.Consent.Authz` consumes: `%{commit_digest, expires_at}` —
  or nil when the key carries none. Malformed stored JSON reads as no
  capability (fail closed).
  """
  @spec consent_capability(Context.t(), String.t() | nil) ::
          {:ok, %{commit_digest: String.t(), expires_at: DateTime.t() | nil} | nil}
  def consent_capability(_ctx, nil), do: {:ok, nil}

  def consent_capability(%Context{} = ctx, api_key_id) when is_binary(api_key_id) do
    with {:ok, row} <- Arca.ApiKeyStorage.get_key_by_id(actor!(ctx), api_key_id),
         {:ok, %{"consent" => %{"commit_digest" => digest} = consent}} <-
           Jason.decode(row.capability || "null"),
         true <- is_binary(digest),
         # The expiry is mandatory at mint; a stored capability without a
         # parseable one reads as no capability, never as a non-expiring one.
         {:ok, expires_at, _} <- DateTime.from_iso8601(consent["expires_at"] || "") do
      {:ok, %{commit_digest: digest, expires_at: expires_at}}
    else
      _ -> {:ok, nil}
    end
  end

  @doc """
  Get a key by name (key value is redacted).
  """
  def get(%Context{} = ctx, name) when is_binary(name) do
    case Arca.ApiKeyStorage.get_key(actor!(ctx), name) do
      {:ok, row} -> {:ok, redact_key(row)}
      {:error, :not_found} -> {:error, :not_found}
      {:error, :database_error} -> {:error, :database_error}
    end
  end

  @doc """
  List all keys (key values are redacted).
  """
  def list(%Context{} = ctx) do
    case Arca.ApiKeyStorage.list_keys(actor!(ctx)) do
      {:ok, rows} ->
        entries = Enum.map(rows, &redact_key/1)
        {:ok, entries}

      error ->
        error
    end
  end

  @doc """
  Revoke a key by name.
  """
  def revoke(%Context{} = ctx, name) when is_binary(name) do
    Arca.ApiKeyStorage.revoke_key(actor!(ctx), name)
  end

  @doc "Revoke every live key a person created — part of denying them on this server."
  @spec revoke_all_created_by(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def revoke_all_created_by(user_id) when is_binary(user_id) do
    Arca.ApiKeyStorage.revoke_all_created_by(user_id)
  end

  @doc """
  Re-enable the key `key_id` that a declared restore suspended, one the
  person created. `ctx` is the person's own, in the key's athanor: the
  change (`key.reenable`) is asked first (`Sanctum.Consent.Authz.check/3`,
  which may answer the confirmation signal), and the confirmation is
  consumed in the transaction that writes the key, after its row is
  locked.

  Refusals: `:not_found` for a key that is not the person's, `:revoked`
  for a revoked one, which is never revived, and `:not_suspended` for one
  that already stands; a confirmation's own refusals pass as they are.
  """
  @spec reenable(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def reenable(%Context{} = ctx, key_id) when is_binary(key_id) do
    with :ok <- tenant(ctx),
         {:ok, user_id} <- person(ctx),
         actor = actor!(ctx),
         {:ok, row} <- Arca.ApiKeyStorage.get_created_key(actor, user_id, key_id),
         :ok <- reenablable(row),
         change = reenable_change(row),
         :ok <- Sanctum.Consent.Authz.check(ctx, :restore_reenable, change),
         {:ok, row} <-
           Arca.ApiKeyStorage.reenable(actor, user_id, key_id,
             verify: fn _row ->
               Sanctum.Consent.Authz.consume(ctx, {:restore_reenable, change})
             end
           ) do
      Sanctum.Consent.Authz.consumed(ctx)
      reenabled(row)
    end
  end

  defp person(%Context{user_id: user_id}) when is_binary(user_id) and user_id != "",
    do: {:ok, user_id}

  defp person(%Context{}), do: {:error, :unauthenticated}

  # Asked before a confirmation is: a key no proof could re-enable asks
  # for none. The write reads the row again under its lock.
  defp reenablable(%{revoked: true}), do: {:error, :revoked}
  defp reenablable(%{suspended: true}), do: :ok
  defp reenablable(%{}), do: {:error, :not_suspended}

  defp reenable_change(row) do
    %{
      operation: "key.reenable",
      arguments: %{"key_id" => row.id},
      resource: row.name,
      details: %{
        "effect" =>
          "Re-enables the API key #{row.name}, suspended when this CYFR was restored " <>
            "from a backup, so its secret authenticates again"
      }
    }
  end

  defp reenabled(row) do
    Sanctum.Telemetry.api_keys_changed(row.athanor_id)
    {:ok, redact_key(row)}
  end

  @doc """
  Rotate a key - issues a new secret for the same name and settings.
  Issuing a secret that outlives the session is a sensitive change
  (`credential_issuance`), decided here, as it is at `create/3`.

  A key a declared restore suspended is refused (`{:error, :suspended}`):
  its successor would stand unsuspended, so it is re-enabled first
  (`reenable/2`).

  A capability-bearing key is refused: rotation is `permission: :admin` and
  mints no capability of its own, so handing a fresh secret to a row that
  already carries one would spend the interactive grant twice. Revoke it and
  mint a new key instead — that path asks the consent plane again.
  """
  def rotate(%Context{} = ctx, name, issuance \\ []) when is_binary(name) and is_list(issuance) do
    actor = actor!(ctx)

    with :ok <-
           Sanctum.Consent.Authz.confirm(ctx, :credential_issuance, %{
             operation: "key.rotate",
             arguments: %{name: name},
             resource: name
           }),
         {:ok, expectation} <- Sanctum.Issuance.expectation(ctx, issuance),
         {:ok, false} <- Arca.ApiKeyStorage.capability_bearing?(actor, name) do
      rotate_plain(expectation, actor, name)
    else
      {:ok, true} -> {:error, :capability_key_immutable}
      {:error, _reason} = refusal -> refusal
    end
  end

  defp rotate_plain(expectation, actor, name) do
    case Arca.ApiKeyStorage.get_key(actor, name) do
      {:ok, %{suspended: true}} ->
        {:error, :suspended}

      {:ok, row} ->
        with {:ok, {scope_list, tools}} <- stored_scope(row.scope) do
          rotate_row(expectation, actor, name, scope_list, tools)
        end

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :database_error} ->
        {:error, :database_error}
    end
  end

  defp rotate_row(expectation, actor, name, scope_list, tools) do
    new_key = generate_key()
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    case Arca.ApiKeyStorage.rotate_key(
           actor,
           name,
           hash_key(new_key),
           String.slice(new_key, 0, 12),
           lock: Sanctum.Issuance.lock(expectation),
           verify: Sanctum.Issuance.verify(expectation)
         ) do
      :ok ->
        {:ok, %{api_key: new_key, name: name, scope: scope_list, tools: tools, rotated_at: now}}

      error ->
        error
    end
  end

  @doc """
  Validate an API key and return its metadata.

  This function checks if the key exists and is neither revoked
  (`{:error, :revoked}`) nor suspended by a declared restore
  (`{:error, :suspended}`). A string without the key prefix is
  `{:error, :invalid_key_format}`.

  ## Options

  - `:client_ip` - The caller's resolved client IP. A key with an IP
    allowlist is rejected when this is absent: no IP means the restriction
    cannot be proven satisfied, so validation fails closed.

  ## Examples

      iex> {:ok, meta} = Sanctum.ApiKey.validate("cyfr_sk_...", client_ip: "192.168.1.10")
      iex> meta.name
      "my-key"
  """
  def validate(key, opts \\ []) when is_binary(key) do
    client_ip = Keyword.get(opts, :client_ip)

    if looks_like_key?(key) do
      validate_key_against_store(key, client_ip)
    else
      # Equalize the malformed-key fast path with the store-lookup path so a
      # missing/foreign prefix is not distinguishable by response timing.
      _ = hash_key(key)
      {:error, :invalid_key_format}
    end
  end

  # API keys are athanor credentials: the key hash (192-bit, globally unique)
  # IS the credential, and the athanor is read back FROM the stored key row —
  # never from the request or the creating user's current standing. A
  # single untenanted hash lookup is therefore correct and authoritative; the
  # tenant binding is enforced on the resulting Context via require_tenant!
  # (see Sanctum.ApiKey.context_from_metadata/1), not at lookup time.
  #
  # A key is a standing channel of its athanor: it stops when the athanor is
  # archived or its creator is denied on this server.
  defp validate_key_against_store(key, client_ip) do
    case Arca.ApiKeyStorage.get_key_by_hash(hash_key(key)) do
      {:error, :not_found} ->
        {:error, :invalid_key}

      # Return a storage outage without treating the credential as invalid.
      {:error, :database_error} ->
        {:error, :database_error}

      {:ok, %{revoked: true}} ->
        {:error, :revoked}

      # A declared restore suspended it: it authenticates nothing until
      # its person re-enables it (`reenable/2`).
      {:ok, %{suspended: true}} ->
        {:error, :suspended}

      {:ok, row} ->
        ip_allowlist = decode_allowlist(row.ip_allowlist)

        cond do
          not Sanctum.Tenancy.channel_active?(row.athanor_id, row.created_by) ->
            {:error, :channel_closed}

          # A restriction that cannot be read admits no address.
          ip_allowlist == :corrupt ->
            {:error, :ip_not_allowed}

          ip_allowlist in [nil, []] ->
            key_metadata(row)

          # An allowlisted key with no caller-supplied IP fails closed:
          # absence of the IP is not proof the restriction is satisfied
          # (Sanctum.ClientIp.resolve/1 is total, so every request path
          # can supply one).
          client_ip == nil ->
            {:error, :ip_not_allowed}

          ip_allowed?(client_ip, ip_allowlist) ->
            key_metadata(row)

          true ->
            {:error, :ip_not_allowed}
        end
    end
  end

  # A stored scope no rule admits makes the key authenticate nothing.
  defp key_metadata(row) do
    with {:ok, {scope_list, _tools}} <- stored_scope(row.scope),
         {:ok, binding} <- key_binding(row) do
      {:ok, row |> build_key_metadata(scope_list) |> Map.put(:credential_binding, binding)}
    end
  end

  # What a key's context was established against: the key itself, its
  # creator's generation and its athanor's. A key one of the server's own
  # principals created has no person behind it and carries no binding: it
  # keeps its primary authentication and can issue nothing. A creator with
  # no row that is none of those principals names nobody, and the key is
  # refused as `channel_active?/2` refuses it.
  defp key_binding(%{id: id, created_by: creator, athanor_id: athanor_id}) do
    case Sanctum.Tenancy.generation_snapshot(creator || "", athanor_id) do
      {:ok, snapshot} ->
        {:ok,
         %{
           source_kind: :api_key,
           source_id: id,
           user_generation: snapshot.user_generation,
           athanor_generation: snapshot.athanor_generation
         }}

      {:error, :not_found} ->
        if Sanctum.Tenancy.synthetic_principal?(creator),
          do: {:ok, nil},
          else: {:error, :channel_closed}

      {:error, :unavailable} ->
        {:error, :database_error}
    end
  end

  @doc """
  Build an athanor-scoped `Sanctum.Context` from validated API-key metadata.

  Builds an API-key context from the stored key row. The `athanor_id` comes
  from that row, and is the one athanor the context works in: a key works
  in the athanor it was minted in alone (`Sanctum.Context.focus/2`). The
  namespace is the creator's personal slug from `Sanctum.Namespace.lookup/1`,
  or nil when no slug is recorded (the namespace is identity-only, so the
  key still works, and the lookup's miss is logged).

  The caller is responsible for the tenant gate
  (`Sanctum.Context.require_tenant!/1`) after building — an athanor-less key
  is rejected by `Sanctum.TenantPolicy`.
  """
  @spec context_from_metadata(map()) :: Sanctum.Context.t()
  def context_from_metadata(metadata) when is_map(metadata) do
    permissions =
      metadata.scope
      |> List.wrap()
      |> Enum.map(&Sanctum.Atoms.safe_to_permission_atom/1)
      |> Enum.filter(&is_atom/1)

    # namespace is identity-only (not path-bearing), so a nil is fine. An
    # orphaned key (owner's namespace gone from their users row) still works —
    # log it so operators can spot keys worth revoking.
    namespace = Sanctum.Namespace.lookup(metadata[:user_id])

    if is_nil(namespace) do
      Logger.warning(
        "[Sanctum.ApiKey] API key namespace lookup returned nil — " <>
          "user_id=#{inspect(metadata[:user_id])} " <>
          "api_key_id=#{inspect(metadata[:id])}. The owning user's " <>
          "namespace is not recorded; consider revoking the key."
      )
    end

    Context.build(
      user_id: metadata[:user_id],
      namespace: namespace,
      athanor_id: metadata[:athanor_id],
      permissions: permissions,
      scope: :athanor,
      auth_method: :api_key,
      # The key's id and the binding that names it, stamped together here
      # and nowhere else.
      api_key_id: metadata[:id],
      credential_binding: metadata[:credential_binding],
      authenticated: true
    )
  end

  defp build_key_metadata(row, scope_list) do
    %{
      id: row.id,
      name: row.name,
      scope: scope_list,
      ip_allowlist: decode_stored(row.ip_allowlist, nil, "ip_allowlist"),
      user_id: row.created_by,
      athanor_id: row.athanor_id
    }
  end

  @doc """
  Check if a client IP is allowed by the key's IP allowlist.

  Supports:
  - Exact IP match (e.g., "192.168.1.10")
  - CIDR notation (e.g., "192.168.1.0/24")

  ## Examples

      iex> Sanctum.ApiKey.ip_allowed?("192.168.1.10", ["192.168.1.0/24"])
      true

      iex> Sanctum.ApiKey.ip_allowed?("10.0.0.1", ["192.168.1.0/24"])
      false

      iex> Sanctum.ApiKey.ip_allowed?("192.168.1.10", ["192.168.1.10"])
      true
  """
  def ip_allowed?(client_ip, allowlist) when is_binary(client_ip) and is_list(allowlist),
    do: Enum.any?(allowlist, &entry_admits?(client_ip, &1))

  # The match is `Prima.Cidr.match?/2`'s, an IPv4-mapped IPv6 address
  # matched against an IPv4 range by its embedded IPv4 form. An entry that
  # names no address or range admits nothing and is logged for the
  # operator who wrote it.
  defp entry_admits?(client_ip, entry) do
    cond do
      Prima.Cidr.match?(client_ip, entry) ->
        true

      Prima.Cidr.parse_cidr(entry) != :error or Prima.Cidr.parse_ip(entry) != :error ->
        false

      true ->
        Logger.warning(
          "[Sanctum.ApiKey] allowlist entry #{inspect(entry)} is neither an IP like " <>
            "'192.168.1.10' nor a CIDR like '192.168.1.0/24'; it admits nothing"
        )

        false
    end
  end

  @doc """
  True when `key` carries the API-key prefix (`Prima.CredentialShape`).

  Single source of truth for "is this string an API key at all", shared by the
  authentication plug and the tincture auth resolver so the prefix check cannot
  drift between entry points.
  """
  @spec looks_like_key?(term()) :: boolean()
  def looks_like_key?(key) when is_binary(key),
    do: String.starts_with?(key, Prima.CredentialShape.api_key_prefix())

  def looks_like_key?(_), do: false

  @doc """
  Whether the key a context acts with may start a run of `reference`: a
  context of no key, and a key with no tools, may; a key with tools may
  run only those, whatever the version. A key whose row cannot be read
  now (revoked, suspended, gone) starts nothing.
  """
  @spec admit_tool(Context.t(), String.t()) ::
          :ok | {:error, :key_tool_not_named | :invalid_api_key | :database_error}
  def admit_tool(%Context{api_key_id: nil}, _reference), do: :ok

  def admit_tool(%Context{api_key_id: api_key_id} = ctx, reference)
      when is_binary(api_key_id) and is_binary(reference) do
    case Arca.ApiKeyStorage.get_key_by_id(actor!(ctx), api_key_id) do
      {:ok, row} ->
        case stored_scope(row.scope) do
          {:ok, {_scope_list, []}} -> :ok
          {:ok, {_scope_list, tools}} -> named(tools, reference)
          {:error, :invalid_key} -> {:error, :invalid_api_key}
        end

      {:error, :database_error} ->
        {:error, :database_error}

      {:error, _gone} ->
        {:error, :invalid_api_key}
    end
  end

  defp named(tools, reference) do
    case tool_name(reference) do
      {:ok, name} -> if name in tools, do: :ok, else: {:error, :key_tool_not_named}
      :error -> {:error, :key_tool_not_named}
    end
  end

  # ============================================================================
  # Permissions and tools
  # ============================================================================

  # Anything but a list of known permission names is refused whole,
  # naming its first other entry, never read as the default: a caller's
  # mistake must not become permissions it did not ask for. The entries
  # outside the vocabulary are collected rather than searched for, so an
  # entry that is itself nil cannot read as none found.
  defp permissions_of(absent) when absent in [nil, []],
    do: {:ok, @presets |> hd() |> elem(1)}

  defp permissions_of(scope) when is_list(scope) do
    case Enum.reject(scope, &(&1 in @permission_names)) do
      [] -> {:ok, Enum.uniq(scope)}
      [unknown | _] -> {:error, {:unknown_permission, unknown}}
    end
  end

  defp permissions_of(other), do: {:error, {:unknown_permission, other}}

  defp tools_of(absent) when absent in [nil, []], do: {:ok, []}

  defp tools_of(tools) when is_list(tools) do
    Enum.reduce_while(tools, {:ok, []}, fn tool, {:ok, acc} ->
      case versionless(tool) do
        {:ok, name} -> {:cont, {:ok, [name | acc]}}
        :error -> {:halt, {:error, {:invalid_tool, tool}}}
      end
    end)
    |> case do
      {:ok, names} -> {:ok, names |> Enum.reverse() |> Enum.uniq()}
      refused -> refused
    end
  end

  defp tools_of(other), do: {:error, {:invalid_tool, other}}

  # A tool is named as a person names a component they run, without its
  # version, so the key keeps running it across updates.
  defp versionless(tool) when is_binary(tool) do
    with {:ok, %Prima.ComponentRef{version: nil} = ref} <- Prima.ComponentRef.parse(tool),
         :ok <- Prima.ComponentRef.validate_type(ref.type),
         :ok <- Prima.ComponentRef.validate_namespace(ref.namespace),
         :ok <- Prima.ComponentRef.validate_name(ref.name) do
      {:ok, Prima.ComponentRef.to_name_ref(ref)}
    else
      _ -> :error
    end
  end

  defp versionless(_), do: :error

  defp tool_name(reference) do
    case Prima.ComponentRef.to_name_ref(reference) do
      {:ok, name} -> {:ok, name}
      {:error, _} -> :error
    end
  end

  # The stored list split into its permissions and its tools. Every entry
  # is exactly a known permission or a tool's name as `tools_of/1` stores
  # it; any other entry, or a column that is no list, makes the key
  # invalid rather than being dropped, since a dropped entry could have
  # been the one that narrowed it. The line names the column's size,
  # never its bytes.
  defp stored_scope(json) do
    with {:ok, list} when is_list(list) <- Prima.Json.decode_stored(json, []),
         {permissions, tools} = Enum.split_with(list, &(&1 in @permission_names)),
         true <- Enum.all?(tools, &(versionless(&1) == {:ok, &1})) do
      {:ok, {permissions, tools}}
    else
      _ ->
        Logger.warning(
          "[Sanctum.ApiKey] stored scope holds an entry no rule admits " <>
            "(#{byte_size(json || "")} bytes)"
        )

        {:error, :invalid_key}
    end
  end

  # ============================================================================
  # Internal
  # ============================================================================

  defp generate_key, do: Prima.CredentialShape.mint(:api_key)

  defp hash_key(key), do: :crypto.hash(:sha256, key)

  # A key whose stored scope no rule admits authenticates nothing
  # (`key_metadata/1`); it is still listed, holding nothing and marked
  # `scope_unreadable`, so its person can find it and revoke it.
  defp redact_key(row) do
    {scope_list, tools, unreadable} =
      case stored_scope(row.scope) do
        {:ok, {scope_list, tools}} -> {scope_list, tools, false}
        {:error, :invalid_key} -> {[], [], true}
      end

    %{
      id: row.id,
      name: row.name,
      key_prefix: (row.key_prefix || "") <> "...",
      suspended: row.suspended == true,
      scope: scope_list,
      tools: tools,
      scope_unreadable: unreadable,
      ip_allowlist: decode_stored(row.ip_allowlist, nil, "ip_allowlist"),
      created_at: Prima.Time.iso8601(row.inserted_at),
      rotated_at: Prima.Time.iso8601(row.rotated_at)
    }
  end

  # The athanor every key path keys on, behind the tenant chokepoint: an
  # athanor-less context raises before it can touch any row.
  defp athanor!(%Context{} = ctx), do: Context.athanor!(ctx)

  # The actor the key rows are read and written under, behind the
  # product-boundary refusal: `athanor!/1` raises
  # `Sanctum.UnauthorizedError` for an unresolved tenant, so only a
  # resolved context reaches Arca and the storage refusal is unreachable
  # from here.
  defp actor!(%Context{} = ctx) do
    _ = athanor!(ctx)
    Context.actor(ctx)
  end

  defp safe_encode(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _} -> "[]"
    end
  end

  # A stored JSON column that does not decode reads as its default. The
  # line names the column and its size, never its bytes.
  defp decode_stored(json, default, field) do
    case Prima.Json.decode_stored(json, default) do
      {:ok, value} ->
        value

      {:error, :invalid_json} ->
        Logger.warning(
          "[Sanctum.ApiKey] stored #{field} is not valid JSON (#{byte_size(json)} bytes)"
        )

        default
    end
  end

  @doc """
  A key's stored `ip_allowlist` column as every admission reads it: valid
  JSON holding only strings is the list, an absent column (`nil`) is no
  restriction, and anything else, an empty string included, is
  `:corrupt`, a security row that admits no address. The warning names
  the column and its size, never its bytes.
  """
  @spec decode_allowlist(String.t() | nil) :: [String.t()] | nil | :corrupt
  def decode_allowlist(nil), do: nil

  def decode_allowlist(json) when is_binary(json) do
    case Prima.Json.decode(json) do
      {:ok, list} when is_list(list) ->
        if Enum.all?(list, &is_binary/1),
          do: list,
          else: corrupt_allowlist("is not a list of strings", json)

      {:ok, _other} ->
        corrupt_allowlist("is not a list of strings", json)

      {:error, :invalid_json} ->
        corrupt_allowlist("is not valid JSON", json)
    end
  end

  defp corrupt_allowlist(problem, json) do
    Logger.warning("[Sanctum.ApiKey] stored ip_allowlist #{problem} (#{byte_size(json)} bytes)")
    :corrupt
  end
end
