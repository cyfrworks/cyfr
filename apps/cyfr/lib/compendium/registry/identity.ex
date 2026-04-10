defmodule Compendium.Registry.Identity do
  @moduledoc """
  Resolves OCI registry credentials and identity information.

  Single source of truth: `Compendium.Registry.CredentialStore`.

  In Core mode, credentials are resolved by user_id from the context.
  In Arx mode, tenant credentials from `Arca.SecretStorage` are checked first,
  then per-user credentials from `CredentialStore`.
  """

  require Logger

  @doc """
  Returns the authenticated identity for the configured OCI registry.

  Takes a `%Sanctum.Context{}` for per-tenant credential resolution in Arx mode.
  In Core mode, falls back to local credentials.
  """
  @spec identity(Sanctum.Context.t()) :: map()
  def identity(%Sanctum.Context{} = ctx) do
    case resolve_credentials(ctx) do
      {:ok, %{username: username, password: password}} ->
        do_whoami(username, password)

      :not_found ->
        %{authenticated: false}
    end
  rescue
    e in [ArgumentError, MatchError, ErlangError, Jason.DecodeError, CaseClauseError] ->
      Logger.error("Registry identity check failed: #{Exception.message(e)}")
      %{authenticated: false, reason: "error"}
  end

  defp do_whoami(username, password) do
    :inets.start()
    :ssl.start()

    url = registry_url()
    basic = Base.encode64("#{username}:#{password}")

    headers = [
      {~c"Authorization", String.to_charlist("Basic #{basic}")},
      {~c"Accept", ~c"application/json"}
    ]

    case :httpc.request(
           :get,
           {~c"https://#{url}/v1/auth/whoami", headers},
           [{:timeout, 3_000}, {:connect_timeout, 3_000}],
           []
         ) do
      {:ok, {{_version, 200, _reason}, _headers, body}} ->
        case Jason.decode(to_string(body)) do
          {:ok, data} ->
            %{
              authenticated: true,
              email: data["email"],
              publisher_name: data["publisher_name"],
              orgs: data["orgs"]
            }

          _ ->
            %{authenticated: true}
        end

      {:ok, {{_version, 401, _reason}, _headers, _body}} ->
        %{authenticated: false, reason: "invalid_credentials"}

      {:ok, {{_version, status, _reason}, _headers, _body}} ->
        Logger.warning("[Registry.Identity] whoami returned HTTP #{status}")
        %{authenticated: false, reason: "unreachable"}

      {:error, _reason} ->
        %{authenticated: false, reason: "unreachable"}
    end
  end

  defp registry_url do
    case Application.get_env(:cyfr, :registry, []) do
      config when is_list(config) -> Keyword.get(config, :url, "registry.cyfr.run")
      _ -> "registry.cyfr.run"
    end
  end

  alias Compendium.Registry.CredentialStore

  defp resolve_credentials(%Sanctum.Context{} = ctx) do
    registry = registry_url()

    if Code.ensure_loaded?(SanctumArx.Edition) and SanctumArx.Edition.arx?() do
      resolve_tenant_credentials(ctx, registry)
    else
      resolve_core_credentials(ctx, registry)
    end
  end

  defp resolve_core_credentials(%Sanctum.Context{user_id: user_id} = _ctx, registry) do
    case CredentialStore.get(user_id, registry) do
      {:ok, %{type: :basic, username: u, password: p}} ->
        {:ok, %{username: u, password: p}}

      {:ok, %{type: :bearer, token: t}} ->
        {:ok, %{username: "bearer", password: t}}

      {:ok, _} ->
        :not_found

      :not_found ->
        # Fallback: any user credential for this registry (Core is single-user)
        case CredentialStore.get_for_registry(registry) do
          {:ok, %{type: :basic, username: u, password: p}} ->
            {:ok, %{username: u, password: p}}

          {:ok, %{type: :bearer, token: t}} ->
            {:ok, %{username: "bearer", password: t}}

          _ ->
            :not_found
        end
    end
  end

  defp resolve_tenant_credentials(%Sanctum.Context{org_id: org_id, user_id: user_id}, registry) do
    # 1. Check tenant (org-scoped) credentials
    case Arca.SecretStorage.get_secret("registry_credentials", "global", org_id) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"username" => u, "password" => p}} ->
            {:ok, %{username: u, password: p}}

          _ ->
            # 2. Fall back to per-user credentials
            resolve_core_credentials(
              %Sanctum.Context{user_id: user_id},
              registry
            )
        end

      {:error, _} ->
        # Fall back to per-user credentials
        resolve_core_credentials(
          %Sanctum.Context{user_id: user_id},
          registry
        )
    end
  end
end
