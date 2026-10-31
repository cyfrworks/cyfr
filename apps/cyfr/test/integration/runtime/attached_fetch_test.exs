# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.AttachedFetchTest do
  @moduledoc """
  A guest's request naming a connection, end to end: the hostile
  `attached_header_probe` (`test_wasm/hostile/` of the runtime's suite) run by
  the runtime in a runner of its own, over the suite's wire
  (`Cyfr.Test.TwoServices`), through CYFR's host and a loopback upstream.
  The probe sends its input as its one request and answers what it got.

  The credential reaches the upstream, attached by CYFR, and nothing of it
  reaches the runner: for an athanor's own attach-only entry, for a value
  an app provides its dependency, and for a key another person shares
  with a group the person is in, bound to a component of the person's
  own. A redirect through a shared key is answered and never followed. A
  URL outside the entry's destination, or outside the grant's egress,
  reaches no upstream and counts no use. A credential the upstream
  reflects is masked across the answer's frames, in the guest's output
  and everywhere the execution leaves a trace. A `once` binding, an
  `until` binding past its instant and a revoked entry each refuse the
  next root before an upstream request.

  After a declared restore a share stands revoked and the run of the
  person it was shared with is refused before an upstream request, until
  its owner rotates the key, shares it again and the person grants it
  again; and a newcomer's first sign-in binds nothing until the
  platform administrator has shared their key with everyone again.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Prima.Test.Wait

  alias Cyfr.Test.{ChatFixture, TwoServices}
  alias Sanctum.Consent.{Commit, Plan}

  @moduletag timeout: 300_000

  @probe Path.expand(
           "../../../../locus/test/support/runtime/test_wasm/hostile/attached_header_probe.wasm",
           __DIR__
         )
  @nested Path.expand("support/test_wasm/nested_probe/nested_probe.wasm", __DIR__)

  @secret "sk-attached-e1-canary-7f3a9c21d0"
  @shared_secret "sk-shared-e1-canary-5a7e2b90d4"
  @rotated_secret "sk-shared-e1-rotated-3c81f6a2e9"
  @model_secret "sk-model-e1-canary-9d42b7c1a6"
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

    # A redirect to a path the shared key's destination admits: followed,
    # the key would reach it.
    defp answer(conn, "/redirect") do
      conn
      |> put_resp_header("location", "/landing")
      |> send_resp(302, "moved")
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
      Prima.Test.Slots.clear_unreaped(Opus.Slots, ctx.athanor_id)

      case previous do
        {:ok, value} -> Application.put_env(:arca, :base_path, value)
        :error -> Application.delete_env(:arca, :base_path)
      end

      File.rm_rf!(run_dir)
    end)

    Cyfr.Test.Sandbox.stop_work_on_exit()
    Sanctum.TestContext.ready!(ctx.athanor_id)
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
          "attach" => @rule,
          "hosts" => ["127.0.0.1"]
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

  # A person made as an open admission makes one, signed in under `name`
  # to their own athanor through Prism: `%{user: _, athanor: _, actor: _,
  # ctx: _}`.
  defp person!(name) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Test.People.linked(%{
        id: "github|https://github.com|attached-#{n}",
        provider: "github",
        email: "attached-#{n}@example.com",
        verified: true,
        name: name
      })

    athanor = Sanctum.Test.People.athanor!(user)

    ctx =
      Sanctum.Context.build(
        user_id: user.id,
        provider: "github",
        namespace: "attached-#{n}",
        athanor_id: athanor.id,
        permissions: Sanctum.Context.person_permissions(),
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )
      |> Sanctum.TestContext.via(:prism)

    %{user: user, athanor: athanor, actor: Sanctum.Context.actor(ctx), ctx: ctx}
  end

  # Terry's attach-only key of the probe's provider, to the upstream's
  # paths a shared key's requests use, shared with `group` under the
  # confirmation a share asks.
  defp shared!(terry, port, group) do
    {:ok, entry} =
      Sanctum.TestContext.create_vault(terry.ctx, %{
        name: "shared-#{System.unique_integer([:positive])}",
        kind: "api_key",
        provider_hint: "upstream.test",
        fields: %{"KEY" => @shared_secret},
        destination: %{
          "hosts" => ["127.0.0.1", "upstream.test"],
          "scheme" => "http",
          "port" => port,
          "methods" => ["GET", "POST"],
          "paths" => ["/hello", "/redirect", "/landing"]
        }
      })

    params = %{entry_id: entry.id, audience: "group", group_id: group.id}

    {:ok, share} =
      Sanctum.TestContext.confirming(terry.ctx, &Sanctum.Shares.create(&1, params))

    share
  end

  # Each person's count of a share's use today, as its owner reads it.
  defp share_used(owner, share) do
    {:ok, %{people: people}} = Arca.ShareUsage.usage(owner.actor, share.id, 1)
    Map.new(people, &{&1.user_id, &1.count})
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

  # A root of `ref` under its owner consent, run by the runtime, with
  # what its stream and the executions topic carried and the log.
  defp run!(ctx, ref, input) do
    id = Prima.UUID7.execution_id()
    :ok = Opus.subscribe_events(id, ctx)
    actor = Sanctum.Context.actor(ctx)
    :ok = Cyfr.Bus.subscribe(actor, Cyfr.Bus.executions(actor))

    {result, log} =
      with_log(fn ->
        Opus.run_root(ctx, :default, ref <> ":1.0.0", input, execution_id: id)
      end)

    TwoServices.settled!()
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

  test "a request through a grant of a shared key carries its owner's key to the source's " <>
         "host, a redirect is answered and never followed, and a request off the destination " <>
         "or the grant's egress is refused with nothing counted",
       %{port: port} do
    # Terry and Alice, each in their own athanor, are in the group Traders,
    # and Terry shares his key with it. Alice grants her own component the
    # share through the consent walk.
    terry = person!("Terry")
    alice = person!("Alice")
    traders = Arca.Test.Shares.group!([terry.user.id, alice.user.id])
    on_exit(fn -> Prima.Test.Slots.clear_unreaped(Opus.Slots, alice.athanor.id) end)
    Sanctum.TestContext.ready!(alice.athanor.id)

    share = shared!(terry, port, traders)
    probe = publish_probe!(alice.ctx)
    consent!(alice.ctx, probe, [%{need: "api_key", share_id: share.id}])

    played = run!(alice.ctx, probe, request(port, "/hello"))
    assert %{"status" => 200, "body" => "hello from upstream"} = output!(played)

    # CYFR attached Terry's key to the request Alice's component named,
    # which carried none, and the runner was handed nothing at its attach.
    sent = upstream!()
    assert sent.path == "/hello" and header(sent, "x-api-key") == [@shared_secret]
    assert [%{answer: %{"ok" => handed}}] = TwoServices.calls(:attach, played.id)
    assert handed == %{}
    assert_never_in_runner(played, @shared_secret)
    assert share_used(terry, share) == %{alice.user.id => 1}

    # A redirect is the guest's answer, and the request it names is never
    # made, with the key or without it: the target, inside the source's
    # destination, sees nothing.
    played = run!(alice.ctx, probe, request(port, "/redirect"))
    assert %{"status" => 302, "headers" => headers} = output!(played)
    assert headers["location"] == "/landing"
    sent = upstream!()
    assert sent.path == "/redirect" and header(sent, "x-api-key") == [@shared_secret]
    refute_receive {:upstream, _followed}, 500
    assert_never_in_runner(played, @shared_secret)
    assert share_used(terry, share) == %{alice.user.id => 2}

    # Off the source's destination, a path, a method or a port it does not
    # name, the request is refused before anything is counted or sent.
    for input <- [
          request(port, "/elsewhere"),
          request(port, "/hello", %{"method" => "DELETE"}),
          request(port + 1, "/hello")
        ] do
      played = run!(alice.ctx, probe, input)

      assert refused!(played, "destination_mismatch") ==
               Prima.Refusal.message(:destination_mismatch)
    end

    # Inside the source's destination, outside the grant's egress: refused
    # by the runner's own check, never sent and never counted.
    played =
      run!(
        alice.ctx,
        probe,
        request(port, "/hello", %{"url" => "http://upstream.test:#{port}/hello"})
      )

    assert refused!(played, "domain_blocked") =~ "upstream.test"

    refute_received {:upstream, _request}
    assert share_used(terry, share) == %{alice.user.id => 2}
  end

  # ---------------------------------------------------------------------------
  # A share across a declared restore
  # ---------------------------------------------------------------------------

  @model "catalyst:local.restore-model"
  @inference %{
    "hosts" => ["api.openai.com"],
    "scheme" => "https",
    "methods" => ["POST"],
    "paths" => ["/v1/"]
  }

  # A shipped catalyst a newcomer's athanor is filled with, whose one need
  # attaches an openai.com key: the need a first sign-in binds the
  # administrator's share to everyone for. The seed tree is the test's own.
  defp ship_model! do
    seed = Cyfr.Test.SeedBundle.isolate!()
    File.cp_r!(Path.expand("../../../../../seed/aqua", __DIR__), Path.join(seed, "aqua"))
    unit = Path.join([seed, "components", "catalysts", "local", "restore-model", "1.0.0"])
    File.mkdir_p!(unit)
    File.write!(Path.join(unit, "catalyst.wasm"), Cyfr.Test.Guests.wasm(:catalyst))

    File.write!(
      Path.join(unit, "cyfr-manifest.json"),
      Jason.encode!(%{
        "name" => "restore-model",
        "version" => "1.0.0",
        "type" => "catalyst",
        "needs" => %{
          "api_key" => %{
            "type" => "api_key:openai.com",
            "hosts" => ["api.openai.com"],
            "reason" => "to call the model",
            "fields" => ["OPENAI_API_KEY"],
            "attach" => %{
              "in" => "header",
              "name" => "Authorization",
              "template" => "Bearer {value}"
            }
          }
        },
        "caps" => %{"egress" => %{"domains" => ["api.openai.com"]}}
      })
    )
  end

  # A newcomer's first sign-in (`Sanctum.Provisioning.after_sign_in/1`):
  # their athanor filled and the model catalyst minted. Answers the
  # catalyst's head and its binding rows, as stored.
  defp first_sign_in!(name) do
    newcomer = person!(name)
    assert :ok = Sanctum.Provisioning.after_sign_in(newcomer.user.id)
    {:ok, [profile]} = Arca.ProfileStorage.list_for_source(newcomer.actor, @model)
    {:ok, head, refs} = Arca.ConsentStorage.get_head(newcomer.actor, profile.id)
    {newcomer, head, refs}
  end

  # The first sign-in's one binding row: the administrator's share in the
  # catalyst's default slot, standing, at the digest its entry derives.
  defp model_bound(newcomer, head, share, entry) do
    [
      %{
        consent_id: head.id,
        athanor_id: newcomer.athanor.id,
        binding_key: "#{@model}|@ingress|default",
        vault_entry_id: nil,
        share_id: share.id,
        via_label: nil,
        binding_digest: entry.binding_digest,
        lifetime_kind: "standing",
        expires_at: nil,
        consumed_by_root: nil
      }
    ]
  end

  # `person`'s call of the gate's tool `tool`, as a person at Prism makes it.
  defp gate!(person, tool, args) do
    {:ok, answer} = Sanctum.Gate.call_external(tool, person.ctx, args)
    answer
  end

  # `owner`'s shares, by id, each with its status, as the share tool lists them.
  defp share_statuses(owner) do
    owner
    |> gate!("share", %{"action" => "list"})
    |> Map.fetch!(:shares)
    |> Map.new(&{&1.id, &1.status})
  end

  # The shares offered to `person`, by id, as the share tool answers them.
  defp offered_ids(person) do
    person |> gate!("share", %{"action" => "offered"}) |> Map.fetch!(:shares) |> Enum.map(& &1.id)
  end

  # `owner` rotates `entry` to the material `fields`, under the
  # confirmation a rotation asks, through the vault tool.
  defp rotate!(owner, entry, fields) do
    %{entries: entries} = gate!(owner, "vault", %{"action" => "list"})
    %{payload_rev: rev} = Enum.find(entries, &(&1.id == entry.id))

    {:ok, _rotated} =
      Sanctum.TestContext.confirming(
        owner.ctx,
        &Sanctum.Gate.call_external("vault", &1, %{
          "action" => "rotate",
          "id" => entry.id,
          "fields" => fields,
          "expected_payload_rev" => rev
        })
      )

    :ok
  end

  # `owner` shares `entry` with `audience`, under the confirmation a share
  # asks, through the share tool. Answers the share's id.
  defp share_again!(owner, entry, audience) do
    {:ok, %{share: %{id: id}}} =
      Sanctum.TestContext.confirming(
        owner.ctx,
        &Sanctum.Gate.call_external(
          "share",
          &1,
          Map.merge(%{"action" => "create", "entry_id" => entry.id}, audience)
        )
      )

    id
  end

  # A run the restore left without a grant: refused at admission, since
  # the restore blocked the profile the grant is held by, before its guest
  # made any request; nothing reached the upstream, and nothing of either
  # key crossed into the runner.
  defp refused_before_request!(played) do
    assert played.result == {:error, {:profile_unavailable, :needs_consent}}
    assert TwoServices.calls(:attached_fetch, played.id) == []
    refute_received {:upstream, _request}
    assert_never_in_runner(played, @shared_secret)
    assert_never_in_runner(played, @rotated_secret)
  end

  test "after a declared restore a share is revoked and its run refused until the key is " <>
         "rotated, shared and granted again; a first sign-in binds nothing until it is shared",
       %{port: port} do
    ship_model!()

    # Terry, the platform administrator, shares his key to the upstream
    # with Traders, Alice's group and his, and his model key with
    # everyone. Alice grants her own component his share and runs it.
    terry = person!("Terry")
    {:ok, _seat} = Sanctum.TestContext.ensure_platform(terry.user.id)
    alice = person!("Alice")
    traders = Arca.Test.Shares.group!([terry.user.id, alice.user.id])
    on_exit(fn -> Prima.Test.Slots.clear_unreaped(Opus.Slots, alice.athanor.id) end)
    Sanctum.TestContext.ready!(alice.athanor.id)

    share = shared!(terry, port, traders)
    {:ok, entry} = Arca.VaultStorage.get(terry.actor, share.entry_id)

    {:ok, model} =
      Sanctum.TestContext.create_vault(terry.ctx, %{
        name: "model-#{System.unique_integer([:positive])}",
        kind: "api_key",
        provider_hint: "openai.com",
        fields: %{"OPENAI_API_KEY" => @model_secret},
        destination: @inference
      })

    {:ok, model} = Arca.VaultStorage.get(terry.actor, model.id)
    model_share = share_again!(terry, model, %{"audience" => "everyone"})

    probe = publish_probe!(alice.ctx)
    consent!(alice.ctx, probe, [%{need: "api_key", share_id: share.id}])

    played = run!(alice.ctx, probe, request(port, "/hello"))
    assert %{"status" => 200} = output!(played)
    sent = upstream!()
    assert sent.path == "/hello" and header(sent, "x-api-key") == [@shared_secret]
    assert share_used(terry, share) == %{alice.user.id => 1}

    # Before the restore a newcomer's first sign-in binds the
    # administrator's share to everyone.
    {pia, head, refs} = first_sign_in!("Pia")
    assert refs == model_bound(pia, head, %{id: model_share}, model)

    # The restore is declared as `cyfr restore` declares it, and the boot's
    # step before the gate applies it.
    assert is_binary(Cyfr.Release.mark_restore())
    assert :ignore = Cyfr.Application.declared_restore()

    # Both shares read revoked to their owner, nothing is offered to Alice,
    # and her run is refused before its guest makes a request: no key is
    # attached, counted or sent.
    assert share_statuses(terry) == %{share.id => "revoked", model_share => "revoked"}
    assert offered_ids(alice) == []
    refused_before_request!(run!(alice.ctx, probe, request(port, "/hello")))
    assert share_used(terry, share) == %{alice.user.id => 1}

    # A first sign-in binds nothing: the administrator's share is revoked.
    {_nia, _head, refs} = first_sign_in!("Nia")
    assert refs == []

    # Terry recovers his passkey, as a recovery re-enables it, and rotates
    # both keys. A rotation revives neither share nor Alice's grant: the
    # shares stay revoked, her run is refused, a first sign-in still binds
    # nothing, and the revoked share cannot be granted again.
    passkey = Arca.Repo.get_by!(Arca.Schemas.Passkey, user_id: terry.user.id)

    {:ok, _reenabled} =
      Arca.Passkeys.reenable(Prima.Actor.system(), terry.user.id, passkey.id,
        verify: fn _passkey -> :ok end
      )

    :ok = rotate!(terry, entry, %{"KEY" => @rotated_secret})
    :ok = rotate!(terry, model, %{"OPENAI_API_KEY" => @model_secret <> "-rotated"})

    assert share_statuses(terry) == %{share.id => "revoked", model_share => "revoked"}
    assert offered_ids(alice) == []
    refused_before_request!(run!(alice.ctx, probe, request(port, "/hello")))
    {_ned, _head, refs} = first_sign_in!("Ned")
    assert refs == []

    assert Commit.preview(alice.ctx, %{
             ref: probe,
             bindings: [%{need: "api_key", share_id: share.id}]
           }) == {:error, {:share_not_offered, "api_key"}}

    # Terry shares the key with Traders again: a new share, offered to
    # Alice. Her grant still names the one the restore revoked, so her run
    # is refused until she grants the new one.
    again = share_again!(terry, entry, %{"audience" => "group", "group_id" => traders.id})
    refute again == share.id

    assert share_statuses(terry) == %{
             share.id => "revoked",
             model_share => "revoked",
             again => "active"
           }

    assert offered_ids(alice) == [again]
    refused_before_request!(run!(alice.ctx, probe, request(port, "/hello")))

    # Alice grants again, and her run carries the rotated key to the
    # source's host, counted on the new share alone.
    consent!(alice.ctx, probe, [%{need: "api_key", share_id: again}])
    played = run!(alice.ctx, probe, request(port, "/hello"))
    assert %{"status" => 200, "body" => "hello from upstream"} = output!(played)
    sent = upstream!()
    assert sent.path == "/hello" and header(sent, "x-api-key") == [@rotated_secret]
    assert_never_in_runner(played, @rotated_secret)
    assert share_used(terry, %{id: again}) == %{alice.user.id => 1}
    assert share_used(terry, share) == %{alice.user.id => 1}

    # Until the administrator shares the model key with everyone again a
    # first sign-in binds nothing; once shared, the next binds the new share.
    {_ida, _head, refs} = first_sign_in!("Ida")
    assert refs == []
    model_again = share_again!(terry, model, %{"audience" => "everyone"})
    {noa, head, refs} = first_sign_in!("Noa")
    {:ok, model} = Arca.VaultStorage.get(terry.actor, model.id)
    assert refs == model_bound(noa, head, %{id: model_again}, model)
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
