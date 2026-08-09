# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.Plugs.RequirePersonalNamespace do
  @moduledoc """
  Gates browser routes behind a claimed personal namespace on cyfr.run.

  Logic:

  1. Bypass `/claim-namespace/*`, `/auth/*`, `/api/health`, `/mcp/*`,
     `/assets/*`, `/t/*` (tincture routes use query-param auth, not session).
  2. Load the user from the session cookie; if anonymous, let through —
     route-level auth plugs or controller guards handle un-authed access.
  3. Consult `EmissaryWeb.Plugs.PersonalNamespaceCache` (30s TTL ETS).
  4. On cache miss, look up `Compendium.Registry.CredentialStore.list_for_user/2`.
     A personal namespace is a bare slug (no dot); publisher namespaces
     contain a dot. The presence of any bare-slug credential proves the user
     has claimed their personal namespace. Populate the cache on success.
  5. On still-no-claim, halt the conn and redirect to `/claim-namespace`.

  `/live/*` is NOT bypassed — LiveSocket WS upgrades carry the session
  cookie through the `:browser` pipeline, so gating them at the plug level
  prevents a dashboard LiveView from mounting for a not-yet-claimed user.
  """

  import Plug.Conn

  require Logger

  alias Compendium.Registry.CredentialStore
  alias EmissaryWeb.Plugs.PersonalNamespaceCache

  @bypass_prefixes ~w(/claim-namespace /auth /api/health /mcp /assets /t)

  def init(opts), do: opts

  def call(conn, _opts) do
    if bypass?(conn.request_path) do
      conn
    else
      case load_user_id(conn) do
        {:ok, user_id} -> enforce(conn, user_id)
        :anonymous -> conn
      end
    end
  end

  # Match on path-segment boundaries, not arbitrary string prefixes — so a
  # future route like `/claim-namespace-evil` doesn't silently inherit the
  # bypass that's intended only for `/claim-namespace` and its descendants.
  defp bypass?(path) do
    Enum.any?(@bypass_prefixes, fn prefix ->
      path == prefix or String.starts_with?(path, prefix <> "/")
    end)
  end

  defp load_user_id(conn) do
    conn = fetch_session(conn)

    case get_session(conn, :sanctum_session_token) do
      token when is_binary(token) and token != "" ->
        case Sanctum.Session.load(token) do
          {:ok, %{user_id: id}} when is_binary(id) -> {:ok, id}
          _ -> :anonymous
        end

      _ ->
        :anonymous
    end
  end

  defp enforce(conn, user_id) do
    registry = Compendium.Registry.canonical_host()

    case PersonalNamespaceCache.claimed?(user_id, registry) do
      :hit ->
        conn

      :miss ->
        if has_personal_namespace?(user_id, registry) do
          PersonalNamespaceCache.put_claimed(user_id, registry)
          conn
        else
          conn
          |> Phoenix.Controller.redirect(to: "/claim-namespace")
          |> halt()
        end
    end
  end

  defp has_personal_namespace?(user_id, registry) do
    CredentialStore.has_personal?(user_id, registry)
  rescue
    # CredentialStore can raise if its store isn't ready (e.g., during app
    # boot). Treat as no-claim — the redirect to
    # /claim-namespace will render the static claim page without hitting
    # CredentialStore again on that bypass path. Log so silent decryption /
    # DB errors don't disappear into the void.
    e ->
      Logger.warning(
        "[RequirePersonalNamespace] CredentialStore.has_personal?/2 failed " <>
          "for user_id=#{inspect(user_id)} registry=#{inspect(registry)}: " <>
          Exception.message(e) <> " — gating user as not-claimed"
      )

      false
  end
end
