# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.WebhookStorage do
  @moduledoc """
  Storage operations for inbound webhooks.

  Webhooks are receiver records bound to a target component. Each row stores
  an HMAC secret encrypted at rest (`secret_encrypted` via `Sanctum.Cipher`)
  because verification requires the raw secret — secrets here are *not* hashed.

  Webhooks have two unique indexes:
    * `slug` — globally unique URL routing key (`/hooks/:slug` → row).
    * `(athanor_id, name)` — stable handle for management operations
      (mirrors the api_keys uniqueness model).

  `slug` lookups are tenant-agnostic by design: the public `/hooks/:slug`
  endpoint cannot know an athanor from a path alone. The owning athanor is
  carried on the row and surfaced into the execution context at invoke time.

  Soft-disable via `enabled: false` (revoke). Audit trail is preserved.
  """

  require Logger
  require Arca.Repo.Errors
  import Ecto.Query

  import Arca.QueryHelpers, only: [where_athanor: 2]

  alias Arca.Schemas.Webhook

  @doc """
  Insert a new webhook row.

  Required attrs: `name`, `slug`, `target_ref`, `secret_encrypted`,
  `signature_header`, `athanor_id`. Optional: `input_template`,
  `description`, `rate_limit`, `created_by`.
  """
  @spec create_webhook(map()) :: :ok | {:error, term()}
  def create_webhook(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    row = %{
      id: Ecto.UUID.generate(),
      name: attrs.name,
      slug: attrs.slug,
      target_ref: attrs.target_ref,
      secret_encrypted: attrs.secret_encrypted,
      signature_header: attrs[:signature_header] || Sanctum.Webhook.default_signature_header(),
      timestamp_header: attrs[:timestamp_header],
      idempotency_key_header: attrs[:idempotency_key_header],
      input_template: attrs[:input_template] || "{}",
      description: attrs[:description],
      enabled: true,
      rate_limit: attrs[:rate_limit],
      profile_id: attrs[:profile_id],
      created_by: attrs[:created_by],
      rotated_at: nil,
      athanor_id: attrs.athanor_id,
      inserted_at: now,
      updated_at: now
    }

    Arca.Repo.insert_all(Webhook, [row])
    :ok
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      if Arca.Repo.Errors.unique_constraint_violation?(e) do
        {:error, :already_exists}
      else
        Logger.error("[WebhookStorage] Database error in create_webhook: #{Exception.message(e)}")
        {:error, :database_error}
      end
  end

  @doc """
  Look up a webhook by slug. Tenant-agnostic by design — the public
  `/hooks/:slug` route has no tenant context. Returns the row including
  `enabled`; callers MUST gate on `enabled == true`.

  > #### Caution {: .warning}
  >
  > The returned row includes the encrypted HMAC secret
  > (`secret_encrypted`). Callers MUST NOT log or serialize the whole row;
  > decrypt only what is needed for signature verification.
  """
  @spec get_by_slug(String.t()) :: {:ok, Webhook.t()} | {:error, :not_found}
  def get_by_slug(slug) when is_binary(slug) do
    query = from(w in Webhook, where: w.slug == ^slug, limit: 1)

    case Arca.Repo.one(query) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[WebhookStorage] Database error in get_by_slug: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  Look up a webhook by name within an athanor. Excludes disabled rows.
  """
  @spec get_by_name(String.t(), String.t()) :: {:ok, Webhook.t()} | {:error, :not_found}
  def get_by_name(name, athanor_id) do
    query =
      from(w in Webhook, where: w.name == ^name and w.enabled == ^true, limit: 1)
      |> where_athanor(athanor_id)

    case Arca.Repo.one(query) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[WebhookStorage] Database error in get_by_name: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  List an athanor's enabled webhooks, ordered by inserted_at.

  Returns the public-view columns only — the encrypted secret columns are
  deliberately not loaded here (the only caller redacts them anyway; the verify
  path uses `get_by_slug`/`get_by_name`, which do load the secret).
  """
  @spec list_webhooks(String.t()) :: {:ok, [Webhook.t()]} | {:error, term()}
  def list_webhooks(athanor_id) do
    query =
      from(w in Webhook,
        where: w.enabled == ^true,
        order_by: [asc: w.inserted_at],
        select: [
          :id,
          :name,
          :slug,
          :target_ref,
          :signature_header,
          :timestamp_header,
          :idempotency_key_header,
          :input_template,
          :description,
          :enabled,
          :rate_limit,
          :rotated_at,
          :inserted_at,
          :updated_at
        ]
      )
      |> where_athanor(athanor_id)

    {:ok, Arca.Repo.all(query)}
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[WebhookStorage] Database error in list_webhooks: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  Update mutable fields on an existing webhook (target_ref, signature_header,
  input_template, description, rate_limit). Does NOT change the secret or slug.
  """
  @spec update_webhook(String.t(), String.t(), map()) :: :ok | {:error, :not_found}
  def update_webhook(name, athanor_id, fields) when is_map(fields) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    allowed =
      fields
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
      |> Map.to_list()

    if allowed == [] do
      {:error, :no_fields}
    else
      query =
        from(w in Webhook, where: w.name == ^name and w.enabled == ^true)
        |> where_athanor(athanor_id)

      case Arca.Repo.update_all(query, set: allowed ++ [updated_at: now]) do
        {0, _} -> {:error, :not_found}
        {_, _} -> :ok
      end
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[WebhookStorage] Database error in update_webhook: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  Soft-disable a webhook. Returns `{:error, :not_found}` if no enabled row matches.
  """
  @spec set_disabled(String.t(), String.t()) :: :ok | {:error, :not_found}
  def set_disabled(name, athanor_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    query =
      from(w in Webhook, where: w.name == ^name and w.enabled == ^true)
      |> where_athanor(athanor_id)

    case Arca.Repo.update_all(query, set: [enabled: false, updated_at: now]) do
      {0, _} -> {:error, :not_found}
      {_, _} -> :ok
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[WebhookStorage] Database error in set_disabled: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  Replace the encrypted secret for an existing webhook.

  The outgoing secret is retained as `previous_secret_encrypted` until
  `previous_expires_at`, so in-flight requests signed with it keep verifying
  during the grace window (see `Sanctum.Webhook.verify_with_grace/4`).
  """
  @spec rotate_secret(String.t(), String.t(), binary(), DateTime.t()) ::
          :ok | {:error, :not_found | :database_error}
  def rotate_secret(name, athanor_id, new_secret_encrypted, previous_expires_at) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    query =
      from(w in Webhook, where: w.name == ^name and w.enabled == ^true)
      |> where_athanor(athanor_id)

    # Capture the outgoing secret so it stays valid through the grace window.
    case Arca.Repo.one(from(w in query, select: w.secret_encrypted, limit: 1)) do
      nil ->
        {:error, :not_found}

      current_secret ->
        result =
          Arca.Repo.update_all(query,
            set: [
              secret_encrypted: new_secret_encrypted,
              previous_secret_encrypted: current_secret,
              previous_secret_expires_at: DateTime.truncate(previous_expires_at, :microsecond),
              rotated_at: now,
              updated_at: now
            ]
          )

        case result do
          {0, _} -> {:error, :not_found}
          {_, _} -> :ok
        end
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[WebhookStorage] Database error in rotate_secret: #{Exception.message(e)}")
      {:error, :database_error}
  end
end
