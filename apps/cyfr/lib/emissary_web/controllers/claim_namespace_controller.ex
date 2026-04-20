defmodule EmissaryWeb.ClaimNamespaceController do
  @moduledoc """
  Handles the personal-namespace claim gate for web-browser sessions.

  - `GET /claim-namespace` — renders a form prompting the user for a slug
    (default = suggested username from the OAuth provider login).
  - `POST /claim-namespace/submit` — validates the signed `_cyfr_pending_probe`
    cookie, invokes `Compendium.Registry.Client.claim_personal_namespace/4`,
    stores the issued push token, and redirects to the dashboard (or the
    deep-link target stashed in `oauth_redirect_uri`).

  Accepted cross-layer coupling — this controller is part of the auth
  sliver in spirit but calls Compendium for the post-claim token storage.
  """

  use EmissaryWeb, :controller

  require Logger

  alias Compendium.Registry.Client
  alias Compendium.Registry.CredentialStore

  def show(conn, _params) do
    suggested = get_session(conn, :claim_suggested_username) || ""

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, render_page(suggested, nil))
  end

  def submit(conn, %{"username" => raw_username} = params) when is_binary(raw_username) do
    # Trim whitespace before sending to cyfr.run — its regex rejects padding
    # with a confusing 400 INVALID_USERNAME otherwise.
    username = String.trim(raw_username)

    with {:ok, conn, access_token} <- pop_pending_probe(conn),
         {:ok, user_id} <- current_user_id(conn),
         {:ok, provider} <- current_provider(conn, params),
         {:ok, body} <-
           Client.claim_personal_namespace(username, provider, access_token) do
      slug = body["slug"] || username
      token = body["token"]
      registry = Compendium.Edition.cyfr_run_registry()

      cond do
        not is_binary(token) ->
          # Server returned success but omitted the token field. Treat as a
          # local-store failure so the user retries rather than landing on a
          # dashboard without a usable push credential.
          Logger.error(
            "[ClaimNamespaceController] claim succeeded for #{slug} but " <>
              "response omitted `token`; refusing to mark claim-gate passed"
          )

          send_store_error_page(conn, username, provider)

        true ->
          cred = %{
            type: :push_token,
            token: token,
            namespace: slug,
            role: "personal",
            issued_at: DateTime.utc_now() |> DateTime.to_iso8601(),
            label: Client.device_label()
          }

          case CredentialStore.put(user_id, registry, slug, cred) do
            :ok ->
              # Prime the cache so the next request exits the gate immediately.
              EmissaryWeb.Plugs.PersonalNamespaceCache.put_claimed(user_id, registry)

              redirect_target =
                get_session(conn, :oauth_redirect_uri) ||
                  Application.get_env(:cyfr, :post_login_redirect, "/")

              conn
              |> clear_pending_probe()
              |> delete_session(:oauth_redirect_uri)
              |> delete_session(:claim_suggested_username)
              |> redirect(external: redirect_target)

            {:error, reason} ->
              Logger.error(
                "[ClaimNamespaceController] CredentialStore.put failed for " <>
                  "#{user_id}/#{slug}: #{inspect(reason)}. Namespace is claimed on " <>
                  "cyfr.run but local credential is missing; user must re-login."
              )

              send_store_error_page(conn, username, provider)
          end
      end
    else
      {:expired, conn} ->
        conn
        |> put_status(:bad_request)
        |> put_resp_content_type("text/html")
        |> send_resp(
          400,
          render_page(username,
            error: "Login session expired. Please re-authenticate and try again."
          )
        )

      {:not_logged_in, conn} ->
        conn
        |> put_status(:unauthorized)
        |> redirect(to: "/auth/github")

      {:error, :invalid_access_token} ->
        # IdP access_token expired between the callback-side cookie stash and
        # the claim submission. Can't recover; bounce back through OAuth.
        # Clear the dead cookie so the fresh auth round starts clean.
        provider_for_redirect =
          case params["provider"] do
            p when p in ["github", "google"] -> p
            _ -> "github"
          end

        conn
        |> clear_pending_probe()
        |> redirect(to: "/auth/#{provider_for_redirect}")

      {:error, err} ->
        msg =
          case err do
            %Compendium.OCI.Errors{} -> Exception.message(err)
            b when is_binary(b) -> b
            other -> inspect(other)
          end

        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, render_page(username, error: msg))
    end
  end

  def submit(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> put_resp_content_type("text/html")
    |> send_resp(400, render_page("", error: "username is required"))
  end

  # ============================================================================
  # Internal
  # ============================================================================

  # Renders a 500 page when the claim succeeded server-side but the local
  # credential store write failed. Session keys are preserved so the user can
  # retry without losing OAuth-redirect context. UX hint directs them to
  # re-login rather than refresh-loop on the same dead cookie.
  defp send_store_error_page(conn, username, _provider) do
    conn
    |> put_status(:internal_server_error)
    |> put_resp_content_type("text/html")
    |> send_resp(
      500,
      render_page(username,
        error:
          "Namespace claimed on cyfr.run but we couldn't save the credential locally. " <>
            "Please sign out and sign back in to retry."
      )
    )
  end

  # Reads (but does NOT delete) the signed `_cyfr_pending_probe` cookie. The
  # caller must call `clear_pending_probe/1` on the success path — a failed
  # claim (e.g. `slug_taken` 409) re-renders the form and the user retries
  # with the same access_token. Deleting here would doom the retry to 400
  # "Login session expired" after a single typo.
  defp pop_pending_probe(conn) do
    conn = fetch_cookies(conn, signed: ["_cyfr_pending_probe"])

    case conn.cookies["_cyfr_pending_probe"] do
      token when is_binary(token) and token != "" ->
        {:ok, conn, token}

      _ ->
        {:expired, conn}
    end
  end

  defp clear_pending_probe(conn) do
    delete_resp_cookie(conn, "_cyfr_pending_probe")
  end

  defp current_user_id(conn) do
    case get_session(conn, :sanctum_session_token) do
      token when is_binary(token) and token != "" ->
        case Sanctum.Session.get_user(token) do
          {:ok, %{id: id}} -> {:ok, id}
          _ -> {:not_logged_in, conn}
        end

      _ ->
        {:not_logged_in, conn}
    end
  end

  defp current_provider(_conn, %{"provider" => p}) when p in ["github", "google"], do: {:ok, p}

  defp current_provider(conn, _params) do
    case Sanctum.Session.get_user(get_session(conn, :sanctum_session_token) || "") do
      {:ok, %{provider: p}} when p in ["github", "google"] -> {:ok, p}
      _ -> {:ok, "github"}
    end
  end

  # Minimal server-rendered HTML. Kept inline to avoid introducing a Phoenix
  # HTML layout just for this transient page. If the gate grows richer UI,
  # swap to a LiveView.
  defp render_page(suggested, opts) do
    error =
      case opts do
        nil -> ""
        list when is_list(list) -> list[:error] || ""
        _ -> ""
      end

    csrf = Plug.CSRFProtection.get_csrf_token()
    safe_suggested = Plug.HTML.html_escape_to_iodata(suggested) |> IO.iodata_to_binary()
    safe_error = Plug.HTML.html_escape_to_iodata(error) |> IO.iodata_to_binary()

    """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8"/>
        <title>Claim your cyfr.run namespace</title>
        <meta name="viewport" content="width=device-width, initial-scale=1"/>
        <style>
          body { font-family: system-ui, sans-serif; max-width: 40rem; margin: 4rem auto; padding: 0 1rem; }
          h1 { font-size: 1.5rem; }
          p { color: #444; line-height: 1.5; }
          label { display:block; margin-top: 1.5rem; font-weight: 600; }
          input[type="text"] { width: 100%; padding: 0.5rem 0.75rem; font-size: 1rem; box-sizing: border-box; }
          button { margin-top: 1rem; padding: 0.5rem 1rem; font-size: 1rem; cursor: pointer; }
          .error { background: #fee; color: #a00; padding: 0.75rem 1rem; border-radius: 4px; margin-top: 1rem; }
          .hint { font-size: 0.875rem; color: #666; margin-top: 0.5rem; }
        </style>
      </head>
      <body>
        <h1>Claim your cyfr.run namespace</h1>
        <p>
          To publish or pull private components, you need a personal namespace on cyfr.run.
          Personal namespaces follow GitHub-style rules: lowercase letters, digits, and single hyphens (1–39 chars).
          This is a one-time choice per identity.
        </p>
        #{if safe_error != "", do: "<div class=\"error\">" <> safe_error <> "</div>", else: ""}
        <form method="POST" action="/claim-namespace/submit">
          <input type="hidden" name="_csrf_token" value="#{csrf}"/>
          <label for="username">Namespace slug</label>
          <input id="username" type="text" name="username" value="#{safe_suggested}" pattern="^[a-z0-9]+(-[a-z0-9]+)*$" minlength="1" maxlength="39" required autofocus/>
          <p class="hint">Must be bare (no dot, no '@'). Examples: <code>alice</code>, <code>bob-123</code>.</p>
          <button type="submit">Claim namespace</button>
        </form>
      </body>
    </html>
    """
  end
end
