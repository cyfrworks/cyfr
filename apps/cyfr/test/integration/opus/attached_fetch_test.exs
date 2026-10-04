# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.AttachedFetchTest do
  @moduledoc """
  A guest's request naming a connection, end to end: the hostile
  `attached_header_probe` (`test_wasm/hostile/` of Opus's suite) run by
  the Opus service in a runner of its own, over the suite's wire
  (`Cyfr.Test.TwoServices`), through CYFR's host and a loopback upstream.
  The probe sends its input as its one request and answers what it got.

  The credential reaches the upstream, attached by CYFR, and nothing of it
  reaches the runner: for an athanor's own attach-only entry, for a value
  an app provides its dependency, and for an instance entry offered to
  everyone, bound to a component of the person's own while the entry's
  component policy is `any`. A URL outside the entry's destination, or
  outside the grant's egress, reaches no upstream; tightening the entry to
  `shipped` refuses the next root before any claim or upstream contact. A
  credential the upstream reflects is masked across the answer's frames,
  in the guest's output and everywhere the execution leaves a trace. A
  `once` binding, an `until` binding past its instant and a revoked entry
  each refuse the next root before an upstream request.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Prima.Test.Wait

  alias Cyfr.Test.{ChatFixture, TwoServices}
  alias Sanctum.Consent.{Commit, Plan}

  @moduletag timeout: 300_000

  @probe Path.expand(
           "../../../../opus/test/support/test_wasm/hostile/attached_header_probe.wasm",
           __DIR__
         )
  @nested Path.expand("support/test_wasm/nested_probe/nested_probe.wasm", __DIR__)

  @secret "sk-attached-e1-canary-7f3a9c21d0"
  @instance_secret "sk-instance-e1-canary-2c8d5e14"
  @rule %{"in" => "header", "name" => "x-api-key", "template" => "{value}"}

  defmodule Upstream do
    @moduledoc """
    The loopback upstream: every request is told to the test, and the path
    names the answer.
    """
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, %{parent: parent}) do
      {:ok, body, conn} = read_body(conn)

      send(parent, {
        :upstream,
        %{method: conn.method, path: conn.request_path, headers: conn.req_headers, body: body}
      })

      answer(conn, conn.request_path)
    end

    # The credential reflected in a header and in a body longer than one
    # frame, split across two writes so no one piece holds it whole.
    defp answer(conn, "/echo") do
      key = conn |> get_req_header("x-api-key") |> List.first("")
      half = div(byte_size(key), 2)
      <<first::binary-size(^half), second::binary>> = key
      conn = conn |> put_resp_header("x-echo", key) |> send_chunked(200)
      {:ok, conn} = chunk(conn, String.duplicate("a", 40_000) <> " key: " <> first)
      Process.sleep(100)
      {:ok, conn} = chunk(conn, second <> " tail")
      conn
    end

    defp answer(conn, _path), do: send_resp(conn, 200, "hello from upstream")
  end

  setup tags do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!(tags)
    TwoServices.watch!()

    run_dir = Path.join(System.tmp_dir!(), "attached_e1_#{System.unique_integer([:positive])}")
    previous = Application.fetch_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, run_dir)

    upstream =
      start_supervised!(
        {Bandit,
         plug: {Upstream, %{parent: self()}},
         scheme: :http,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(upstream)
    {ctx, _user} = Sanctum.TestContext.person!(Sanctum.TestContext.local(:prism))

    on_exit(fn ->
      Prima.Slots.forgive_unreaped(Crucible.Slots, ctx.athanor_id)

      case previous do
        {:ok, value} -> Application.put_env(:arca, :base_path, value)
        :error -> Application.delete_env(:arca, :base_path)
      end

      File.rm_rf!(run_dir)
    end)

    Cyfr.Test.Sandbox.stop_work_on_exit()
    {:ok, ctx: ctx, port: port}
  end

  # ---------------------------------------------------------------------------
  # Seeding
  # ---------------------------------------------------------------------------

  # The egress the probe asks for and its consent grants: the loopback
  # upstream by address, its private address, and the methods below.
  defp egress do
    %{
      "domains" => ["127.0.0.1"],
      "methods" => ["GET", "POST", "DELETE"],
      "schemes" => ["http"],
      "private_ips" => ["127.0.0.1"]
    }
  end

  # The probe, published as a component of the person's own whose need
  # `api_key` is attached by the rule.
  defp publish_probe!(ctx) do
    name = "attached-probe-#{System.unique_integer([:positive])}"

    manifest = %{
      "name" => name,
      "version" => "1.0.0",
      "type" => "catalyst",
      "needs" => %{
        "api_key" => %{
          "type" => "api_key:upstream.test",
          "reason" => "to call the upstream with your key",
          "fields" => ["KEY"],
          "attach" => @rule
        }
      },
      "caps" => %{"egress" => egress()}
    }

    {:ok, _component} =
      Compendium.Registry.publish_bytes(ctx, File.read!(@probe), %{
        name: name,
        version: "1.0.0",
        type: "catalyst",
        manifest: Jason.encode!(manifest)
      })

    "catalyst:local." <> name
  end

  # An app of the person's own whose formula runs the probe as its child,
  # providing the probe's need with a public `value` to the upstream:
  # `nested_probe`'s bytes under the app's own reference.
  defp publish_app!(ctx, probe, port, value) do
    name = "attached-app-#{System.unique_integer([:positive])}"

    manifest = %{
      "name" => name,
      "version" => "1.0.0",
      "type" => "formula",
      "caps" => %{"tools" => ["execution.run"]},
      "dependencies" => %{"static" => [%{"ref" => probe}]},
      "provides" => %{
        probe => %{
          "api_key" => %{
            "destination" => %{
              "hosts" => ["127.0.0.1"],
              "scheme" => "http",
              "port" => port,
              "methods" => ["GET", "POST"]
            },
            "values" => %{"KEY" => value}
          }
        }
      }
    }

    {:ok, _component} =
      Compendium.Registry.publish_bytes(ctx, File.read!(@nested), %{
        name: name,
        version: "1.0.0",
        type: "formula",
        manifest: Jason.encode!(manifest)
      })

    "formula:local." <> name
  end

  # An attach-only entry of the probe's provider, to the upstream.
  defp entry!(ctx, port, over \\ %{}) do
    {:ok, entry} =
      Sanctum.TestContext.create_vault(
        ctx,
        Map.merge(
          %{
            name: "attached-#{System.unique_integer([:positive])}",
            kind: "api_key",
            provider_hint: "upstream.test",
            fields: %{"KEY" => @secret},
            destination: %{
              "hosts" => ["127.0.0.1", "upstream.test"],
              "scheme" => "http",
              "port" => port,
              "methods" => ["GET", "POST"]
            }
          },
          over
        )
      )

    entry
  end

  # An instance entry a platform administrator offers everyone, under the
  # `any` component policy it is created with, to the upstream's two paths.
  defp instance!(ctx, port) do
    admin = %{ctx | platform_admin: true}

    params = %{
      name: "shared-#{System.unique_integer([:positive])}",
      kind: "api_key",
      provider_hint: "upstream.test",
      fields: %{"KEY" => @instance_secret},
      destination: %{
        "hosts" => ["127.0.0.1", "upstream.test"],
        "scheme" => "http",
        "port" => port,
        "methods" => ["GET", "POST"],
        "paths" => ["/hello", "/echo"]
      },
      audience: "everyone"
    }

    confirmed =
      Sanctum.TestContext.confirmed(admin, :credential_entry, %{
        operation: "instance_entry.create",
        arguments: params,
        resource: params.name
      })

    {:ok, entry} = Sanctum.InstanceEntries.create(confirmed, params)
    entry
  end

  # The requests claimed against an instance entry's caps today.
  defp usage(entry_id) do
    {:ok, %{totals: totals}} = Arca.InstanceEntryUsage.usage(Prima.Actor.system(), entry_id, 1)
    Enum.sum(Enum.map(totals, & &1.count))
  end

  # `ref`'s owner consent, binding `bindings`, through the consent walk.
  defp consent!(ctx, ref, bindings, over \\ %{}) do
    {:ok, plan} = Plan.plan(ctx, %{ref: ref})
    decisions = Map.merge(%{ref: ref, bindings: bindings}, over)
    {:ok, preview} = Commit.preview(ctx, decisions)

    {:ok, %{profile_id: profile_id}} =
      Commit.commit(ctx, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })

    profile_id
  end

  defp request(port, path, over \\ %{}) do
    Map.merge(
      %{
        "connection" => "api_key",
        "method" => "GET",
        "url" => "http://127.0.0.1:#{port}#{path}",
        "headers" => %{"accept" => "text/plain"}
      },
      over
    )
  end

  # A root of `ref` under its owner consent, run by the Opus service, with
  # what its stream and the executions topic carried and the log.
  defp run!(ctx, ref, input) do
    id = Prima.UUID7.execution_id()
    :ok = Crucible.subscribe_events(id, ctx)
    actor = Sanctum.Context.actor(ctx)
    :ok = Cyfr.Bus.subscribe(actor, Cyfr.Bus.executions(actor))

    {result, log} =
      with_log(fn ->
        Crucible.run_root(ctx, :default, ref <> ":1.0.0", input, execution_id: id)
      end)

    %{result: result, id: id, bus: drain(), log: log}
  end

  # What the execution's stream and the executions topic carried: every
  # message but the upstream's, which stay for the test to read.
  defp drain do
    receive do
      message when not is_tuple(message) or elem(message, 0) != :upstream ->
        [message | drain()]
    after
      200 -> []
    end
  end

  defp output!(%{result: {:ok, %{output: output}}}), do: output

  # The guest's answer as its runner closed the attempt with it: a request
  # refused is the guest's error, which closes the run failed with the
  # refusal's sentence.
  defp answer!(played) do
    assert [%{args: %{"outcome" => %{"output" => output}}}] =
             TwoServices.calls(:complete, played.id)

    output
  end

  defp refused!(played, type) do
    assert %{"error" => %{"type" => ^type, "message" => message}} = answer!(played)
    assert played.result == {:error, message}
    message
  end

  # What the app's formula was answered for its child: the child's close.
  defp child_output!(played) do
    %{"op" => "call", "result_raw" => raw} = output!(played)
    Jason.decode!(raw)
  end

  defp upstream! do
    receive do
      {:upstream, request} -> request
    after
      5_000 -> flunk("the upstream received nothing")
    end
  end

  defp header(request, name), do: for({^name, value} <- request.headers, do: value)

  # Nothing of `secret` crossed the suite's wire to or from a runner, nor
  # shows in the run's output, events or log, nor anywhere CYFR stores.
  defp assert_never_in_runner(played, secret) do
    assert ChatFixture.leaks(secret,
             wire: TwoServices.calls(),
             result: played.result,
             bus: played.bus,
             log: played.log
           ) == []
  end

  # ---------------------------------------------------------------------------
  # E1
  # ---------------------------------------------------------------------------

  test "own and provided connections reach the pinned upstream without entering the runner", %{
    ctx: ctx,
    port: port
  } do
    probe = publish_probe!(ctx)
    entry = entry!(ctx, port)
    consent!(ctx, probe, [%{need: "api_key", entry_id: entry.id}])

    played = run!(ctx, probe, request(port, "/hello"))
    assert %{"status" => 200, "body" => "hello from upstream"} = output!(played)

    # CYFR attached the key to the request the guest named, which carried
    # none; the runner was handed nothing at its attach.
    sent = upstream!()
    assert sent.path == "/hello" and header(sent, "x-api-key") == [@secret]
    assert [%{answer: %{"ok" => handed}}] = TwoServices.calls(:attach, played.id)
    assert handed == %{}

    assert [%{args: %{"connection" => "api_key", "headers" => headers}, answer: nil}] =
             TwoServices.calls(:attached_fetch, played.id)

    refute Enum.any?(headers, fn [name, _value] -> String.downcase(name) == "x-api-key" end)
    assert_never_in_runner(played, @secret)

    # A value the app provides its dependency is attached the same way: the
    # probe runs as the app's child, on the edge the app provides.
    provided = "pk-provided-public-4b2e"
    app = publish_app!(ctx, probe, port, provided)
    consent!(ctx, app, [])

    played =
      run!(ctx, app, %{
        "op" => "call",
        "request" => %{
          "tool" => "execution",
          "action" => "run",
          "args" => %{"reference" => probe <> ":1.0.0", "input" => request(port, "/hello")}
        }
      })

    assert %{"output" => %{"status" => 200, "body" => "hello from upstream"}} =
             child_output!(played)

    sent = upstream!()
    assert sent.path == "/hello" and header(sent, "x-api-key") == [provided]

    assert %{fields: %{execution_id: child}, args: %{"headers" => headers}} =
             TwoServices.calls() |> Enum.filter(&(&1.callback == :attached_fetch)) |> List.last()

    assert child != played.id
    refute Enum.any?(headers, fn [name, _value] -> String.downcase(name) == "x-api-key" end)
  end

  test "destination and egress refusals contact no upstream", %{ctx: ctx, port: port} do
    probe = publish_probe!(ctx)
    entry = entry!(ctx, port)
    consent!(ctx, probe, [%{need: "api_key", entry_id: entry.id}])

    # Inside the grant's egress, outside the entry's destination: another
    # port, and a method the destination does not name.
    for input <- [request(port + 1, "/hello"), request(port, "/hello", %{"method" => "DELETE"})] do
      played = run!(ctx, probe, input)

      assert refused!(played, "destination_mismatch") ==
               Prima.Refusal.message(:destination_mismatch)
    end

    # Inside the destination, outside the grant's egress: refused by the
    # runner's own check and recorded, never sent.
    played =
      run!(ctx, probe, request(port, "/hello", %{"url" => "http://upstream.test:#{port}/hello"}))

    assert refused!(played, "domain_blocked") =~ "upstream.test"
    assert TwoServices.calls(:attached_fetch, played.id) == []
    assert [%{args: %{"type" => "domain_blocked"}}] = TwoServices.calls(:record_denial, played.id)

    # A credential header beside the connection is refused by shape.
    played =
      run!(
        ctx,
        probe,
        request(port, "/hello", %{"headers" => %{"Authorization" => "Bearer guest"}})
      )

    assert refused!(played, "credential_header_refused") ==
             Prima.Refusal.message(:credential_header_refused)

    assert TwoServices.calls(:attached_fetch, played.id) == []

    refute_received {:upstream, _request}
  end

  test "any admits a consented custom component only within its destination and egress", %{
    ctx: ctx,
    port: port
  } do
    entry = instance!(ctx, port)
    probe = publish_probe!(ctx)
    consent!(ctx, probe, [%{need: "api_key", instance_entry_id: entry.id}])

    assert %{"status" => 200, "body" => "hello from upstream"} =
             output!(run!(ctx, probe, request(port, "/hello")))

    assert header(upstream!(), "x-api-key") == [@instance_secret]
    assert usage(entry.id) == 1

    # A method or path outside the entry's destination, or a host outside
    # the grant's egress, is refused before the cap is claimed.
    for {input, type} <- [
          {request(port, "/hello", %{"method" => "DELETE"}), "destination_mismatch"},
          {request(port, "/elsewhere"), "destination_mismatch"},
          {request(port, "/hello", %{"url" => "http://upstream.test:#{port}/hello"}),
           "domain_blocked"}
        ] do
      assert refused!(run!(ctx, probe, input), type)
    end

    refute_received {:upstream, _request}
    assert usage(entry.id) == 1
  end

  test "tightening to shipped refuses the next custom component request before claim or upstream contact",
       %{ctx: ctx, port: port} do
    entry = instance!(ctx, port)
    probe = publish_probe!(ctx)
    consent!(ctx, probe, [%{need: "api_key", instance_entry_id: entry.id}])

    assert %{"status" => 200} = output!(run!(ctx, probe, request(port, "/hello")))
    assert header(upstream!(), "x-api-key") == [@instance_secret]
    assert usage(entry.id) == 1

    :ok =
      Arca.InstanceEntries.set_component_policy(Prima.Actor.system(), entry.id, "any", "shipped")

    played = run!(ctx, probe, request(port, "/hello"))

    assert refused!(played, "component_not_admitted") ==
             Prima.Refusal.message(:component_not_admitted)

    refute_received {:upstream, _request}
    assert usage(entry.id) == 1
  end

  # ---------------------------------------------------------------------------
  # E2
  # ---------------------------------------------------------------------------

  test "reflected credentials are masked across frames and execution exits", %{
    ctx: ctx,
    port: port
  } do
    probe = publish_probe!(ctx)
    entry = entry!(ctx, port)
    consent!(ctx, probe, [%{need: "api_key", entry_id: entry.id}])

    played = run!(ctx, probe, request(port, "/echo"))
    sent = upstream!()

    # The upstream reflected the key in a header and across two writes of
    # a body longer than one frame; the guest read neither.
    assert %{"status" => 200, "headers" => headers, "body" => body} = output!(played)
    assert Map.has_key?(headers, "x-echo") and not String.contains?(headers["x-echo"], @secret)
    assert String.starts_with?(body, String.duplicate("a", 40_000) <> " key: ")
    assert String.ends_with?(body, " tail")
    refute String.contains?(body, @secret)
    assert_never_in_runner(played, @secret)

    # The scan finds the key where it is: the upstream was sent it.
    assert {:term, :upstream} in ChatFixture.leaks(@secret, upstream: sent)
  end

  # ---------------------------------------------------------------------------
  # E7
  # ---------------------------------------------------------------------------

  test "once expiry and revocation refuse subsequent roots before an upstream request", %{
    ctx: ctx,
    port: port
  } do
    # A once binding is spent by the first root that uses it.
    probe = publish_probe!(ctx)
    entry = entry!(ctx, port)
    consent!(ctx, probe, [%{need: "api_key", entry_id: entry.id, lifetime: %{kind: "once"}}])

    assert %{"status" => 200} = output!(run!(ctx, probe, request(port, "/once")))
    assert upstream!().path == "/once"

    assert refused!(run!(ctx, probe, request(port, "/once-again")), "grant_expired") ==
             Prima.Refusal.message(:grant_expired)

    refute_received {:upstream, _request}

    # An until binding is refused once its instant passes.
    until = DateTime.utc_now() |> DateTime.add(5, :second) |> DateTime.truncate(:second)
    probe = publish_probe!(ctx)
    entry = entry!(ctx, port)

    consent!(ctx, probe, [
      %{
        need: "api_key",
        entry_id: entry.id,
        lifetime: %{kind: "until", until: DateTime.to_iso8601(until)}
      }
    ])

    assert %{"status" => 200} = output!(run!(ctx, probe, request(port, "/before")))
    assert upstream!().path == "/before"

    wait_until(
      fn -> DateTime.compare(DateTime.utc_now(), until) == :gt end,
      10_000,
      "the binding's instant to pass"
    )

    assert refused!(run!(ctx, probe, request(port, "/after")), "grant_expired") ==
             Prima.Refusal.message(:grant_expired)

    refute_received {:upstream, _request}

    # A revoked entry dispenses nothing, attached or not.
    probe = publish_probe!(ctx)
    entry = entry!(ctx, port)
    consent!(ctx, probe, [%{need: "api_key", entry_id: entry.id}])

    assert %{"status" => 200} = output!(run!(ctx, probe, request(port, "/standing")))
    assert upstream!().path == "/standing"
    {:ok, _affected} = Sanctum.Vault.revoke(ctx, entry.id)

    # The next root is refused at its attach, before its guest runs.
    played = run!(ctx, probe, request(port, "/revoked"))

    assert {:error, {:setup_required, %{reason: "vault_entry_revoked"}}} = played.result
    assert TwoServices.calls(:attached_fetch, played.id) == []
    refute_received {:upstream, _request}
  end
end
