defmodule Arca.WebhookStorage do
  @moduledoc """
  SQLite storage operations for inbound webhooks.

  Webhooks are receiver records bound to a target component. Each row stores
  an HMAC secret encrypted at rest (`secret_encrypted` via `Sanctum.Crypto`)
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
  import Arca.QueryHelpers, only: [normalize_org_id: 1, where_org_id: 2, where_project_id: 2]

  defp normalize_project_id(nil), do: "default"
  defp normalize_project_id(""), do: "default"
  defp normalize_project_id(project_id) when is_binary(project_id), do: project_id

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
      created_by: attrs[:created_by],
      rotated_at: nil,
      scope_type: attrs[:scope_type] || "project",
      org_id: normalize_org_id(attrs[:org_id]),
      project_id: normalize_project_id(attrs[:project_id]),
      inserted_at: now,
      updated_at: now
    }

    Arca.Repo.insert_all("webhooks", [row])
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
  """
  @spec get_by_slug(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_by_slug(slug) when is_binary(slug) do
    query =
      from(w in "webhooks",
        where: w.slug == ^slug,
        limit: 1,
        select: %{
          id: w.id,
          name: w.name,
          slug: w.slug,
          target_ref: w.target_ref,
          secret_encrypted: w.secret_encrypted,
          signature_header: w.signature_header,
          timestamp_header: w.timestamp_header,
          idempotency_key_header: w.idempotency_key_header,
          input_template: w.input_template,
          description: w.description,
          enabled: w.enabled,
          rate_limit: w.rate_limit,
          created_by: w.created_by,
          rotated_at: w.rotated_at,
          scope_type: w.scope_type,
          org_id: w.org_id,
          project_id: w.project_id,
          inserted_at: w.inserted_at,
          updated_at: w.updated_at
        }
      )

    case Arca.Repo.one(query) do
      nil -> {:error, :not_found}
      row -> {:ok, normalize_row(row)}
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
          {:ok, map()} | {:error, :not_found}
  def get_by_name(name, scope_type, org_id, project_id \\ nil) do
    project = normalize_project_id(project_id)

    query =
      from(w in "webhooks",
        where: w.name == ^name and w.scope_type == ^scope_type and w.enabled == ^true,
        limit: 1,
        select: %{
          id: w.id,
          name: w.name,
          slug: w.slug,
          target_ref: w.target_ref,
          secret_encrypted: w.secret_encrypted,
          signature_header: w.signature_header,
          timestamp_header: w.timestamp_header,
          idempotency_key_header: w.idempotency_key_header,
          input_template: w.input_template,
          description: w.description,
          enabled: w.enabled,
          rate_limit: w.rate_limit,
          created_by: w.created_by,
          rotated_at: w.rotated_at,
          scope_type: w.scope_type,
          org_id: w.org_id,
          project_id: w.project_id,
          inserted_at: w.inserted_at,
          updated_at: w.updated_at
        }
      )

    query = query |> where_org_id(org_id) |> where_project_id(project)

    case Arca.Repo.one(query) do
      nil -> {:error, :not_found}
      row -> {:ok, normalize_row(row)}
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[WebhookStorage] Database error in get_by_name: #{Exception.message(e)}")
      {:error, :database_error}
  end

  @doc """
  List enabled webhooks within tenant scope, ordered by inserted_at.
  """
  @spec list_webhooks(String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, [map()]} | {:error, term()}
  def list_webhooks(scope_type, org_id, project_id \\ nil) do
    project = normalize_project_id(project_id)

    query =
      from(w in "webhooks",
        where: w.scope_type == ^scope_type and w.enabled == ^true,
        order_by: [asc: w.inserted_at],
        select: %{
          id: w.id,
          name: w.name,
          slug: w.slug,
          target_ref: w.target_ref,
          secret_encrypted: w.secret_encrypted,
          signature_header: w.signature_header,
          timestamp_header: w.timestamp_header,
          idempotency_key_header: w.idempotency_key_header,
          input_template: w.input_template,
          description: w.description,
          enabled: w.enabled,
          rate_limit: w.rate_limit,
          created_by: w.created_by,
          rotated_at: w.rotated_at,
          scope_type: w.scope_type,
          org_id: w.org_id,
          project_id: w.project_id,
          inserted_at: w.inserted_at,
          updated_at: w.updated_at
        }
      )

    query = query |> where_org_id(org_id) |> where_project_id(project)

    {:ok, Enum.map(Arca.Repo.all(query), &normalize_row/1)}
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
        :rate_limit
      ])
      |> Map.to_list()

    if allowed == [] do
      {:error, :no_fields}
    else
      query =
        from(w in "webhooks",
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
      from(w in "webhooks",
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
  """
  @spec rotate_secret(String.t(), String.t(), String.t() | nil, String.t() | nil, binary()) ::
          :ok | {:error, :not_found}
  def rotate_secret(name, scope_type, org_id, project_id, new_secret_encrypted) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    project = normalize_project_id(project_id)

    query =
      from(w in "webhooks",
        where: w.name == ^name and w.scope_type == ^scope_type and w.enabled == ^true
      )

    query = query |> where_org_id(org_id) |> where_project_id(project)

    case Arca.Repo.update_all(query,
           set: [
             secret_encrypted: new_secret_encrypted,
             rotated_at: now,
             updated_at: now
           ]
         ) do
      {0, _} -> {:error, :not_found}
      {_, _} -> :ok
    end
  rescue
    e in Arca.Repo.Errors.db_errors() ->
      Logger.error("[WebhookStorage] Database error in rotate_secret: #{Exception.message(e)}")
      {:error, :database_error}
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp normalize_row(row) do
    %{row | enabled: normalize_bool(row.enabled)}
  end

  defp normalize_bool(true), do: true
  defp normalize_bool(false), do: false
  defp normalize_bool("true"), do: true
  defp normalize_bool("false"), do: false
  defp normalize_bool(1), do: true
  defp normalize_bool(0), do: false
  defp normalize_bool(other), do: other
end
