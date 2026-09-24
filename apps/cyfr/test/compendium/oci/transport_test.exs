# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.OCI.TransportTest do
  @moduledoc """
  The OCI transport on the shared retry policy: ambiguous failures are
  idempotency-gated, a 401 surfaces for re-login rather than negotiating,
  and an SSRF refusal is never dialled at all. A push token that cannot
  be read refuses the request before anything is sent; only a caller with
  no token goes anonymous.
  """

  use ExUnit.Case, async: false

  alias Compendium.OCI.Errors
  alias Compendium.OCI.Transport

  @url "http://127.0.0.1:9/v2/testns/thing/blobs/uploads/"
  @registry "oci.test"
  @repository "testns/thing"

  setup do
    Req.default_options(plug: {Req.Test, :oci_transport})
    on_exit(fn -> Req.default_options([]) end)
    :ok
  end

  defp stub(fun) do
    parent = self()

    Req.Test.stub(:oci_transport, fn conn ->
      send(parent, :attempt)
      fun.(conn)
    end)
  end

  defp attempts do
    receive do
      :attempt -> 1 + attempts()
    after
      0 -> 0
    end
  end

  defp request(method, body \\ nil) do
    Transport.request_url(nil, method, @url, @registry, @repository, [], body)
  end

  test "a success passes through untouched" do
    stub(fn conn -> Plug.Conn.send_resp(conn, 202, "") end)

    assert {:ok, 202, _headers, ""} = request(:post, "")
    assert attempts() == 1
  end

  test "a response over the size ceiling is refused once, never re-fetched" do
    big = String.duplicate("x", 64 * 1024)
    stub(fn conn -> Plug.Conn.send_resp(conn, 200, big) end)

    assert {:error, %Errors{reason: :registry_unavailable, detail: detail}} =
             Transport.request_url(nil, :get, @url, @registry, @repository, [], nil,
               max_response_bytes: 1024
             )

    assert {:response_too_large, _seen, 1024} = detail
    assert attempts() == 1
  end

  test "a 5xx GET is retried to the budget" do
    stub(fn conn -> Plug.Conn.send_resp(conn, 502, "bad gateway") end)

    assert {:error, %Errors{}} = request(:get)
    assert attempts() == 3
  end

  test "a 5xx POST is not replayed — the server may have acted" do
    stub(fn conn -> Plug.Conn.send_resp(conn, 502, "bad gateway") end)

    assert {:error, %Errors{}} = request(:post, "")
    assert attempts() == 1
  end

  test "an ambiguous transport error gates on the method the same way" do
    stub(fn conn -> Req.Test.transport_error(conn, :timeout) end)
    assert {:error, %Errors{}} = request(:post, "")
    assert attempts() == 1

    stub(fn conn -> Req.Test.transport_error(conn, :timeout) end)
    assert {:error, %Errors{}} = request(:head)
    assert attempts() == 3
  end

  test "a 429 retries for any method, honouring Retry-After" do
    stub(fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "0")
      |> Plug.Conn.send_resp(429, "slow down")
    end)

    assert {:error, %Errors{}} = request(:post, "")
    assert attempts() == 3
  end

  test "a 401 surfaces for re-login after one attempt — no negotiation" do
    stub(fn conn -> Plug.Conn.send_resp(conn, 401, "unauthorized") end)

    assert {:error, %Errors{}} = request(:get)
    assert attempts() == 1
  end

  test "an SSRF refusal is never dialled" do
    stub(fn conn -> Plug.Conn.send_resp(conn, 200, "never reached") end)

    assert {:error, %Errors{}} =
             Transport.request_url(
               nil,
               :get,
               "http://169.254.169.254/v2/x",
               @registry,
               @repository
             )

    assert attempts() == 0
  end

  describe "the caller's push token" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
      Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

      user_id = "oci_transport_#{System.unique_integer([:positive])}"
      ctx = Sanctum.Context.build(user_id: user_id, authenticated: true, auth_method: :oidc)
      {:ok, ctx: ctx}
    end

    # A row written past the facade under the key the transport reads —
    # the repository's first segment — sealed around `plaintext`.
    defp plant!(%Sanctum.Context{user_id: user_id}, plaintext) do
      aad = Sanctum.CipherAAD.registry_token(user_id, @registry, "testns")
      {:ok, ciphertext} = Sanctum.Cipher.encrypt(plaintext, aad)

      :ok =
        Arca.RegistryTokenStorage.put(%{
          user_id: user_id,
          registry: @registry,
          namespace_slug: "testns",
          credential_ciphertext: ciphertext
        })
    end

    defp authorization(parent) do
      fn conn ->
        send(parent, {:authorization, Plug.Conn.get_req_header(conn, "authorization")})
        Plug.Conn.send_resp(conn, 200, "")
      end
    end

    test "a stored token is sent as the bearer", %{ctx: ctx} do
      :ok =
        Compendium.Registry.CredentialStore.put_push_token(
          ctx,
          @registry,
          "testns",
          "cyfr_pt_transport",
          "personal"
        )

      stub(authorization(self()))

      assert {:ok, 200, _headers, ""} =
               Transport.request_url(ctx, :get, @url, @registry, @repository)

      assert_received {:authorization, ["Bearer cyfr_pt_transport"]}
      assert attempts() == 1
    end

    test "a caller with no stored token is sent anonymously", %{ctx: ctx} do
      stub(authorization(self()))

      assert {:ok, 200, _headers, ""} =
               Transport.request_url(ctx, :get, @url, @registry, @repository)

      assert_received {:authorization, []}
      assert attempts() == 1
    end

    @tag :capture_log
    test "a stored token that does not open refuses before anything is sent", %{ctx: ctx} do
      stub(fn conn -> Plug.Conn.send_resp(conn, 200, "never reached") end)
      plant!(ctx, ~s({"type":"push_token","token":""}))

      assert {:error, %Errors{reason: :registry_unavailable} = err} =
               Transport.request_url(ctx, :get, @url, @registry, @repository)

      assert err.detail == %{credential_store: :corrupt}
      assert Errors.to_string(err) =~ "The stored registry credential is damaged"
      assert attempts() == 0
    end

    @tag :capture_log
    test "a credential store that cannot answer refuses at once, never retried", %{ctx: ctx} do
      stub(fn conn -> Plug.Conn.send_resp(conn, 200, "never reached") end)
      Arca.Repo.query!("ALTER TABLE registry_tokens RENAME TO registry_tokens_unavailable")

      assert {:error, %Errors{reason: :registry_unavailable} = err} =
               Transport.request_url(ctx, :get, @url, @registry, @repository)

      assert err.detail == %{credential_store: :unavailable}

      assert Errors.to_string(err) ==
               "Your registry credentials could not be read — retry shortly"

      assert attempts() == 0
    end
  end
end
