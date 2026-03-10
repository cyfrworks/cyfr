defmodule Compendium.Registry.Identity do
  @moduledoc """
  Resolves OCI registry credentials and identity information.

  Credentials are resolved in order:
  1. Application config (`:compendium, :registry` with `:username`/`:password`)
  2. Credentials file at `~/.cyfr/oci-credentials.json`
  """

  require Logger

  @doc """
  Returns the authenticated identity for the configured OCI registry.

  Makes a whoami request against the registry and returns a map with
  authentication status and user details.
  """
  @spec identity() :: map()
  def identity do
    case resolve_registry_credentials() do
      {:ok, %{username: username, password: password}} ->
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

      :not_found ->
        %{authenticated: false}
    end
  rescue
    e ->
      Logger.error("Registry identity check failed: #{Exception.message(e)}")
      %{authenticated: false, reason: "error"}
  end

  defp registry_url do
    case Application.get_env(:compendium, :registry, []) do
      config when is_list(config) -> Keyword.get(config, :url, "registry.cyfr.run")
      _ -> "registry.cyfr.run"
    end
  end

  defp resolve_registry_credentials do
    registry = registry_url()

    # First: check app config (env var based)
    case Application.get_env(:compendium, :registry) do
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
