# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.OCI.PushAuthTest do
  @moduledoc """
  Regression guard: OCI requests must carry the caller's push token.

  The `ctx` was once dropped between `OCI.Client.push` and the HTTP layer
  (`Transport.request`'s `ctx` defaulted to `nil`), so every blob/manifest
  upload went out anonymous and cyfr.run rejected the push with 401. These
  wire tests pin the `Transport` chokepoint: with a credential in `ctx`, the
  outbound request carries `Authorization: Bearer <push_token>`; with `nil`
  ctx (anonymous catalog reads) it carries none.

  `Transport.request/6` now takes `ctx` as a required first arg, so the
  compiler enforces every `Blob`/`Client` call site supplies it — these tests
  cover that the chokepoint then attaches the header.
  """
  use ExUnit.Case, async: false

  alias Compendium.OCI.{Reference, Transport}
  alias Compendium.Registry.CredentialStore
  alias Sanctum.Context

  @user "oci_push_auth_test_user"
  @namespace "alice"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    bypass = Bypass.open()
    # `Reference.api_base/1` maps `localhost:` to http:// (not 127.0.0.1) so Bypass works.
    registry = "localhost:#{bypass.port}"
    ref = %Reference{registry: registry, repository: "#{@namespace}/catalysts/foo", tag: "1.0.0"}

    # No manual cleanup: the shared SQL sandbox rolls back the stored
    # credential when the test ends.
    {:ok, bypass: bypass, registry: registry, ref: ref}
  end

  defp ctx do
    Context.build(
      user_id: @user,
      project_id: "default",
      permissions: [:*],
      scope: :project,
      auth_method: :oidc,
      namespace: @namespace,
      authenticated: true
    )
  end

  test "a write request carries Bearer <push_token> when ctx holds a credential", c do
    %{bypass: bypass, registry: registry, ref: ref} = c

    :ok =
      CredentialStore.put(@user, registry, @namespace, %{
        type: :push_token,
        token: "cyfr_pt_push_test",
        namespace: @namespace
      })

    test_pid = self()
    path = "/v2/#{ref.repository}/manifests/#{ref.tag}"

    Bypass.expect_once(bypass, "PUT", path, fn conn ->
      send(test_pid, {:auth, Plug.Conn.get_req_header(conn, "authorization")})
      Plug.Conn.resp(conn, 201, "")
    end)

    assert {:ok, 201, _headers, _body} =
             Transport.request(ctx(), :put, path, ref, [{"content-type", "application/json"}], "{}")

    assert_received {:auth, ["Bearer cyfr_pt_push_test"]}
  end

  test "a request with nil ctx carries no Authorization header (anonymous read)", c do
    %{bypass: bypass, ref: ref} = c
    test_pid = self()
    path = "/v2/#{ref.repository}/tags/list"

    Bypass.expect_once(bypass, "GET", path, fn conn ->
      send(test_pid, {:auth, Plug.Conn.get_req_header(conn, "authorization")})
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.resp(200, ~s({"tags":[]}))
    end)

    assert {:ok, 200, _headers, _body} = Transport.request(nil, :get, path, ref)

    assert_received {:auth, []}
  end
end
