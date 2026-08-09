# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.WebhookStorage do
  @moduledoc """
  Storage operations for inbound webhooks.

  Webhooks are receiver records bound to a target component. Each row stores
  an HMAC secret encrypted at rest (`secret_encrypted` via the configured `Sanctum.Cipher`)
  because verification requires the raw secret — secrets here are *not* hashed.

  Webhooks have two unique indexes:
    * `slug` — globally unique URL routing key (`/hooks/:slug` → row).
    * `(name, scope_type, org_id, project_id)` — stable handle for management
      operations (mirrors the api_keys uniqueness model).

  `slug` lookups are tenant-agnostic by design: the public `/hooks/:slug`
  endpoint cannot know an org/project from a path alone. Tenant scoping is
  carried on the row and surfaced into the execution context at invoke time.

  Soft-disable via `enabled: false` (revoke). Audit trail is preserved.
  """

  require Logger
  require Arca.Repo.Errors
  import Ecto.Query

  import Arca.QueryHelpers,
    only: [normalize_org_id: 1, normalize_project_id: 1, where_org_id: 2, where_project_id: 2]

  alias Arca.Schemas.Webhook

  @doc """
  Insert a new webhook row.

  Required attrs: `name`, `slug`, `target_ref`, `secret_encrypted`,
  `signature_header`, `scope_type`. Optional: `input_template`,
  `description`, `rate_limit`, `created_by`, `org_id`, `project_id`.
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
      signature_header: attrs[:signature_header] || "x-cyfr-signature",
      timestamp_header: attrs[:timestamp_header],
      idempotency_key_header: attrs[:idempotency_key_header],
      input_template: attrs[:input_template] || "{}",
      description: attrs[:description],
      enabled: true,
      rate_limit: attrs[:rate_limit],
      profile_id: attrs[:profile_id],
      created_by: attrs[:created_by],
      rotated_at: nil,
      scope_type: attrs[:scope_type] || "project",
      org_id: normalize_org_id(attrs[:org_id]),
      project_id: normalize_project_id(attrs[:project_id]),
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
  Look up a webhook by name within tenant scope. Excludes disabled rows.
  """
  @spec get_by_name(String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, Webhook.t()} | {:error, :not_found}
  def get_by_name(name, scope_type, org_id, project_id \\ nil) do
    project = normalize_project_id(project_id)

    query =
      from(w in Webhook,
        where: w.name == ^name and w.scope_type == ^scope_type and w.enabled == ^true,
        limit: 1
      )

    query = query |> where_org_id(org_id) |> where_project_id(project)

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
  List enabled webhooks within tenant scope, ordered by inserted_at.

  Returns the public-view columns only — the encrypted secret columns are
  deliberately not loaded here (the only caller redacts them anyway; the verify
  path uses `get_by_slug`/`get_by_name`, which do load the secret).
  """
  @spec list_webhooks(String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, [Webhook.t()]} | {:error, term()}
  def list_webhooks(scope_type, org_id, project_id \\ nil) do
    project = normalize_project_id(project_id)

    query =
      from(w in Webhook,
        where: w.scope_type == ^scope_type and w.enabled == ^true,
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

    query = query |> where_org_id(org_id) |> where_project_id(project)

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
  @spec update_webhook(String.t(), String.t(), String.t() | nil, String.t() | nil, map()) ::
          :ok | {:error, :not_found}
  def update_webhook(name, scope_type, org_id, project_id, fields) when is_map(fields) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    project = normalize_project_id(project_id)

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
        from(w in Webhook,
          where: w.name == ^name and w.scope_type == ^scope_type and w.enabled == ^true
        )

      query = query |> where_org_id(org_id) |> where_project_id(project)

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
  @spec set_disabled(String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          :ok | {:error, :not_found}
  def set_disabled(name, scope_type, org_id, project_id \\ nil) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    project = normalize_project_id(project_id)

    query =
      from(w in Webhook,
        where: w.name == ^name and w.scope_type == ^scope_type and w.enabled == ^true
      )

    query = query |> where_org_id(org_id) |> where_project_id(project)

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
  @spec rotate_secret(
          String.t(),
          String.t(),
          String.t() | nil,
          String.t() | nil,
          binary(),
          DateTime.t()
        ) :: :ok | {:error, :not_found | :database_error}
  def rotate_secret(
        name,
        scope_type,
        org_id,
        project_id,
        new_secret_encrypted,
        previous_expires_at
      ) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    project = normalize_project_id(project_id)

    query =
      from(w in Webhook,
        where: w.name == ^name and w.scope_type == ^scope_type and w.enabled == ^true
      )

    query = query |> where_org_id(org_id) |> where_project_id(project)

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
