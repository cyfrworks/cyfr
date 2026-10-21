# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.OAuthCallbackControllerTest do
  @moduledoc """
  The vault grant callback writes a credential only for the session that
  started the grant, as it stands when the provider answers: one revoked
  while the code was being exchanged writes nothing.
  """

  use CyfrWeb.ConnCase, async: false

  import Ecto.Query

  alias Sanctum.{Caller, Context}
  alias Sanctum.Vault.OAuthGrant

  # A provider no shipped preset is, scripted for these grants
  # (`:sanctum, :scripted_oauth_provider`): its token endpoint runs the
  # test's `before` and answers its token.
  defmodule CallbackIdp do
    @moduledoc false

    @hint "callback-idp"
    @endpoints %{
      "authorize_url" => "https://idp.callback.test/authorize",
      "token_url" => "https://idp.callback.test/token"
    }

    def hint, do: @hint
    def endpoints, do: @endpoints

    def preset(@hint), do: %{endpoints: @endpoints}
    def preset(_hint), do: nil

    def post(_url, _headers, _body) do
      {before, answer} = Agent.get(__MODULE__, & &1)
      before.()
      {:ok, Map.merge(%{"access_token" => "at-1", "expires_in" => 3600}, answer)}
    end
  end

  setup do
    Arca.Cache.init()

    # Restored by on_exit, registered before the change.
    prior = Application.fetch_env(:sanctum, :scripted_oauth_provider)

    on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:sanctum, :scripted_oauth_provider, value)
        :error -> Application.delete_env(:sanctum, :scripted_oauth_provider)
      end
    end)

    Application.put_env(:sanctum, :scripted_oauth_provider, CallbackIdp)

    person = Sanctum.TestContext.issuer!(Sanctum.TestContext.local())
    {:ok, session} = Sanctum.Session.create(person)
    {:ok, ctx} = Caller.establish(session.token)

    :ok =
      Sanctum.TestContext.put_provider_credentials(
        ctx,
        CallbackIdp.hint(),
        "client-id-1",
        "client-secret-1"
      )

    {:ok, ctx: ctx}
  end

  defp pending!(ctx, name) do
    state = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    Arca.Cache.put(
      {:vault_oauth_pending, state},
      %{
        target: %{
          kind: :new,
          entry_id: nil,
          name: name,
          provider: CallbackIdp.hint(),
          endpoints: CallbackIdp.endpoints(),
          scopes: ["https://www.googleapis.com/auth/gmail.readonly"],
          # Where the new entry may go; attach-only, as the grant left it.
          destination: ~s({"hosts":["gmail.googleapis.com"],"scheme":"https"}),
          attach_only: true
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

  defp token_endpoint(before_answer, answer \\ %{}) do
    start_supervised!(%{
      id: CallbackIdp,
      start: {Agent, :start_link, [fn -> {before_answer, answer} end, [name: CallbackIdp]]}
    })
  end

  defp entry_named?(ctx, name) do
    Arca.Repo.exists?(
      from(v in Arca.Schemas.VaultEntry,
        where: v.athanor_id == ^ctx.athanor_id and v.name == ^name
      )
    )
  end

  test "a standing session's grant is written", %{conn: conn, ctx: ctx} do
    name = "Mail #{System.unique_integer([:positive])}"
    state = pending!(ctx, name)
    token_endpoint(fn -> :ok end)

    conn = get(conn, "/auth/oauth/callback", %{"code" => "code-1", "state" => state})

    assert conn.status == 200
    assert entry_named?(ctx, name)
  end

  test "a grant answered for scopes it did not ask for says so and writes nothing", %{
    conn: conn,
    ctx: ctx
  } do
    name = "Mail #{System.unique_integer([:positive])}"
    state = pending!(ctx, name)

    token_endpoint(fn -> :ok end, %{
      "scope" =>
        "https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/gmail.send"
    })

    conn = get(conn, "/auth/oauth/callback", %{"code" => "code-3", "state" => state})

    assert conn.status == 400

    assert conn.resp_body =~
             "The provider granted scopes this connection did not ask for; nothing was stored."

    refute conn.resp_body =~ "at-1"
    refute entry_named?(ctx, name)
  end

  test "a session revoked while the code was exchanged writes nothing", %{
    conn: conn,
    ctx: ctx
  } do
    name = "Mail #{System.unique_integer([:positive])}"
    state = pending!(ctx, name)
    hash = ctx.session_token_hash

    token_endpoint(fn ->
      Arca.Repo.delete_all(from(s in Arca.Schemas.Session, where: s.token_hash == ^hash))
    end)

    conn = get(conn, "/auth/oauth/callback", %{"code" => "code-2", "state" => state})

    assert conn.status == 400
    assert conn.resp_body =~ "no longer signed in"
    refute entry_named?(ctx, name)
  end
end
