# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.OCI.BlobTest do
  @moduledoc """
  A blob download the registry redirects is fetched from the redirect's
  target on a pin of its own: the request carries none of the caller's
  registry credential, its bytes must match the digest asked for, and a
  target the operator's private-egress allowlist no longer names is
  refused before anything is sent to it. A blob upload goes to the
  location the registry's upload session names, and the caller's
  credential goes with it only on the registry's own origin.
  """

  use ExUnit.Case, async: false

  alias Compendium.OCI.{Blob, Errors, Reference}
  alias Compendium.Registry.CredentialStore
  alias Sanctum.Context

  @user "oci_blob_test_user"
  @namespace "alice"
  @token "cyfr_pt_blob_redirect_test"

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    previous = Application.fetch_env(:sanctum, :private_egress_targets)
    Application.put_env(:sanctum, :private_egress_targets, ["127.0.0.1"])

    on_exit(fn ->
      case previous do
        {:ok, targets} -> Application.put_env(:sanctum, :private_egress_targets, targets)
        :error -> Application.delete_env(:sanctum, :private_egress_targets)
      end
    end)

    registry = Bypass.open()
    storage = Bypass.open()
    # A loopback registry is reached over http (`Compendium.RegistryHost.base_url/1`),
    # so Bypass answers it.
    name = "localhost:#{registry.port}"
    ref = %Reference{registry: name, repository: "#{@namespace}/catalysts/foo", tag: "1.0.0"}

    # The caller holds a push token for the namespace, so the registry hop
    # carries one; the shared SQL sandbox rolls it back.
    :ok = CredentialStore.put_push_token(ctx(), name, @namespace, @token, "personal")

    {:ok, registry: registry, storage: storage, ref: ref}
  end

  defp ctx do
    Context.build(
      user_id: @user,
      athanor_id: "ath_test",
      permissions: [:*],
      scope: :athanor,
      auth_method: :oidc,
      namespace: @namespace,
      authenticated: true
    )
  end

  # Bypass reads every request path as a Plug route, where `:` opens a
  # parameter whose name must start with a letter, so the hex of a
  # `sha256:<hex>` segment must start with a-f. The first such blob of a
  # fixed sequence keeps each case the same on every run.
  defp blob(label) do
    Enum.find_value(0..1_000, fn n ->
      bytes = "#{label} #{n}"
      digest = Prima.Digest.sha256(bytes)
      if digest =~ ~r/\Asha256:[a-f]/, do: {bytes, digest}
    end)
  end

  # The registry answers the blob's GET with a 307 to `location`, telling
  # the test the path and the authorization it was sent, and running
  # `before_redirect` between the request's arrival and the answer.
  defp redirects(registry, location, before_redirect \\ fn -> :ok end) do
    test = self()

    Bypass.expect_once(registry, fn conn ->
      send(test, {:registry, conn.request_path, Plug.Conn.get_req_header(conn, "authorization")})
      before_redirect.()

      conn
      |> Plug.Conn.put_resp_header("location", location)
      |> Plug.Conn.resp(307, "")
    end)
  end

  test "a 307 to storage is followed with no authorization, and the blob is its bytes", c do
    %{registry: registry, storage: storage, ref: ref} = c
    {bytes, digest} = blob("redirected")
    test = self()
    redirects(registry, "http://127.0.0.1:#{storage.port}/presigned/blob?sig=s1")

    Bypass.expect_once(storage, fn conn ->
      send(test, {:storage, conn.request_path, conn.query_string, conn.req_headers})
      Plug.Conn.resp(conn, 200, bytes)
    end)

    assert {:ok, ^bytes} = Blob.download(ctx(), ref, digest)

    # The registry hop carried the caller's token: there was one to leak.
    bearer = "Bearer " <> @token
    assert_receive {:registry, path, [^bearer]}, 5_000
    assert path == "/v2/#{ref.repository}/blobs/#{digest}"

    assert_receive {:storage, "/presigned/blob", "sig=s1", headers}, 5_000
    refute List.keymember?(headers, "authorization", 0)
    refute Enum.any?(headers, fn {_name, value} -> value =~ @token end)
  end

  test "a redirect's bytes that do not match the digest asked for are refused", c do
    %{registry: registry, storage: storage, ref: ref} = c
    {_bytes, digest} = blob("expected")
    test = self()
    redirects(registry, "http://127.0.0.1:#{storage.port}/presigned/blob")

    Bypass.expect_once(storage, fn conn ->
      send(test, :storage_reached)
      Plug.Conn.resp(conn, 200, "other bytes")
    end)

    assert {:error,
            %Errors{reason: :digest_mismatch, detail: %{expected: ^digest, actual: actual}}} =
             Blob.download(ctx(), ref, digest)

    assert actual == Prima.Digest.sha256("other bytes")
    assert_receive {:registry, _path, _authorization}, 5_000
    assert_receive :storage_reached, 5_000
  end

  test "a redirect to an address the allowlist stopped naming reaches nothing", c do
    %{registry: registry, storage: storage, ref: ref} = c
    {_bytes, digest} = blob("blocked")
    test = self()

    # The registry hop is admitted; the permission goes after it arrives and
    # before its 307, so the refusal is the redirect's own.
    redirects(registry, "http://127.0.0.1:#{storage.port}/presigned/blob", fn ->
      Application.put_env(:sanctum, :private_egress_targets, [])
    end)

    Bypass.stub(storage, "GET", "/presigned/blob", fn conn ->
      send(test, :storage_reached)
      Plug.Conn.resp(conn, 200, "x")
    end)

    assert {:error, %Errors{reason: :ssrf_blocked, message: "Redirect blocked: " <> reason}} =
             Blob.download(ctx(), ref, digest)

    assert reason =~ "127.0.0.1"
    assert_receive {:registry, _path, ["Bearer " <> @token]}, 5_000
    refute_received :storage_reached
  end

  describe "an upload" do
    # The registry holds no blob, opens an upload session at `location` and
    # takes a PUT to it should the location be its own, telling the test
    # each request's method, path and authorization.
    defp opens_session(registry, location) do
      test = self()

      Bypass.expect(registry, fn conn ->
        authorization = Plug.Conn.get_req_header(conn, "authorization")
        send(test, {:registry, conn.method, conn.request_path, authorization})

        case conn.method do
          "HEAD" ->
            Plug.Conn.resp(conn, 404, "")

          "POST" ->
            conn
            |> Plug.Conn.put_resp_header("location", location)
            |> Plug.Conn.resp(202, "")

          "PUT" ->
            takes_upload(conn, test)
        end
      end)
    end

    # The PUT's answer, telling the test what it was sent.
    defp takes_upload(conn, test) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:upload, conn.request_path, conn.query_string, conn.req_headers, body})
      Plug.Conn.resp(conn, 201, "")
    end

    test "on another origin carries no credential, and the blob lands there", c do
      %{registry: registry, storage: storage, ref: ref} = c
      {bytes, digest} = blob("uploaded elsewhere")
      test = self()
      opens_session(registry, "http://127.0.0.1:#{storage.port}/upload/session?state=s1")
      Bypass.expect_once(storage, &takes_upload(&1, test))

      assert {:ok, ^digest} = Blob.upload(ctx(), ref, bytes)

      # The registry's own hops carried the caller's token: there was one to leak.
      bearer = "Bearer " <> @token
      assert_receive {:registry, "HEAD", _path, [^bearer]}, 5_000
      assert_receive {:registry, "POST", path, [^bearer]}, 5_000
      assert path == "/v2/#{ref.repository}/blobs/uploads/"

      assert_receive {:upload, "/upload/session", query, headers, ^bytes}, 5_000
      assert URI.decode_query(query) == %{"state" => "s1", "digest" => digest}
      refute List.keymember?(headers, "authorization", 0)
      refute Enum.any?(headers, fn {_name, value} -> value =~ @token end)
    end

    test "on the registry's own origin carries the credential", c do
      %{registry: registry, ref: ref} = c
      {bytes, digest} = blob("uploaded here")
      opens_session(registry, "http://localhost:#{registry.port}/upload/session")

      assert {:ok, ^digest} = Blob.upload(ctx(), ref, bytes)

      assert_receive {:upload, "/upload/session", query, headers, ^bytes}, 5_000
      assert URI.decode_query(query) == %{"digest" => digest}
      assert {"authorization", "Bearer " <> @token} in headers
    end
  end
end
