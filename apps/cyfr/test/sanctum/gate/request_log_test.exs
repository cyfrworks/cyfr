# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Gate.RequestLogTest.Patterned do
  @moduledoc false
  # A tool whose argument declares a format: its runs tell the process
  # registered as `:request_log_patterned_observer`.
  @behaviour Prima.Provider

  def tool, do: "patterned_probe"

  @impl true
  def service, do: "probe"

  @impl true
  def tools do
    [
      Prima.Operation.tool([
        Prima.Operation.new(
          "patterned_probe",
          "look",
          "Look a reference up",
          [
            Prima.Arg.new("reference", :string, required: true, pattern: "^ref-[0-9]{1,8}$"),
            Prima.Arg.new("count", :integer),
            Prima.Arg.new("label", :string)
          ],
          kind: :read,
          planes: [:external, :in_chain]
        )
      ])
    ]
  end

  @impl true
  def handle(_tool, _ctx, %{"action" => "look"}) do
    send(:request_log_patterned_observer, :ran)
    {:ok, %{"found" => true}}
  end
end

defmodule Sanctum.Gate.RequestLogTest do
  @moduledoc """
  The request log's rows as projections of admission decisions: a
  decision opened with its row in one write, the row closed with the
  decision's completion, no row for a decision without a tenant, an
  append that cannot land answered `:ok` with the loss event, and the
  rows read back by the caller's athanor alone.
  """
  use ExUnit.Case, async: false

  import Phoenix.ConnTest, only: [get: 2]
  import Phoenix.LiveViewTest, only: [live: 2, render_hook: 3]

  alias Sanctum.{Decisions, RequestLog}

  @endpoint CyfrWeb.Endpoint
  alias Prima.{Decision, UUID7}

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)

    ctx = %{Sanctum.TestContext.local() | request_id: UUID7.request_id()}
    %{ctx: ctx}
  end

  defp decision(ctx, extra \\ []) do
    Decision.new(
      Keyword.merge(
        [
          call_id: UUID7.generate_id("call"),
          request_id: ctx.request_id,
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          plane: :external,
          tool: "storage",
          action: "get",
          inserted_at: DateTime.utc_now(),
          admission: :admitted
        ],
        extra
      )
    )
  end

  defp row(call_id), do: Arca.Repo.get(Arca.Schemas.McpLog, call_id)

  defp stored(call_id),
    do: Arca.Repo.get(Arca.Schemas.DecisionLog, call_id)

  defp decode_json(nil), do: nil
  defp decode_json(str) when is_binary(str), do: Jason.decode!(str)

  defp attach(event) do
    ref = make_ref()
    test = self()

    :telemetry.attach(
      {__MODULE__, ref},
      event,
      fn name, measurements, metadata, _ -> send(test, {ref, name, measurements, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
    ref
  end

  describe "open/3" do
    test "an admitted decision leaves a pending row and the decision, one write", %{ctx: ctx} do
      decision = decision(ctx)

      assert :ok =
               Decisions.open(ctx, decision, %{
                 method: "tools/call",
                 input: %{"action" => "get", "path" => "/some/file"}
               })

      log = row(decision.call_id)
      assert log.id == decision.call_id
      assert log.request_id == ctx.request_id
      assert log.user_id == ctx.user_id
      assert log.athanor_id == ctx.athanor_id
      assert log.tool == "storage"
      assert log.action == "get"
      assert log.method == "tools/call"
      assert log.status == "pending"
      assert log.refusal_class == nil
      assert decode_json(log.input)["path"] == "/some/file"
      assert DateTime.compare(log.timestamp, decision.inserted_at) == :eq
      assert is_nil(log.output)
      assert is_nil(log.duration_ms)

      assert %{admission: "admitted", athanor_id: athanor, completion: nil} =
               stored(decision.call_id)

      assert athanor == ctx.athanor_id
    end

    test "the method defaults to tools/call", %{ctx: ctx} do
      decision = decision(ctx)
      assert :ok = Decisions.open(ctx, decision)
      assert row(decision.call_id).method == "tools/call"
    end

    test "a refused decision is a closed error row with its class and sentence", %{ctx: ctx} do
      decision =
        decision(ctx, admission: :refused, refusal_class: :forbidden, reason: "Not allowed.")

      assert :ok = Decisions.open(ctx, decision, %{input: %{"action" => "get"}})

      log = row(decision.call_id)
      assert log.status == "error"
      assert log.refusal_class == "forbidden"
      assert log.error == "Not allowed."
      assert log.error_code == nil

      assert %{admission: "refused", refusal_class: "forbidden", reason: "Not allowed."} =
               stored(decision.call_id)
    end

    test "input is sanitized before it is stored", %{ctx: ctx} do
      decision = decision(ctx)

      assert :ok =
               Decisions.open(ctx, decision, %{
                 input: %{
                   "name" => "my_secret",
                   "secret" => "super_secret_value_123",
                   "password" => "hunter2",
                   "metadata" => %{"token" => "bearer_token_xyz", "safe" => "visible"}
                 }
               })

      input = decode_json(row(decision.call_id).input)
      assert input["secret"] == "[REDACTED]"
      assert input["password"] == "[REDACTED]"
      assert input["metadata"]["token"] == "[REDACTED]"
      assert input["name"] == "my_secret"
      assert input["metadata"]["safe"] == "visible"
    end

    test "a decision without a tenant has no row: the decision alone", %{ctx: ctx} do
      platform = Sanctum.Context.internal()
      decision = decision(platform, request_id: ctx.request_id)

      assert :ok = Decisions.open(platform, decision, %{input: %{}})
      assert row(decision.call_id) == nil
      assert %{athanor_id: nil, user_id: "system"} = stored(decision.call_id)

      refused =
        decision(%{platform | user_id: nil},
          admission: :refused,
          refusal_class: :unauthenticated,
          reason: "Sign in."
        )

      assert :ok = Decisions.open(nil, refused)
      assert row(refused.call_id) == nil
      assert %{athanor_id: nil, user_id: nil, admission: "refused"} = stored(refused.call_id)
    end

    test "the decision's event is emitted, admitted or refused", %{ctx: ctx} do
      admitted = attach([:cyfr, :sanctum, :decision, :admitted])
      refused = attach([:cyfr, :sanctum, :decision, :refused])

      assert :ok = Decisions.open(ctx, decision(ctx))
      assert_receive {^admitted, _, %{count: 1}, %{plane: :external, tool: "storage"}}

      assert :ok =
               Decisions.open(
                 ctx,
                 decision(ctx, admission: :refused, refusal_class: :not_found, reason: "Gone.")
               )

      assert_receive {^refused, _, %{count: 1}, %{refusal_class: :not_found}}
    end

    test "an append that cannot land answers :ok, emits the decision and the loss", %{ctx: ctx} do
      admitted = attach([:cyfr, :sanctum, :decision, :admitted])
      lost = attach([:cyfr, :sanctum, :decision, :lost])

      # The call id already holds another decision: this one cannot land.
      held = decision(ctx)
      assert :ok = Decisions.open(ctx, held, %{input: %{}})
      assert_receive {^admitted, _, _, _}

      assert :ok = Decisions.open(ctx, %{held | action: "list"}, %{input: %{}})
      assert_receive {^admitted, _, _, %{action: "list"}}
      assert_receive {^lost, _, %{count: 1}, %{stage: :append, kind: :conflict}}

      # Nothing of the second was written, row or decision.
      assert row(held.call_id).action == "get"
      assert stored(held.call_id).action == "get"
    end
  end

  describe "close/3" do
    test "a success completes the decision and the row", %{ctx: ctx} do
      decision = decision(ctx)
      :ok = Decisions.open(ctx, decision, %{input: %{}})

      assert :ok =
               Decisions.close(ctx, decision.call_id, %{
                 result: {:ok, %{status: "ok", data: "file content"}},
                 duration_ms: 150,
                 routed_to: "arca"
               })

      log = row(decision.call_id)
      assert log.status == "success"
      assert decode_json(log.output)["status"] == "ok"
      assert log.duration_ms == 150
      assert log.routed_to == "arca"

      assert %{completion: "succeeded", completion_class: nil, duration_ms: 150} =
               stored(decision.call_id)
    end

    test "a failure is failed with its class, and the row carries the sentence, no code",
         %{ctx: ctx} do
      decision = decision(ctx)
      :ok = Decisions.open(ctx, decision, %{input: %{}})

      assert :ok =
               Decisions.close(ctx, decision.call_id, %{
                 result: {:error, {:not_found, "component", "c1"}},
                 duration_ms: 10
               })

      log = row(decision.call_id)
      assert log.status == "error"
      assert log.error == Sanctum.Refusals.render({:not_found, "component", "c1"})
      assert log.duration_ms == 10
      # The meaning is the class; a JSON-RPC code is a transport's rendering.
      assert log.error_code == nil

      assert %{completion: "failed", completion_class: "not_found"} = stored(decision.call_id)
    end

    test "cancelled and uncertain ends keep their own outcomes", %{ctx: ctx} do
      for {reason, outcome} <- [
            {{:cancelled, "Tool t was cancelled"}, "cancelled"},
            {{:uncertain, "Tool t crashed; its outcome is unknown"}, "uncertain"}
          ] do
        decision = decision(ctx)
        :ok = Decisions.open(ctx, decision, %{input: %{}})
        :ok = Decisions.close(ctx, decision.call_id, %{result: {:error, reason}, duration_ms: 1})

        assert %{completion: ^outcome, completion_class: ^outcome} = stored(decision.call_id)
        assert row(decision.call_id).status == "error"
      end
    end

    test "a completion that cannot land answers :ok with the loss", %{ctx: ctx} do
      lost = attach([:cyfr, :sanctum, :decision, :lost])

      assert :ok =
               Decisions.close(ctx, UUID7.generate_id("call"), %{
                 result: {:ok, %{}},
                 duration_ms: 1
               })

      assert_receive {^lost, _, %{count: 1}, %{stage: :finish, kind: :not_found}}
    end
  end

  describe "the stored output" do
    # The router re-encodes the tool's structured result as a JSON string
    # under "content"[]."text". A credential a tool legitimately returns to
    # its caller (created API key, webhook secret, session token) must not
    # be persisted verbatim.
    defp closed_output(ctx, output) do
      decision = decision(ctx)
      :ok = Decisions.open(ctx, decision, %{input: %{}})
      :ok = Decisions.close(ctx, decision.call_id, %{result: {:ok, output}, duration_ms: 5})
      row(decision.call_id).output
    end

    test "redacts credentials inside the content text JSON", %{ctx: ctx} do
      output =
        closed_output(ctx, %{
          "content" => [
            %{
              "type" => "text",
              "text" =>
                Jason.encode!(%{
                  "api_key" => "cyfr_pk_super_secret_value",
                  "session_token" => "raw-session-token",
                  "secret" => "whsec_value",
                  "name" => "my-key"
                })
            }
          ],
          "isError" => false
        })

      refute output =~ "cyfr_pk_super_secret_value"
      refute output =~ "raw-session-token"
      refute output =~ "whsec_value"

      [%{"text" => text}] = decode_json(output)["content"]
      inner = Jason.decode!(text)
      assert inner["api_key"] == "[REDACTED]"
      assert inner["session_token"] == "[REDACTED]"
      assert inner["secret"] == "[REDACTED]"
      assert inner["name"] == "my-key"
    end

    test "redacts credentials in structuredContent", %{ctx: ctx} do
      output =
        closed_output(ctx, %{
          "content" => [%{"type" => "text", "text" => "created"}],
          "structuredContent" => %{"secret" => "whsec_value", "slug" => "hook-1"},
          "isError" => false
        })

      refute output =~ "whsec_value"
      assert decode_json(output)["structuredContent"]["secret"] == "[REDACTED]"
      assert decode_json(output)["structuredContent"]["slug"] == "hook-1"
    end

    test "leaves prose text blocks untouched", %{ctx: ctx} do
      output =
        closed_output(ctx, %{
          "content" => [%{"type" => "text", "text" => "all services healthy"}],
          "isError" => false
        })

      [%{"text" => text}] = decode_json(output)["content"]
      assert text == "all services healthy"
    end
  end

  describe "an identity's recovery material" do
    # A printed kit's seed, as the enrollment form draws it and the kit
    # answers it: the field is `recovery_secret` wherever it appears.
    defp seed, do: Prima.Identity.Encoding.b64(:crypto.strong_rand_bytes(32))

    test "the enrollment's input is stored with every seed redacted", %{ctx: ctx} do
      decision = decision(ctx, tool: "person", action: "enroll_holder")
      signing = seed()
      added = seed()

      :ok =
        Decisions.open(ctx, decision, %{
          input: %{
            "action" => "enroll_holder",
            "recovery_secret" => signing,
            "holder" => %{"kind" => "kit", "recovery_secret" => added},
            "request_id" => "req_kit"
          }
        })

      stored = row(decision.call_id).input
      refute stored =~ signing
      refute stored =~ added

      input = decode_json(stored)
      assert input["recovery_secret"] == "[REDACTED]"
      assert input["holder"] == %{"kind" => "kit", "recovery_secret" => "[REDACTED]"}
      assert input["request_id"] == "req_kit"
    end

    test "the kit answered is stored redacted, in the MCP text block and the structured content",
         %{ctx: ctx} do
      secret = seed()
      identifier = "per_" <> String.duplicate("d", 64)

      # What `person.enroll` answers, as the MCP router encodes a result:
      # the JSON text of the structured value, and the value itself.
      answer = %{
        attempt_id: "iat_x",
        phase: "accepted",
        identifier: identifier,
        kit: %{
          identifier: identifier,
          directory_url: "https://dir.example",
          recovery_secret: secret
        }
      }

      output =
        closed_output(ctx, %{
          "content" => [%{"type" => "text", "text" => Jason.encode!(answer)}],
          "structuredContent" => Jason.decode!(Jason.encode!(answer)),
          "isError" => false
        })

      refute output =~ secret
      [%{"text" => text}] = decode_json(output)["content"]
      inner = Jason.decode!(text)
      assert inner["kit"]["recovery_secret"] == "[REDACTED]"
      assert inner["kit"]["identifier"] == identifier
      assert inner["kit"]["directory_url"] == "https://dir.example"

      structured = decode_json(output)["structuredContent"]
      assert structured["kit"]["recovery_secret"] == "[REDACTED]"
      assert structured["identifier"] == identifier
    end

    test "the ingress and the console log neither a seed nor the installation token" do
      previous = Logger.level()
      token = String.duplicate("8d", 32)
      restore_token = Application.fetch_env(:sanctum, :restore_token)
      Logger.configure(level: :debug)
      Application.put_env(:sanctum, :restore_token, token)

      on_exit(fn ->
        Logger.configure(level: previous)

        case restore_token do
          {:ok, value} -> Application.put_env(:sanctum, :restore_token, value)
          :error -> Application.delete_env(:sanctum, :restore_token)
        end
      end)

      secret = seed()

      kit = %{
        "identifier" => "per_" <> String.duplicate("e", 64),
        "directory_url" => "http://not-https.example",
        "recovery_secret" => secret
      }

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          conn =
            Phoenix.ConnTest.build_conn()
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
            |> Phoenix.ConnTest.dispatch(CyfrWeb.Endpoint, :post, "/restore", Jason.encode!(kit))

          assert conn.status == 422
        end)

      assert log =~ "/restore"
      refute log =~ secret
      refute log =~ token

      # A console event carrying the field is logged filtered too.
      console =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          {:ok, view, _html} = live(Phoenix.ConnTest.build_conn(), "/login")
          render_hook(view, "cancel", %{"recovery_secret" => secret})
        end)

      refute console =~ secret
    end
  end

  describe "the projections" do
    test "a decision without a tenant projects no row", %{ctx: ctx} do
      assert RequestLog.opened(nil, decision(ctx), %{}) == nil
      assert RequestLog.opened(Sanctum.Context.internal(), decision(ctx), %{}) == nil
    end

    test "a completion's columns leave out what it does not name, and never a code" do
      assert RequestLog.closed({:error, "No."}, %{duration_ms: 3}) ==
               %{status: "error", error: "No.", duration_ms: 3}

      assert %{status: "success", routed_to: "arca"} =
               RequestLog.closed({:ok, %{}}, %{routed_to: "arca"})

      # A JSON-RPC code is a transport's rendering of a class: a caller's
      # code is not a column the gate's rows write.
      refute Map.has_key?(RequestLog.closed({:error, "No."}, %{error_code: -1}), :error_code)
      refute Map.has_key?(RequestLog.closed({:ok, %{}}, %{error_code: -1}), :error_code)
    end
  end

  describe "list/2" do
    test "answers the caller's athanor's rows alone, whatever athanor the options name",
         %{ctx: ctx} do
      {_ath_a, other} = Sanctum.TestContext.two_contexts()
      other = %{other | request_id: ctx.request_id}
      own = decision(ctx)
      foreign = decision(other)

      assert :ok = Decisions.open(ctx, own, %{input: %{}})
      assert :ok = Decisions.open(other, foreign, %{input: %{}})

      for opts <- [
            [request_id: ctx.request_id],
            [request_id: ctx.request_id, athanor_id: other.athanor_id]
          ] do
        assert {:ok, [log]} = RequestLog.list(ctx, opts)
        assert log.id == own.call_id
        assert log.athanor_id == ctx.athanor_id
      end

      # The two athanors share the request id, and each reads its own row.
      assert {:ok, [log]} =
               RequestLog.list(other, request_id: ctx.request_id, athanor_id: ctx.athanor_id)

      assert log.id == foreign.call_id
    end

    test "a context with no athanor is refused before any row is read, whatever its scope",
         %{ctx: ctx} do
      assert :ok = Decisions.open(ctx, decision(ctx), %{input: %{}})

      for reader <- [
            %{ctx | athanor_id: nil},
            Sanctum.TestContext.platform(platform_admin: true),
            Sanctum.system_context()
          ] do
        assert {:error, :no_athanor} = RequestLog.list(reader, request_id: ctx.request_id)
      end
    end
  end

  # No shipped operation declares a `pattern:`; the probe does.
  describe "a refused call's arguments" do
    setup do
      Process.register(self(), :request_log_patterned_observer)
      :ok
    end

    defp patterned(ctx, args) do
      Sanctum.Catalog.with_providers([__MODULE__.Patterned], fn ->
        Sanctum.Gate.call_external(
          __MODULE__.Patterned.tool(),
          ctx,
          Map.put(args, "action", "look")
        )
      end)
    end

    defp granting(tool_action) do
      node = "formula:local.request-log-probe"

      graph = %{
        "canonical" => "jcs-1",
        "nodes" => %{
          node => %{
            "limits" => %{
              "timeout" => "1m",
              "max_memory_bytes" => 67_108_864,
              "max_request_size" => 1_048_576,
              "max_response_size" => 5_242_880,
              "rate_limit" => %{"requests" => 10_000, "window" => "1m"},
              "max_concurrent_tasks" => 10,
              "batch_timeout" => "1m"
            },
            "edges" => %{"@ingress" => %{"tools" => [tool_action]}}
          }
        }
      }

      {:ok, blob} = Prima.Authority.Blob.parse(graph)

      {:ok, authority} =
        Prima.Authority.root(
          %{
            profile_id: "prof-request-log",
            consent_id: "consent-request-log",
            source_ref: node,
            kind: :owner,
            invoke_mode: :open_inert,
            activation: %{node => "sha256:request-log"}
          },
          blob,
          ceiling: Sanctum.Policy.Ceiling.platform_ceiling()
        )

      authority
    end

    defp patterned_rows(ctx) do
      import Ecto.Query, only: [from: 2]

      Arca.Repo.all(
        from(l in Arca.Schemas.McpLog,
          where: l.athanor_id == ^ctx.athanor_id and l.tool == "patterned_probe"
        )
      )
    end

    defp patterned_decisions(ctx) do
      import Ecto.Query, only: [from: 2]

      Arca.Repo.all(
        from(d in Arca.Schemas.DecisionLog,
          where: d.athanor_id == ^ctx.athanor_id and d.tool == "patterned_probe"
        )
      )
    end

    test "a value failing its declared pattern is refused before the handler, and its row " <>
           "holds the placeholder and no fragment of it",
         %{ctx: ctx} do
      canary = "canary" <> Integer.to_string(System.unique_integer([:positive]))
      value = "ref-" <> canary <> " and more"

      assert {:error, %Prima.Refusal{class: :invalid_argument, stage: :admission} = refusal} =
               patterned(ctx, %{"reference" => value, "label" => "kept"})

      assert refusal.message =~ "Field 'reference' does not match the required pattern"
      refute inspect(refusal) =~ canary
      refute_received :ran

      assert [row] = patterned_rows(ctx)
      assert row.status == "error"
      assert row.refusal_class == "invalid_argument"

      assert decode_json(row.input) == %{
               "action" => "look",
               "reference" => "[REDACTED]",
               "label" => "kept"
             }

      assert [decision] = patterned_decisions(ctx)
      assert decision.admission == "refused"
      assert decision.refusal_class == "invalid_argument"

      for stored <- [row, decision],
          column <- Map.values(Map.from_struct(stored)),
          is_binary(column),
          do: refute(column =~ canary)
    end

    test "each argument is judged by its own declaration", %{ctx: ctx} do
      assert {:error, %Prima.Refusal{class: :invalid_argument}} =
               patterned(ctx, %{"reference" => "ref-42", "count" => "many", "label" => "kept"})

      refute_received :ran
      assert [row] = patterned_rows(ctx)

      assert decode_json(row.input) == %{
               "action" => "look",
               "reference" => "ref-42",
               "count" => "[REDACTED]",
               "label" => "kept"
             }
    end

    test "in a chain, a value failing its declared pattern is withheld from the refused row",
         %{ctx: ctx} do
      canary = "canary" <> Integer.to_string(System.unique_integer([:positive]))
      guest = Sanctum.Context.enter_guest(%{ctx | origin: :programmatic})

      assert {:error, %Prima.Refusal{class: :invalid_argument} = refusal} =
               Sanctum.Catalog.with_providers([__MODULE__.Patterned], fn ->
                 Sanctum.Gate.call_in_chain(
                   __MODULE__.Patterned.tool(),
                   guest,
                   %{"action" => "look", "reference" => canary, "label" => "kept"},
                   granting("patterned_probe.look"),
                   lineage: Cyfr.Test.AttemptFixtures.lineage!(guest)
                 )
               end)

      refute inspect(refusal) =~ canary
      refute_received :ran

      assert [row] = patterned_rows(ctx)
      assert row.status == "error"
      assert %{"reference" => "[REDACTED]", "label" => "kept"} = decode_json(row.input)
      assert [%{admission: "refused", plane: "in_chain"}] = patterned_decisions(ctx)
      refute row.input =~ canary
    end

    test "an admitted call's row holds the values its declarations admitted", %{ctx: ctx} do
      assert {:ok, %{"found" => true}} = patterned(ctx, %{"reference" => "ref-7", "count" => 2})
      assert_received :ran

      assert [row] = patterned_rows(ctx)
      assert decode_json(row.input) == %{"action" => "look", "reference" => "ref-7", "count" => 2}
    end
  end

  # The recording point sanitizes every text both rows store: a caller's
  # action name, a refusal's sentence quoting it, a failure's text.
  describe "the texts a decision and its row store" do
    setup do
      Process.register(self(), :request_log_patterned_observer)
      {:ok, key: Prima.CredentialShape.mint({:api_key, :service})}
    end

    test "an unknown action named with a credential leaves it in neither row, and the " <>
           "caller's refusal is its own",
         %{ctx: ctx, key: key} do
      assert {:error, %Prima.Refusal{} = refusal} =
               Sanctum.Catalog.with_providers([__MODULE__.Patterned], fn ->
                 Sanctum.Gate.call_external(__MODULE__.Patterned.tool(), ctx, %{
                   "action" => key
                 })
               end)

      assert refusal.message =~ key

      assert [row] = patterned_rows(ctx)
      assert row.action == "[REDACTED]"
      assert row.error =~ "[REDACTED]"
      assert [decision] = patterned_decisions(ctx)
      assert decision.action == row.action
      assert decision.reason == row.error

      for stored <- [row, decision],
          column <- Map.values(Map.from_struct(stored)),
          is_binary(column),
          do: refute(column =~ key)
    end

    test "a decision opened and closed with a credential in its texts stores none", %{
      ctx: ctx,
      key: key
    } do
      refused =
        decision(ctx,
          action: key,
          admission: :refused,
          refusal_class: :not_found,
          reason: "Unknown action: storage.#{key}"
        )

      :ok = Decisions.open(ctx, refused, %{input: %{"action" => key}})

      admitted = decision(ctx)
      :ok = Decisions.open(ctx, admitted, %{input: %{}})

      :ok =
        Decisions.close(ctx, admitted.call_id, %{
          result: {:error, {:internal, "upstream said #{key}"}},
          error_text: "upstream said #{key}"
        })

      for call_id <- [refused.call_id, admitted.call_id],
          stored <- [row(call_id), stored(call_id)],
          column <- Map.values(Map.from_struct(stored)),
          is_binary(column),
          do: refute(column =~ key)

      assert row(refused.call_id).action == "[REDACTED]"
      assert row(refused.call_id).error == "Unknown action: storage.[REDACTED]"
      assert stored(refused.call_id).reason == row(refused.call_id).error
      assert row(admitted.call_id).error == "upstream said [REDACTED]"
    end

    test "a method a caller named with a credential is stored redacted", %{ctx: ctx, key: key} do
      ctx = %{ctx | call_id: Decisions.call_id!(nil)}
      message = %Prima.MCP.Message{type: :request, id: 1, method: key, params: %{}}

      assert {:error, :method_not_found, _message} = Emissary.MCP.Router.dispatch(ctx, message)

      assert %Arca.Schemas.McpLog{status: "error", method: "[REDACTED]"} =
               stored_row = row(ctx.call_id)

      assert %Arca.Schemas.DecisionLog{} = stored(ctx.call_id)

      for column <- Map.values(Map.from_struct(stored_row)),
          is_binary(column),
          do: refute(column =~ key)
    end

    test "a completion's routing label is stored redacted", %{ctx: ctx, key: key} do
      admitted = decision(ctx)
      :ok = Decisions.open(ctx, admitted, %{input: %{}})

      :ok =
        Decisions.close(ctx, admitted.call_id, %{
          result: {:ok, %{}},
          routed_to: "external:" <> key <> ":lookup"
        })

      assert %Arca.Schemas.McpLog{status: "success", routed_to: "external:[REDACTED]:lookup"} =
               row(admitted.call_id)
    end

    test "every text column a row is built from carries no credential, whichever caller " <>
           "supplied it",
         %{ctx: ctx, key: key} do
      texts = fn columns -> for {_, value} <- columns, is_binary(value), do: value end

      refused =
        decision(ctx,
          tool: key,
          action: key,
          admission: :refused,
          refusal_class: :not_found,
          reason: "Unknown action: #{key}"
        )

      opened = Sanctum.RequestLog.opened(ctx, refused, %{method: key, input: %{"x" => key}})
      assert opened.method == "[REDACTED]"
      for text <- texts.(opened), do: refute(text =~ key)

      pending = Sanctum.RequestLog.opened(ctx, decision(ctx), %{method: key})
      assert pending.status == "pending"
      for text <- texts.(pending), do: refute(text =~ key)

      failed = Sanctum.RequestLog.closed({:error, "upstream said #{key}"}, %{routed_to: key})
      assert failed.error == "upstream said [REDACTED]"
      assert failed.routed_to == "[REDACTED]"

      succeeded =
        Sanctum.RequestLog.closed(
          {:ok, %{"content" => [%{"type" => "text", "text" => key}]}},
          %{routed_to: "external:#{key}:lookup", duration_ms: 3}
        )

      assert succeeded.duration_ms == 3
      for text <- texts.(succeeded), do: refute(text =~ key)

      string_columns =
        for field <- Arca.Schemas.McpLog.__schema__(:fields),
            Arca.Schemas.McpLog.__schema__(:type, field) == :string,
            do: field

      covered = Map.keys(opened) ++ Map.keys(failed) ++ Map.keys(succeeded)
      assert string_columns -- covered == [:athanor_id]
    end

    test "credentials run together in a refusal's reason reach neither the decision nor the row",
         %{ctx: ctx, key: key} do
      refused =
        decision(ctx,
          admission: :refused,
          refusal_class: :not_found,
          reason: "Unknown action: " <> key <> key
        )

      :ok = Decisions.open(ctx, refused, %{input: %{}})

      assert row(refused.call_id).error == stored(refused.call_id).reason
      assert row(refused.call_id).error == "Unknown action: [REDACTED][REDACTED]"
      refute stored(refused.call_id).reason =~ key
    end

    test "an MCP method holding credentials run together stores neither", %{ctx: ctx, key: key} do
      ctx = %{ctx | call_id: Decisions.call_id!(nil)}
      message = %Prima.MCP.Message{type: :request, id: 1, method: key <> key, params: %{}}

      assert {:error, :method_not_found, _message} = Emissary.MCP.Router.dispatch(ctx, message)

      assert %Arca.Schemas.McpLog{status: "error", method: "[REDACTED][REDACTED]"} =
               row(ctx.call_id)

      assert %Arca.Schemas.DecisionLog{} = stored(ctx.call_id)
    end

    test "a name cut to its column is sanitized whole first" do
      key = Prima.CredentialShape.mint(:webhook_secret)
      name = String.duplicate("a", 240) <> key

      refute Decisions.bounded(name) =~ binary_part(key, 0, 15)
      assert Decisions.bounded(name) == String.duplicate("a", 240) <> "[REDACTED]"
    end
  end

  # Each minter draws from `Prima.CredentialShape`, so what it issues is
  # what the request log recognises under any key.
  describe "the credentials the platform mints" do
    test "every API-key type, the webhook secret and the confirmation secret have their " <>
           "declared shape and reach no row",
         %{ctx: ctx} do
      issuer = Sanctum.TestContext.issuer!(ctx)

      api_keys =
        for {type, _prefix} <- Prima.CredentialShape.api_key_prefixes() do
          opts = %{name: "shape-#{type}", type: type, scope: []}

          confirmed =
            Sanctum.TestContext.confirmed(issuer, :credential_issuance, %{
              operation: "key.create",
              arguments: opts,
              resource: opts.name
            })

          {:ok, %{api_key: key}} = Sanctum.ApiKey.create(confirmed, opts)
          {{:api_key, type}, key}
        end

      assert {:error, {:confirmation_required, %{id: secret}}} =
               Sanctum.ApiKey.create(issuer, %{name: "unproven", scope: []})

      minted = [{:confirmation_secret, secret}, {:webhook_secret, webhook_secret!(issuer)}]

      for {kind, credential} <- api_keys ++ minted do
        assert Prima.CredentialShape.match?(kind, credential), inspect(kind)

        decision = decision(ctx)

        :ok =
          Decisions.open(ctx, decision, %{
            input: %{"action" => "get", "path" => "/notes/#{credential}.txt"}
          })

        assert decode_json(row(decision.call_id).input)["path"] == "/notes/[REDACTED].txt"
      end
    end

    defp webhook_secret!(ctx) do
      Sanctum.TestContext.ready!(ctx.athanor_id)
      component = "shape-target-#{System.unique_integer([:positive])}"
      Sanctum.Test.ComponentHelpers.register_test_component(component, "1.0.0", "formula", %{})
      target = "f:local.#{component}"
      profile = Sanctum.Test.ConsentFixtures.bindable_profile(ctx, target, origins: [:webhook])

      {:ok, %{secret: secret}} =
        Sanctum.TestContext.create_webhook(ctx, %{
          name: "shape-hook",
          target_ref: target,
          profile_id: profile,
          replay_protection: "none"
        })

      secret
    end
  end

  describe "sanitize_input/1" do
    test "redacts password variants" do
      input = %{
        "password" => "secret",
        "passwd" => "secret",
        "pwd" => "secret"
      }

      result = RequestLog.sanitize_input(input)

      assert result["password"] == "[REDACTED]"
      assert result["passwd"] == "[REDACTED]"
      assert result["pwd"] == "[REDACTED]"
    end

    test "redacts token variants" do
      input = %{
        "token" => "abc123",
        "access_token" => "xyz789",
        "refresh_token" => "refresh123",
        "bearer" => "bearer_token"
      }

      result = RequestLog.sanitize_input(input)

      assert result["token"] == "[REDACTED]"
      assert result["access_token"] == "[REDACTED]"
      assert result["refresh_token"] == "[REDACTED]"
      assert result["bearer"] == "[REDACTED]"
    end

    test "redacts API key variants" do
      input = %{
        "api_key" => "key123",
        "apikey" => "key456",
        "api-key" => "key789",
        "x-api-key" => "keyabc"
      }

      result = RequestLog.sanitize_input(input)

      assert result["api_key"] == "[REDACTED]"
      assert result["apikey"] == "[REDACTED]"
      assert result["api-key"] == "[REDACTED]"
      assert result["x-api-key"] == "[REDACTED]"
    end

    test "redacts secret variants" do
      input = %{
        "secret" => "shh",
        "secret_key" => "shhh",
        "private_key" => "very_private"
      }

      result = RequestLog.sanitize_input(input)

      assert result["secret"] == "[REDACTED]"
      assert result["secret_key"] == "[REDACTED]"
      assert result["private_key"] == "[REDACTED]"
    end

    test "handles nested maps" do
      input = %{
        "outer" => %{
          "password" => "nested_secret",
          "safe" => "visible"
        }
      }

      result = RequestLog.sanitize_input(input)

      assert result["outer"]["password"] == "[REDACTED]"
      assert result["outer"]["safe"] == "visible"
    end

    test "handles lists" do
      input = [
        %{"password" => "secret1"},
        %{"password" => "secret2", "name" => "test"}
      ]

      result = RequestLog.sanitize_input(input)

      assert Enum.at(result, 0)["password"] == "[REDACTED]"
      assert Enum.at(result, 1)["password"] == "[REDACTED]"
      assert Enum.at(result, 1)["name"] == "test"
    end

    test "handles atom keys" do
      input = %{
        password: "secret",
        api_key: "key123",
        safe: "visible"
      }

      result = RequestLog.sanitize_input(input)

      assert result[:password] == "[REDACTED]"
      assert result[:api_key] == "[REDACTED]"
      assert result[:safe] == "visible"
    end

    test "preserves non-sensitive data" do
      input = %{
        "name" => "test_component",
        "version" => "1.0.0",
        "count" => 42,
        "enabled" => true
      }

      result = RequestLog.sanitize_input(input)

      assert result == input
    end
  end
end
