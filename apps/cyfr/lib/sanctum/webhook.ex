# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Webhook do
  @moduledoc """
  Inbound webhook management for CYFR.

  A webhook is a stable URL (`/hooks/:slug`) that accepts external POSTs,
  verifies an HMAC-SHA256 signature, and invokes a target component.

  Unlike API keys (which are hashed for indexed lookup), webhook secrets must
  be reproducible at verification time — every inbound POST recomputes the
  HMAC against the stored secret. So secrets are encrypted at rest via the
  configured `Sanctum.Cipher` (the `:webhook_secret` purpose) and decrypted
  just-in-time. Inbound verification (`verify_with_grace/4`) binds the
  webhook row's tenant identity into the cipher's AAD.

  Secrets are returned in plaintext exactly twice in their lifetime:
    * When created (`create/2`).
    * When rotated (`rotate/2`).
  Never on `get/2` or `list/1`. The CLI/UI must surface a one-time reveal.

  ## Storage

  Rows are stored via `Arca.WebhookStorage`. See that module for tenant
  scoping and unique-index semantics.
  """

  require Logger

  alias Sanctum.Context
  alias Arca.WebhookStorage

  @secret_random_bytes 24
  @slug_random_bytes 18

  @max_input_template_bytes 16 * 1024
  @reserved_input_keys ~w(_webhook)

  # Maximum acceptable clock skew (seconds) between sender and receiver
  # for timestamp-protected webhooks. 300s = 5 min matches Stripe's window.
  @default_max_skew_seconds 300

  # After a rotation the outgoing secret keeps verifying for this long so
  # in-flight requests aren't dropped while the sender is updated. 24h is a
  # generous-but-bounded window; the old secret is ignored once it expires.
  @previous_secret_grace_seconds 86_400

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Create a new webhook. Returns the plaintext secret exactly once.

  Required: `name`, `target_ref`. Optional: `input_template` (map; default
  `%{}`), `signature_header` (default `x-cyfr-signature`), `description`,
  `rate_limit`.
  """
  @spec create(Context.t(), map()) :: {:ok, map()} | {:error, term()}
  def create(%Context{} = ctx, %{name: name, target_ref: target_ref} = opts)
      when is_binary(name) and is_binary(target_ref) do
    {scope_t, oid, pid} = extract_scope(ctx)

    with :ok <- validate_target_ref(ctx, target_ref),
         {:ok, input_template_json} <- encode_input_template(Map.get(opts, :input_template, %{})),
         {:ok, secret} <- generate_secret(),
         {:ok, secret_encrypted} <-
           Sanctum.Cipher.encrypt(secret, ctx_webhook_aad(scope_t, oid, pid, name)),
         slug <- generate_slug(),
         attrs <-
           build_attrs(
             ctx,
             scope_t,
             oid,
             pid,
             name,
             target_ref,
             slug,
             secret_encrypted,
             input_template_json,
             opts
           ),
         :ok <- WebhookStorage.create_webhook(attrs) do
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      {:ok,
       %{
         name: name,
         slug: slug,
         secret: secret,
         url: build_url(slug),
         target_ref: target_ref,
         input_template: Jason.decode!(input_template_json),
         signature_header: attrs.signature_header,
         created_at: now
       }}
    end
  end

  def create(_ctx, _opts), do: {:error, "name and target_ref are required"}

  @doc """
  Get webhook details by name. Secret is never returned.
  """
  @spec get(Context.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(%Context{} = ctx, name) when is_binary(name) do
    {scope_t, oid, pid} = extract_scope(ctx)

    case WebhookStorage.get_by_name(name, scope_t, oid, pid) do
      {:ok, row} -> {:ok, public_view(row)}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  List all enabled webhooks within tenant scope. Secrets are never returned.
  """
  @spec list(Context.t()) :: {:ok, [map()]} | {:error, term()}
  def list(%Context{} = ctx) do
    {scope_t, oid, pid} = extract_scope(ctx)

    case WebhookStorage.list_webhooks(scope_t, oid, pid) do
      {:ok, rows} -> {:ok, Enum.map(rows, &public_view/1)}
      error -> error
    end
  end

  @doc """
  Update mutable webhook fields without rotating the secret.

  Allowed fields: `target_ref`, `signature_header`, `input_template`,
  `description`, `rate_limit`. Unknown fields are ignored.
  """
  @spec update(Context.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update(%Context{} = ctx, name, attrs) when is_binary(name) and is_map(attrs) do
    {scope_t, oid, pid} = extract_scope(ctx)

    with {:ok, normalized} <- normalize_update_attrs(attrs),
         :ok <- maybe_validate_target_ref(ctx, normalized),
         :ok <-
           WebhookStorage.update_webhook(
             name,
             scope_t,
             oid,
             pid,
             normalized
           ) do
      get(ctx, name)
    end
  end

  @doc """
  Soft-disable a webhook. Subsequent inbound POSTs to its slug return 404.
  """
  @spec revoke(Context.t(), String.t()) :: :ok | {:error, :not_found}
  def revoke(%Context{} = ctx, name) when is_binary(name) do
    {scope_t, oid, pid} = extract_scope(ctx)
    WebhookStorage.set_disabled(name, scope_t, oid, pid)
  end

  @doc """
  Rotate the HMAC secret for a webhook. Returns the new plaintext secret
  exactly once.

  Not a hard cutover: the outgoing secret stays valid for
  `#{@previous_secret_grace_seconds}` seconds (`verify_with_grace/4` accepts
  it until then), so in-flight requests signed with the old secret keep
  working while the sender is updated. The new plaintext is returned only
  after the storage write commits.
  """
  @spec rotate(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def rotate(%Context{} = ctx, name) when is_binary(name) do
    {scope_t, oid, pid} = extract_scope(ctx)

    previous_expires_at =
      DateTime.add(DateTime.utc_now(), @previous_secret_grace_seconds, :second)

    with {:ok, existing} <- get(ctx, name),
         {:ok, new_secret} <- generate_secret(),
         {:ok, new_secret_encrypted} <-
           Sanctum.Cipher.encrypt(new_secret, ctx_webhook_aad(scope_t, oid, pid, name)),
         :ok <-
           WebhookStorage.rotate_secret(
             name,
             scope_t,
             oid,
             pid,
             new_secret_encrypted,
             previous_expires_at
           ) do
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      {:ok,
       %{
         name: name,
         slug: existing.slug,
         secret: new_secret,
         url: existing.url,
         rotated_at: now
       }}
    end
  end

  defp do_verify(secret_encrypted, aad, raw_body, "sha256=" <> received_hex, nil)
       when is_binary(secret_encrypted) and is_binary(raw_body) and is_binary(received_hex) do
    with {:ok, secret} <- decrypt_secret(secret_encrypted, aad) do
      compare(:crypto.mac(:hmac, :sha256, secret, raw_body), received_hex)
    end
  end

  defp do_verify(secret_encrypted, aad, raw_body, "sha256=" <> received_hex, timestamp)
       when is_binary(secret_encrypted) and is_binary(raw_body) and is_binary(received_hex) and
              is_binary(timestamp) do
    with {:ok, ts} <- parse_timestamp(timestamp),
         :ok <- check_skew(ts),
         {:ok, secret} <- decrypt_secret(secret_encrypted, aad) do
      payload = Integer.to_string(ts) <> "." <> raw_body
      compare(:crypto.mac(:hmac, :sha256, secret, payload), received_hex)
    end
  end

  defp do_verify(_secret_encrypted, _aad, _raw_body, _received, _timestamp),
    do: {:error, :malformed_signature}

  # Decrypt the stored secret via `Sanctum.Cipher`. Any decrypt failure
  # (wrong tenant AAD, corrupt ciphertext, key mismatch) is an authentication
  # failure, not an internal error — normalize to :signature_mismatch so the
  # signature plug responds 401 and the {:error, atom()} contract holds (the
  # cipher may return a tuple reason).
  defp decrypt_secret(secret_encrypted, aad) do
    case Sanctum.Cipher.decrypt(secret_encrypted, aad) do
      {:ok, secret} -> {:ok, secret}
      {:error, _} -> {:error, :signature_mismatch}
    end
  end

  @doc """
  Verify a signature against a webhook row, accepting the **previous** secret
  during the post-rotation grace window.

  Tries the current `secret_encrypted` first; on any failure, falls back to
  `previous_secret_encrypted` iff it is present and `previous_secret_expires_at`
  is still in the future. After the grace window the previous secret is
  ignored, so a rotation isn't a hard cutover. AAD is rebuilt from the row's
  tenant tuple so the stored ciphertext is tenant-bound under any AAD-binding
  cipher.
  """
  @spec verify_with_grace(map(), binary(), binary(), binary() | nil) ::
          :ok | {:error, atom()}
  def verify_with_grace(webhook, raw_body, received_signature, timestamp \\ nil)
      when is_map(webhook) do
    aad = webhook_aad(webhook)

    case do_verify(webhook.secret_encrypted, aad, raw_body, received_signature, timestamp) do
      :ok ->
        :ok

      {:error, reason} ->
        prev = Map.get(webhook, :previous_secret_encrypted)

        if is_binary(prev) and previous_active?(Map.get(webhook, :previous_secret_expires_at)) do
          do_verify(prev, aad, raw_body, received_signature, timestamp)
        else
          {:error, reason}
        end
    end
  end

  # The grace window is open while previous_secret_expires_at is in the future.
  # The schema loads this column as a `%DateTime{}` on both adapters.
  defp previous_active?(%DateTime{} = exp), do: DateTime.compare(exp, DateTime.utc_now()) == :gt
  defp previous_active?(_), do: false

  defp compare(expected_mac, received_hex) do
    expected = Base.encode16(expected_mac, case: :lower)

    if Plug.Crypto.secure_compare(received_hex, expected) do
      :ok
    else
      {:error, :signature_mismatch}
    end
  end

  defp parse_timestamp(value) when is_binary(value) do
    case Integer.parse(value) do
      {ts, ""} when ts > 0 -> {:ok, ts}
      _ -> {:error, :malformed_timestamp}
    end
  end

  defp check_skew(ts) when is_integer(ts) do
    skew = abs(System.system_time(:second) - ts)
    max = Application.get_env(:cyfr, :webhook_max_skew_seconds, @default_max_skew_seconds)

    if skew <= max do
      :ok
    else
      {:error, :timestamp_skew}
    end
  end

  @doc """
  Decode the stored JSON `input_template` to a map. Used by the controller
  to merge with the POST envelope at invoke time.
  """
  @spec decode_input_template(String.t() | nil) :: {:ok, map()} | {:error, atom()}
  def decode_input_template(nil), do: {:ok, %{}}
  def decode_input_template(""), do: {:ok, %{}}

  def decode_input_template(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = map} -> {:ok, map}
      {:ok, _} -> {:error, :not_an_object}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  # ============================================================================
  # Internal
  # ============================================================================

  # A webhook must never be registered against a ref that does not exist —
  # otherwise it goes live the moment anyone publishes that name (delivery
  # resolves the ref at request time). Mirrors the cron schedule gate.
  # Existence only; the ref is stored as given and still resolves per
  # delivery, matching update semantics for components.
  defp validate_target_ref(ctx, target_ref) do
    case Compendium.Resolver.resolve(ctx, target_ref) do
      {:ok, resolved, _meta} ->
        case Compendium.Component.inspect_component(ctx, resolved) do
          {:ok, _} ->
            :ok

          {:error, _} ->
            {:error,
             "Component '#{resolved}' not found in registry. Register or pull it first."}
        end

      {:error, reason} ->
        {:error, "Cannot use target_ref '#{target_ref}': #{reason}"}
    end
  end

  defp maybe_validate_target_ref(ctx, %{target_ref: target_ref}) when is_binary(target_ref),
    do: validate_target_ref(ctx, target_ref)

  defp maybe_validate_target_ref(_ctx, _attrs), do: :ok

  defp build_attrs(
         ctx,
         scope_t,
         oid,
         pid,
         name,
         target_ref,
         slug,
         secret_encrypted,
         input_template_json,
         opts
       ) do
    %{
      name: name,
      slug: slug,
      target_ref: target_ref,
      secret_encrypted: secret_encrypted,
      signature_header: signature_header_value(opts),
      timestamp_header: timestamp_header_value(opts),
      idempotency_key_header: idempotency_key_header_value(opts),
      input_template: input_template_json,
      description: Map.get(opts, :description),
      rate_limit: Map.get(opts, :rate_limit),
      created_by: ctx.user_id,
      scope_type: scope_t,
      org_id: oid,
      project_id: pid
    }
  end

  # `nil`/`""` ⇒ feature off (no timestamp check). Stored lowercased so
  # incoming header lookup is case-insensitive (Plug headers are downcased).
  defp timestamp_header_value(opts) do
    case Map.get(opts, :timestamp_header) do
      nil -> nil
      "" -> nil
      header when is_binary(header) -> String.downcase(header)
    end
  end

  # `nil`/`""` ⇒ no idempotency check. When set, the named header carries
  # an event id (e.g. GitHub's "x-github-delivery", Stripe's event id) and
  # repeat deliveries within the TTL window short-circuit to a 200 with
  # `status: "duplicate"`.
  defp idempotency_key_header_value(opts) do
    case Map.get(opts, :idempotency_key_header) do
      nil -> nil
      "" -> nil
      header when is_binary(header) -> String.downcase(header)
    end
  end

  defp signature_header_value(opts) do
    case Map.get(opts, :signature_header) do
      nil -> "x-cyfr-signature"
      "" -> "x-cyfr-signature"
      header when is_binary(header) -> String.downcase(header)
    end
  end

  defp normalize_update_attrs(attrs) do
    fields =
      attrs
      |> Map.take([
        :target_ref,
        :signature_header,
        :timestamp_header,
        :idempotency_key_header,
        :input_template,
        :description,
        :rate_limit
      ])

    with {:ok, fields} <- maybe_encode_input_template_attr(fields) do
      fields =
        fields
        |> maybe_normalize_signature_header()
        |> maybe_normalize_timestamp_header()
        |> maybe_normalize_idempotency_key_header()

      {:ok, fields}
    end
  end

  defp maybe_encode_input_template_attr(%{input_template: template} = fields) do
    case encode_input_template(template) do
      {:ok, json} -> {:ok, Map.put(fields, :input_template, json)}
      {:error, _} = error -> error
    end
  end

  defp maybe_encode_input_template_attr(fields), do: {:ok, fields}

  defp maybe_normalize_signature_header(%{signature_header: header} = fields)
       when is_binary(header) do
    Map.put(fields, :signature_header, signature_header_value(%{signature_header: header}))
  end

  defp maybe_normalize_signature_header(fields), do: fields

  defp maybe_normalize_timestamp_header(%{timestamp_header: header} = fields)
       when is_binary(header) do
    # Empty string updates clear the field (turn replay protection off).
    Map.put(fields, :timestamp_header, timestamp_header_value(%{timestamp_header: header}))
  end

  defp maybe_normalize_timestamp_header(fields), do: fields

  defp maybe_normalize_idempotency_key_header(%{idempotency_key_header: header} = fields)
       when is_binary(header) do
    # Empty string updates clear the field (turn idempotency check off).
    Map.put(
      fields,
      :idempotency_key_header,
      idempotency_key_header_value(%{idempotency_key_header: header})
    )
  end

  defp maybe_normalize_idempotency_key_header(fields), do: fields

  defp encode_input_template(nil), do: {:ok, "{}"}
  defp encode_input_template(map) when map_size(map) == 0, do: {:ok, "{}"}

  defp encode_input_template(map) when is_map(map) do
    cond do
      has_reserved_key?(map) ->
        {:error, :reserved_key}

      true ->
        case Jason.encode(map) do
          {:ok, json} when byte_size(json) <= @max_input_template_bytes -> {:ok, json}
          {:ok, _} -> {:error, :input_template_too_large}
          {:error, _} -> {:error, :invalid_input_template}
        end
    end
  end

  defp encode_input_template(_), do: {:error, :invalid_input_template}

  # Check the map for reserved keys in BOTH string and atom forms. Direct
  # Elixir callers can pass atom-keyed maps (e.g. `%{_webhook: "x"}`); we
  # reject those upfront for a clean error rather than relying on the
  # controller's `Map.put("_webhook", envelope)` to silently overwrite.
  defp has_reserved_key?(map) do
    Enum.any?(@reserved_input_keys, fn key ->
      Map.has_key?(map, key) or Map.has_key?(map, String.to_atom(key))
    end)
  end

  defp generate_secret do
    secret =
      "whsec_" <>
        (:crypto.strong_rand_bytes(@secret_random_bytes) |> Base.url_encode64(padding: false))

    {:ok, secret}
  end

  defp generate_slug do
    "wh_" <> (:crypto.strong_rand_bytes(@slug_random_bytes) |> Base.url_encode64(padding: false))
  end

  defp public_view(row) do
    slug = row.slug

    %{
      name: row.name,
      slug: slug,
      url: build_url(slug),
      target_ref: row.target_ref,
      signature_header: row.signature_header,
      timestamp_header: row.timestamp_header,
      idempotency_key_header: row.idempotency_key_header,
      input_template: decode_template_safely(row.input_template, slug),
      description: row.description,
      enabled: row.enabled,
      rate_limit: row.rate_limit,
      created_at: format_datetime(row.inserted_at),
      rotated_at: format_datetime(row.rotated_at)
    }
  end

  defp decode_template_safely(json, slug) do
    case decode_input_template(json) do
      {:ok, map} ->
        map

      {:error, reason} ->
        Logger.warning(
          "[Sanctum.Webhook] corrupted input_template for slug=#{inspect(slug)} reason=#{inspect(reason)} — falling back to empty map"
        )

        %{}
    end
  end

  # Build the full webhook URL using the configured public URL. Returns the
  # path-only form when CYFR_PUBLIC_URL is unset (dev/test without explicit
  # config) — clients then need to prepend their own host.
  defp build_url(slug) when is_binary(slug) and slug != "" do
    case Application.get_env(:cyfr, :public_url) do
      base when is_binary(base) and base != "" ->
        String.trim_trailing(base, "/") <> "/hooks/" <> slug

      _ ->
        "/hooks/" <> slug
    end
  end

  defp build_url(_), do: nil

  # Single source of truth for the {scope, org_id, project_id} triple and the
  # tenant chokepoint — Sanctum.TenantScope (shared with Secrets/OAuth) raises
  # for an org-less non-platform context.
  defp extract_scope(%Context{} = ctx), do: Sanctum.TenantScope.extract(ctx)

  # AAD for create/2 and rotate/2, built from the writing context. Symmetric
  # with webhook_aad/1 (rebuilt from the stored row at verify time) via the
  # single `Sanctum.CipherAAD` definition.
  defp ctx_webhook_aad(scope_t, oid, pid, name),
    do: Sanctum.CipherAAD.webhook_secret(scope_t, oid, pid, name)

  # AAD for verify_with_grace/4, rebuilt from the stored webhook row. The
  # current and previous secret share this identity, so the rotation grace
  # window is AAD-stable.
  defp webhook_aad(webhook),
    do:
      Sanctum.CipherAAD.webhook_secret(
        webhook.scope_type,
        webhook.org_id,
        webhook.project_id,
        webhook.name
      )

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(other), do: other
end
