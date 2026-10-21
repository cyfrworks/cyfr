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
  `Sanctum.Cipher` (the `:webhook_secret` purpose) and decrypted
  just-in-time. Inbound verification (`verify_with_grace/4`) binds the
  webhook row's tenant identity into the cipher's AAD.

  Secrets are returned in plaintext exactly twice in their lifetime:
    * When created (`create/2`).
    * When rotated (`rotate/2`).
  Never on `get/2` or `list/1`. The CLI/UI must surface a one-time reveal.
  The inbound path opens them once more, inside the server:
  `resolve_ingress/1` hands the ingress plugs a row carrying a function
  that opens its signing secrets when it is called. Nothing is decrypted
  at the lookup, so a delivery the rate limiter refuses costs no
  decryption, and no inspection of the row or the connection carrying it
  can print a secret.

  ## Storage

  Rows are stored via `Arca.WebhookStorage`. See that module for tenant
  scoping and unique-index semantics.
  """

  require Logger

  # The default HMAC header is a wire shape (`Prima.Webhook`), read the same
  # way by webhook creation, the row store, the console and request
  # redaction.
  @default_signature_header Prima.Webhook.default_signature_header()

  alias Arca.WebhookStorage
  alias Prima.ComponentRef
  alias Sanctum.Consent.Components
  alias Sanctum.Context

  @slug_random_bytes 18

  @max_input_template_bytes 16 * 1024
  @reserved_input_keys ~w(_webhook)

  # After a rotation the outgoing secret keeps verifying for this long so
  # in-flight requests aren't dropped while the sender is updated. 24h is a
  # generous-but-bounded window; the old secret is ignored once it expires.
  @previous_secret_grace_seconds 86_400

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Create a new webhook. Returns the plaintext secret exactly once. Its
  secret outlives the session that mints it, so issuing one is a
  sensitive change (`credential_issuance`), decided here. From a paired
  device, the row is written in a transaction that holds the device's
  client and certificate (`Sanctum.Issuance.device_hold/1`): a revocation
  that commits after the request was verified writes nothing, and answers
  `{:error, :not_standing}`.

  Required: `name`, `target_ref`, `profile_id` (deliveries fire under the
  bound profile's consent). Optional: `input_template` (map; default
  `%{}`), `signature_header` (default `x-cyfr-signature`), `description`,
  `rate_limit`.

  Replay protection must be explicit: set `timestamp_header` or
  `idempotency_key_header`, or use `replay_protection: "none"` to accept
  replays. Configured headers must be supplied by the sender.
  """
  @spec create(Context.t(), map()) :: {:ok, map()} | {:error, term()}
  def create(%Context{} = ctx, %{name: name, target_ref: target_ref} = opts)
      when is_binary(name) and is_binary(target_ref) do
    athanor_id = athanor!(ctx)

    with :ok <- check_replay_decision(opts),
         :ok <- validate_target_ref(ctx, target_ref),
         :ok <- authorize_profile_binding(ctx, target_ref, Map.get(opts, :profile_id)),
         {:ok, input_template_json} <- encode_input_template(Map.get(opts, :input_template, %{})),
         {:ok, hold} <- Sanctum.Issuance.device_hold(ctx),
         :ok <-
           Sanctum.Consent.Authz.confirm(ctx, :credential_issuance, %{
             operation: "webhook.create",
             arguments: opts,
             resource: name
           }),
         {:ok, secret} <- generate_secret(),
         {:ok, secret_encrypted} <-
           Sanctum.Cipher.encrypt(secret, Sanctum.CipherAAD.webhook_secret(athanor_id, name)),
         slug <- generate_slug(),
         attrs <-
           build_attrs(
             ctx,
             athanor_id,
             name,
             target_ref,
             slug,
             secret_encrypted,
             input_template_json,
             opts
           ),
         :ok <- WebhookStorage.create_webhook(attrs, hold) do
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      {:ok,
       %{
         name: name,
         slug: slug,
         secret: secret,
         url: build_url(slug),
         target_ref: target_ref,
         # A round-trip of the JSON `encode_input_template/1` just produced,
         # not a read of a stored column: the template as every reader sees
         # it. The bang is safe because the value was encoded two lines up.
         input_template: Jason.decode!(input_template_json),
         signature_header: attrs.signature_header,
         replay_protection: replay_protection(attrs),
         created_at: now
       }}
    end
  end

  def create(_ctx, _opts), do: {:error, "name and target_ref are required"}

  # A signature proves the body came from someone holding the secret. It
  # says nothing about WHEN, so on its own it stays valid for a captured
  # delivery forever. Two things bound that, and both are per-webhook
  # optional: `timestamp_header` refuses a delivery outside the skew
  # window, `idempotency_key_header` refuses one that already ran.
  #
  # Neither can be inferred. An identical body is a replay if the sender
  # sends unique events and a legitimate repeat if it does not, and only
  # the sender's own timestamp or event id tells the two apart — so this
  # reports the gap rather than guessing at it.
  defp replay_protection(attrs) do
    case {present?(attrs[:timestamp_header]), present?(attrs[:idempotency_key_header])} do
      {false, false} -> "none"
      {true, false} -> "timestamp"
      {false, true} -> "idempotency_key"
      {true, true} -> "timestamp+idempotency_key"
    end
  end

  # Require an explicit idempotency mode before creating the webhook.
  # The caller may choose "none" for senders without an idempotency header.
  defp check_replay_decision(opts) do
    named_header? =
      present?(Map.get(opts, :timestamp_header)) or
        present?(Map.get(opts, :idempotency_key_header))

    case {named_header?, Map.get(opts, :replay_protection)} do
      {true, _} ->
        :ok

      {false, "none"} ->
        :ok

      {false, _absent_or_other} ->
        {:error, :replay_protection_required}
    end
  end

  defp present?(value), do: is_binary(value) and value != ""

  @doc """
  Get webhook details by name. Secret is never returned.
  """
  @spec get(Context.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(%Context{} = ctx, name) when is_binary(name) do
    case WebhookStorage.get_by_name(actor!(ctx), name) do
      {:ok, row} -> {:ok, public_view(row)}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  List the athanor's enabled webhooks. Secrets are never returned.
  """
  @spec list(Context.t()) :: {:ok, [map()]} | {:error, term()}
  def list(%Context{} = ctx) do
    case WebhookStorage.list_webhooks(actor!(ctx)) do
      {:ok, rows} -> {:ok, Enum.map(rows, &public_view/1)}
      error -> error
    end
  end

  @doc """
  Update mutable webhook fields without rotating the secret.

  Allowed fields: `target_ref`, `profile_id`, `signature_header`,
  `input_template`, `description`, `rate_limit`. Unknown fields are ignored.
  """
  @spec update(Context.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update(%Context{} = ctx, name, attrs) when is_binary(name) and is_map(attrs) do
    athanor_id = athanor!(ctx)

    with {:ok, normalized} <- normalize_update_attrs(attrs),
         :ok <- maybe_validate_target_ref(ctx, normalized),
         :ok <- maybe_authorize_profile_binding(ctx, name, athanor_id, normalized),
         :ok <- check_replay_transition(athanor_id, name, normalized, attrs),
         :ok <-
           WebhookStorage.update_webhook(Prima.Actor.in_athanor(athanor_id), name, normalized) do
      get(ctx, name)
    end
  end

  # The create-time decision is a one-shot unless this runs too. Clearing a
  # header is spelled `""` (see `maybe_normalize_timestamp_header/1`), so a
  # webhook created with `timestamp_header: "x-timestamp"` — which passed
  # the gate — could be updated to neither header and silently return to
  # accepting replays forever. Nothing recorded that it happened: there is
  # no `replay_protection` column, only the two header fields, so the row
  # afterwards is indistinguishable from one created with `"none"`.
  #
  # Judged on the RESULTING row, not the patch: an update that touches
  # neither header changes nothing to decide, and one that names a header
  # is its own answer.
  defp check_replay_transition(athanor_id, name, normalized, attrs) do
    touches_headers? =
      Map.has_key?(normalized, :timestamp_header) or
        Map.has_key?(normalized, :idempotency_key_header)

    if touches_headers? do
      case WebhookStorage.get_by_name(Prima.Actor.in_athanor(athanor_id), name) do
        {:ok, row} ->
          resulting = %{
            timestamp_header: resulting_header(normalized, row, :timestamp_header),
            idempotency_key_header: resulting_header(normalized, row, :idempotency_key_header),
            replay_protection: Map.get(attrs, :replay_protection)
          }

          check_replay_decision(resulting)

        # Nothing to transition from; `update_webhook/3` reports the miss.
        _ ->
          :ok
      end
    else
      :ok
    end
  end

  defp resulting_header(normalized, row, key) do
    case Map.fetch(normalized, key) do
      {:ok, value} -> value
      :error -> Map.get(row, key)
    end
  end

  # Re-pointing is the same act as binding: the gate runs against the
  # target the row will have after this update. An explicit nil is an
  # unbind, and an unbound webhook can never fire — refuse it here the
  # same way create does.
  defp maybe_authorize_profile_binding(ctx, name, athanor_id, normalized) do
    case Map.fetch(normalized, :profile_id) do
      :error ->
        :ok

      {:ok, nil} ->
        {:error, "profile_id is required — a webhook fires under its bound profile's consent"}

      {:ok, profile_id} ->
        target_ref =
          case Map.fetch(normalized, :target_ref) do
            {:ok, ref} when is_binary(ref) ->
              {:ok, ref}

            _ ->
              case WebhookStorage.get_by_name(Prima.Actor.in_athanor(athanor_id), name) do
                {:ok, row} -> {:ok, row.target_ref}
                {:error, _} = error -> error
              end
          end

        with {:ok, ref} <- target_ref do
          authorize_profile_binding(ctx, ref, profile_id)
        end
    end
  end

  @doc """
  Soft-disable a webhook. Subsequent inbound POSTs to its slug return 404.
  """
  @spec revoke(Context.t(), String.t()) ::
          :ok | {:error, :no_athanor | :not_found | :database_error}
  def revoke(%Context{} = ctx, name) when is_binary(name) do
    WebhookStorage.set_disabled(actor!(ctx), name)
  end

  @doc """
  Soft-disable every enabled webhook in the caller's athanor whose target
  is the component `target_ref` names, at any version — what removing the
  last version of a component does to the registrations that point at it.

  The disable is one write: every targeted webhook is disabled, or — when
  the store fails — none is, so an outage never leaves some of a
  component's registrations live and others not. Answers the ids disabled;
  one another caller disabled first is not among them. A ref that does not
  parse names no target, so nothing is disabled.
  """
  @spec disable_for_component(Context.t(), String.t()) ::
          {:ok, %{disabled: [String.t()]}} | {:error, :unavailable | :no_athanor}
  def disable_for_component(%Context{} = ctx, target_ref) when is_binary(target_ref) do
    actor = Context.actor(ctx)

    with {:ok, name_ref} <- component_name_ref(target_ref),
         {:ok, rows} <- enabled_webhooks(actor) do
      ids = for row <- rows, component_name_ref(row.target_ref) == {:ok, name_ref}, do: row.id
      disable_all(actor, ids)
    else
      {:error, :invalid_ref} -> {:ok, %{disabled: []}}
      {:error, _reason} = refusal -> refusal
    end
  end

  defp disable_all(_actor, []), do: {:ok, %{disabled: []}}

  defp disable_all(actor, ids) do
    case WebhookStorage.disable_all(actor, ids) do
      {:ok, disabled} -> {:ok, %{disabled: disabled}}
      {:error, :no_athanor} -> {:error, :no_athanor}
      {:error, _unreadable} -> {:error, :unavailable}
    end
  end

  defp component_name_ref(ref) when is_binary(ref) do
    case ComponentRef.to_name_ref(ref) do
      {:ok, name_ref} -> {:ok, name_ref}
      {:error, _} -> {:error, :invalid_ref}
    end
  end

  defp component_name_ref(_ref), do: {:error, :invalid_ref}

  defp enabled_webhooks(actor) do
    case WebhookStorage.list_webhooks(actor) do
      {:ok, rows} -> {:ok, rows}
      {:error, :no_athanor} -> {:error, :no_athanor}
      {:error, _unreadable} -> {:error, :unavailable}
    end
  end

  @doc """
  The webhook a delivery's slug names, for the ingress plugs that
  rate-limit, verify and admit it.

  An inventoried system responsibility
  (`Cyfr.Boundaries.system_responsibilities/0`): the slug is the public
  address a sender posts to, read before any caller is known, and the
  athanor every later step is scoped by is the one read off the row.

  An enabled row carries `:signing_secrets`, a function that — when
  called, and not before — opens the current and, inside its grace window,
  previous secret, answering each as a binary or `:unreadable`, for
  `verify_with_grace/4`. The sealed columns are not carried as fields,
  and a disabled row carries no secret at all. A webhook a declared
  restore suspended is `{:error, :not_found}`, as a slug no row holds,
  and its secrets are never opened. The plug that verifies drops the
  function from the connection once it has.
  """
  @spec resolve_ingress(String.t()) :: {:ok, map()} | {:error, :not_found | :unavailable}
  def resolve_ingress(slug) when is_binary(slug) do
    case WebhookStorage.get_by_slug(slug) do
      # A declared restore suspended it: refused as a slug no row holds.
      {:ok, %{suspended: true}} -> {:error, :not_found}
      {:ok, row} -> {:ok, ingress_view(row)}
      {:error, :not_found} -> {:error, :not_found}
      {:error, _unreadable} -> {:error, :unavailable}
    end
  end

  # The closure holds the sealed bytes and the AAD they open under; it
  # decrypts only when the verifying plug calls it, so a lookup the rate
  # limiter refuses never touches the keyring.
  defp ingress_view(row) do
    view = Map.drop(row, [:secret_encrypted, :previous_secret_encrypted])

    if row.enabled == true and row.suspended == false do
      aad = webhook_aad(row)
      current = row.secret_encrypted
      previous = Map.get(row, :previous_secret_encrypted)
      expires_at = Map.get(row, :previous_secret_expires_at)

      Map.put(view, :signing_secrets, fn ->
        open_signing_secrets(current, previous, expires_at, aad)
      end)
    else
      view
    end
  end

  defp open_signing_secrets(current, previous, expires_at, aad) do
    %{
      current: open_secret(current, aad),
      previous:
        if(is_binary(previous) and previous_active?(expires_at), do: open_secret(previous, aad))
    }
  end

  defp open_secret(sealed, aad) do
    case decrypt_secret(sealed, aad) do
      {:ok, secret} -> secret
      {:error, :secret_unreadable} -> :unreadable
    end
  end

  @doc """
  Rotate the HMAC secret for a webhook. Returns the new plaintext secret
  exactly once. A sensitive change (`credential_issuance`), held to a
  paired device's client and certificate as at `create/2`.

  Not a hard cutover: the outgoing secret stays valid for
  `#{@previous_secret_grace_seconds}` seconds (`verify_with_grace/4` accepts
  it until then), so in-flight requests signed with the old secret keep
  working while the sender is updated. The new plaintext is returned only
  after the storage write commits.
  """
  @spec rotate(Context.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def rotate(%Context{} = ctx, name) when is_binary(name) do
    athanor_id = athanor!(ctx)

    previous_expires_at =
      DateTime.add(DateTime.utc_now(), @previous_secret_grace_seconds, :second)

    with {:ok, existing} <- get(ctx, name),
         {:ok, hold} <- Sanctum.Issuance.device_hold(ctx),
         :ok <-
           Sanctum.Consent.Authz.confirm(ctx, :credential_issuance, %{
             operation: "webhook.rotate",
             arguments: %{name: name},
             resource: name
           }),
         {:ok, new_secret} <- generate_secret(),
         {:ok, new_secret_encrypted} <-
           Sanctum.Cipher.encrypt(new_secret, Sanctum.CipherAAD.webhook_secret(athanor_id, name)),
         :ok <-
           WebhookStorage.rotate_secret(
             Prima.Actor.in_athanor(athanor_id),
             name,
             new_secret_encrypted,
             previous_expires_at,
             hold
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

  @doc """
  Re-enable the webhook `webhook_id` that a declared restore suspended,
  one the person created, under `proof` (`t:Sanctum.ApiKey.proof/0`).

  Under `:confirmation`, `ctx` is the person's own, in the webhook's
  athanor: the change (`webhook.reenable`) is asked first
  (`Sanctum.Consent.Authz.check/3`, which may answer the confirmation
  signal), and in the transaction that writes the webhook, after its row
  is locked, the confirmation is consumed and must be one
  `Sanctum.Pairing.restore_confirmed/1` admits: while the person's
  restore row is open, never one a passkey or paired device gave.

  Under `{:kit, %{user_id, credential_digest}}` no confirmation is asked:
  the webhook is found among the person's suspended webhooks in whichever
  athanor holds it, and in the transaction that writes it the person's
  restore row must be open and the kit credential still standing there.

  Refusals: `:not_found` for a webhook that is not the person's,
  `:revoked` for a disabled one, which is never revived, `:not_suspended`
  for one that already stands, and `:not_standing` for a kit credential
  that no longer stands; a confirmation's own refusals pass as they are.
  """
  @spec reenable(Context.t(), String.t(), Sanctum.ApiKey.proof()) ::
          {:ok, map()} | {:error, term()}
  def reenable(%Context{} = ctx, webhook_id, :confirmation) when is_binary(webhook_id) do
    with :ok <- tenant(ctx),
         {:ok, user_id} <- person(ctx),
         actor = actor!(ctx),
         {:ok, row} <- WebhookStorage.get_created_webhook(actor, user_id, webhook_id),
         :ok <- reenablable(row),
         change = reenable_change(row),
         :ok <- Sanctum.Consent.Authz.check(ctx, :restore_reenable, change),
         {:ok, row} <-
           WebhookStorage.reenable(actor, user_id, webhook_id,
             verify: fn _row -> confirmed_reenable(ctx, change) end
           ) do
      Sanctum.Consent.Authz.consumed(ctx)
      reenabled(row)
    end
  end

  def reenable(%Context{}, webhook_id, {:kit, %{user_id: user_id, credential_digest: digest}})
      when is_binary(webhook_id) and is_binary(user_id) and is_binary(digest) do
    with {:ok, athanor_id} <- suspended_webhook_athanor(user_id, webhook_id),
         {:ok, row} <-
           WebhookStorage.reenable(Prima.Actor.in_athanor(athanor_id), user_id, webhook_id,
             verify: fn _row -> Sanctum.Pairing.kit_confirmed(user_id, digest) end
           ) do
      reenabled(row)
    end
  end

  defp tenant(ctx) do
    case Context.tenant_ok(ctx) do
      {:error, :missing_tenant} -> {:error, :athanor_required}
      :ok -> :ok
    end
  end

  defp person(%Context{user_id: user_id}) when is_binary(user_id) and user_id != "",
    do: {:ok, user_id}

  defp person(%Context{}), do: {:error, :unauthenticated}

  # Asked before a confirmation is: a webhook no proof could re-enable
  # asks for none. The write reads the row again under its lock.
  defp reenablable(%{enabled: false}), do: {:error, :revoked}
  defp reenablable(%{suspended: true}), do: :ok
  defp reenablable(%{}), do: {:error, :not_suspended}

  defp reenable_change(row) do
    %{
      operation: "webhook.reenable",
      arguments: %{"webhook_id" => row.id},
      resource: row.name,
      details: %{
        "effect" =>
          "Re-enables the webhook #{row.name}, suspended when this home was restored " <>
            "from a backup, so deliveries signed with its secret run again"
      }
    }
  end

  # The confirmation is consumed after the webhook's row is locked, and
  # the person's restore row is locked after it (`restore_confirmed/1`).
  defp confirmed_reenable(ctx, change) do
    with :ok <- Sanctum.Consent.Authz.consume(ctx, {:restore_reenable, change}),
         do: Sanctum.Pairing.restore_confirmed(ctx)
  end

  # The kit sees the person's suspended webhooks alone, wherever they are.
  defp suspended_webhook_athanor(user_id, webhook_id) do
    case Arca.SecurityTransitions.restore_checklist(Prima.Actor.system(), user_id) do
      {:ok, %{webhooks: webhooks}} ->
        case Enum.find(webhooks, &(&1.id == webhook_id)) do
          %{athanor_id: athanor_id} -> {:ok, athanor_id}
          nil -> {:error, :not_found}
        end

      {:error, _unanswered} ->
        {:error, :database_error}
    end
  end

  defp reenabled(row) do
    Sanctum.Telemetry.webhooks_changed(row.athanor_id)

    {:ok,
     %{
       id: row.id,
       name: row.name,
       slug: row.slug,
       url: build_url(row.slug),
       target_ref: row.target_ref,
       description: row.description,
       enabled: row.enabled,
       suspended: row.suspended == true,
       created_at: Prima.Time.iso8601(row.inserted_at),
       rotated_at: Prima.Time.iso8601(row.rotated_at)
     }}
  end

  # The secret is opened only once the signature (and any timestamp) is
  # well-formed, so a malformed delivery is reported as malformed whatever
  # the state of the stored secret.
  defp do_verify(source, raw_body, "sha256=" <> received_hex, nil)
       when is_binary(raw_body) and is_binary(received_hex) do
    with {:ok, secret} <- open_source(source) do
      compare(:crypto.mac(:hmac, :sha256, secret, raw_body), received_hex)
    end
  end

  defp do_verify(source, raw_body, "sha256=" <> received_hex, timestamp)
       when is_binary(raw_body) and is_binary(received_hex) and is_binary(timestamp) do
    with {:ok, ts} <- parse_timestamp(timestamp),
         :ok <- check_skew(ts),
         {:ok, secret} <- open_source(source) do
      payload = Integer.to_string(ts) <> "." <> raw_body
      compare(:crypto.mac(:hmac, :sha256, secret, payload), received_hex)
    end
  end

  defp do_verify(_source, _raw_body, _received, _timestamp),
    do: {:error, :malformed_signature}

  # A secret the ingress row opened.
  defp open_source({:opened, secret}) when is_binary(secret), do: {:ok, secret}
  defp open_source({:opened, _unreadable}), do: {:error, :secret_unreadable}

  # Return stored-secret decryption failures separately from signature
  # mismatches. The rotation grace path may retry with the previous secret.
  defp decrypt_secret(secret_encrypted, aad) when is_binary(secret_encrypted) do
    case Sanctum.Cipher.decrypt(secret_encrypted, aad) do
      {:ok, secret} -> {:ok, secret}
      {:error, _} -> {:error, :secret_unreadable}
    end
  end

  defp decrypt_secret(_secret_encrypted, _aad), do: {:error, :secret_unreadable}

  @doc """
  Verify a signature against a webhook row, accepting the **previous** secret
  during the post-rotation grace window.

  Tries the current secret first; on any failure, falls back to the
  previous one iff it is present and `previous_secret_expires_at` is still
  in the future. After the grace window the previous secret is ignored, so
  a rotation isn't a hard cutover.

  `webhook` is a `resolve_ingress/1` row, whose secrets open under the AAD
  of the row's tenant tuple. A secret that does not open is
  `{:error, :secret_unreadable}`, and a timestamped delivery whose skew
  window the store cannot answer is `{:error, :unavailable}`.
  """
  @spec verify_with_grace(map(), binary(), binary(), binary() | nil) ::
          :ok | {:error, atom()}
  def verify_with_grace(webhook, raw_body, received_signature, timestamp \\ nil)
      when is_map(webhook) do
    {current, previous} = secret_sources(webhook)

    case do_verify(current, raw_body, received_signature, timestamp) do
      :ok ->
        :ok

      # The skew window could not be read: the previous secret would meet
      # the same window.
      {:error, :unavailable} ->
        {:error, :unavailable}

      {:error, reason} ->
        if previous != nil and
             previous_active?(Map.get(webhook, :previous_secret_expires_at)) do
          do_verify(previous, raw_body, received_signature, timestamp)
        else
          {:error, reason}
        end
    end
  end

  defp secret_sources(%{signing_secrets: opened}) when is_function(opened, 0) do
    %{current: current, previous: previous} = opened.()
    {{:opened, current}, if(previous != nil, do: {:opened, previous})}
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

  # The window is the `webhook_max_skew_seconds` platform setting, which
  # refuses a stale value: a store that cannot answer it refuses the
  # delivery (`{:error, :unavailable}`) rather than admit one against a
  # window this member cannot read.
  defp check_skew(ts) when is_integer(ts) do
    skew = abs(System.system_time(:second) - ts)

    case Arca.PlatformSettings.effective("webhook_max_skew_seconds") do
      {:ok, max} when is_integer(max) and skew <= max ->
        :ok

      {:ok, max} when is_integer(max) ->
        {:error, :timestamp_skew}

      {:ok, _malformed} ->
        {:error, :unavailable}

      {:error, :unavailable} ->
        {:error, :unavailable}

      {:error, reason} when reason in [:uninstalled, :unknown_key] ->
        raise "[Sanctum.Webhook] webhook_max_skew_seconds cannot be read: the setting is " <>
                "#{reason}"
    end
  end

  @doc """
  Decode the stored JSON `input_template` to a map. Used by the controller
  to merge with the POST envelope at invoke time.
  """
  @spec decode_input_template(String.t()) :: {:ok, map()} | {:error, atom()}
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
  #
  # The row is read through the component-facts port
  # (`Sanctum.Consent.Components`), which answers the exact version a
  # pinned ref names and the newest otherwise — so a pinned target whose
  # own version is gone is refused rather than admitted on its name.
  defp validate_target_ref(ctx, target_ref) do
    case ComponentRef.normalize_flexible(target_ref) do
      {:ok, ref} ->
        case Components.get_component(ctx, ref.name, ref.version, ref.namespace, ref.type) do
          {:ok, _row} ->
            :ok

          {:error, :not_found} ->
            {:error,
             "Component '#{ComponentRef.to_string(ref)}' not found in registry. " <>
               "Register or pull it first."}

          {:error, reason} ->
            {:error, "Cannot use target_ref '#{target_ref}': #{Prima.Refusal.message(reason)}"}
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
         athanor_id,
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
      profile_id: Map.get(opts, :profile_id),
      created_by: ctx.user_id,
      athanor_id: athanor_id
    }
  end

  # Binding a registration to a profile mints a standing conduit for that
  # profile's authority — it takes the consent authorization class, not a
  # permission a wildcard key would satisfy. A webhook fires under its bound
  # profile's consent or not at all, so an unbound registration is refused at
  # creation rather than minted as a row that can never fire.
  defp authorize_profile_binding(_ctx, _target_ref, nil) do
    {:error, "profile_id is required — a webhook fires under its bound profile's consent"}
  end

  defp authorize_profile_binding(ctx, target_ref, profile_id) when is_binary(profile_id) do
    case Sanctum.Consent.RegistrationBinding.authorize(ctx, target_ref, profile_id) do
      :ok ->
        :ok

      # A profile list or head the store could not answer, or one stored
      # damaged, is refused in its own class; every other refusal answers
      # the binding's sentence.
      {:error, reason} ->
        case Sanctum.Consent.RegistrationBinding.refusal(reason) do
          %Prima.Refusal{} = classed ->
            {:error, classed}

          _consent_or_argument ->
            {:error,
             "profile binding refused: #{Sanctum.Consent.RegistrationBinding.message(reason)}"}
        end
    end
  end

  defp authorize_profile_binding(_ctx, _target_ref, _), do: {:error, "invalid profile_id"}

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
      nil -> @default_signature_header
      "" -> @default_signature_header
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
        :rate_limit,
        :profile_id
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

  # Refused up front for a clean error rather than left for the
  # controller's `Map.put("_webhook", envelope)` to overwrite.
  defp has_reserved_key?(map), do: Enum.any?(@reserved_input_keys, &Map.has_key?(map, &1))

  defp generate_secret, do: {:ok, Prima.CredentialShape.mint(:webhook_secret)}

  defp generate_slug do
    "wh_" <> (:crypto.strong_rand_bytes(@slug_random_bytes) |> Base.url_encode64(padding: false))
  end

  defp public_view(row) do
    slug = row.slug

    %{
      id: row.id,
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
      suspended: row.suspended == true,
      rate_limit: row.rate_limit,
      created_at: Prima.Time.iso8601(row.inserted_at),
      rotated_at: Prima.Time.iso8601(row.rotated_at)
    }
  end

  defp decode_template_safely(json, slug) do
    case decode_input_template(json) do
      {:ok, map} ->
        map

      {:error, reason} ->
        Logger.error(
          "[Sanctum.Webhook] corrupted input_template for slug=#{inspect(slug)} reason=#{inspect(reason)} — falling back to empty map"
        )

        %{}
    end
  end

  # The sender needs an absolute URL, and only the operator knows the host
  # this instance is reachable at — behind a proxy or a tunnel it is not the
  # bind address. `CYFR_PUBLIC_URL` supplies it; without it the URL is the
  # path alone, which a client prefixes with the host it reaches the
  # deployment on, and the console and the CLI say what to set.
  defp build_url(slug) when is_binary(slug) and slug != "" do
    path = "/hooks/" <> slug

    case Sanctum.public_url() do
      nil -> path
      base -> base <> path
    end
  end

  defp build_url(_), do: nil

  # The athanor every management path keys on, behind the tenant chokepoint:
  # an athanor-less context raises before it can touch any row.
  defp athanor!(%Context{} = ctx), do: Context.athanor!(ctx)

  defp actor!(%Context{} = ctx) do
    _ = athanor!(ctx)
    Context.actor(ctx)
  end

  # AAD for opening a stored webhook row's secrets. The
  # current and previous secret share this identity, so the rotation grace
  # window is AAD-stable; create/2 and rotate/2 build the same tuple from the
  # writing context via the single `Sanctum.CipherAAD` definition.
  defp webhook_aad(webhook),
    do: Sanctum.CipherAAD.webhook_secret(webhook.athanor_id, webhook.name)
end
