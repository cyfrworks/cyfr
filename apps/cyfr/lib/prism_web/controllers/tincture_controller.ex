defmodule PrismWeb.TinctureController do
  @moduledoc """
  Unified tincture serving: public tinctures are accessible by anyone,
  private tinctures require authentication.

  GET /t/:publisher/:tincture_name           — serve index.html
  GET /t/:publisher/:tincture_name/q/:query  — execute a declared query (public tinctures only)
  GET /t/:publisher/:tincture_name/*path     — serve static assets (public or signed-token)
  """

  use PrismWeb, :controller

  require Logger

  alias Sanctum.TinctureAccess
  alias Arca.TinctureData.{Schema, QueryRunner}

  @token_salt "tincture_access"
  @token_max_age 86_400

  # connect-src 'self' allows standalone public tinctures to use HTTP queries.
  # Shell iframes use PostMessage (unaffected by connect-src).
  @csp "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; " <>
         "img-src 'self' data:; font-src 'self'; connect-src 'self'; " <>
         "object-src 'none'; base-uri 'self'; frame-ancestors 'self'"

  # -------------------------------------------------------------------
  # Index — serve the tincture's entry HTML
  # -------------------------------------------------------------------

  def index(conn, %{"publisher" => publisher, "tincture_name" => tincture_name}) do
    case resolve_tincture(conn, publisher, tincture_name) do
      {:ok, tincture, :public} ->
        case PrismWeb.TinctureHelpers.resolve_entry(tincture) do
          {:ok, file_path} ->
            base_href = "/t/#{publisher}/#{tincture_name}/"
            PrismWeb.TinctureHelpers.serve_index(conn, file_path, base_href, @csp)

          :error ->
            send_resp(conn, 404, "Not Found")
        end

      {:ok, tincture, :private} ->
        case PrismWeb.TinctureHelpers.resolve_entry(tincture) do
          {:ok, file_path} ->
            token = Phoenix.Token.sign(PrismWeb.Endpoint, @token_salt, {publisher, tincture_name})
            base_href = "/t/#{publisher}/#{tincture_name}/_s/#{token}/"
            PrismWeb.TinctureHelpers.serve_index(conn, file_path, base_href, @csp)

          :error ->
            send_resp(conn, 404, "Not Found")
        end

      {:error, :not_found} ->
        send_resp(conn, 404, "Not Found")
    end
  end

  # -------------------------------------------------------------------
  # Query — execute a declared query against the tincture's data.db
  # Only accessible for public tinctures (standalone mode uses HTTP).
  # Shell mode uses PostMessage and never hits this endpoint.
  # -------------------------------------------------------------------

  def query(conn, %{
        "publisher" => publisher,
        "tincture_name" => tincture_name,
        "query_name" => query_name
      } = params) do
    public_ctx = PrismWeb.TinctureHelpers.build_public_context()

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
    case segments do
      ["_s", token | asset_segments] when asset_segments != [] ->
        serve_signed_asset(conn, publisher, tincture_name, token, asset_segments)

      _ ->
        serve_public_asset(conn, publisher, tincture_name, segments)
    end
  end

  defp serve_public_asset(conn, publisher, tincture_name, segments) do
    public_ctx = PrismWeb.TinctureHelpers.build_public_context()

    case TinctureAccess.get_public(public_ctx, publisher, tincture_name) do
      {:ok, tincture} ->
        PrismWeb.TinctureHelpers.serve_asset(conn, tincture.dir, segments, public: true, cors: true)

      {:error, :not_found} ->
        send_resp(conn, 404, "Not Found")
    end
  end

  defp serve_signed_asset(conn, publisher, tincture_name, token, segments) do
    case Phoenix.Token.verify(PrismWeb.Endpoint, @token_salt, token, max_age: @token_max_age) do
      {:ok, {^publisher, ^tincture_name}} ->
        public_ctx = PrismWeb.TinctureHelpers.build_public_context()

        case TinctureAccess.lookup(public_ctx, publisher, tincture_name) do
          {:ok, tincture} ->
            PrismWeb.TinctureHelpers.serve_asset(conn, tincture.dir, segments, public: false, cors: true)

          {:error, _} ->
            send_resp(conn, 404, "Not Found")
        end

      _ ->
        send_resp(conn, 404, "Not Found")
    end
  end

  # -------------------------------------------------------------------
  # Private
  # -------------------------------------------------------------------

  # Try public access first, then token auth (shell iframe), then session auth.
  # Returns indistinguishable 404 for missing AND private tinctures when
  # unauthenticated — never redirects, never leaks existence.
  # Returns {:ok, tincture, :public | :private} or {:error, :not_found}.
  defp resolve_tincture(conn, publisher, tincture_name) do
    public_ctx = PrismWeb.TinctureHelpers.build_public_context()

    case TinctureAccess.get_public(public_ctx, publisher, tincture_name) do
      {:ok, tincture} ->
        {:ok, tincture, :public}

      {:error, :not_found} ->
        cond do
          # Token auth — shell iframe passes ?_t=TOKEN (can't send cookies)
          (token = extract_token(conn)) != nil and
              verify_token(token, publisher, tincture_name) ->
            case TinctureAccess.lookup(public_ctx, publisher, tincture_name) do
              {:ok, tincture} -> {:ok, tincture, :private}
              {:error, _} -> {:error, :not_found}
            end

          # Session auth — direct browser visit with cookies
          conn.assigns[:context] != nil ->
            case TinctureAccess.get_private(conn.assigns[:context], publisher, tincture_name) do
              {:ok, tincture} -> {:ok, tincture, :private}
              {:error, _} -> {:error, :not_found}
            end

          true ->
            {:error, :not_found}
        end
    end
  end

  defp extract_token(conn) do
    case conn.query_string do
      "" -> nil
      qs -> URI.decode_query(qs)["_t"]
    end
  end

  defp verify_token(token, publisher, tincture_name) do
    case Phoenix.Token.verify(PrismWeb.Endpoint, @token_salt, token, max_age: @token_max_age) do
      {:ok, {^publisher, ^tincture_name}} -> true
      _ -> false
    end
  end
end
