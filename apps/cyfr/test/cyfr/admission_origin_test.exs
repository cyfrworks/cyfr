# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.AdmissionOriginTest.Probe do
  @moduledoc false
  # Answers the origin of the context the gate handed its handler, on both
  # planes. Its `origin` argument is one a caller may send; nothing reads it.
  @behaviour Prima.Provider

  alias Prima.{Arg, Operation}

  @tool "origin_probe"

  def tool, do: @tool

  @impl true
  def service, do: "probe"

  @impl true
  def tools do
    [
      Operation.tool([
        Operation.new(@tool, "peek", "Answer the handler's origin", [Arg.new("origin", :string)],
          kind: :read,
          planes: [:external, :in_chain]
        )
      ])
    ]
  end

  @impl true
  def handle(@tool, ctx, %{"action" => "peek"}),
    do: {:ok, %{"origin" => ctx.origin && Atom.to_string(ctx.origin)}}
end

defmodule Cyfr.AdmissionOriginTest do
  @moduledoc """
  Every admission entry `Cyfr.Boundaries.admission_entries/0` gives an
  origin builds a context carrying it. Each such row is driven through its
  entry — whatever the request, the context it arrived with or an argument
  names — and the context the entry hands on carries the row's origin; an
  in-chain entry (`:inherits`) carries the origin its root's row records.
  A row with an origin and no driver, or a driver whose row names none,
  fails the inventory.

  Beside the rows: the console's context, which decides no request itself
  and so is no row, is `interactive`; a root's row records its context's
  origin and a child's its parent's, so a child of a scheduled root is
  `schedule` and never `interactive`; a frame's run is rooted under the
  frame path's origin; a webhook replayed carries the same origin under
  the idempotency it already has; and a hidden frame its background grant
  keeps live is admitted on the frame path like a shown one.
  """

  use PrismWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Prima.Test.Wait

  alias Cyfr.AdmissionOriginTest.Probe
  alias Cyfr.Boundaries
  alias Cyfr.Test.{AttemptFixtures, ScriptedWorker}
  alias Emissary.Web.DeviceChannel
  alias Prima.Authority
  alias Prima.Authority.Blob
  alias Prima.Test.AuthorityFixtures, as: Graph
  alias Prima.TinctureWire
  alias Sanctum.TinctureAuth

  @math_wasm_path Path.expand("../support/test_wasm/math.wasm", __DIR__)
  # The node an in-chain call's authority is rooted at.
  @node "catalyst:local.origin-probe"
  @formula "formula:local.origin-formula"
  @target "reagent:local.origin-target"
  @dep "reagent:local.origin-dep"
  @dep_ref "reagent:local.origin-dep:0.1.0"
  # `Sanctum.TestContext.athanor!/0`'s group slug: a public tincture's address.
  @address "test"

  # The rows this test holds: every built entry that names an origin.
  @rows for row <- Boundaries.admission_entries(),
            row.origin != :none,
            not Map.get(row, :pending, false),
            do: row

  @drivers %{
    {Grimoire, :call_in_chain} => :gate_in_chain,
    {Emissary.MCP.Router, :dispatch} => :mcp_router,
    {CyfrWeb.Plugs.Authenticate, :call} => :http_api,
    {Emissary.Web.TinctureDataController, :invoke} => :frame_invoke,
    {Emissary.Web.TinctureDataController, :system_action} => :frame_action,
    {Emissary.Web.TinctureDataController, :stream} => :frame_stream,
    {Emissary.Web.WebhookController, :invoke} => :webhook_delivery,
    {Crucible.Schedules.Scheduler, :handle_info} => :schedule_fire,
    {Crucible.Host.Children, :call} => :host_tool_call,
    {Emissary.Web.DeviceChannel, :handle_in} => :device_channel
  }

  setup do
    Arca.Cache.init()
    Prima.RateLimiter.reset()
    _athanor = Sanctum.TestContext.athanor!()

    base = Path.join(System.tmp_dir!(), "admission_origin_#{System.unique_integer([:positive])}")
    keys = [cyfr: :opus_workers, cyfr: :cron_scheduler_enabled, arca: :base_path]
    prev = Map.new(keys, fn {app, key} -> {{app, key}, Application.get_env(app, key)} end)
    Application.put_env(:arca, :base_path, base)

    on_exit(fn ->
      Prima.Slots.forgive_unreaped(Crucible.Slots, Sanctum.TestContext.local().athanor_id)
      Prima.RateLimiter.reset()
      File.rm_rf!(base)

      for {{app, key}, value} <- prev do
        if is_nil(value),
          do: Application.delete_env(app, key),
          else: Application.put_env(app, key, value)
      end
    end)

    :ok
  end

  # ==========================================================================
  # The roster
  # ==========================================================================

  test "every built entry that names an origin has one driver, and every driver such a row" do
    assert Enum.sort(Enum.map(@rows, &{&1.module, &1.site})) == Enum.sort(Map.keys(@drivers))
  end

  for %{module: module, site: site, origin: origin} <- @rows do
    label = if origin == :inherits, do: "its root's origin", else: "the origin #{origin}"

    @tag entry: {module, site}, origin: origin
    test "#{inspect(module)}.#{site} builds a context carrying #{label}",
         %{conn: conn, entry: entry, origin: origin} do
      driver = Map.fetch!(@drivers, entry)

      case apply(__MODULE__, driver, [conn]) do
        {:inherits, root, seen} ->
          assert origin == :inherits
          # The root was admitted on the scheduler's path, so a context
          # that fell back to the console's origin would show.
          assert root == :schedule
          assert seen != []
          assert Enum.all?(seen, &(&1 == root)), "#{inspect(entry)} carried #{inspect(seen)}"

        seen when is_list(seen) ->
          assert origin in Prima.Origin.values()
          assert seen != []
          assert Enum.all?(seen, &(&1 == origin)), "#{inspect(entry)} built #{inspect(seen)}"
      end
    end
  end

  # ==========================================================================
  # Drivers. Each answers the origins of the contexts its entry built, or
  # `{:inherits, root, seen}` for an in-chain entry. Wherever a request
  # can say something, it names another origin; the entry decides.
  # ==========================================================================

  def gate_in_chain(_conn) do
    ctx = scheduled()
    lineage = AttemptFixtures.lineage!(ctx)

    {:ok, %{"origin" => seen}} =
      with_probe(fn ->
        Grimoire.call_in_chain(
          Probe.tool(),
          Sanctum.Context.enter_guest(ctx),
          %{"action" => "peek", "origin" => "interactive"},
          granting(),
          lineage: lineage
        )
      end)

    {:inherits, row_origin(lineage.root_execution_id), [origin(seen)]}
  end

  def host_tool_call(_conn) do
    fixture =
      AttemptFixtures.attached!(
        ctx: scheduled(),
        authority: granting(),
        component_ref: "#{@node}:0.1.0"
      )

    answer =
      with_probe(fn ->
        AttemptFixtures.call(fixture, "tool_call", %{
          "name" => Probe.tool(),
          "args" => %{"action" => "peek", "origin" => "interactive"},
          "guest_fn" => "call",
          "origin" => "interactive"
        })
      end)

    assert %{"ok" => %{"origin" => seen}} = answer
    {:inherits, row_origin(fixture.execution_id), [origin(seen)]}
  end

  def mcp_router(_conn) do
    # The context arrives claiming the console's origin.
    ctx = %{
      Sanctum.TestContext.local()
      | origin: :interactive,
        call_id: Prima.UUID7.generate_id("call")
    }

    message = %Prima.MCP.Message{
      type: :request,
      id: 1,
      method: "tools/call",
      params: %{
        "name" => Probe.tool(),
        "arguments" => %{"action" => "peek", "origin" => "interactive"}
      }
    }

    assert {:ok, %{"content" => [%{"text" => text}], "isError" => false}} =
             with_probe(fn -> Emissary.MCP.Router.dispatch(ctx, message) end)

    [origin(Jason.decode!(text)["origin"])]
  end

  def http_api(_conn) do
    n = System.unique_integer([:positive])

    {ctx, user} =
      Sanctum.TestContext.person!(Sanctum.TestContext.local(), %{
        email: "origin#{n}@example.com"
      })

    # The key's context names its person's namespace, as a signed-in
    # person's does.
    {:ok, _} = Sanctum.Tenancy.Users.set_namespace(user, ctx.namespace)

    {:ok, key} =
      Sanctum.TestContext.create_key(ctx, %{
        name: "origin-#{n}",
        type: :application,
        scope: ["execute"]
      })

    {:ok, session} = Sanctum.TestContext.create_session(Sanctum.TestContext.issuer!(ctx))

    # An API key, a session token and no credential at all: the HTTP API
    # is programmatic whichever proves who is calling.
    for bearer <- [key.api_key, session.token, nil] do
      conn =
        build_conn(:get, "/api/v1/whoami?origin=interactive")
        |> put_req_header("x-cyfr-origin", "interactive")

      conn = if bearer, do: put_req_header(conn, "authorization", "Bearer " <> bearer), else: conn

      conn =
        conn
        |> CyfrWeb.Plugs.CallIdentity.call(CyfrWeb.Plugs.CallIdentity.init([]))
        |> CyfrWeb.Plugs.Authenticate.call(CyfrWeb.Plugs.Authenticate.init([]))

      refute conn.halted
      assert conn.assigns.context.authenticated == not is_nil(bearer)
      conn.assigns.context.origin
    end
  end

  def frame_invoke(_conn) do
    frame_calls(:invoke, %{ref: "c:local.undeclared", operation: "run", args: %{}})
  end

  def frame_action(_conn) do
    frame_calls(:action, %{operation: "execution.list", args: %{}})
  end

  def frame_stream(_conn) do
    frame_calls(:stream_open, %{stream: "executions.deltas", subject: "exec_1"})
  end

  def webhook_delivery(conn) do
    ctx = Sanctum.TestContext.local()
    runnable!(ctx, [%{"ran" => true}])
    hook = hook!(ctx)
    watch_deliveries()

    # The body and a header name another origin; neither is read.
    delivered =
      conn
      |> put_req_header("x-cyfr-origin", "interactive")
      |> post_signed(hook, ~s({"origin":"interactive"}))

    request_id = json_response(delivered, 200)["request_id"]
    assert_receive {:delivered, ^request_id}, 30_000

    for execution <- executions(request_id: request_id), do: origin(execution.origin)
  end

  def schedule_fire(_conn) do
    ctx = Sanctum.TestContext.local()
    runnable!(ctx, [%{"ran" => true}])
    Application.put_env(:cyfr, :cron_scheduler_enabled, true)

    {:ok, schedule} =
      Arca.CronSchedule.create(%{
        user_id: ctx.user_id,
        athanor_id: ctx.athanor_id,
        name: "origin-#{System.unique_integer([:positive])}",
        cron_expression: "0 * * * *",
        reference: "#{@dep}:0.1.0",
        resolved_reference: @dep_ref,
        profile_id: "prof_origin_dep",
        next_run_at: DateTime.add(DateTime.utc_now(), -60, :second)
      })

    start_supervised!(Crucible.Schedules.Scheduler)

    wait_until(
      fn -> match?([%{status: "completed"}], executions(schedule_id: schedule.id)) end,
      30_000
    )

    for execution <- executions(schedule_id: schedule.id), do: origin(execution.origin)
  end

  def device_channel(_conn) do
    for origin <- ["programmatic", "webhook"] do
      {:ok, state} =
        DeviceChannel.connect(%{
          endpoint: CyfrWeb.Endpoint,
          transport: :websocket,
          options: [],
          params: %{"origin" => origin},
          connect_info: %{peer_data: %{address: {127, 0, 0, 1}, port: 50_000, ssl_cert: nil}}
        })

      {:ok, state} = DeviceChannel.init(state)
      state.ctx.origin
    end
  end

  # ==========================================================================
  # Beside the rows
  # ==========================================================================

  describe "the console" do
    test "a mounted view's context and a per-request read's are interactive", %{conn: conn} do
      conn = log_in_user(conn, test_user())
      {view, _html} = mount_athanor(conn, "/executions")

      assert %{socket: %{assigns: %{context: %Sanctum.Context{origin: :interactive}}}} =
               :sys.get_state(view.pid)

      token = Plug.Conn.get_session(conn, session_key())

      assert {:ok, %Sanctum.Context{origin: :interactive}} =
               CyfrWeb.ContextGuard.authenticate(token, seated_athanor().id)

      Cyfr.Test.Sandbox.end_views()
    end
  end

  describe "the rows a run writes" do
    test "a root records its context's origin and names none of a caller's; a child records its parent's" do
      root =
        Crucible.Record.new(scheduled(), "formula:local.origin-root:0.1.0", %{},
          component_type: :formula,
          origin: :interactive
        )

      assert root.origin == :schedule
      :ok = Crucible.Record.write_started(root)

      # A child whose context says `interactive` is still its parent's.
      child =
        Crucible.Record.new(
          %{scheduled() | origin: :interactive},
          "reagent:local.origin-child:0.1.0",
          %{},
          parent_execution_id: root.id,
          root_execution_id: root.id
        )

      assert is_nil(child.origin)
      :ok = Crucible.Record.write_started(child)

      assert row_origin(root.id) == :schedule
      assert row_origin(child.id) == :schedule
    end

    test "a child a scheduled root admits through the HostAPI carries schedule, never interactive" do
      publisher = Sanctum.TestContext.local()
      wasm = File.read!(@math_wasm_path)

      for {name, type} <- [{"origin-formula", "formula"}, {"origin-target", "reagent"}] do
        {:ok, _} =
          Compendium.Registry.publish_bytes(publisher, wasm, %{
            name: name,
            version: "1.0.0",
            type: type
          })
      end

      start_supervised!({ScriptedWorker, ref: "reagent:local.unscripted", script: []})

      fixture =
        AttemptFixtures.attached!(
          ctx: scheduled(),
          authority: formula_authority(),
          component_ref: "#{@formula}:1.0.0",
          component_type: :formula,
          worker: ScriptedWorker.endpoint(),
          reservation: true
        )

      assert row_origin(fixture.execution_id) == :schedule

      # The runner's body names an origin; nothing reads it.
      assert %{"ok" => answer} =
               AttemptFixtures.call(fixture, "admit_child", %{
                 "reference" => "#{@target}:1.0.0",
                 "input" => %{},
                 "guest_fn" => "call",
                 "child_key" => "ck_#{System.unique_integer([:positive])}",
                 "origin" => "interactive"
               })

      child = child!(fixture, answer)
      assert row_origin(child.execution_id) == :schedule
      assert %{"ok" => _} = fail!(child, "done")
      assert %{"ok" => _} = fail!(fixture, "done")
    end

    test "a frame's invoke, and a public page's, root their runs on the frame path's origin" do
      source = frame_source!()
      runnable_dep!(source)

      node = tincture!(source, "origin-run", %{}, [%{"ref" => @dep, "reason" => "dep"}])
      _owner = tincture_profile!(source, node, :owner)
      frame = frame!(source, "origin-run", digest_of("origin-run"), 1)

      body = TinctureWire.request(:invoke, %{ref: @dep_ref, operation: "run", args: %{}})
      assert data(:invoke, body, bearer: frame.bearer).status == 200

      public = tincture!(source, "origin-public", %{}, [%{"ref" => @dep, "reason" => "dep"}])
      _public = tincture_profile!(source, public, :public)

      public_body =
        TinctureWire.request(:invoke, %{
          ref: @dep_ref,
          operation: "run",
          args: %{},
          public: %{athanor: @address, publisher: "local", name: "origin-public"}
        })

      assert data(:invoke, public_body).status == 200

      origins =
        Arca.Repo.all(
          from(e in Arca.Schemas.Execution,
            where: like(e.reference, ^"#{@dep}%") and is_nil(e.parent_execution_id),
            select: e.origin
          )
        )

      assert origins == ["interactive", "interactive"]
    end
  end

  describe "a webhook replayed" do
    test "runs once under its idempotency, and its row keeps the origin webhook", %{conn: conn} do
      ctx = Sanctum.TestContext.local()
      runnable!(ctx, [%{"ran" => true}, %{"ran" => true}])
      hook = hook!(ctx, idempotency_key_header: "x-delivery-id")
      watch_deliveries()

      first =
        conn
        |> put_req_header("x-delivery-id", "delivery-1")
        |> post_signed(hook, ~s({"n":1}))

      request_id = json_response(first, 200)["request_id"]
      assert_receive {:delivered, ^request_id}, 30_000

      replayed =
        build_conn()
        |> put_req_header("x-delivery-id", "delivery-1")
        |> post_signed(hook, ~s({"n":1}))

      assert %{"status" => "duplicate"} = json_response(replayed, 200)

      assert [%{origin: "webhook"}] =
               Arca.Repo.all(
                 from(e in Arca.Schemas.Execution, where: like(e.reference, ^"#{@dep}%"))
               )
    end
  end

  describe "a hidden frame" do
    test "the shell suspends a hidden frame only when it holds no background grant" do
      frames =
        Prism.Frames.new()
        |> Prism.Frames.put(shell_frame({:full, "shown"}, :full, false))
        |> Prism.Frames.put(shell_frame({:slot, "kept"}, {:slot, "kept"}, true))
        |> Prism.Frames.put(shell_frame({:slot, "idle"}, {:slot, "idle"}, false))
        |> Prism.Frames.activate({:full, "shown"})
        |> Prism.Frames.visibility()

      assert Prism.Frames.plan(frames) == [{:freeze, {:slot, "idle"}}]
    end

    test "one its background grant keeps live is admitted as interactive; a suspended one is refused" do
      source = frame_source!()
      frame = frame!(source, "hidden-dash", declared!(source, "hidden-dash"))

      # Hidden but standing, as its background grant leaves it: admitted on
      # the frame path, and the origin says how, not that anyone watches.
      conn = action(frame.bearer, "system.status")
      assert conn.status == 200
      assert conn.assigns.context.origin == :interactive

      {:ok, _} = TinctureAuth.suspend_frame(source, frame.id)
      assert action(frame.bearer, "system.status").status == 403
    end
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  defp with_probe(fun), do: Grimoire.Catalog.with_providers([Probe], fun)

  # A context the scheduler's fire builds, in the fixture athanor.
  defp scheduled do
    local = Sanctum.TestContext.local()
    Sanctum.Context.for_scheduled(local.user_id, athanor_id: local.athanor_id)
  end

  defp origin(nil), do: nil

  defp origin(spelling) when is_binary(spelling) do
    {:ok, origin} = Prima.Origin.from_wire(spelling)
    origin
  end

  defp row_origin(execution_id),
    do: origin(Arca.Repo.get!(Arca.Schemas.Execution, execution_id).origin)

  defp executions(filters),
    do: Arca.Repo.all(from(e in Arca.Schemas.Execution, where: ^filters))

  # An authority rooted at `@node` whose ingress edge grants the probe.
  defp granting do
    {:ok, blob} =
      Blob.parse(%{
        "canonical" => "jcs-1",
        "nodes" => %{
          @node => %{
            "limits" => Graph.limits_map(),
            "edges" => %{"@ingress" => %{"tools" => ["#{Probe.tool()}.peek"]}}
          }
        }
      })

    {:ok, authority} =
      Authority.root(
        %{
          profile_id: "prof-origin",
          consent_id: "consent-origin",
          source_ref: @node,
          kind: :owner,
          invoke_mode: :open_inert,
          activation: %{@node => "sha256:origin"}
        },
        blob,
        ceiling: Graph.ceiling()
      )

    authority
  end

  # A root authority bound at the formula, consenting to invoke the target.
  defp formula_authority do
    nodes = %{
      @formula => %{
        "limits" => Graph.limits_map(),
        "edges" => %{"@ingress" => %{"tools" => []}, @target => %{}}
      },
      @target => %{"limits" => Graph.limits_map(), "edges" => %{}}
    }

    {:ok, blob} = Blob.parse(%{"canonical" => "jcs-1", "nodes" => nodes})

    {:ok, authority} =
      Authority.root(
        %{
          profile_id: "prof-origin-formula",
          consent_id: "consent-origin-formula",
          source_ref: @formula,
          kind: :owner,
          invoke_mode: :open_inert,
          activation: %{@formula => Prima.Digest.sha256("origin-formula")}
        },
        blob,
        ceiling: Graph.ceiling()
      )

    authority
  end

  # The admitted child as its runner holds it: its keys, opened with the
  # calling attempt's seal key.
  defp child!(fixture, answer) do
    assert %{"assignment" => token, "attempt_keys" => sealed} = answer
    {:ok, keys} = Prima.WorkerAuth.open_attempt_keys(fixture.keys.seal, sealed)
    {:ok, assignment} = Prima.Assignment.read(token)

    Map.merge(keys.attempt, %{
      boot: fixture.boot,
      runner: fixture.runner,
      member: assignment.member,
      keys: keys,
      call_key: keys.call
    })
  end

  defp fail!(child, error) do
    AttemptFixtures.call(child, "fail", %{
      "outcome" => AttemptFixtures.outcome(child, "failed", %{"error" => error})
    })
  end

  # A component that runs: the dependency published, its profile's head
  # consent activating it, and a scripted worker service answering its runs.
  defp runnable!(ctx, script) do
    runnable_dep!(ctx)

    :ok =
      Sanctum.Test.ConsentFixtures.seed_head!(
        ctx,
        %{
          id: "prof_origin_dep",
          kind: :owner,
          source_ref: @dep,
          label: "default",
          status: :active
        },
        %{
          id: "consent-prof_origin_dep",
          revision: 1,
          scope: :versionless,
          pinned_version: "",
          invoke_mode: :open_inert,
          shape_digest: "sha256:shape-origin",
          commit_digest: "sha256:commit-origin",
          resolved_policy:
            Jason.encode!(%{
              "canonical" => "jcs-1",
              "nodes" => %{
                @dep => %{"limits" => Graph.limits_map(), "edges" => %{"@ingress" => %{}}}
              }
            }),
          activation: %{@dep => digest_of("origin-dep")},
          vault_refs: []
        }
      )

    start_supervised!({ScriptedWorker, ref: @dep_ref, script: script})
    ScriptedWorker.fresh_limits!(ctx, [@dep_ref])
  end

  defp runnable_dep!(ctx) do
    {:ok, _dep} =
      Compendium.Registry.publish_bytes(ctx, File.read!(@math_wasm_path), %{
        name: "origin-dep",
        version: "0.1.0",
        type: "reagent"
      })

    :ok
  end

  defp hook!(ctx, attrs \\ []) do
    {:ok, hook} =
      Sanctum.Webhook.create(
        ctx,
        Map.merge(
          %{
            name: "origin-#{System.unique_integer([:positive])}",
            target_ref: @dep_ref,
            profile_id: "prof_origin_dep",
            replay_protection: "none"
          },
          Map.new(attrs)
        )
      )

    hook
  end

  defp post_signed(conn, hook, body) do
    signature =
      "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, hook.secret, body), case: :lower)

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-cyfr-signature", signature)
    |> post("/hooks/" <> hook.slug, body)
  end

  # Each delivery's task ends with its stop event.
  defp watch_deliveries do
    id = {__MODULE__, make_ref()}
    test = self()

    :telemetry.attach(
      id,
      [:cyfr, :emissary, :webhook, :invoke, :stop],
      fn _event, _measurements, meta, _ -> send(test, {:delivered, meta.request_id}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  # Every context the tincture data routes build for `kind`: a frame's,
  # under its credential, and a public page's. Each asks for what its
  # tincture does not declare, so it is refused after the caller is
  # established, before anything is dispatched.
  defp frame_calls(kind, request) do
    source = frame_source!()

    name =
      "origin-#{String.replace(to_string(kind), "_", "-")}-#{System.unique_integer([:positive])}"

    frame = frame!(source, name, declared!(source, name))
    public = public_tincture!(source)

    framed = data(kind, TinctureWire.request(kind, request), bearer: frame.bearer)

    paged =
      data(
        kind,
        TinctureWire.request(
          kind,
          Map.put(request, :public, %{athanor: @address, publisher: "local", name: public})
        )
      )

    # A body naming an origin is refused unread: no context is built.
    named = Map.put(TinctureWire.request(kind, request), "origin", "programmatic")
    unread = data(kind, named, bearer: frame.bearer)
    assert unread.status == 400
    refute Map.has_key?(unread.assigns, :context)

    for conn <- [framed, paged] do
      assert conn.status == 403
      conn.assigns.context.origin
    end
  end

  defp frame_source! do
    issuer = Sanctum.TestContext.issuer!(Sanctum.TestContext.local())
    {:ok, session} = Sanctum.TestContext.create_session(issuer)
    {:ok, source} = Sanctum.Caller.establish(session.token)
    source
  end

  # A tincture version in the source's athanor declaring `block` and the
  # static dependencies `deps`. Answers its reference.
  defp tincture!(ctx, name, block, deps) do
    manifest = %{
      "name" => name,
      "type" => "tincture",
      "version" => "1.0.0",
      "publisher" => "local",
      "tincture" => Map.merge(%{"entry" => "index.html"}, block),
      "dependencies" => %{"static" => deps}
    }

    digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, name), case: :lower)
    {:ok, release_digest} = Compendium.ReleaseDigest.compute(digest, manifest)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, _} =
      Arca.ComponentStorage.put_component(Sanctum.Context.actor(ctx), %{
        id: "cmp_#{name}_#{System.unique_integer([:positive])}",
        name: name,
        version: "1.0.0",
        component_type: "tincture",
        description: name,
        tags: "[]",
        digest: digest,
        release_digest: release_digest,
        size: 100,
        exports: "[]",
        manifest: Jason.encode!(manifest),
        publisher: "local",
        publisher_id: "local|local|testns",
        source: Compendium.Source.filesystem(),
        signature_verified: false,
        inserted_at: now,
        updated_at: now
      })

    "tincture:local.#{name}"
  end

  # A tincture declaring one action and one stream. Answers its release digest.
  defp declared!(ctx, name) do
    tincture!(
      ctx,
      name,
      %{"actions" => ["system.status"], "streams" => [%{"name" => "mcp_servers.changes"}]},
      [%{"ref" => "reagent:local.echo", "reason" => "echo"}]
    )

    digest_of(name)
  end

  # A public tincture, as its public profile makes it. Answers its name.
  defp public_tincture!(ctx) do
    name = "origin-public-#{System.unique_integer([:positive])}"
    declared!(ctx, name)

    {:ok, _} =
      Arca.ProfileStorage.put(%{
        id: "prof_#{name}",
        athanor_id: ctx.athanor_id,
        source_ref: "tincture:local.#{name}",
        kind: "public",
        label: "public",
        status: "active"
      })

    name
  end

  # A profile of `kind` for the tincture `node`, whose head consent binds
  # its edge to the dependency.
  defp tincture_profile!(ctx, node, kind) do
    id = "prof_#{kind}_#{System.unique_integer([:positive])}"
    {:ok, _ref, _type, component} = Crucible.Admission.inspect_component(ctx, node)
    {:ok, %{graph: activation}} = Compendium.Activation.resolve_verified(ctx, component)

    :ok =
      Sanctum.Test.ConsentFixtures.seed_head!(
        ctx,
        %{id: id, kind: kind, source_ref: node, label: to_string(kind), status: :active},
        %{
          id: "consent_#{id}",
          revision: 1,
          scope: :versionless,
          pinned_version: "",
          invoke_mode: if(kind == :public, do: :edge_only, else: :open_inert),
          shape_digest: "sha256:shape-#{id}",
          commit_digest: "sha256:commit-#{id}",
          resolved_policy:
            Jason.encode!(%{
              "canonical" => "jcs-1",
              "nodes" => %{
                node => %{
                  "limits" => Graph.limits_map(),
                  "edges" => %{"@ingress" => %{}, @dep => %{}}
                },
                @dep => %{"limits" => Graph.limits_map(), "edges" => %{}}
              }
            }),
          activation: activation,
          vault_refs: []
        }
      )

    start_worker_once!()
    id
  end

  # The dependency's scripted worker service, started by the first profile
  # a test makes.
  defp start_worker_once! do
    if is_nil(Process.whereis(ScriptedWorker)) do
      start_supervised!({ScriptedWorker, ref: @dep_ref, script: [%{"ok" => 1}, %{"ok" => 2}]})
      ScriptedWorker.fresh_limits!(Sanctum.TestContext.local(), [@dep_ref])
    end

    :ok
  end

  defp digest_of(name) do
    Arca.Repo.one!(
      from(c in Arca.Schemas.Component,
        where: c.name == ^name,
        select: c.release_digest,
        limit: 1
      )
    )
  end

  # The frame the shell would open for `name`: its credential and row id.
  defp frame!(source, name, digest, revision \\ 0) do
    reference = %{publisher: "local", name: name, version: "1.0.0"}
    frame_id = "frm_origin_#{System.unique_integer([:positive])}"

    {:ok, %{credential: bearer, id: id}} =
      TinctureAuth.mint_frame_credential(source, reference, digest, revision, frame_id)

    %{bearer: bearer, id: id}
  end

  defp data(kind, body, opts \\ []) do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("origin", "null")

    conn =
      case Keyword.get(opts, :bearer) do
        nil -> conn
        bearer -> put_req_header(conn, "authorization", TinctureWire.bearer(bearer))
      end

    post(conn, TinctureWire.route(kind), Jason.encode!(body))
  end

  defp action(bearer, operation) do
    data(:action, TinctureWire.request(:action, %{operation: operation, args: %{}}),
      bearer: bearer
    )
  end

  # A frame as the shell holds one: shown or hidden by where it sits and
  # which frame is active, frozen by `plan/1` only when it may not run in
  # the background.
  defp shell_frame(key, placement, background) do
    %{
      key: key,
      id: "frm_#{inspect(key)}",
      tincture_id: "tincture:local.shell",
      reference: %{publisher: "local", name: "shell", version: "1.0.0"},
      src: nil,
      sandbox: nil,
      allow: nil,
      state: :live,
      refusal: nil,
      credential_id: nil,
      bearer: nil,
      placement: placement,
      visible: true,
      background: background,
      actions: []
    }
  end
end
