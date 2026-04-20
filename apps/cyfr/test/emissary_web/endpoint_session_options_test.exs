defmodule EmissaryWeb.EndpointSessionOptionsTest do
  # Session cookies must be http_only + SameSite=Lax unconditionally; the
  # `secure` flag must track the :cookie_secure application env (true in prod,
  # false in dev/test) — runtime.exs sets it to true under the prod block.
  # Same invariants apply to PrismWeb.Endpoint — both are tested here.
  #
  # Covers Phase A "Done when" #36 (session cookie security flags).

  use ExUnit.Case, async: false

  setup do
    original = Application.get_env(:cyfr, :cookie_secure)
    on_exit(fn ->
      if is_nil(original),
        do: Application.delete_env(:cyfr, :cookie_secure),
        else: Application.put_env(:cyfr, :cookie_secure, original)
    end)

    :ok
  end

  for endpoint <- [EmissaryWeb.Endpoint, PrismWeb.Endpoint] do
    describe "#{inspect(endpoint)}.session_options/0" do
      @endpoint endpoint

      test "always sets http_only and same_site=Lax" do
        Application.put_env(:cyfr, :cookie_secure, false)
        opts = @endpoint.session_options()

        assert Keyword.fetch!(opts, :http_only) == true
        assert Keyword.fetch!(opts, :same_site) == "Lax"
        assert Keyword.fetch!(opts, :store) == :cookie
      end

      test "secure=false when :cookie_secure is unset" do
        Application.delete_env(:cyfr, :cookie_secure)
        opts = @endpoint.session_options()
        assert Keyword.fetch!(opts, :secure) == false
      end

      test "secure=false when :cookie_secure is explicitly false (dev/test)" do
        Application.put_env(:cyfr, :cookie_secure, false)
        opts = @endpoint.session_options()
        assert Keyword.fetch!(opts, :secure) == false
      end

      test "secure=true when :cookie_secure is true (prod)" do
        Application.put_env(:cyfr, :cookie_secure, true)
        opts = @endpoint.session_options()
        assert Keyword.fetch!(opts, :secure) == true
      end
    end
  end

  describe "end-to-end Set-Cookie header via the endpoint pipeline" do
    # Extra belt: exercise Plug.Session against the same options the endpoint
    # emits, then verify the Cookie attribute string carries the expected
    # flags. Catches regressions where session_options is correct but
    # :dynamic_session wiring drops them.

    test "emitted Set-Cookie includes HttpOnly, SameSite=Lax, Secure when :cookie_secure=true" do
      Application.put_env(:cyfr, :cookie_secure, true)

      conn = run_through_session(EmissaryWeb.Endpoint.session_options(), "_emissary_key")

      attrs = conn_set_cookie(conn, "_emissary_key")
      assert attrs =~ ~r/HttpOnly/i
      assert attrs =~ ~r/SameSite=Lax/i
      assert attrs =~ ~r/; Secure(;|$)/i
    end

    test "emitted Set-Cookie omits Secure when :cookie_secure=false" do
      Application.put_env(:cyfr, :cookie_secure, false)

      conn = run_through_session(PrismWeb.Endpoint.session_options(), "_prism_key")

      attrs = conn_set_cookie(conn, "_prism_key")
      assert attrs =~ ~r/HttpOnly/i
      assert attrs =~ ~r/SameSite=Lax/i
      refute attrs =~ ~r/; Secure(;|$)/i
    end
  end

  defp run_through_session(opts, _key) do
    # Minimal request that touches session so Plug.Session emits Set-Cookie.
    # secret_key_base is set from the endpoint's runtime config; in tests we
    # need enough entropy (≥64 bytes) for Plug.Session.COOKIE to accept it.
    secret = String.duplicate("a", 64)

    conn = %{Plug.Test.conn(:get, "/") | secret_key_base: secret}
    plug_opts = Plug.Session.init(opts)

    conn
    |> Plug.Session.call(plug_opts)
    |> Plug.Conn.fetch_session()
    |> Plug.Conn.put_session(:trigger, "write")
    |> Plug.Conn.resp(200, "")
    |> Plug.Conn.send_resp()
  end

  defp conn_set_cookie(conn, key) do
    # Phoenix / Plug emits Set-Cookie into resp_headers; resp_cookies is a
    # map keyed by cookie name with the attribute options. Assert on both.
    set_cookie_headers =
      for {"set-cookie", v} <- conn.resp_headers, String.starts_with?(v, "#{key}="), do: v

    assert set_cookie_headers != [], "expected Set-Cookie for #{key}, got: #{inspect(conn.resp_headers)}"
    hd(set_cookie_headers)
  end
end
