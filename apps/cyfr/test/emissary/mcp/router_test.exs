# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.RouterTest.Confirming do
  @moduledoc false
  # A handler that answers what a sensitive change answers until its
  # confirmation is given: the `confirmation_required` signal naming the
  # pending confirmation, never a result.
  @behaviour Prima.Provider

  alias Prima.Operation

  @impl true
  def service, do: "probe"

  @impl true
  def tools do
    [
      Operation.tool([
        Operation.new("confirming_probe", "change", "Ask for a fresh confirmation", [],
          kind: :read,
          planes: [:external]
        )
      ])
    ]
  end

  @impl true
  def handle(_tool, _ctx, %{"action" => "change"}) do
    {:error,
     {:confirmation_required,
      %{
        id: "confirmation-7f3a",
        operation: "confirming_probe/change",
        expires_at: ~U[2026-09-29 12:05:00Z]
      }}}
  end
end

defmodule Emissary.MCP.RouterTest do
  use ExUnit.Case, async: false

  alias Emissary.MCP.Router
  alias Prima.MCP.Message

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    ctx = Sanctum.TestContext.local()

    {:ok, context: ctx}
  end

  describe "dispatch/2 with server/discover" do
    test "advertises the supported revisions, capabilities and identity", %{context: ctx} do
      msg = %Message{type: :request, id: 1, method: "server/discover", params: %{}}

      assert {:ok, result} = Router.dispatch(ctx, msg)
      assert result["supportedVersions"] == Prima.MCP.Protocol.supported()
      assert is_map(result["capabilities"])

      # Identity is stamped onto every result by the encoder, so the router's
      # own return value carries only what is specific to discovery.
      refute Map.has_key?(result, "serverInfo")
    end

    test "does not advertise a resource-subscribe capability it cannot honour",
         %{context: ctx} do
      msg = %Message{type: :request, id: 1, method: "server/discover", params: %{}}

      assert {:ok, result} = Router.dispatch(ctx, msg)

      # Advertise subscriptions/listen support without the unsupported resources/subscribe capability.
      refute Map.has_key?(result["capabilities"]["resources"], "subscribe")
      assert is_map(result["capabilities"]["extensions"])
    end
  end

  describe "dispatch/2 with ping" do
    # Reject unsupported methods for the current protocol revision.
    test "is not a method this revision has", %{context: ctx} do
      msg = %Message{
        type: :request,
        id: 2,
        method: "ping",
        params: nil
      }

      assert {:error, :method_not_found, message} = Router.dispatch(ctx, msg)
      assert message =~ "ping"
    end
  end

  describe "dispatch/2 with tools/list" do
    test "delegates to the catalog and returns tools list", %{context: ctx} do
      msg = %Message{
        type: :request,
        id: 3,
        method: "tools/list",
        params: nil
      }

      assert {:ok, result} = Router.dispatch(ctx, msg)
      assert is_list(result["tools"])
    end

    test "reads the page a cursor it issued names", %{context: ctx} do
      cursor = Base.url_encode64("0", padding: false)
      first = %Message{type: :request, id: 4, method: "tools/list", params: nil}
      named = %Message{first | params: %{"cursor" => cursor}}

      assert {:ok, %{"tools" => tools}} = Router.dispatch(ctx, first)
      assert {:ok, %{"tools" => ^tools}} = Router.dispatch(ctx, named)
    end

    test "refuses a cursor it did not issue as invalid params", %{context: ctx} do
      for cursor <- [
            "not a cursor",
            Base.url_encode64("-1", padding: false),
            Base.url_encode64("1x", padding: false),
            Base.url_encode64("1000001", padding: false),
            7
          ] do
        msg = %Message{type: :request, id: 5, method: "tools/list", params: %{"cursor" => cursor}}

        assert {:error, :invalid_params, "Invalid cursor"} = Router.dispatch(ctx, msg),
               inspect(cursor)
      end
    end
  end

  describe "dispatch/2 with tools/call" do
    test "delegates to the catalog for valid tool", %{context: ctx} do
      msg = %Message{
        type: :request,
        id: 4,
        method: "tools/call",
        params: %{
          "name" => "system",
          "arguments" => %{"action" => "status"}
        }
      }

      assert {:ok, result} = Router.dispatch(ctx, msg)
      assert is_list(result["content"])
      [content] = result["content"]
      assert content["type"] == "text"
      assert result["isError"] == false
    end

    test "returns protocol error for unknown tool", %{context: ctx} do
      msg = %Message{
        type: :request,
        id: 5,
        method: "tools/call",
        params: %{
          "name" => "nonexistent/tool",
          "arguments" => %{}
        }
      }

      assert {:error, :invalid_params, message} = Router.dispatch(ctx, msg)
      assert message =~ "Unknown tool: nonexistent/tool"
    end

    test "returns protocol error when tool name is missing", %{context: ctx} do
      msg = %Message{
        type: :request,
        id: 5,
        method: "tools/call",
        params: %{"arguments" => %{}}
      }

      assert {:error, :invalid_params, message} = Router.dispatch(ctx, msg)
      assert message =~ "Missing required field: name"
    end

    test "returns invalid_params for non-object arguments", %{context: ctx} do
      # Reject non-map arguments as invalid_params before action lookup.
      for bad_arguments <- [[1, 2, 3], "a string", 42] do
        msg = %Message{
          type: :request,
          id: 5,
          method: "tools/call",
          params: %{"name" => "system", "arguments" => bad_arguments}
        }

        assert {:error, :invalid_params, message} = Router.dispatch(ctx, msg)
        assert message =~ "must be an object"
      end
    end

    test "handles missing arguments as empty map", %{context: ctx} do
      msg = %Message{
        type: :request,
        id: 6,
        method: "tools/call",
        params: %{
          "name" => "session",
          "arguments" => nil
        }
      }

      # Should not crash — returns validation error if schema requires fields,
      # or succeeds if tool has no required fields
      result = Router.dispatch(ctx, msg)
      assert match?({:ok, _}, result) or match?({:error, :invalid_params, _}, result)
    end
  end

  # The Router makes no decision of its own: the gate authorizes and casts
  # once, and the stage of its answer says how the wire carries it. What
  # the gate refused before the tool ran is a JSON-RPC error by class,
  # with its class's code; what the tool answered is a failed tool result, except
  # an authentication, permission or consent refusal.
  describe "dispatch/2 with tools/call refusals" do
    defp call(ctx, name, arguments) do
      Router.dispatch(ctx, %Message{
        type: :request,
        id: 7,
        method: "tools/call",
        params: %{"name" => name, "arguments" => arguments}
      })
    end

    test "the gate's refusals are protocol errors by class", %{context: ctx} do
      Sanctum.Catalog.with_providers([Sanctum.Gate.Probe.Refusing], fn ->
        # A declared argument the gate cannot cast.
        assert {:error, :invalid_params, message} =
                 call(ctx, "refusing_probe", %{"action" => "invalid", "n" => "x"})

        assert message =~ "integer"

        # An undeclared argument, an undeclared action, no action at all.
        assert {:error, :invalid_params, "Unknown field: extra"} =
                 call(ctx, "refusing_probe", %{"action" => "invalid", "extra" => 1})

        assert {:error, :invalid_params, "Unknown action: refusing_probe.dance"} =
                 call(ctx, "refusing_probe", %{"action" => "dance"})

        assert {:error, :invalid_params, "Missing required argument: action"} =
                 call(ctx, "refusing_probe", %{})
      end)

      # The caller's authorization, refused before the arguments are read:
      # a caller with no credential, and one without the declared permission.
      anonymous = %{ctx | authenticated: false}

      assert {:error, :auth_required, _message} =
               call(anonymous, "component", %{"action" => "list", "extra" => 1})

      no_admin = %{ctx | permissions: MapSet.new([:execute])}

      assert {:error, :insufficient_permissions, message} =
               call(no_admin, "system", %{"action" => "notify"})

      assert message ==
               Sanctum.Unauthorized.message({:missing_permission, :admin}, no_admin.auth_method)
    end

    test "a tool's own refusal is a failed tool result; its permission refusal keeps its code",
         %{context: ctx} do
      Sanctum.Catalog.with_providers([Sanctum.Gate.Probe.Refusing], fn ->
        assert {:ok, %{"isError" => true, "content" => [%{"text" => text}]}} =
                 call(ctx, "refusing_probe", %{"action" => "invalid", "n" => 1})

        assert text == "the handler refused this argument"

        assert {:error, :insufficient_permissions, _message} =
                 call(ctx, "refusing_probe", %{"action" => "forbidden"})
      end)
    end

    # The sentence is worded for the caller's credential on both paths: an
    # API key's holder can change only the key's scopes, so its missing
    # permission names the scope to recreate the key with.
    test "an API key's missing permission names the scope to recreate it with, on both paths",
         %{context: ctx} do
      api_key = %{ctx | auth_method: :api_key, permissions: MapSet.new([:execute])}
      expected = Sanctum.Unauthorized.message({:missing_permission, :admin}, :api_key)
      assert expected =~ "--scope admin"

      # The gate's refusal before the tool runs, and the tool's own
      # permission refusal, which the router unwraps.
      answers = [
        gate: call(api_key, "system", %{"action" => "notify"}),
        tool:
          Sanctum.Catalog.with_providers([Sanctum.Gate.Probe.Refusing], fn ->
            call(api_key, "refusing_probe", %{"action" => "forbidden"})
          end)
      ]

      assert answers == [
               gate: {:error, :insufficient_permissions, expected},
               tool: {:error, :insufficient_permissions, expected}
             ]
    end

    test "a pending confirmation is a protocol error, -33505, its secret in the data alone",
         %{context: ctx} do
      Sanctum.Catalog.with_providers([Emissary.MCP.RouterTest.Confirming], fn ->
        assert {:error, :confirmation_required, message, data} =
                 call(ctx, "confirming_probe", %{"action" => "change"})

        # The id is the asking request's secret: it rides the data alone,
        # never the sentence a log or a page keeps.
        refute message =~ "confirmation-7f3a"
        assert message =~ "Prism"

        # As the wire carries it.
        assert %{
                 "error" => %{
                   "code" => -33_505,
                   "message" => ^message,
                   "data" => %{
                     "tag" => "confirmation_required",
                     "payload" => %{
                       "id" => "confirmation-7f3a",
                       "operation" => "confirming_probe/change",
                       "expires_at" => "2026-09-29T12:05:00Z"
                     }
                   }
                 }
               } =
                 7
                 |> Message.encode_error(:confirmation_required, message, data)
                 |> Jason.encode!()
                 |> Jason.decode!()
      end)
    end
  end

  # An outside server's tools are called by the names `tools list` gives
  # them, `server:tool`, which the catalogue does not hold: the gate
  # resolves the name, and the server's `console` setting decides whether
  # a call from outside a chain reaches it.
  describe "dispatch/2 with tools/call by an outside server's name" do
    setup do
      stub = Cyfr.Test.HTTPStub.open()
      test = self()

      Cyfr.Test.HTTPStub.stub(stub, "POST", "/mcp", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        result =
          case body["method"] do
            # An upstream schema with an `action` enum of its own, which
            # is not a CYFR action.
            "tools/list" ->
              %{
                "tools" => [
                  %{
                    "name" => "hello",
                    "inputSchema" => %{
                      "type" => "object",
                      "properties" => %{"action" => %{"type" => "string", "enum" => ["read"]}}
                    }
                  }
                ]
              }

            "tools/call" ->
              send(test, {:tools_call, body["params"]})
              %{"content" => [%{"type" => "text", "text" => "hello back"}]}
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => body["id"], "result" => result})
        )
      end)

      {:ok, url: "http://127.0.0.1:#{stub.port}/mcp"}
    end

    defp outside_server(ctx, name, url, config) do
      {:ok, _} =
        Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
          cap: 0,
          name: name,
          url: url,
          config_json: Jason.encode!(config)
        })

      # The athanor's outside tools are cached: a server made here drops
      # the entry as one made through its operation does, so no earlier
      # test's list is read, and the entry goes with the server, so no
      # later test reads this one.
      Emissary.External.Proxy.invalidate_external_tools_cache(ctx)

      on_exit(fn ->
        Emissary.External.ServerSupervisor.stop(name, ctx.athanor_id)
        Emissary.External.Proxy.invalidate_external_tools_cache(ctx)
      end)
    end

    # Every tools/list page, as a client reads it, following each cursor.
    defp listed(ctx, cursor \\ nil) do
      params = if cursor, do: %{"cursor" => cursor}, else: %{}

      {:ok, page} =
        Router.dispatch(ctx, %Message{type: :request, id: 3, method: "tools/list", params: params})

      names = Enum.map(page["tools"], & &1["name"])
      if page["nextCursor"], do: names ++ listed(ctx, page["nextCursor"]), else: names
    end

    defp outside_names(ctx), do: Enum.filter(listed(ctx), &String.contains?(&1, ":"))

    # The outside tools the tools tool lists, called as a client calls it.
    defp tools_tool_outside_names(ctx) do
      {:ok, %{"content" => [%{"text" => text}], "isError" => false}} =
        call(ctx, "tools", %{"action" => "list"})

      text
      |> Jason.decode!()
      |> Map.fetch!("tools")
      |> Enum.map(& &1["name"])
      |> Enum.filter(&String.contains?(&1, ":"))
    end

    @hello_back {:ok,
                 %{
                   "content" => [
                     %{
                       "type" => "text",
                       "text" =>
                         Jason.encode!(%{
                           "content" => [%{"type" => "text", "text" => "hello back"}]
                         })
                     }
                   ],
                   "isError" => false
                 }}

    test "a listed name of a server with console on is called", %{context: ctx, url: url} do
      outside_server(ctx, "greeter", url, %{"console" => true})

      # Listed and called through the MCP method, as a client does.
      assert outside_names(ctx) == ["greeter:hello"]
      assert call(ctx, "greeter:hello", %{"who" => "Oren"}) == @hello_back
      assert_received {:tools_call, %{"name" => "hello", "arguments" => %{"who" => "Oren"}}}
    end

    # An outside tool's call is a run like any other: it takes the
    # permission a run needs, decided at the gate's admission.
    test "a key without execute is neither shown nor let call an outside tool, and the server hears nothing",
         %{context: ctx, url: url} do
      outside_server(ctx, "greeter", url, %{"console" => true})
      key = %{ctx | auth_method: :api_key, permissions: MapSet.new([:storage_read])}

      assert outside_names(key) == []

      assert call(key, "greeter:hello", %{}) ==
               {:error, :insufficient_permissions,
                Sanctum.Unauthorized.message({:missing_permission, :execute}, :api_key)}

      refute_received {:tools_call, _}
    end

    test "a key with execute, a browser session and a paired box are each shown and admitted",
         %{context: ctx, url: url} do
      outside_server(ctx, "greeter", url, %{"console" => true})

      callers = [
        key: %{ctx | auth_method: :api_key, permissions: MapSet.new([:execute])},
        session: Sanctum.TestContext.local(:prism),
        box: %{Sanctum.TestContext.local(:device) | auth_method: :device}
      ]

      for {who, caller} <- callers do
        assert {who, outside_names(caller)} == {who, ["greeter:hello"]}
        assert {who, call(caller, "greeter:hello", %{})} == {who, @hello_back}
        assert_received {:tools_call, %{"name" => "hello"}}
      end
    end

    # One admission decides both lists; an upstream schema's `action` enum
    # is not read as CYFR's actions by either.
    test "the tools tool's list and tools/list name the same outside tools, with or without execute",
         %{context: ctx, url: url} do
      outside_server(ctx, "greeter", url, %{"console" => true})

      for {caller, expected} <- [
            {%{ctx | auth_method: :api_key, permissions: MapSet.new([:execute])},
             ["greeter:hello"]},
            {%{ctx | auth_method: :api_key, permissions: MapSet.new([:storage_read])}, []}
          ] do
        assert {tools_tool_outside_names(caller), outside_names(caller)} == {expected, expected}
      end
    end

    # A key narrowed to named tools is admitted to, and shown, only the
    # outside tools it lists; the fixture athanor's owner mints it there.
    defp narrowed_key!(ctx, name, tools) do
      _owner = Sanctum.TestContext.owner!()
      issuer = Sanctum.TestContext.issuer!(%{ctx | user_id: Arca.Test.Actor.owner_id()})

      {:ok, %{api_key: raw}} =
        Sanctum.TestContext.create_key(issuer, %{name: name, scope: ["execute"], tools: tools})

      {:ok, key} = Sanctum.Caller.establish({:api_key, raw}, client_ip: "127.0.0.1")
      key
    end

    test "a key narrowed to an outside tool calls and is shown that tool",
         %{context: ctx, url: url} do
      outside_server(ctx, "greeter", url, %{"console" => true})
      key = narrowed_key!(ctx, "greeter-only", ["greeter:hello"])

      assert {tools_tool_outside_names(key), outside_names(key)} ==
               {["greeter:hello"], ["greeter:hello"]}

      assert call(key, "greeter:hello", %{}) == @hello_back
      assert_received {:tools_call, %{"name" => "hello"}}
    end

    test "a key narrowed to other tools is neither shown nor let call an outside tool, and the server hears nothing",
         %{context: ctx, url: url} do
      outside_server(ctx, "greeter", url, %{"console" => true})

      for {name, tools} <- [
            {"component-only", ["c:local.ship"]},
            {"other-outside", ["greeter:goodbye"]}
          ] do
        key = narrowed_key!(ctx, name, tools)

        assert {tools_tool_outside_names(key), outside_names(key)} == {[], []}

        assert call(key, "greeter:hello", %{}) ==
                 {:error, :insufficient_permissions,
                  "This API key may run only the tools named when it was made, and this is " <>
                    "not one of them."}

        refute_received {:tools_call, _}
      end
    end

    # A stub server listing `tools`, which tells the test of any call.
    defp stub_listing(tools) do
      stub = Cyfr.Test.HTTPStub.open()
      test = self()

      Cyfr.Test.HTTPStub.stub(stub, "POST", "/mcp", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        result =
          case body["method"] do
            "tools/list" ->
              %{
                "tools" =>
                  Enum.map(tools, &%{"name" => &1, "inputSchema" => %{"type" => "object"}})
              }

            "tools/call" ->
              send(test, {:tools_call, body["params"]})
              %{"content" => [%{"type" => "text", "text" => "called"}]}
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => body["id"], "result" => result})
        )
      end)

      "http://127.0.0.1:#{stub.port}/mcp"
    end

    # The kind of what a key starts is the caller's to say, never the
    # name's: an outside tool whose name reads like a component matches no
    # component entry, and no outside entry can name a server called like
    # a component type, so a narrowed key is refused it.
    test "a key narrowed to a component is refused, and not shown, an outside tool spelled like it",
         %{context: ctx} do
      outside_server(ctx, "c", stub_listing(["local.ship", "local.ship:1.0.0"]), %{
        "console" => true
      })

      outside_server(ctx, "catalyst", stub_listing(["local.ship"]), %{"console" => true})
      key = narrowed_key!(ctx, "ship-only", ["c:local.ship"])

      # The person sees all three; the key sees none.
      assert Enum.sort(outside_names(ctx)) ==
               ["c:local.ship", "c:local.ship:1.0.0", "catalyst:local.ship"]

      assert {tools_tool_outside_names(key), outside_names(key)} == {[], []}

      for name <- ["c:local.ship", "catalyst:local.ship", "c:local.ship:1.0.0"] do
        assert {name, call(key, name, %{})} ==
                 {name,
                  {:error, :insufficient_permissions,
                   "This API key may run only the tools named when it was made, and this is " <>
                     "not one of them."}}
      end

      refute_received {:tools_call, _}

      # The component it names is still the key's to run.
      assert Sanctum.ApiKey.admit_tool(key, {:component, "catalyst:local.ship:1.0.0"}) == :ok
      assert Sanctum.ApiKey.admit_tool(key, {:component, "c:local.ship"}) == :ok
    end

    test "a key with execute and no tool list is shown and admitted as before",
         %{context: ctx, url: url} do
      outside_server(ctx, "greeter", url, %{"console" => true})
      key = narrowed_key!(ctx, "any-tool", [])

      assert {tools_tool_outside_names(key), outside_names(key)} ==
               {["greeter:hello"], ["greeter:hello"]}

      assert call(key, "greeter:hello", %{}) == @hello_back
      assert_received {:tools_call, %{"name" => "hello"}}
    end

    test "a server without console is refused with the setting to turn on", %{
      context: ctx,
      url: url
    } do
      outside_server(ctx, "inside-only", url, %{})

      # Nothing a call is refused is listed.
      assert outside_names(ctx) == []

      assert call(ctx, "inside-only:hello", %{}) ==
               {:error, :invalid_params,
                "Tool 'hello' on server 'inside-only' is reachable only from inside a " <>
                  "chain — set \"console\": true in the server's config to call it from the console"}

      refute_received {:tools_call, _}
    end

    test "a name no server answers is an unknown tool", %{context: ctx} do
      assert call(ctx, "nobody:hello", %{}) ==
               {:error, :invalid_params, "Unknown tool: nobody:hello"}
    end
  end

  describe "dispatch/2 with resources/list" do
    test "delegates to Sanctum.Resources and returns resources list", %{context: ctx} do
      msg = %Message{
        type: :request,
        id: 7,
        method: "resources/list",
        params: nil
      }

      assert {:ok, result} = Router.dispatch(ctx, msg)
      assert is_list(result["resources"])

      # Resources list must not contain URI templates
      Enum.each(result["resources"], fn resource ->
        uri = resource["uri"]

        refute String.contains?(uri, "{"),
               "resources/list should not contain URI templates, found: #{uri}"
      end)
    end
  end

  describe "dispatch/2 with resources/templates/list" do
    test "returns resource templates with uriTemplate field", %{context: ctx} do
      msg = %Message{
        type: :request,
        id: 20,
        method: "resources/templates/list",
        params: nil
      }

      assert {:ok, result} = Router.dispatch(ctx, msg)
      assert is_list(result["resourceTemplates"])

      # All templates should have uriTemplate field
      Enum.each(result["resourceTemplates"], fn template ->
        assert is_binary(template["uriTemplate"]),
               "resource template missing uriTemplate field: #{inspect(template)}"

        assert String.contains?(template["uriTemplate"], "{"),
               "uriTemplate should contain template variables: #{template["uriTemplate"]}"
      end)
    end
  end

  describe "dispatch/2 with resources/read" do
    test "returns error for unknown URI scheme", %{context: ctx} do
      msg = %Message{
        type: :request,
        id: 8,
        method: "resources/read",
        params: %{"uri" => "unknown://resource/path"}
      }

      # An argument refusal answers by its class: invalid params.
      assert {:error, :invalid_params, message} = Router.dispatch(ctx, msg)
      assert message =~ "No provider found for scheme: unknown"
    end

    test "returns error for a URI with no scheme", %{context: ctx} do
      msg = %Message{
        type: :request,
        id: 8,
        method: "resources/read",
        params: %{"uri" => "invalid-uri-no-scheme"}
      }

      assert {:error, :invalid_params, message} = Router.dispatch(ctx, msg)
      assert message =~ "Invalid URI format"
    end

    test "a declared read answers its content in the MCP shape", %{context: ctx} do
      :ok = Arca.put(Sanctum.Context.actor(ctx), ["data", "router.txt"], "bytes")

      msg = %Message{
        type: :request,
        id: 8,
        method: "resources/read",
        params: %{"uri" => "arca://files/data/router.txt"}
      }

      assert {:ok, %{"contents" => [entry], "cacheScope" => "private"}} =
               Router.dispatch(ctx, msg)

      assert entry["uri"] == "arca://files/data/router.txt"
      assert entry["mimeType"] == Prima.MediaType.binary()
      assert Base.decode64!(entry["blob"]) == "bytes"

      msg = %{msg | params: %{"uri" => "sanctum://identity"}}
      assert {:ok, %{"contents" => [%{"text" => text}]}} = Router.dispatch(ctx, msg)
      assert Jason.decode!(text)["user_id"] == ctx.user_id
    end

    # Reject missing or non-string resource URIs as invalid_params.
    for {label, params} <- [
          {"no params at all", %{}},
          {"a null uri", %{"uri" => nil}},
          {"a numeric uri", %{"uri" => 42}},
          {"an object uri", %{"uri" => %{"nested" => true}}},
          {"an empty uri", %{"uri" => ""}}
        ] do
      test "refuses #{label} with invalid_params", %{context: ctx} do
        msg = %Message{
          type: :request,
          id: 9,
          method: "resources/read",
          params: unquote(Macro.escape(params))
        }

        assert {:error, :invalid_params, message} = Router.dispatch(ctx, msg)
        assert message =~ "uri"
      end
    end
  end

  describe "the decision a call is recorded as" do
    test "a tools/call is recorded under the call id the request's context carries",
         %{context: ctx} do
      call_id = Prima.UUID7.generate_id("call")
      ctx = %{ctx | request_id: Prima.UUID7.request_id(), call_id: call_id}

      msg = %Message{
        type: :request,
        id: 1,
        method: "tools/call",
        params: %{"name" => "session", "arguments" => %{"action" => "whoami"}}
      }

      assert {:ok, _} = Router.dispatch(ctx, msg)

      assert {:ok, %{admission: :admitted, tool: "session", request_id: request_id}} =
               Arca.DecisionLog.get(Sanctum.Context.actor(ctx), call_id)

      assert request_id == ctx.request_id

      assert %{method: "tools/call"} = Arca.Repo.get(Arca.Schemas.McpLog, call_id)
    end

    test "a resources/read keeps its wire method on the row", %{context: ctx} do
      call_id = Prima.UUID7.generate_id("call")
      ctx = %{ctx | request_id: Prima.UUID7.request_id(), call_id: call_id}

      msg = %Message{
        type: :request,
        id: 1,
        method: "resources/read",
        params: %{"uri" => "arca://files/data/nothing-here.txt"}
      }

      _ = Router.dispatch(ctx, msg)

      assert {:ok, %{admission: :admitted}} =
               Arca.DecisionLog.get(Sanctum.Context.actor(ctx), call_id)

      assert %{method: "resources/read"} = Arca.Repo.get(Arca.Schemas.McpLog, call_id)
    end
  end

  describe "dispatch/2 with unknown method" do
    test "returns method_not_found error", %{context: ctx} do
      msg = %Message{
        type: :request,
        id: 9,
        method: "unknown/method",
        params: nil
      }

      assert {:error, :method_not_found, message} = Router.dispatch(ctx, msg)
      assert message =~ "Unknown method"
    end
  end

  describe "dispatch/2 with notifications" do
    test "any notification is logged and absorbed, never dispatched", %{context: ctx} do
      # There is deliberately no notification clause besides the catch-all:
      # on Streamable HTTP the only cancellation signal is the caller
      # closing its own stream, so `notifications/cancelled` must NOT be a
      # second way in — it lands in the same absorb-and-log arm as anything
      # else.
      for {method, params} <- [
            {"notifications/cancelled", %{"requestId" => 123}},
            {"notifications/unknown", nil}
          ] do
        msg = %Message{type: :notification, method: method, params: params}
        assert :ok = Router.dispatch(ctx, msg)
      end
    end
  end

  describe "dispatch/2 with client response/error types" do
    test "returns :ok for response type (per MCP spec, maps to 202)", %{context: ctx} do
      msg = %Message{
        type: :response,
        id: 10,
        result: %{}
      }

      assert :ok = Router.dispatch(ctx, msg)
    end

    test "returns :ok for error type (per MCP spec, maps to 202)", %{context: ctx} do
      msg = %Message{
        type: :error,
        id: 11,
        error: %{"code" => -32600, "message" => "Error"}
      }

      assert :ok = Router.dispatch(ctx, msg)
    end
  end
end
