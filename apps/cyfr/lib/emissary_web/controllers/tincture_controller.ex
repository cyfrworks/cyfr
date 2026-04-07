defmodule EmissaryWeb.TinctureController do
  @moduledoc """
  Tincture HTTP serving on EmissaryWeb (the platform API surface).

  All clients (Prism shell, Porta desktop, CLI, API keys) access tinctures
  through this single controller. Authentication is delegated to
  `Sanctum.TinctureAuth` which supports Phoenix signed tokens, MCP sessions,
  and API keys via query parameters.

  GET /t/:publisher/:tincture_name           — serve index.html
  GET /t/:publisher/:tincture_name/q/:query  — execute a declared query (public only)
  GET /t/:publisher/:tincture_name/*path     — serve static assets
  """

  use EmissaryWeb, :controller

  require Logger

  alias Sanctum.TinctureAccess
  alias Arca.TinctureData.{Schema, QueryRunner}

  @token_salt "tincture_access"
  @token_max_age 86_400

  # frame-ancestors * is safe — tincture iframes use sandbox="allow-scripts"
  # (no allow-same-origin), so the sandbox is the security boundary.
  @csp "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; " <>
         "img-src 'self' data:; font-src 'self'; connect-src 'self'; " <>
         "object-src 'none'; base-uri 'self'; frame-ancestors *"

  # -------------------------------------------------------------------
  # Index — serve the tincture's entry HTML
  # -------------------------------------------------------------------

  def index(conn, %{"publisher" => publisher, "tincture_name" => tincture_name}) do
    case resolve_tincture(conn, publisher, tincture_name) do
      {:ok, tincture, :public} ->
        case Cyfr.TinctureHelpers.resolve_entry(tincture) do
          {:ok, file_path} ->
            base_href = "/t/#{publisher}/#{tincture_name}/"

            conn
            |> delete_resp_header("x-frame-options")
            |> Cyfr.TinctureHelpers.serve_index(file_path, base_href, @csp)

          :error ->
            send_resp(conn, 404, "Not Found")
        end

      {:ok, tincture, :private} ->
        case Cyfr.TinctureHelpers.resolve_entry(tincture) do
          {:ok, file_path} ->
            token = Phoenix.Token.sign(EmissaryWeb.Endpoint, @token_salt, {publisher, tincture_name})
            base_href = "/t/#{publisher}/#{tincture_name}/_s/#{token}/"

            conn
            |> delete_resp_header("x-frame-options")
            |> Cyfr.TinctureHelpers.serve_index(file_path, base_href, @csp)

          :error ->
            send_resp(conn, 404, "Not Found")
        end

      {:error, :not_found} ->
        send_resp(conn, 404, "Not Found")
    end
  end

  # -------------------------------------------------------------------
  # Query — execute a declared query against the tincture's data.db
  # Public tinctures only (standalone mode uses HTTP).
  # Shell/Porta mode uses PostMessage and never hits this endpoint.
  # -------------------------------------------------------------------

  def query(conn, %{
        "publisher" => publisher,
        "tincture_name" => tincture_name,
        "query_name" => query_name
      } = params) do
    public_ctx = Cyfr.TinctureHelpers.build_public_context()

    with {:ok, tincture} <- TinctureAccess.get_public(public_ctx, publisher, tincture_name),
         true <- TinctureAccess.can_query?(tincture, query_name),
         {:ok, schema} <- Schema.parse_manifest_schema(tincture.manifest),
         query_def when not is_nil(query_def) <- schema.queries[query_name] do
      user_params = Map.drop(params, ["publisher", "tincture_name", "query_name"])

      case QueryRunner.execute(public_ctx, tincture, query_name, query_def, user_params) do
        {:ok, result} ->
          json(conn, %{
            query: query_name,
            data: result.data,
            columns: result.columns,
            cached: result.cached,
            updated_at: result.updated_at
          })

        {:error, reason} ->
          Logger.warning("[TinctureQuery] query failed: #{inspect(reason)}")
          conn |> put_status(500) |> json(%{error: "Internal error"})
      end
    else
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "Not Found"})
      false -> conn |> put_status(404) |> json(%{error: "Not Found"})
      nil -> conn |> put_status(404) |> json(%{error: "Not Found"})
      {:error, reason} ->
        Logger.warning("[TinctureQuery] request failed: #{inspect(reason)}")
        conn |> put_status(400) |> json(%{error: "Bad request"})
    end
  end

  # -------------------------------------------------------------------
  # Assets — static files (JS, CSS, images).
  # Public tinctures: served directly. Private: require signed token in path.
  # -------------------------------------------------------------------

  def asset(conn, %{
        "publisher" => publisher,
        "tincture_name" => tincture_name,
        "path" => segments
      }) do
    # Delete x-frame-options for assets loaded by tincture iframes
    conn = delete_resp_header(conn, "x-frame-options")

    case segments do
      ["_s", token | asset_segments] when asset_segments != [] ->
        serve_signed_asset(conn, publisher, tincture_name, token, asset_segments)

      _ ->
        serve_public_asset(conn, publisher, tincture_name, segments)
    end
  end

  defp serve_public_asset(conn, publisher, tincture_name, segments) do
    public_ctx = Cyfr.TinctureHelpers.build_public_context()

    case TinctureAccess.get_public(public_ctx, publisher, tincture_name) do
      {:ok, tincture} ->
        Cyfr.TinctureHelpers.serve_asset(conn, tincture.dir, segments, public: true, cors: true)

      {:error, :not_found} ->
        send_resp(conn, 404, "Not Found")
    end
  end

  defp serve_signed_asset(conn, publisher, tincture_name, token, segments) do
    case Phoenix.Token.verify(EmissaryWeb.Endpoint, @token_salt, token, max_age: @token_max_age) do
      {:ok, {^publisher, ^tincture_name}} ->
        public_ctx = Cyfr.TinctureHelpers.build_public_context()

        case TinctureAccess.lookup(public_ctx, publisher, tincture_name) do
          {:ok, tincture} ->
            Cyfr.TinctureHelpers.serve_asset(conn, tincture.dir, segments, public: false, cors: true)

          {:error, _} ->
            send_resp(conn, 404, "Not Found")
        end

      _ ->
        send_resp(conn, 404, "Not Found")
    end
  end

  # -------------------------------------------------------------------
  # Private — auth delegation to Sanctum.TinctureAuth
  # -------------------------------------------------------------------

  defp resolve_tincture(conn, publisher, tincture_name) do
    public_ctx = Cyfr.TinctureHelpers.build_public_context()

    case TinctureAccess.get_public(public_ctx, publisher, tincture_name) do
      {:ok, tincture} ->
        {:ok, tincture, :public}

      {:error, :not_found} ->
        case Sanctum.TinctureAuth.authenticate(conn) do
          {:ok, %Sanctum.Context{} = ctx} ->
            case TinctureAccess.get_private(ctx, publisher, tincture_name) do
              {:ok, tincture} -> {:ok, tincture, :private}
              {:error, _} -> {:error, :not_found}
            end

          :unauthenticated ->
            {:error, :not_found}
        end
    end
  end
end
