# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.BuilderServiceTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  @opts Locus.BuilderService.init([])
  @token "test-builder-token"

  setup do
    prev = Application.get_env(:cyfr, :builder_token)
    Application.put_env(:cyfr, :builder_token, @token)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:cyfr, :builder_token, prev),
        else: Application.delete_env(:cyfr, :builder_token)
    end)

    :ok
  end

  defp post_build(body, headers) do
    conn =
      :post
      |> conn("/build", Jason.encode!(body))
      |> put_req_header("content-type", "application/json")

    headers
    |> Enum.reduce(conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    |> Locus.BuilderService.call(@opts)
  end

  test "health answers without auth and names the toolchains" do
    conn = :get |> conn("/health") |> Locus.BuilderService.call(@opts)

    assert conn.status == 200
    assert %{"ok" => true, "toolchains" => toolchains} = Jason.decode!(conn.resp_body)
    assert is_map(toolchains)
  end

  test "a build without a token is refused" do
    conn = post_build(%{}, [])
    assert conn.status == 401
  end

  test "a build with the wrong token is refused" do
    conn = post_build(%{}, [{"authorization", "Bearer wrong"}])
    assert conn.status == 401
  end

  test "an unauthenticated caller is refused before the body is read" do
    # The parser admitted 100 MB before the route body ever checked the
    # token, so anyone who could reach the port could make the container
    # buffer and JSON-parse that much per request, and the concurrency cap —
    # taken later still — bounded toolchain processes, not memory. The
    # endpoint binds 0.0.0.0.
    big = %{
      "source_files" => %{"src/lib.rs" => Base.encode64(:binary.copy("x", 4_000_000))},
      "language" => "rust",
      "target_type" => "reagent"
    }

    conn =
      :post
      |> Plug.Test.conn("/build", Jason.encode!(big))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Locus.BuilderService.call(@opts)

    assert conn.status == 401
    # Nothing was parsed on the way to that answer.
    assert conn.body_params == %Plug.Conn.Unfetched{aspect: :body_params}
  end

  test "an unconfigured builder refuses every token" do
    # No token configured is a refusal too: an unauthenticated builder is
    # a remote code executor.
    Application.delete_env(:cyfr, :builder_token)

    conn = post_build(%{}, [{"authorization", "Bearer " <> @token}])
    assert conn.status == 401
  end

  test "a malformed body is refused with 400, never run" do
    conn = post_build(%{"language" => "rust"}, [{"authorization", "Bearer " <> @token}])

    assert conn.status == 400
    assert %{"ok" => false, "error" => error} = Jason.decode!(conn.resp_body)
    assert error =~ "required"
  end

  test "an unknown language is refused" do
    body = %{
      "source_files" => %{"main.c" => Base.encode64("int main(){}")},
      "language" => "c",
      "target_type" => "reagent"
    }

    conn = post_build(body, [{"authorization", "Bearer " <> @token}])

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"] =~ "unknown language"
  end

  test "a type is built only from its own language" do
    for {language, type} <- [{"rust", "tincture"}, {"javascript", "reagent"}] do
      body = %{
        "source_files" => %{"src/lib.rs" => Base.encode64("fn main() {}")},
        "language" => language,
        "target_type" => type
      }

      conn = post_build(body, [{"authorization", "Bearer " <> @token}])

      assert conn.status == 400, "#{language} + #{type} was not refused"
      assert Jason.decode!(conn.resp_body)["error"] =~ "is not built from"
    end
  end

  test "sources that are not base64 are refused" do
    body = %{
      "source_files" => %{"src/lib.rs" => "not base64 !!!"},
      "language" => "rust",
      "target_type" => "reagent"
    }

    conn = post_build(body, [{"authorization", "Bearer " <> @token}])

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"] =~ "base64"
  end
end
