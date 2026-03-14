defmodule Compendium.Registry.Identity do
  @moduledoc """
  Resolves OCI registry credentials and identity information.

  Credentials are resolved in order:
  1. Tenant credentials from `Arca.SecretStorage` (Arx mode only)
  2. Application config (`:compendium, :registry` with `:username`/`:password`)
  3. Credentials file at `~/.cyfr/oci-credentials.json`
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
    e in [ArgumentError, MatchError, ErlangError, Jason.DecodeError] ->
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

  defp resolve_credentials(%Sanctum.Context{} = ctx) do
    if SanctumArx.Edition.arx?() do
      resolve_tenant_credentials(ctx)
    else
      resolve_local_credentials()
    end
  end

  defp resolve_tenant_credentials(%Sanctum.Context{org_id: org_id} = _ctx) do
    case Arca.SecretStorage.get_secret("registry_credentials", "global", org_id) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"username" => u, "password" => p}} ->
            {:ok, %{username: u, password: p}}

          _ ->
            :not_found
        end

      {:error, _} ->
        # Fall back to local credentials if no tenant credentials stored
        resolve_local_credentials()
    end
  end

  defp resolve_local_credentials do
    registry = registry_url()

    # First: check app config (env var based)
    case Application.get_env(:cyfr, :registry) do
      config when is_list(config) ->
        username = Keyword.get(config, :username)
        password = Keyword.get(config, :password)

        if username && password do
          {:ok, %{username: username, password: password}}
        else
          resolve_registry_credentials_from_file(registry)
        end

      _ ->
        resolve_registry_credentials_from_file(registry)
    end
  end

  defp resolve_registry_credentials_from_file(registry) do
    path = Path.join([System.user_home!(), ".cyfr", "oci-credentials.json"])

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"registries" => registries}} ->
            case Map.get(registries, registry) do
              %{"username" => u, "password" => p} when is_binary(u) and is_binary(p) ->
                {:ok, %{username: u, password: p}}

              _ ->
                :not_found
            end

          _ ->
            :not_found
        end

      {:error, _} ->
        :not_found
    end
  end
end
