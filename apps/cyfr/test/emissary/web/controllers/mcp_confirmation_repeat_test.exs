# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.MCPConfirmationRepeatTest.Probe do
  @moduledoc false
  # Reports, to the process registered as `Emissary.Web.MCPConfirmationRepeatTest`,
  # the confirmation each call's context names: by a tool call and by a
  # resource read. Nothing it answers carries the value.
  @behaviour Prima.Provider

  alias Prima.{Arg, Operation}

  @impl true
  def service, do: "probe"

  @impl true
  def tools do
    [
      Operation.tool([
        Operation.new("confirmation_probe", "carried", "Report the context's confirmation", [],
          kind: :read,
          planes: [:external]
        ),
        Operation.new(
          "confirmation_probe",
          "read_resource",
          "Read a cyfrprobe:// resource",
          [Arg.new("uri", :string, required: true)],
          kind: :read,
          planes: [:external],
          recovery: :replay_safe,
          resource_schemes: ["cyfrprobe"]
        )
      ])
    ]
  end

  @impl true
  def resource_templates do
    [%{uriTemplate: "cyfrprobe://{id}", name: "Probe", description: "A probe resource"}]
  end

  @impl true
  def handle(_tool, ctx, %{"action" => "carried"}) do
    report(ctx)
    {:ok, %{"reported" => true}}
  end

  def handle(_tool, ctx, %{"action" => "read_resource", "uri" => uri}) do
    report(ctx)
    {:ok, %{content: %{"uri" => uri}}}
  end

  defp report(ctx),
    do: send(Emissary.Web.MCPConfirmationRepeatTest, {:carried, ctx.confirmation_id})
end

defmodule Emissary.Web.MCPConfirmationRepeatTest do
  @moduledoc """
  A change repeated over MCP: a `tools/call` names the confirmation it
  repeats under in `params._meta["cyfr/confirmationId"]`, whose value is
  the secret id the `confirmation_required` signal answered.

  A repeat before the person's proof waits on its own record, answered the
  same id, and opens nothing; after the proof the repeat completes, once. A
  value not spelled as a secret is refused `-32602` at `400` before any
  handler runs, and opens nothing. The value rides a `tools/call`'s context
  alone. No request-log row, decision, telemetry event or log line records
  the secret, Phoenix's own `Parameters:` line included.
  """

  use Emissary.Web.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Prima.MCP.Protocol
  alias Sanctum.{Context, TestContext}
  alias Sanctum.Tenancy.{Athanors, Users}

  @key "cyfr/confirmationId"

  setup do
    Prima.RateLimiter.reset()
    on_exit(fn -> Prima.RateLimiter.reset() end)

    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|mcp-repeat-#{n}",
        provider: "github",
        email: "mcp-repeat#{n}@example.com",
        verified: true
      })

    {:ok, athanor} = Athanors.create_group(user.id, "MCP repeat #{n}")

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
    {:ok, ctx} = Sanctum.Caller.establish(session.token, focus: athanor.id, task_supervisor: nil)

    %{user: user, token: session.token, ctx: ctx}
  end

  # ---------------------------------------------------------------------------
  # The wire
  # ---------------------------------------------------------------------------

  # One JSON-RPC message to `/mcp`, sent as the CLI sends it: the body as
  # JSON, the declared metadata in `params._meta` with `meta` beside it, and
  # the mirrored headers.
  defp send_mcp(token, body, meta) do
    params = Map.get(body, "params", %{})

    declared = %{
      Protocol.meta_protocol_version_key() => Protocol.version(),
      Protocol.meta_client_info_key() => %{"name" => "cyfr", "version" => "test"},
      Protocol.meta_client_capabilities_key() => %{}
    }

    body = Map.put(body, "params", Map.put(params, "_meta", Map.merge(declared, meta)))

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("mcp-protocol-version", Protocol.version())
      |> put_req_header("mcp-method", body["method"])

    conn =
      case Protocol.named_subject(body) do
        name when is_binary(name) -> put_req_header(conn, "mcp-name", name)
        _ -> conn
      end

    Phoenix.ConnTest.dispatch(conn, CyfrWeb.Endpoint, :post, "/mcp", Jason.encode!(body))
  end

  defp tools_call(token, name, arguments, meta \\ %{}) do
    send_mcp(
      token,
      %{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => arguments}
      },
      meta
    )
  end

  defp repeat(id), do: %{@key => id}

  defp entry(name),
    do: %{
      "action" => "create",
      "name" => name,
      "kind" => "api_key",
      "fields" => %{"KEY" => "sk-repeat-secret"},
      "destination" => %{"hosts" => ["api.example.com"]}
    }

  # The signal as the wire carries it: its secret and its expiry.
  defp signal!(conn) do
    assert %{
             "error" => %{
               "code" => -33_505,
               "data" => %{
                 "tag" => "confirmation_required",
                 "payload" => %{"id" => id, "expires_at" => expires_at}
               }
             }
           } = json_response(conn, 400)

    assert id =~ ~r/\Acnf_[A-Za-z0-9_-]{43}\z/
    {id, expires_at}
  end

  defp open_records(ctx, user) do
    {:ok, rows} = Arca.PendingConfirmations.list_open(Context.actor(ctx), user.id)
    rows
  end

  defp entries(ctx, name) do
    {:ok, entries} = Sanctum.Vault.list(ctx)
    Enum.filter(entries, &(&1.name == name))
  end

  def handle_telemetry(event, measurements, metadata, pid),
    do: send(pid, {:telemetry_seen, event, measurements, metadata})

  defp drain_telemetry(acc \\ []) do
    receive do
      {:telemetry_seen, _event, _measurements, _metadata} = seen -> drain_telemetry([seen | acc])
    after
      0 -> acc
    end
  end

  # ---------------------------------------------------------------------------
  # The repeat
  # ---------------------------------------------------------------------------

  describe "a tools/call repeated under _meta" do
    test "waits on its own record before the proof, completes once after it, and the secret is recorded nowhere",
         %{token: token, ctx: ctx, user: user} do
      authenticator = TestContext.passkey!(user.id)

      handler = {__MODULE__, make_ref()}

      :ok =
        :telemetry.attach_many(
          handler,
          Cyfr.Telemetry.Catalog.events(),
          &__MODULE__.handle_telemetry/4,
          self()
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      # Every log line, down to debug, is read for the secret.
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)

      {id, log} =
        with_log([level: :debug], fn ->
          # Asked with no proof: the signal and its secret, one record.
          {id, expires_at} = signal!(tools_call(token, "vault", entry("repeat-key")))
          assert [_one] = open_records(ctx, user)

          # Repeated before the proof: the same secret and expiry, still one
          # record, nothing stored.
          assert {^id, ^expires_at} =
                   signal!(tools_call(token, "vault", entry("repeat-key"), repeat(id)))

          assert [_still_one] = open_records(ctx, user)
          assert entries(ctx, "repeat-key") == []

          # Proven by the person, by its ref; repeated under its secret: done.
          TestContext.prove!(ctx, id, authenticator)

          conn = tools_call(token, "vault", entry("repeat-key"), repeat(id))

          assert %{"result" => %{"content" => [%{"text" => text}]} = result} =
                   json_response(conn, 200)

          refute result["isError"]
          assert text =~ "repeat-key"
          assert [_created] = entries(ctx, "repeat-key")

          # Once: the record is spent, so the same secret asks again.
          {again, _expires_at} =
            signal!(tools_call(token, "vault", entry("repeat-key"), repeat(id)))

          refute again == id
          assert [_still_created] = entries(ctx, "repeat-key")

          id
        end)

      Logger.configure(level: previous)

      seen = drain_telemetry()
      assert Enum.any?(seen, &match?({_, [:cyfr, :emissary, :request], _, _}, &1))

      assert {:ok, %{logs: logs}} =
               Grimoire.call_external("mcp_log", ctx, %{"action" => "list", "limit" => 100})

      assert {:ok, %{decisions: decisions}} =
               Grimoire.call_external("decision", ctx, %{"action" => "list", "limit" => 100})

      assert Enum.any?(logs, &(&1.tool == "vault" and &1.status == "success"))

      rows = {Arca.Repo.all(Arca.Schemas.McpLog), Arca.Repo.all(Arca.Schemas.DecisionLog)}

      for {name, recorded} <- [
            {"the request log", logs},
            {"the decisions", decisions},
            {"the stored rows", rows},
            {"the telemetry", seen},
            {"the log", log}
          ] do
        text =
          if is_binary(recorded),
            do: recorded,
            else: inspect(recorded, limit: :infinity, printable_limit: :infinity)

        refute text =~ id, "#{name} recorded the secret"
      end

      assert log =~ "Parameters:", "Phoenix's request line was not captured"
    end

    test "names a confirmation only in a tools/call's context", %{token: token} do
      Process.register(self(), __MODULE__)
      id = "cnf_" <> String.duplicate("A", 43)

      Grimoire.Catalog.with_providers([__MODULE__.Probe], fn ->
        conn = tools_call(token, "confirmation_probe", %{"action" => "carried"}, repeat(id))
        assert json_response(conn, 200)
        assert_received {:carried, ^id}

        conn = tools_call(token, "confirmation_probe", %{"action" => "carried"})
        assert json_response(conn, 200)
        assert_received {:carried, nil}

        conn =
          send_mcp(
            token,
            %{
              "jsonrpc" => "2.0",
              "id" => 1,
              "method" => "resources/read",
              "params" => %{"uri" => "cyfrprobe://one"}
            },
            repeat(id)
          )

        assert json_response(conn, 200)
        assert_received {:carried, nil}

        conn =
          send_mcp(token, %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"}, repeat(id))

        assert %{"result" => %{"tools" => [_ | _]}} = json_response(conn, 200)
      end)
    end

    test "Phoenix's own request line hides the secret", %{token: token} do
      id = "cnf_" <> String.duplicate("B", 43)

      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)

      log =
        capture_log([level: :debug], fn ->
          send_mcp(token, %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}, repeat(id))
        end)

      Logger.configure(level: previous)

      assert log =~ "Parameters:"
      assert log =~ ~s("#{@key}" => "[FILTERED]")
      refute log =~ id
    end
  end

  # ---------------------------------------------------------------------------
  # A malformed value
  # ---------------------------------------------------------------------------

  describe "a _meta value not spelled as a secret" do
    test "is refused -32602 at 400 before any handler runs, unechoed, and opens nothing",
         %{token: token, ctx: ctx, user: user} do
      valid = "cnf_" <> String.duplicate("C", 43)

      for value <- [
            "cnf_short",
            "cnf_" <> String.duplicate("C", 44),
            "cnf_" <> String.duplicate("C", 42) <> "!",
            "CNF_" <> String.duplicate("C", 43),
            " " <> valid,
            Prima.Confirmation.ref(valid),
            "",
            42,
            nil,
            %{"id" => valid},
            [valid]
          ] do
        conn = tools_call(token, "vault", entry("malformed-key"), repeat(value))

        assert %{"error" => %{"code" => -32_602, "message" => message}} = json_response(conn, 400),
               "#{inspect(value)} was not refused"

        assert message =~ @key

        if is_binary(value) and value != "",
          do: refute(conn.resp_body =~ String.trim(value), "#{inspect(value)} was echoed")
      end

      # Nothing reached the change: no record was opened, nothing stored.
      assert open_records(ctx, user) == []
      assert entries(ctx, "malformed-key") == []

      # A notification carrying one is refused the same way.
      conn =
        send_mcp(
          token,
          %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
          repeat("cnf_short")
        )

      assert %{"error" => %{"code" => -32_602}} = json_response(conn, 400)
    end
  end
end
