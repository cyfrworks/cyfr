defmodule EmissaryWeb.Plugs.RequirePersonalNamespaceTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias EmissaryWeb.Plugs.PersonalNamespaceCache
  alias EmissaryWeb.Plugs.RequirePersonalNamespace
  alias Sanctum.{Context, Session}

  @endpoint_opts [
    store: :cookie,
    key: "_test_cookie_key",
    signing_salt: "test_salt",
    encryption_salt: "test_salt_enc"
  ]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "require_personal_namespace_test_#{:rand.uniform(100_000)}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)

    original_oci = Application.get_env(:cyfr, :oci_registry_url)
    registry = "registry.cyfr.run.test"
    Application.put_env(:cyfr, :oci_registry_url, registry)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)

      if original_oci,
        do: Application.put_env(:cyfr, :oci_registry_url, original_oci),
        else: Application.delete_env(:cyfr, :oci_registry_url)
    end)

    {:ok, registry: registry}
  end

  describe "bypass paths" do
    test "/claim-namespace is bypassed" do
      conn = build_conn(:get, "/claim-namespace")
      result = RequirePersonalNamespace.call(conn, [])
      refute result.halted
      refute result.status
    end

    test "/auth/github is bypassed" do
      conn = build_conn(:get, "/auth/github")
      result = RequirePersonalNamespace.call(conn, [])
      refute result.halted
    end

    test "/mcp is bypassed" do
      conn = build_conn(:post, "/mcp")
      result = RequirePersonalNamespace.call(conn, [])
      refute result.halted
    end

    test "/assets/app.css is bypassed" do
      conn = build_conn(:get, "/assets/app.css")
      result = RequirePersonalNamespace.call(conn, [])
      refute result.halted
    end

    test "/t/alice/demo is bypassed" do
      conn = build_conn(:get, "/t/alice/demo")
      result = RequirePersonalNamespace.call(conn, [])
      refute result.halted
    end
  end

  describe "anonymous users" do
    test "are not redirected (route-level auth handles them)" do
      conn = build_conn(:get, "/dashboard")
      result = RequirePersonalNamespace.call(conn, [])
      refute result.halted
      refute result.status
    end
  end

  describe "authed users" do
    test "with a cached claim pass through", %{registry: registry} do
      user = build_user()
      {:ok, session} = Session.create(user)

      PersonalNamespaceCache.put_claimed(user.user_id, registry)

      conn = authed_conn(session.token)
      result = RequirePersonalNamespace.call(conn, [])

      refute result.halted
      refute result.status
    end

    test "with a personal-namespace credential pass through and populate cache",
         %{registry: registry} do
      user = build_user()
      {:ok, session} = Session.create(user)

      PersonalNamespaceCache.invalidate(user.user_id, registry)

      :ok =
        Compendium.Registry.CredentialStore.put(user.user_id, registry, "alice", %{
          type: :push_token,
          token: "cyfr_pt_testtoken",
          namespace: "alice",
          role: "personal",
          issued_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          label: "test"
        })

      conn = authed_conn(session.token)
      result = RequirePersonalNamespace.call(conn, [])

      refute result.halted
      assert PersonalNamespaceCache.claimed?(user.user_id, registry) == :hit
    end

    test "with only publisher credentials (dotted slugs) are redirected",
         %{registry: registry} do
      user = build_user()
      {:ok, session} = Session.create(user)

      PersonalNamespaceCache.invalidate(user.user_id, registry)

      :ok =
        Compendium.Registry.CredentialStore.put(user.user_id, registry, "stripe.com", %{
          type: :push_token,
          token: "cyfr_pt_pubtoken",
          namespace: "stripe.com",
          role: "admin",
          issued_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          label: "test"
        })

      conn = authed_conn(session.token)
      result = RequirePersonalNamespace.call(conn, [])

      assert result.halted
      assert result.status in [302, 303]
      assert Plug.Conn.get_resp_header(result, "location") == ["/claim-namespace"]
    end

    test "with no credentials are redirected", %{registry: registry} do
      user = build_user()
      {:ok, session} = Session.create(user)

      PersonalNamespaceCache.invalidate(user.user_id, registry)

      conn = authed_conn(session.token)
      result = RequirePersonalNamespace.call(conn, [])

      assert result.halted
      assert Plug.Conn.get_resp_header(result, "location") == ["/claim-namespace"]
    end

    test "/claim-namespace-fake is NOT bypassed (prefix boundary)",
         %{registry: registry} do
      user = build_user()
      {:ok, session} = Session.create(user)
      PersonalNamespaceCache.invalidate(user.user_id, registry)

      conn =
        build_conn(:get, "/claim-namespace-fake")
        |> put_session(:sanctum_session_token, session.token)

      result = RequirePersonalNamespace.call(conn, [])

      assert result.halted
      assert Plug.Conn.get_resp_header(result, "location") == ["/claim-namespace"]
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp build_user do
    Context.build(
      user_id: "github|https://github.com|#{System.unique_integer([:positive])}",
      email: "test-#{System.unique_integer([:positive])}@example.com",
      provider: "github",
      org_id: "",
      project_id: "default",
      permissions: [],
      namespace: "testns",
      authenticated: true
    )
  end

  defp build_conn(method, path) do
    conn(method, path)
    |> Map.put(:secret_key_base, String.duplicate("a", 64))
    |> Plug.Session.call(Plug.Session.init(@endpoint_opts))
    |> fetch_session()
  end

  defp authed_conn(session_token) do
    build_conn(:get, "/dashboard")
    |> put_session(:sanctum_session_token, session_token)
  end
end
