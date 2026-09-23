# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule EmissaryWeb.OAuthCallbackControllerTest do
  @moduledoc """
  The vault grant callback writes a credential only for the session that
  started the grant, as it stands when the provider answers: one revoked
  while the code was being exchanged writes nothing.
  """

  use EmissaryWeb.ConnCase, async: false

  import Ecto.Query

  alias Sanctum.{Caller, Context}
  alias Sanctum.Vault.OAuthGrant

  setup do
    Arca.Cache.init()
    bypass = Bypass.open()

    # The token endpoint is a local Bypass; plain HTTP is allowed only on a
    # server with no sign-in configured (`Sanctum.Vault.OAuth.http_post/4`).
    Application.delete_env(:sanctum, :auth_provider)

    person = Sanctum.TestContext.issuer!(Sanctum.TestContext.local())
    {:ok, session} = Sanctum.Session.create(person)
    {:ok, ctx} = Caller.establish(session.token)
    :ok = Sanctum.ProviderCredentials.put(ctx, "google", "client-id-1", "client-secret-1")

    {:ok, bypass: bypass, ctx: ctx}
  end

  defp pending!(ctx, bypass, name) do
    state = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    Arca.Cache.put(
      {:vault_oauth_pending, state},
      %{
        target: %{
          kind: :new,
          entry_id: nil,
          name: name,
          provider: "google",
          endpoints: %{
            "authorize_url" => "https://accounts.google.com/o/oauth2/v2/auth",
            "token_url" => "http://localhost:#{bypass.port}/token",
            "auth_style" => "params"
          },
          scopes: ["https://www.googleapis.com/auth/gmail.readonly"]
        },
        redirect_uri: OAuthGrant.redirect_uri(),
        code_verifier: "verifier-1",
        context: ctx,
        actor: Context.actor(ctx)
      },
      120_000
    )

    state
  end

  defp token_endpoint(bypass, before_answer) do
    Bypass.expect_once(bypass, "POST", "/token", fn conn ->
      before_answer.()

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"access_token" => "at-1", "expires_in" => 3600}))
    end)
  end

  defp entry_named?(ctx, name) do
    Arca.Repo.exists?(
      from(v in Arca.Schemas.VaultEntry,
        where: v.athanor_id == ^ctx.athanor_id and v.name == ^name
      )
    )
  end

  test "a standing session's grant is written", %{conn: conn, bypass: bypass, ctx: ctx} do
    name = "Mail #{System.unique_integer([:positive])}"
    state = pending!(ctx, bypass, name)
    token_endpoint(bypass, fn -> :ok end)

    conn = get(conn, "/auth/oauth/callback", %{"code" => "code-1", "state" => state})

    assert conn.status == 200
    assert entry_named?(ctx, name)
  end

  test "a session revoked while the code was exchanged writes nothing", %{
    conn: conn,
    bypass: bypass,
    ctx: ctx
  } do
    name = "Mail #{System.unique_integer([:positive])}"
    state = pending!(ctx, bypass, name)
    hash = ctx.session_token_hash

    token_endpoint(bypass, fn ->
      Arca.Repo.delete_all(from(s in Arca.Schemas.Session, where: s.token_hash == ^hash))
    end)

    conn = get(conn, "/auth/oauth/callback", %{"code" => "code-2", "state" => state})

    assert conn.status == 400
    assert conn.resp_body =~ "no longer signed in"
    refute entry_named?(ctx, name)
  end
end
