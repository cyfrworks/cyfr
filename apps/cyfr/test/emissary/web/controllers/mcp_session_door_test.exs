# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.MCPSessionDoorTest do
  @moduledoc """
  `/mcp` as a person's client speaks to it: under the bearer of a session
  the person signed in with, each request's body sent as bytes.

  A key issued over `/mcp` asks for the person's confirmation, is minted
  once they prove it and the client repeats the call, and then
  authenticates a request of its own. An external MCP server's address is
  validated under the shipped private-egress policy, which names no
  private address unless the operator sets one
  (`CYFR_PRIVATE_EGRESS_TARGETS`): a loopback and a private address are
  refused at every caller that validates one, `create`, `update` and the
  server's connect.
  """

  use Emissary.Web.ConnCase, async: false

  alias Sanctum.{Context, TestContext}

  @confirmation "cyfr/confirmationId"
  @loopback "http://127.0.0.1:9/mcp"
  @private "http://10.20.30.40/mcp"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Test.People.linked(%{
        id: "github|https://github.com|mcp-door-#{n}",
        provider: "github",
        email: "mcp-door#{n}@example.com",
        verified: true
      })

    athanor = Sanctum.Test.People.athanor!(user)

    built =
      Context.build(
        user_id: user.id,
        email: user.email,
        provider: "github",
        athanor_id: athanor.id,
        permissions: [:*],
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, session} = TestContext.create_session(built)
    {:ok, ctx} = Sanctum.Caller.establish(session.token, focus: athanor.id, refresh: false)

    %{
      ctx: ctx,
      authenticator: TestContext.passkey!(user.id),
      as_person: put_req_header(conn, "authorization", "Bearer #{session.token}")
    }
  end

  defp call(conn, name, arguments, meta \\ %{}) do
    conn
    |> recycle()
    |> mcp_post(
      %{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => arguments}
      },
      meta
    )
  end

  # The call as a person's client makes it: asked, answered the
  # confirmation signal, proven by the person, repeated under its id.
  defp confirmed_call(conn, %{ctx: ctx, authenticator: authenticator}, name, arguments) do
    assert %{
             "error" => %{
               "data" => %{"tag" => "confirmation_required", "payload" => %{"id" => id}}
             }
           } =
             json_response(call(conn, name, arguments), 400)

    TestContext.prove!(ctx, id, authenticator)
    call(conn, name, arguments, %{@confirmation => id})
  end

  defp result!(conn) do
    assert %{"result" => %{"content" => [%{"text" => text}]} = result} = json_response(conn, 200)
    refute result["isError"], text
    Jason.decode!(text)
  end

  defp refusal!(conn) do
    assert %{"result" => %{"isError" => true, "content" => [%{"text" => text}]}} =
             json_response(conn, 200)

    text
  end

  describe "a key issued over /mcp" do
    test "is minted once the person confirms it, and then authenticates a request of its own",
         %{as_person: as_person} = seat do
      key =
        as_person
        |> confirmed_call(seat, "key", %{
          "action" => "create",
          "name" => "laptop",
          "type" => "admin"
        })
        |> result!()

      assert %{"api_key" => "cyfr_" <> _ = api_key, "name" => "laptop"} = key

      as_key =
        as_person
        |> delete_req_header("authorization")
        |> put_req_header("authorization", "Bearer #{api_key}")

      listed = as_key |> call("key", %{"action" => "list"}) |> result!()
      assert Enum.any?(listed["keys"], &(&1["name"] == "laptop"))

      # Without it the same request is refused: the key is what admitted it.
      refused =
        as_person
        |> delete_req_header("authorization")
        |> call("key", %{"action" => "list"})

      assert %{"error" => %{"message" => "Unauthorized: tool 'key' requires authentication"}} =
               json_response(refused, 401)
    end
  end

  describe "an external MCP server's address" do
    setup do
      # The shipped policy: the operator's allowlist is empty unless set
      # (config/runtime.exs reads `CYFR_PRIVATE_EGRESS_TARGETS`); the suite's
      # names loopback for its fake servers.
      Prima.Test.Env.put_app_env(:sanctum, :private_egress_targets, [])
      :ok
    end

    test "create refuses a loopback and a private address", %{as_person: as_person, ctx: ctx} do
      for url <- [@loopback, @private] do
        text =
          as_person
          |> call("mcp_servers", %{
            "action" => "create",
            "name" => "relay",
            "config" => %{"url" => url}
          })
          |> refusal!()

        assert text =~ "Invalid URL: private IP"
      end

      assert {:error, :not_found} = Arca.McpServerStorage.get(Context.actor(ctx), "relay")
    end

    test "update refuses them, and a saved server's connect refuses its own",
         %{as_person: as_person, ctx: ctx} do
      # Saved while the operator named loopback, as one who later removed it.
      Prima.Test.Env.put_app_env(:sanctum, :private_egress_targets, ["127.0.0.1/8"])

      assert %{"epoch" => 1, "url" => @loopback} =
               as_person
               |> call("mcp_servers", %{
                 "action" => "create",
                 "name" => "relay",
                 "config" => %{"url" => @loopback}
               })
               |> result!()

      Prima.Test.Env.put_app_env(:sanctum, :private_egress_targets, [])

      for url <- [@loopback, @private] do
        text =
          as_person
          |> call("mcp_servers", %{
            "action" => "update",
            "name" => "relay",
            "epoch" => 1,
            "config" => %{"url" => url}
          })
          |> refusal!()

        assert text =~ "Invalid URL: private IP"
      end

      assert {:ok, %{epoch: 1, url: @loopback}} =
               Arca.McpServerStorage.get(Context.actor(ctx), "relay")

      # Its connect validates the saved address again, under today's policy.
      assert %{"status" => "error", "error" => error} =
               as_person
               |> call("mcp_servers", %{"action" => "test", "name" => "relay"})
               |> result!()

      assert error == "private IP 127.0.0.1 blocked (resolved from 127.0.0.1)"
    end
  end
end
