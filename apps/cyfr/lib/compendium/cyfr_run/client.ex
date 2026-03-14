defmodule Compendium.CyfrRun.Client do
  @moduledoc """
  Client for the cyfr.run registry REST API.

  Handles search, discover, and component metadata operations via
  the cyfr.run REST API (/v1/ endpoints). Push and pull use OCI
  protocol through the gateway (registry.cyfr.run/v2/) via OCI.Client.

  This module is used exclusively by Core edition. Arx edition uses
  OCI.Client directly with configurable registries.
  """

  require Logger

  alias Compendium.Edition
  alias Compendium.OCI.Errors
  alias Sanctum.Context

  @default_api_url "https://cyfr.run"
  @max_retries 3
  @base_delay_ms 500
  @receive_timeout 30_000

  # -- Public API --

  @doc """
  Search for components on the cyfr.run registry.

  Sends GET /v1/components with query parameters (q, type, category, tags, license, limit, offset).
  Auth is not required for search (public endpoint).
  """
  @spec search(Context.t(), map()) :: {:ok, map()} | {:error, Errors.t()}
  def search(%Context{} = _ctx, params) when is_map(params) do
    query = build_search_query(params)
    path = "/v1/components" <> query

    case request(:get, path) do
      {:ok, 200, _headers, body} ->
        case Jason.decode(body) do
          {:ok, %{"components" => components} = data} ->
            {:ok, %{components: components, total: data["total"] || length(components)}}

          {:ok, unexpected} ->
            {:error, Errors.parse_error("search", unexpected)}

          {:error, reason} ->
            {:error, Errors.parse_error("search", reason)}
        end

      {:ok, status, _headers, body} ->
        {:error, Errors.from_api_response(status, body, "search")}

      {:error, %Errors{} = err} ->
        {:error, err}
    end
  end

  @doc """
  Discover components on the cyfr.run registry.

  Sends GET /v1/components with publisher/namespace filter.
  Replaces the fragile _catalog approach for Core edition.
  """
  @spec discover(Context.t(), map()) :: {:ok, map()} | {:error, Errors.t()}
  def discover(%Context{} = _ctx, params) when is_map(params) do
    query = build_discover_query(params)
    path = "/v1/components" <> query

    case request(:get, path) do
      {:ok, 200, _headers, body} ->
        case Jason.decode(body) do
          {:ok, %{"components" => components} = data} ->
            {:ok, %{
              registry: Edition.cyfr_run_registry(),
              components: components,
              total: data["total"] || length(components)
            }}

          {:ok, unexpected} ->
            {:error, Errors.parse_error("discover", unexpected)}

          {:error, reason} ->
            {:error, Errors.parse_error("discover", reason)}
        end

      {:ok, status, _headers, body} ->
        {:error, Errors.from_api_response(status, body, "discover")}

      {:error, %Errors{} = err} ->
        {:error, err}
    end
  end

  @doc """
  Get component metadata from the cyfr.run index.

  Sends GET /v1/components/:type/:publisher/:name[/:version].
  """
  @spec get_component(Context.t(), String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, Errors.t()}
  def get_component(%Context{} = _ctx, type, publisher, name, version \\ nil) do
    path =
      if version do
        "/v1/components/#{URI.encode(type)}/#{URI.encode(publisher)}/#{URI.encode(name)}/#{URI.encode(version)}"
      else
        "/v1/components/#{URI.encode(type)}/#{URI.encode(publisher)}/#{URI.encode(name)}"
      end

    case request(:get, path) do
      {:ok, 200, _headers, body} ->
        case Jason.decode(body) do
          {:ok, component} when is_map(component) ->
            {:ok, component}

          {:ok, unexpected} ->
            {:error, Errors.parse_error("get_component", unexpected)}

          {:error, reason} ->
            {:error, Errors.parse_error("get_component", reason)}
        end

      {:ok, status, _headers, body} ->
        {:error, Errors.from_api_response(status, body, "get_component")}

      {:error, %Errors{} = err} ->
        {:error, err}
    end
  end

  # -- Transport --

  defp request(method, path, extra_headers \\ [], body \\ nil) do
    url = api_base_url() <> path
    headers = auth_headers() ++ extra_headers
    do_request(method, url, headers, body, 0)
  end

  defp do_request(_method, _url, _headers, _body, attempt) when attempt >= @max_retries do
    Logger.error("[Compendium.CyfrRun.Client] All #{@max_retries} retries exhausted for cyfr.run API")
    {:error, Errors.api_connection_error(:max_retries_exceeded)}
  end

  defp do_request(method, url, headers, body, attempt) do
    req =
      Finch.build(method, url, headers, body)

    case Finch.request(req, Compendium.Finch, receive_timeout: @receive_timeout) do
      {:ok, %Finch.Response{status: status, headers: _resp_headers, body: resp_body}}
      when status >= 500 ->
        if attempt + 1 < @max_retries do
          delay = @base_delay_ms * Integer.pow(2, attempt)
          Logger.warning("[Compendium.CyfrRun.Client] #{status} from cyfr.run, retrying in #{delay}ms (attempt #{attempt + 1}/#{@max_retries})")
          Process.sleep(delay)
          do_request(method, url, headers, body, attempt + 1)
        else
          Logger.error("[Compendium.CyfrRun.Client] #{status} from cyfr.run on final attempt — giving up")
          {:error, Errors.from_api_response(status, resp_body, "request")}
        end

      {:ok, %Finch.Response{status: status, headers: resp_headers, body: resp_body}} ->
        {:ok, status, resp_headers, resp_body}

      {:error, %Mint.TransportError{reason: reason}} ->
        if attempt + 1 < @max_retries do
          delay = @base_delay_ms * Integer.pow(2, attempt)
          Logger.warning("[Compendium.CyfrRun.Client] Connection error: #{inspect(reason)}, retrying in #{delay}ms (attempt #{attempt + 1}/#{@max_retries})")
          Process.sleep(delay)
          do_request(method, url, headers, body, attempt + 1)
        else
          Logger.error("[Compendium.CyfrRun.Client] Connection error: #{inspect(reason)} — giving up after #{@max_retries} attempts")
          {:error, Errors.api_connection_error(reason)}
        end

      {:error, reason} ->
        if attempt + 1 < @max_retries do
          delay = @base_delay_ms * Integer.pow(2, attempt)
          Logger.warning("[Compendium.CyfrRun.Client] Error: #{inspect(reason)}, retrying in #{delay}ms (attempt #{attempt + 1}/#{@max_retries})")
          Process.sleep(delay)
          do_request(method, url, headers, body, attempt + 1)
        else
          Logger.error("[Compendium.CyfrRun.Client] Error: #{inspect(reason)} — giving up after #{@max_retries} attempts")
          {:error, Errors.api_connection_error(reason)}
        end
    end
  end

  defp api_base_url do
    Application.get_env(:cyfr, :cyfr_run_api_url, @default_api_url)
  end

  # Uses the OCI credential `password` field as a Bearer token. This works because
  # `cyfr login` stores the JWT in the password field of the Docker credential store.
  # The coupling is intentional: one credential set serves both OCI (Basic auth via
  # Transport) and REST API (Bearer token here).
  defp auth_headers do
    case Compendium.OCI.Auth.resolve_credentials(Edition.cyfr_run_registry()) do
      {:ok, %{password: password}} when is_binary(password) and password != "" ->
        [{"authorization", "Bearer #{password}"}]

      :anonymous ->
        []

      {:ok, unexpected} ->
        Logger.warning("[Compendium.CyfrRun.Client] Unexpected credential format: #{inspect(unexpected)}. " <>
                       "Proceeding without auth. Run `cyfr login` to reconfigure credentials.")
        []
    end
  end

  defp build_search_query(params) do
    pairs =
      [
        {"q", params[:query]},
        {"type", params[:type]},
        {"category", params[:category]},
        {"license", params[:license]},
        {"limit", params[:limit]},
        {"offset", params[:offset]}
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    pairs =
      case params[:tags] do
        tags when is_list(tags) and tags != [] ->
          pairs ++ Enum.map(tags, fn tag -> {"tags", tag} end)

        _ ->
          pairs
      end

    if pairs == [] do
      ""
    else
      "?" <> URI.encode_query(pairs)
    end
  end

  defp build_discover_query(params) do
    pairs =
      [
        {"publisher", params[:namespace]},
        {"type", params[:type]},
        {"limit", params[:limit]}
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    if pairs == [] do
      ""
    else
      "?" <> URI.encode_query(pairs)
    end
  end

end
