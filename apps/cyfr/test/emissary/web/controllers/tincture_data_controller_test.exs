# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.Web.TinctureDataControllerTest do
  @moduledoc """
  The tincture data routes (`/_f/v1/invoke`, `/_f/v1/action`,
  `/_f/v1/stream`): a frame's per-open credential as a bearer and nothing
  else, held at every request to its row, its source, the version it
  opened and the grant it was opened under; the tincture's declaration as
  the grant, enforced before dispatch; a public tincture's page admitted
  under its public profile only; the per-frame invocation rate and
  open-stream count; and the stream answered as the wire's event stream,
  closed within the revalidation bound once its frame stops standing.

  A frame that connects to origins beyond the endpoint: an invoke, an
  action or a stream is refused before anything is read or run unless
  every class it may carry has a flow to every origin on its grant's
  ingress edge (the owner head's for a frame, the public profile's for a
  public page), an open stream ends once its grant stops letting its
  events flow, a grant that cannot be trusted refuses as damage, and a
  frame that connects nowhere, a canvas among them, reads nothing of its
  grant.

  A canvas's own data path (`/_f/v1/o/<frame id>/stream`): only the bearer
  of the frame the path names, refused before its version, grant or charge
  is read otherwise; only a canvas; no public page; and a canvas refused
  on the shared routes. A validation trial is answered there from
  fixtures, a feed's from the binding the athanor holds, and admits
  nothing.
  """

  # Mints and suspends frame credentials, writes platform settings and
  # meters rates, all of them process-wide.
  use CyfrWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Prima.Test.Wait

  alias Prima.Canvas.Shape
  alias Prima.Test.EventStream
  alias Prima.TinctureWire
  alias Sanctum.TinctureAuth

  # A provider whose one stream a canvas may read: it declares a shape.
  defmodule ShapedProbe do
    @moduledoc false
    @behaviour Prima.Provider

    @impl true
    def service, do: "shaped-probe"

    @impl true
    def tools, do: []

    @impl true
    def handle(_tool, _ctx, _args), do: {:error, :unreachable}

    @impl true
    def streams do
      {:ok, shape} =
        Prima.Canvas.Shape.validate(%{
          "type" => "object",
          "fields" => %{
            "kind" => %{"type" => "enum", "values" => ["changed", "removed"]},
            "count" => %{"type" => "integer"},
            "at" => %{"type" => "time"}
          },
          "required" => ["kind"]
        })

      [
        %Prima.Provider.Stream{
          name: "probe.shaped",
          topic: :mcp_servers,
          projection: ["at", "count", "kind"],
          deadline_bound: 60,
          shape: shape
        }
      ]
    end
  end

  # A provider of a feed's results as a canvas reads them: a filtering
  # stream whose subject is a feed's name.
  defmodule FeedProbe do
    @moduledoc false
    @behaviour Prima.Provider

    @impl true
    def service, do: "feed-probe"

    @impl true
    def tools, do: []

    @impl true
    def handle(_tool, _ctx, _args), do: {:error, :unreachable}

    @impl true
    def streams do
      text = %{"type" => "string"}

      {:ok, shape} =
        Prima.Canvas.Shape.validate(%{
          "type" => "object",
          "fields" => %{
            "binding" => text,
            "feed" => text,
            "revision" => %{"type" => "integer"},
            "at" => %{"type" => "time"},
            "result" => %{"type" => "json"},
            "label" => text,
            "actions" => %{
              "type" => "list",
              "of" => %{"type" => "object", "fields" => %{"name" => text, "label" => text}}
            }
          }
        })

      [
        %Prima.Provider.Stream{
          name: "feed.results",
          topic: :mcp_servers,
          projection: ~w(actions at binding feed label result revision),
          subject: ~S"\A[a-z0-9][a-z0-9-]{0,47}\z",
          filter: "feed",
          deadline_bound: 60,
          shape: shape
        }
      ]
    end
  end

  # A provider of one read whose answers are filed material, as its
  # operation declares (`Prima.Operation`'s `sources`). Each read tells
  # the process registered as `:tincture_flow_probe`, so a case sees
  # whether the read was made at all.
  defmodule FiledProbe do
    @moduledoc false
    @behaviour Prima.Provider

    alias Prima.Operation

    @impl true
    def service, do: "filed-probe"

    @impl true
    def tools do
      [
        Operation.tool([
          Operation.new("flow_probe", "filed", "Read filed material", [],
            kind: :read,
            planes: [:external],
            sources: [:filed]
          )
        ])
      ]
    end

    @impl true
    def handle("flow_probe", _ctx, %{"action" => "filed"}) do
      if observer = Process.whereis(:tincture_flow_probe), do: send(observer, :flow_probe_read)
      {:ok, %{"filed" => true}}
    end
  end

  @version "1.0.0"

  # How long a stream may take to open (the gate's admission and the
  # subscription) or to take an event, on a loaded host. Each wait ends on
  # the subscription or the delivery itself; this bounds one that never
  # ends.
  @stream_ms 10_000

  setup do
    Prima.Test.RateLimiter.reset!()
    on_exit(fn -> Prima.Test.RateLimiter.reset!() end)

    _athanor = Sanctum.TestContext.athanor!()
    issuer = Sanctum.TestContext.issuer!(Sanctum.TestContext.local())
    {:ok, session} = Sanctum.TestContext.create_session(issuer)
    {:ok, source} = Sanctum.Caller.establish(session.token)
    echo!(source)

    {:ok, source: source, session: session}
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  # A tincture version in the source's athanor declaring `block` (its
  # actions and streams) and `deps` (its static dependencies). Answers
  # its release digest.
  defp tincture!(ctx, name, block, deps) do
    put_version!(ctx, name, %{
      "name" => name,
      "type" => "tincture",
      "version" => @version,
      "publisher" => "local",
      "tincture" => Map.merge(%{"entry" => "index.html"}, block),
      "dependencies" => %{"static" => deps}
    })
  end

  # A canvas version in the source's athanor declaring `streams`, put as
  # any version's row is: a canvas declaring a stream no provider declares
  # yet is refused at publish, not at this row. Answers its release digest.
  defp canvas!(ctx, name, streams) do
    put_version!(ctx, name, %{
      "name" => name,
      "type" => "tincture",
      "version" => @version,
      "publisher" => "local",
      "tincture" => %{
        "frame" => %{"placement" => "canvas"},
        "entry" => "index.html",
        "streams" => streams
      }
    })
  end

  # The reagent the fixtures' tinctures name as their static dependency,
  # installed so a tincture's closure resolves as an installed one does.
  defp echo!(ctx) do
    put_row!(ctx, "reagent", "echo", %{
      "name" => "echo",
      "type" => "reagent",
      "version" => @version,
      "publisher" => "local"
    })
  end

  defp put_version!(ctx, name, manifest), do: put_row!(ctx, "tincture", name, manifest)

  defp put_row!(ctx, type, name, manifest) do
    digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, name), case: :lower)
    {:ok, release_digest} = Compendium.ReleaseDigest.compute(digest, manifest)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {:ok, _} =
      Arca.ComponentStorage.put_component(Sanctum.Context.actor(ctx), %{
        id: "cmp_#{name}_#{System.unique_integer([:positive])}",
        name: name,
        version: Map.get(manifest, "version", @version),
        component_type: type,
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

    release_digest
  end

  defp declared!(ctx, name) do
    tincture!(
      ctx,
      name,
      %{"actions" => ["system.status"], "streams" => [%{"name" => "mcp_servers.changes"}]},
      [%{"ref" => "reagent:local.echo", "reason" => "echo"}]
    )
  end

  defp frame_id, do: "frm_data_#{System.unique_integer([:positive])}"

  # Another signed-in person of the same athanor.
  defp person!(namespace) do
    issuer =
      Sanctum.TestContext.issuer!(%{
        Sanctum.TestContext.local()
        | user_id: "local|local|#{namespace}",
          namespace: namespace
      })

    {:ok, session} = Sanctum.TestContext.create_session(issuer)
    {:ok, ctx} = Sanctum.Caller.establish(session.token)
    ctx
  end

  # The frame the shell would open for `name`: its credential, row id and
  # frame id, minted at `revision`, or by default at the revision of the
  # grant the version opens under, granted first as the person would grant
  # it (`Sanctum.Test.ConsentFixtures.grant_tincture!/3`) when it holds none.
  defp frame!(source, name, digest, revision \\ nil) do
    reference = %{publisher: "local", name: name, version: @version}
    revision = revision || standing_revision!(source, name)
    frame = frame_id()

    {:ok, %{credential: bearer, id: id}} =
      TinctureAuth.mint_frame_credential(source, reference, digest, revision, frame)

    %{bearer: bearer, id: id, frame_id: frame}
  end

  defp standing_revision!(source, name) do
    case Sanctum.Consent.tincture_grant(source, "tincture:local.#{name}:#{@version}") do
      {:ok, %{revision: revision}} ->
        revision

      {:error, :ungranted} ->
        Sanctum.Test.ConsentFixtures.grant_tincture!(source, "tincture:local.#{name}")
        1
    end
  end

  defp data(kind, body, opts \\ []) do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("origin", Keyword.get(opts, :origin, "null"))
      |> Map.put(:remote_ip, Keyword.get(opts, :ip, {127, 0, 0, 1}))

    conn =
      case Keyword.get(opts, :bearer) do
        nil -> conn
        bearer -> put_req_header(conn, "authorization", TinctureWire.bearer(bearer))
      end

    post(conn, Keyword.get(opts, :path, TinctureWire.route(kind)), Jason.encode!(body))
  end

  defp action(bearer, operation, opts \\ []) do
    body = TinctureWire.request(:action, %{operation: operation, args: %{}})
    data(:action, body, Keyword.put(opts, :bearer, bearer))
  end

  defp answer(conn, kind), do: TinctureWire.decode_answer(kind, Jason.decode!(conn.resp_body))

  defp refused(conn, kind) do
    assert {:refused, projection} = answer(conn, kind)
    projection
  end

  defp mcp_rows(tool),
    do: Arca.Repo.all(from(l in Arca.Schemas.McpLog, where: l.tool == ^tool))

  # The gate's decisions for `tool`: what was dispatched, whether or not
  # the request log keeps a row of it.
  defp decisions(tool),
    do: Arca.Repo.all(from(d in Arca.Schemas.DecisionLog, where: d.tool == ^tool))

  # ---------------------------------------------------------------------------
  # Who is asking
  # ---------------------------------------------------------------------------

  describe "the frame credential" do
    test "a declared action runs through the gate as the frame's person, in its athanor",
         %{source: source} do
      frame = frame!(source, "act-dash", declared!(source, "act-dash"))
      conn = action(frame.bearer, "system.status")

      assert conn.status == 200
      assert {:ok, _status} = answer(conn, :action)
      assert get_resp_header(conn, "access-control-allow-origin") == ["null"]
      assert get_resp_header(conn, "access-control-allow-credentials") == []

      # A refusal after the frame was established is recorded as its
      # person's, in its athanor.
      assert action(frame.bearer, "execution.list").status == 403
      assert [row] = decisions("tincture")
      assert {row.action, row.admission} == {"system_action", "refused"}
      assert {row.user_id, row.athanor_id} == {source.user_id, source.athanor_id}
    end

    test "a request with no credential and no public tincture is no frame", %{source: source} do
      declared!(source, "none-dash")

      conn =
        data(:action, TinctureWire.request(:action, %{operation: "system.status", args: %{}}))

      assert conn.status == 401
      assert %{class: "unauthenticated", stage: "admission"} = refused(conn, :action)
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
    end

    test "a session token, an API key or a session cookie is never a frame credential",
         %{source: source, session: session} do
      declared!(source, "cookie-dash")
      body = TinctureWire.request(:action, %{operation: "system.status", args: %{}})

      conn = data(:action, body, bearer: session.token)
      assert %{class: "unauthenticated"} = refused(conn, :action)

      cookie =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("cookie", "_cyfr_key=" <> session.token)
        |> post(TinctureWire.route(:action), Jason.encode!(body))

      assert cookie.status == 401
      assert Enum.all?(decisions("tincture"), &(&1.admission == "refused" and is_nil(&1.user_id)))
    end

    test "a suspended frame is refused, a resumed one admitted, a revoked one refused at once",
         %{source: source} do
      frame = frame!(source, "state-dash", declared!(source, "state-dash"))

      {:ok, _} = TinctureAuth.suspend_frame(source, frame.id)
      suspended = action(frame.bearer, "system.status")
      assert suspended.status == 403
      assert %{class: "forbidden", stage: "admission"} = refused(suspended, :action)

      {:ok, _} = TinctureAuth.resume_frame(source, frame.id)
      assert action(frame.bearer, "system.status").status == 200

      # A closed tab: the shell's terminate revokes every credential it
      # minted, and the next request is refused.
      {:ok, _} = TinctureAuth.revoke_frame(source, frame.id)
      assert %{class: "unauthenticated"} = refused(action(frame.bearer, "system.status"), :action)
    end

    test "an unobserved frame's credential past its deadline is refused at the next request",
         %{source: source} do
      # A killed shell revokes nothing; the deadline is the backstop.
      frame = frame!(source, "late-dash", declared!(source, "late-dash"))
      assert action(frame.bearer, "system.status").status == 200

      {1, _} =
        Arca.Repo.update_all(
          from(f in Arca.Schemas.FrameCredential, where: f.id == ^frame.id),
          set: [deadline: DateTime.add(DateTime.utc_now(), -1, :second)]
        )

      assert %{class: "unauthenticated"} = refused(action(frame.bearer, "system.status"), :action)
    end

    test "a bearer this server did not sign as a frame credential is refused", %{source: source} do
      frame = frame!(source, "forged-dash", declared!(source, "forged-dash"))

      assert %{class: "unauthenticated"} =
               refused(action(frame.bearer <> "x", "system.status"), :action)

      {:ok, %{credential: asset}} =
        TinctureAuth.mint_asset_credential(source, declared!(source, "a2"))

      assert %{class: "unauthenticated"} = refused(action(asset, "system.status"), :action)
    end

    test "a credential presented for another version is refused", %{source: source} do
      frame = frame!(source, "moved-dash", declared!(source, "moved-dash"))

      {1, _} =
        Arca.Repo.update_all(
          from(c in Arca.Schemas.Component, where: c.name == "moved-dash"),
          set: [release_digest: "sha256:" <> String.duplicate("f", 64)]
        )

      conn = action(frame.bearer, "system.status")
      assert conn.status == 403
      assert %{class: "forbidden", stage: "admission"} = refused(conn, :action)
    end

    test "a tincture with no grant reaches nothing: its declaration is never its grant, and it is asked for one",
         %{source: source} do
      frame = frame!(source, "bare-dash", declared!(source, "bare-dash"), 0)

      conn = action(frame.bearer, "system.status")
      assert %{class: "consent_required", stage: "admission"} = refused(conn, :action)

      body = TinctureWire.request(:stream_open, %{stream: "mcp_servers.changes", subject: nil})
      conn = data(:stream_open, body, bearer: frame.bearer)
      assert %{class: "consent_required", stage: "admission"} = refused(conn, :stream_open)
    end

    test "a version that reads more than its grant names reaches nothing and is asked again",
         %{source: source} do
      # 1.0.0 declares a stream; the newest, 1.0.1, which the grant was
      # made for, declares none.
      older = declared!(source, "more-dash")

      put_version!(source, "more-dash", %{
        "name" => "more-dash",
        "type" => "tincture",
        "version" => "1.0.1",
        "publisher" => "local",
        "tincture" => %{"entry" => "index.html", "actions" => ["system.status"]},
        "dependencies" => %{"static" => [%{"ref" => "reagent:local.echo", "reason" => "echo"}]}
      })

      Sanctum.Test.ConsentFixtures.grant_tincture!(source, "tincture:local.more-dash")
      frame = frame!(source, "more-dash", older, 1)

      conn = action(frame.bearer, "system.status")
      assert %{class: "consent_required", stage: "admission"} = refused(conn, :action)

      body = TinctureWire.request(:stream_open, %{stream: "mcp_servers.changes", subject: nil})
      conn = data(:stream_open, body, bearer: frame.bearer)
      assert %{class: "consent_required", stage: "admission"} = refused(conn, :stream_open)
    end

    test "a credential presented for another grant is refused", %{source: source} do
      frame = frame!(source, "grant-dash", declared!(source, "grant-dash"))
      assert action(frame.bearer, "system.status").status == 200

      :ok =
        Sanctum.Test.ConsentFixtures.seed_head!(
          source,
          %{
            id: "prof_grant_dash",
            kind: :owner,
            source_ref: "tincture:local.grant-dash",
            label: "owner",
            status: :active
          },
          %{
            id: "cons_grant_dash",
            revision: 2,
            scope: :versionless,
            pinned_version: "",
            invoke_mode: :open_inert,
            shape_digest: :live,
            commit_digest: "sha256:commit",
            resolved_policy:
              Sanctum.Test.ConsentFixtures.empty_policy("tincture:local.grant-dash"),
            activation: %{"tincture:local.grant-dash" => "sha256:act"}
          }
        )

      assert %{class: "forbidden"} = refused(action(frame.bearer, "system.status"), :action)

      # A frame opened under the grant as it now stands is admitted.
      current = frame!(source, "grant-dash", digest_of("grant-dash"), 2)
      assert action(current.bearer, "system.status").status == 200
    end

    test "a credential replayed from elsewhere carries its bound authority and nothing wider",
         %{source: source} do
      frame = frame!(source, "replay-dash", declared!(source, "replay-dash"))
      elsewhere = [ip: {203, 0, 113, 9}, origin: "https://attacker.example"]

      # Proven, not refused: the same person, athanor and declaration...
      conn = action(frame.bearer, "system.status", elsewhere)
      assert conn.status == 200
      # ...and no CORS grant for an origin the deployment does not list.
      assert get_resp_header(conn, "access-control-allow-origin") == []

      # ...and nothing the declaration does not name, as the same person.
      assert %{class: "forbidden"} =
               refused(action(frame.bearer, "execution.list", elsewhere), :action)

      assert [row] = decisions("tincture")
      assert {row.user_id, row.athanor_id} == {source.user_id, source.athanor_id}
    end
  end

  defp digest_of(name) do
    Arca.Repo.one!(
      from(c in Arca.Schemas.Component, where: c.name == ^name, select: c.release_digest)
    )
  end

  # ---------------------------------------------------------------------------
  # The grant
  # ---------------------------------------------------------------------------

  describe "the declaration is the grant" do
    test "an action outside it is refused before dispatch", %{source: source} do
      frame = frame!(source, "narrow-dash", declared!(source, "narrow-dash"))
      conn = action(frame.bearer, "execution.list")

      assert conn.status == 403

      assert %{class: "forbidden", stage: "admission", message: message} =
               refused(conn, :action)

      assert message =~ "does not declare that action"
      # The one decision is this route's refusal: the gate never saw it.
      assert [%{tool: "tincture", action: "system_action", refusal_class: "forbidden"}] =
               Arca.Repo.all(Arca.Schemas.DecisionLog)
    end

    # A stored version whose declaration names a tool only an agent asks
    # for never reached its row through publish; read at the request, its
    # declaration does not read, and nothing of it is dispatched.
    for tool <- ["layout.edit", "schedule.create", "schedule.update"] do
      test "a declared #{tool} is refused before dispatch, and so is the rest of its declaration",
           %{source: source} do
        tool = unquote(tool)
        name = "agent-only-#{String.replace(tool, ".", "-")}"

        digest =
          tincture!(source, name, %{"actions" => ["system.status", tool]}, [])

        frame = frame!(source, name, digest)

        for operation <- [tool, "system.status"] do
          conn = action(frame.bearer, operation)

          assert conn.status == 403, operation

          assert %{class: "forbidden", stage: "admission", message: message} =
                   refused(conn, :action)

          assert message =~ "declares nothing it can reach: its declaration does not read",
                 operation
        end

        # Each decision is this route's refusal: the gate never saw either.
        assert [_, _] = rows = Arca.Repo.all(Arca.Schemas.DecisionLog)

        assert Enum.all?(
                 rows,
                 &match?(
                   %{tool: "tincture", action: "system_action", refusal_class: "forbidden"},
                   &1
                 )
               )

        assert Arca.Repo.all(Arca.Schemas.CronSchedule) == []
      end
    end

    test "a declared component is invoked through the tincture operation with operation and params",
         %{source: source} do
      frame = frame!(source, "inv-dash", declared!(source, "inv-dash"))

      body =
        TinctureWire.request(:invoke, %{
          ref: "r:local.echo:1.0.0",
          operation: "run",
          args: %{"x" => 1}
        })

      conn = data(:invoke, body, bearer: frame.bearer)
      refute conn.resp_body =~ "does not declare"

      assert [row] = mcp_rows("tincture")
      assert row.action == "invoke_protected"

      assert %{
               "publisher" => "local",
               "tincture_name" => "inv-dash",
               "reference" => "r:local.echo:1.0.0",
               "input" => %{"operation" => "run", "params" => %{"x" => 1}}
             } = Jason.decode!(row.input)
    end

    test "a component outside it is refused before dispatch", %{source: source} do
      frame = frame!(source, "inv-narrow", declared!(source, "inv-narrow"))
      body = TinctureWire.request(:invoke, %{ref: "c:local.stripe", operation: "run", args: %{}})
      conn = data(:invoke, body, bearer: frame.bearer)

      assert conn.status == 403
      assert %{class: "forbidden", message: message} = refused(conn, :invoke)
      assert message =~ "does not declare that component"
      refute Enum.any?(decisions("tincture"), &(&1.action == "invoke_protected"))
    end

    test "a stream outside it, or with a subject it does not take, is refused before the gate",
         %{source: source} do
      frame = frame!(source, "stream-narrow", declared!(source, "stream-narrow"))

      for {stream, subject} <- [{"executions.deltas", "exec_1"}, {"mcp_servers.changes", "x"}] do
        body = TinctureWire.request(:stream_open, %{stream: stream, subject: subject})
        conn = data(:stream_open, body, bearer: frame.bearer)
        assert conn.status == 403
        assert %{class: "forbidden", message: message} = refused(conn, :stream_open)
        assert message =~ "does not declare that stream"
      end

      refute Arca.Repo.exists?(
               from(d in Arca.Schemas.DecisionLog, where: like(d.tool, "stream:%"))
             )
    end

    test "a body at another version or with a field its kind does not carry is refused unread",
         %{source: source} do
      frame = frame!(source, "body-dash", declared!(source, "body-dash"))
      body = TinctureWire.request(:action, %{operation: "system.status", args: %{}})

      for bad <- [%{body | "v" => 2}, Map.put(body, "credential", frame.bearer)] do
        conn = data(:action, bad, bearer: frame.bearer)
        assert conn.status == 400
        assert %{class: "invalid_argument"} = refused(conn, :action)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # A public tincture's page
  # ---------------------------------------------------------------------------

  describe "a public tincture's page" do
    setup %{source: source} do
      declared!(source, "pub-data")

      {:ok, _} =
        Arca.Test.Writers.put_profile(%{
          id: "prof_pub_data_#{System.unique_integer([:positive])}",
          athanor_id: source.athanor_id,
          source_ref: "tincture:local.pub-data",
          kind: "public",
          label: "public",
          status: "active"
        })

      declared!(source, "priv-data")
      :ok
    end

    defp public(name), do: %{athanor: "test", publisher: "local", name: name}

    test "invokes under its public profile, named by its address, with no bearer" do
      body =
        TinctureWire.request(:invoke, %{
          ref: "reagent:local.echo:1.0.0",
          operation: "run",
          args: %{},
          public: public("pub-data")
        })

      conn = data(:invoke, body)
      refute conn.status in [400, 401, 404]

      assert [row] = mcp_rows("tincture")
      assert row.action == "invoke_public"
      assert %{"athanor" => "test", "tincture_name" => "pub-data"} = Jason.decode!(row.input)
    end

    test "a private tincture named as public is not found, whoever asks" do
      body =
        TinctureWire.request(:action, %{
          operation: "system.status",
          args: %{},
          public: public("priv-data")
        })

      conn = data(:action, body)
      assert conn.status == 404
      assert %{class: "not_found"} = refused(conn, :action)
    end

    test "a request with a bearer and a public tincture is refused unread", %{source: source} do
      frame = frame!(source, "pub-data", digest_of("pub-data"))

      body =
        TinctureWire.request(:action, %{
          operation: "system.status",
          args: %{},
          public: public("pub-data")
        })

      conn = data(:action, body, bearer: frame.bearer)
      assert conn.status == 400
      assert %{class: "invalid_argument"} = refused(conn, :action)
    end

    # One outage and one request per test: on PostgreSQL the failed read
    # aborts the test's transaction, so a second request would meet that,
    # not the outage. Every kind is admitted through the same caller.
    for kind <- [:invoke, :action, :stream_open] do
      test "a registry that cannot answer for it is refused unavailable at admission: #{kind}" do
        # The athanor and the public profile resolve; the version cannot.
        Arca.Repo.query!("ALTER TABLE components RENAME TO components_unavailable")

        conn = data(unquote(kind), public_request(unquote(kind), "pub-data"))
        assert conn.status == 503
        assert %{class: "unavailable", stage: "admission"} = refused(conn, unquote(kind))
      end

      for name <- ["pub-data", "priv-data", "no-such-data"] do
        test "a profile store that cannot answer is unavailable, never not found: " <>
               "#{kind} #{name}" do
          Arca.Repo.query!("ALTER TABLE profiles RENAME TO profiles_unavailable")

          conn = data(unquote(kind), public_request(unquote(kind), unquote(name)))
          assert conn.status == 503
          assert %{class: "unavailable", stage: "admission"} = refused(conn, unquote(kind))
        end
      end
    end
  end

  # A request of `kind` naming the public tincture `name`.
  defp public_request(:invoke, name),
    do:
      TinctureWire.request(:invoke, %{
        ref: "reagent:local.echo:1.0.0",
        operation: "run",
        args: %{},
        public: public(name)
      })

  defp public_request(:action, name),
    do:
      TinctureWire.request(:action, %{operation: "system.status", args: %{}, public: public(name)})

  defp public_request(:stream_open, name),
    do:
      TinctureWire.request(:stream_open, %{
        stream: "mcp_servers.changes",
        subject: nil,
        public: public(name)
      })

  # ---------------------------------------------------------------------------
  # Limits
  # ---------------------------------------------------------------------------

  describe "the per-frame invocation rate" do
    setup do
      Cyfr.Test.Settings.put("frame_invocation_max", 2)
      Cyfr.Test.Settings.put("frame_invocation_window_ms", 60_000)
      :ok
    end

    test "is charged per request, refused over its bound with a typed refusal, one frame at a time",
         %{source: source} do
      digest = declared!(source, "rate-dash")
      frame = frame!(source, "rate-dash", digest)
      other = frame!(source, "rate-dash", digest)

      # An undeclared attempt is charged too.
      assert action(frame.bearer, "execution.list").status == 403
      assert action(frame.bearer, "system.status").status == 200

      over = action(frame.bearer, "system.status")
      assert over.status == 429
      assert %{class: "rate_limited", stage: "admission"} = refused(over, :action)
      assert [_seconds] = get_resp_header(over, "retry-after")

      assert action(other.bearer, "system.status").status == 200
    end
  end

  # ---------------------------------------------------------------------------
  # Streams
  # ---------------------------------------------------------------------------

  describe "a stream" do
    setup %{source: source} do
      digest = declared!(source, "live-dash")
      {:ok, frame: frame!(source, "live-dash", digest)}
    end

    defp open_stream(bearer) do
      body = TinctureWire.request(:stream_open, %{stream: "mcp_servers.changes", subject: nil})
      Task.async(fn -> data(:stream_open, body, bearer: bearer) end)
    end

    defp topic(source), do: Cyfr.Bus.mcp_servers(Sanctum.Context.actor(source))

    defp subscribed?(source),
      do: Registry.lookup(Cyfr.PubSub, topic(source)) != []

    # The stream process has taken every `payload` it was sent and waits in
    # its delivery loop for the next: what it was sent is written.
    defp delivered?(stream, payload) do
      case Process.info(stream, [:messages, :status, :current_function]) do
        [messages: messages, status: :waiting, current_function: {CyfrWeb.SSE, :loop, 2}] ->
          not Enum.any?(messages, &is_struct(&1, payload))

        _other ->
          false
      end
    end

    test "is answered as the wire's event stream, and closed within the bound once its frame is suspended",
         %{source: source, frame: frame} do
      stream = open_stream(frame.bearer)
      wait_until(fn -> subscribed?(source) end, @stream_ms)

      actor = Sanctum.Context.actor(source)
      :ok = Cyfr.Bus.broadcast(actor, topic(source), Cyfr.Bus.McpServers.new(actor, :changed))

      # A stream re-establishes its caller before delivering once its
      # context is past the freshness bound, so a frame suspended before
      # the event is delivered takes the event with it. The suspension
      # waits until the stream has taken the event and is waiting for the
      # next.
      wait_until(fn -> delivered?(stream.pid, Cyfr.Bus.McpServers) end, @stream_ms)

      suspended_at = System.monotonic_time(:millisecond)
      {:ok, _} = TinctureAuth.suspend_frame(source, frame.id)
      conn = Task.await(stream, 10_000)
      closed_in = System.monotonic_time(:millisecond) - suspended_at

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == [TinctureWire.stream_content_type()]

      assert [
               %{event: "mcp_servers.changes", data: %{"kind" => "changed"}},
               %{event: "refusal", data: %{"class" => "forbidden"}}
             ] = EventStream.decode(conn.resp_body)

      # The session-freshness bound and the stream's own tick.
      assert closed_in < 5_000
      refute conn.resp_body =~ "tenant:"
      refute subscribed?(source)

      assert Arca.Repo.exists?(
               from(d in Arca.Schemas.DecisionLog,
                 where: d.tool == "stream:mcp_servers.changes" and d.admission == "admitted"
               )
             )
    end

    for act <- [:suspend_frame, :revoke_frame] do
      @tag act: act
      test "ends at once when its frame's credential is #{act}, its announcement and not the freshness bound closing it",
           %{source: source, frame: frame, act: act} do
        # A freshness bound no case outlasts: only the announcement can
        # close the stream within this case.
        bound = Application.get_env(:sanctum, :caller_memo_ttl_ms)

        on_exit(fn ->
          if bound,
            do: Application.put_env(:sanctum, :caller_memo_ttl_ms, bound),
            else: Application.delete_env(:sanctum, :caller_memo_ttl_ms)
        end)

        Application.put_env(:sanctum, :caller_memo_ttl_ms, 600_000)

        stream = open_stream(frame.bearer)
        wait_until(fn -> subscribed?(source) end, @stream_ms)

        {:ok, _} = apply(TinctureAuth, act, [source, frame.id])
        assert {:ok, conn} = Task.yield(stream, 5_000) || Task.shutdown(stream)

        # A suspended frame is the shell's to show again; a revoked bearer
        # opens nothing.
        class = if act == :suspend_frame, do: "forbidden", else: "unauthenticated"

        assert [%{event: "refusal", data: %{"class" => ^class}}] =
                 EventStream.decode(conn.resp_body)

        refute subscribed?(source)
      end
    end

    test "bound to its holder is each person's own, and a named subject is refused",
         %{source: source} do
      digest =
        tincture!(
          source,
          "confirm-dash",
          %{"streams" => [%{"name" => "confirmation.changes"}]},
          []
        )

      other = person!("bystander")
      mine = frame!(source, "confirm-dash", digest)
      theirs = frame!(other, "confirm-dash", digest)

      # A subject from the frame is never taken, the holder's own included.
      for subject <- [other.user_id, source.user_id] do
        body =
          TinctureWire.request(:stream_open, %{stream: "confirmation.changes", subject: subject})

        conn = data(:stream_open, body, bearer: mine.bearer)
        assert conn.status == 403
        assert %{message: message} = refused(conn, :stream_open)
        assert message =~ "does not declare that stream"
      end

      body = TinctureWire.request(:stream_open, %{stream: "confirmation.changes", subject: nil})
      my_stream = Task.async(fn -> data(:stream_open, body, bearer: mine.bearer) end)
      their_stream = Task.async(fn -> data(:stream_open, body, bearer: theirs.bearer) end)

      actor = Sanctum.Context.actor(source)
      my_topic = Cyfr.Bus.confirmations(actor, source.user_id)
      their_topic = Cyfr.Bus.confirmations(actor, other.user_id)
      wait_until(fn -> Registry.lookup(Cyfr.PubSub, my_topic) != [] end, @stream_ms)
      wait_until(fn -> Registry.lookup(Cyfr.PubSub, their_topic) != [] end, @stream_ms)

      ref = Prima.Confirmation.ref("cnf_" <> String.duplicate("A", 43))

      opened =
        Cyfr.Bus.Confirmation.new(actor, :opened,
          ref: ref,
          operation: "vault.create",
          expires_at: ~U[2026-10-09 12:05:00Z]
        )

      :ok = Cyfr.Bus.broadcast(actor, my_topic, opened)

      # A stream re-establishes its caller before delivering once its
      # context is past the freshness bound, so a frame revoked before the
      # event is delivered takes the event with it. The revocation waits
      # until the stream has taken the event and is waiting for the next.
      wait_until(fn -> delivered?(my_stream.pid, Cyfr.Bus.Confirmation) end, @stream_ms)

      for {frame, ctx} <- [{mine, source}, {theirs, other}],
          do: {:ok, _} = TinctureAuth.revoke_frame(ctx, frame.id)

      mine_body = Task.await(my_stream, 10_000).resp_body
      theirs_body = Task.await(their_stream, 10_000).resp_body

      assert [
               %{
                 event: "confirmation.changes",
                 data: %{"ref" => ^ref, "kind" => "opened", "operation" => "vault.create"} = event
               }
               | _closing
             ] = EventStream.decode(mine_body)

      # The projection carries no person and no athanor.
      refute Map.has_key?(event, "user_id")
      refute Map.has_key?(event, "athanor_id")

      refute Enum.any?(
               EventStream.decode(theirs_body),
               &(&1.event == "confirmation.changes")
             )
    end

    test "holds one of its frame's open-stream slots, released when it closes",
         %{source: source, frame: frame} do
      Cyfr.Test.Settings.put("frame_stream_max_concurrent", 1)

      first = open_stream(frame.bearer)
      wait_until(fn -> subscribed?(source) end, @stream_ms)

      body = TinctureWire.request(:stream_open, %{stream: "mcp_servers.changes", subject: nil})
      over = data(:stream_open, body, bearer: frame.bearer)
      assert over.status == 429
      assert %{class: "rate_limited"} = refused(over, :stream_open)

      # Another frame's budget is its own.
      other = frame!(source, "live-dash", digest_of("live-dash"))
      second = open_stream(other.bearer)

      {:ok, _} = TinctureAuth.suspend_frame(source, frame.id)
      Task.await(first, 10_000)
      {:ok, _} = TinctureAuth.resume_frame(source, frame.id)

      # The closed stream released its slot: a reconnect is a new open.
      third = open_stream(frame.bearer)
      wait_until(fn -> length(Registry.lookup(Cyfr.PubSub, topic(source))) == 2 end, @stream_ms)

      for {stream, id} <- [{second, other.id}, {third, frame.id}] do
        {:ok, _} = TinctureAuth.revoke_frame(source, id)
        assert Task.await(stream, 10_000).status == 200
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The frame's flows
  # ---------------------------------------------------------------------------

  @origin "api.flows.example"
  @elsewhere "*.elsewhere.example"
  @echo %{"ref" => "reagent:local.echo", "reason" => "echo"}

  # The tincture's head grant of `kind` at `revision`, whose ingress edge
  # on the tincture's own node declares `flows` (`{class, exit}` pairs);
  # its policy is `policy` when a case spells one. A second grant of the
  # same tincture and kind replaces the first. Answers the revision.
  defp grant!(source, name, kind, flows, revision \\ 1, policy \\ nil) do
    node = "tincture:local.#{name}"
    policy = policy || policy(name, flows)

    # An owner grant replaces the one a frame was granted under
    # (`Sanctum.Test.ConsentFixtures.grant_tincture!/3`'s profile).
    id =
      if kind == :owner,
        do: "prof_" <> String.replace(name, "-", "_"),
        else: "prof_flows_#{name}_#{kind}"

    :ok =
      Sanctum.Test.ConsentFixtures.seed_head!(
        source,
        %{id: id, kind: kind, source_ref: node, label: to_string(kind), status: :active},
        %{
          id: "cons_#{id}_#{revision}",
          revision: revision,
          scope: :versionless,
          pinned_version: "",
          invoke_mode: if(kind == :public, do: :edge_only, else: :open_inert),
          shape_digest: :live,
          commit_digest: "sha256:commit",
          resolved_policy: policy,
          activation: %{node => "sha256:act"}
        }
      )

    revision
  end

  # A grant of the tincture `name` whose own node's ingress edge declares
  # `flows` and nothing else.
  defp policy(name, flows) do
    ingress = if flows == [], do: %{}, else: %{"flows" => Enum.map(flows, &flow/1)}

    Jason.encode!(%{
      "canonical" => "jcs-1",
      "nodes" => %{
        "tincture:local.#{name}" => %{
          "limits" => Prima.Test.AuthorityFixtures.limits_map(),
          "edges" => %{"@ingress" => ingress}
        }
      }
    })
  end

  defp flow({class, exit}), do: %{"from" => Atom.to_string(class), "to" => exit}

  # A flow of every class to `exit`.
  defp every_class_to(exit), do: Enum.map(Prima.Source.classes(), &{&1, exit})

  defp invoke(opts) do
    body =
      TinctureWire.request(
        :invoke,
        Map.merge(
          %{ref: "reagent:local.echo:1.0.0", operation: "run", args: %{}},
          Map.new(Keyword.take(opts, [:public]))
        )
      )

    data(:invoke, body, Keyword.take(opts, [:bearer]))
  end

  defp executions, do: Arca.Repo.all(Arca.Schemas.Execution)

  # The request-log rows of the gate's `tincture` operation called on
  # `route` (`invoke_protected`, `invoke_public`): a refusal made here is
  # the route's own row, named `invoke`.
  defp invoked(route), do: Enum.filter(mcp_rows("tincture"), &(&1.action == route))

  # A tincture `name` reading `flow_probe.filed` that connects to
  # `connect` and declares `flows` (`{class, to}` pairs), granted through
  # the consent commit the person makes from its preview: its frame, and
  # the classes the preview showed flowing to each exit.
  defp previewed_frame!(source, name, connect, flows) do
    manifest = %{
      "name" => name,
      "type" => "tincture",
      "version" => @version,
      "publisher" => "local",
      "tincture" => %{
        "entry" => "index.html",
        "connect" => connect,
        "actions" => ["flow_probe.filed"]
      },
      "caps" => %{"flows" => Enum.map(flows, &flow/1)}
    }

    assert :ok = Prima.Manifest.validate(manifest, fn _ -> true end)
    digest = put_version!(source, name, manifest)
    decisions = %{ref: "tincture:local.#{name}"}
    {:ok, plan} = Sanctum.Consent.Plan.plan(source, decisions)
    {:ok, preview} = Sanctum.Consent.Commit.preview(source, decisions)

    {:ok, committed} =
      Sanctum.Consent.Commit.commit(source, %{
        decisions: decisions,
        plan_token: plan.plan_token,
        proof: preview.proof,
        commit_digest: preview.commit_digest,
        expected_consent_revision: plan.expected_consent_revision
      })

    shown =
      for %{"kind" => "exits", "values" => %{"exit" => exit, "flows" => classes}} <- plan.rows,
          into: %{},
          do: {exit, classes}

    {frame!(source, name, digest, committed.revision), shown}
  end

  describe "a frame that connects beyond its endpoint" do
    test "an origin under a declared pattern is read with the pattern's flows, as the preview " <>
           "showed them flowing to it",
         %{source: source} do
      Sanctum.Catalog.with_providers([FiledProbe], fn ->
        Process.register(self(), :tincture_flow_probe)

        {frame, shown} =
          previewed_frame!(source, "inherited-origin", ["*.flows.example", @origin], [
            {:filed, "*.flows.example"}
          ])

        assert shown[@origin] == ["filed"]
        conn = action(frame.bearer, "flow_probe.filed")

        assert conn.status == 200
        assert {:ok, _answer} = answer(conn, :action)
        assert_receive :flow_probe_read, @stream_ms
      end)
    end

    test "an origin under no declared pattern is shown no flow and refused the read",
         %{source: source} do
      Sanctum.Catalog.with_providers([FiledProbe], fn ->
        Process.register(self(), :tincture_flow_probe)
        unflowed = "api.unflowed.example"

        {frame, shown} =
          previewed_frame!(source, "uncovered-origin", ["*.flows.example", unflowed], [
            {:filed, "*.flows.example"}
          ])

        assert shown[unflowed] == []
        conn = action(frame.bearer, "flow_probe.filed")

        assert conn.status == 403
        assert %{class: "forbidden", message: message} = refused(conn, :action)
        assert message == Prima.Flow.sentence([:filed], unflowed)
        refute_received :flow_probe_read
      end)
    end

    test "a file read carries what an unrecorded file is, outside material, beside the grant's own class",
         %{source: source} do
      actor = Sanctum.Context.actor(source)
      assert {:ok, _} = Arca.Files.write(actor, "data/legacy-outside.txt", "OUTSIDE-BYTES")
      name = "file-flow"
      digest = tincture!(source, name, %{"connect" => [@origin], "actions" => ["file.read"]}, [])
      revision = grant!(source, name, :owner, [{:files_by_grant, @origin}])
      frame = frame!(source, name, digest, revision)

      body =
        TinctureWire.request(:action, %{
          operation: "file.read",
          args: %{"path" => "data/legacy-outside.txt"}
        })

      conn = data(:action, body, bearer: frame.bearer)
      assert conn.status == 403
      assert %{class: "forbidden", message: message} = refused(conn, :action)
      assert message =~ "outside"
    end

    test "an action whose answer may carry a class with no flow to the origin is refused " <>
           "before it is read; with the flow it is read",
         %{source: source} do
      Sanctum.Catalog.with_providers([FiledProbe], fn ->
        Process.register(self(), :tincture_flow_probe)
        name = "flow-act"

        digest =
          tincture!(
            source,
            name,
            %{"connect" => [@origin], "actions" => ["flow_probe.filed"]},
            []
          )

        # Outside material may reach the origin; filed material may not.
        frame = frame!(source, name, digest, grant!(source, name, :owner, [{:outside, @origin}]))
        conn = action(frame.bearer, "flow_probe.filed")

        assert conn.status == 403

        assert %{class: "forbidden", stage: "admission", message: message} =
                 refused(conn, :action)

        assert message == Prima.Flow.sentence([:filed], @origin)
        refute_received :flow_probe_read

        # The one decision is this route's refusal, recorded as the frame's
        # person's: the gate never saw the read.
        assert [row] = Arca.Repo.all(Arca.Schemas.DecisionLog)

        assert {row.tool, row.action, row.admission, row.refusal_class, row.user_id} ==
                 {"tincture", "system_action", "refused", "forbidden", source.user_id}

        assert row.reason == message

        # Granted again with filed material let flow there, it is read.
        revision = grant!(source, name, :owner, [{:filed, @origin}], 2)
        conn = action(frame!(source, name, digest, revision).bearer, "flow_probe.filed")

        assert conn.status == 200
        assert {:ok, _answer} = answer(conn, :action)
        assert_receive :flow_probe_read, @stream_ms
      end)
    end

    test "an invoke, whose result may carry every class, needs a flow of each to every origin " <>
           "before it runs",
         %{source: source} do
      name = "flow-inv"
      digest = tincture!(source, name, %{"connect" => [@origin, @elsewhere]}, [@echo])

      # Every class may reach the first origin, none the second.
      revision = grant!(source, name, :owner, every_class_to(@origin))
      conn = invoke(bearer: frame!(source, name, digest, revision).bearer)

      assert conn.status == 403
      assert %{class: "forbidden", message: message} = refused(conn, :invoke)
      assert message == Prima.Flow.sentence(Prima.Source.classes(), @elsewhere)

      # Nothing ran: the one row is the route's refusal, the gate's tincture
      # operation was never called, and no run was admitted.
      assert [%{action: "invoke", refusal_class: "forbidden", error: ^message}] =
               mcp_rows("tincture")

      assert executions() == []

      revision =
        grant!(source, name, :owner, every_class_to(@origin) ++ every_class_to(@elsewhere), 2)

      conn = invoke(bearer: frame!(source, name, digest, revision).bearer)
      refute conn.resp_body =~ "declares no flow"
      assert [_called] = invoked("invoke_protected")
    end

    test "a stream needs a flow of what its events may carry before it opens",
         %{source: source} do
      name = "flow-live"

      digest =
        tincture!(
          source,
          name,
          %{"connect" => [@origin], "streams" => [%{"name" => "mcp_servers.changes"}]},
          []
        )

      # No grant declares no flow. A refusal answers at once; a stream that
      # opened instead would hold the request until it ends.
      body = TinctureWire.request(:stream_open, %{stream: "mcp_servers.changes", subject: nil})
      bearer = frame!(source, name, digest).bearer
      refusal = Task.async(fn -> data(:stream_open, body, bearer: bearer) end)

      conn =
        case Task.yield(refusal, @stream_ms) || Task.shutdown(refusal, :brutal_kill) do
          {:ok, conn} -> conn
          nil -> flunk("the stream opened instead of being refused")
        end

      assert conn.status == 403
      assert %{class: "forbidden", message: message} = refused(conn, :stream_open)
      assert message == Prima.Flow.sentence([:outside], @origin)
      assert stream_decisions() == []
      refute subscribed?(source)

      frame = frame!(source, name, digest, grant!(source, name, :owner, [{:outside, @origin}]))
      stream = open_stream(frame.bearer)
      wait_until(fn -> subscribed?(source) end, @stream_ms)

      assert [%{admission: "admitted"}] =
               Enum.filter(stream_decisions(), &(&1.tool == "stream:mcp_servers.changes"))

      # The grant rewritten in place, at the revision the frame names, to
      # declare no flow: the open stream's next revalidation ends it with
      # the refusal, within the bound.
      policy = policy(name, [])

      :ok =
        Sanctum.Test.ConsentFixtures.hand_edit_head!(
          source,
          "prof_" <> String.replace(name, "-", "_"),
          resolved_policy: policy,
          blob_digest: Prima.Digest.sha256(policy)
        )

      conn = Task.await(stream, 10_000)
      assert conn.status == 200

      assert %{event: "refusal", data: %{"class" => "forbidden", "message" => ^message}} =
               conn.resp_body |> EventStream.decode() |> List.last()

      refute subscribed?(source)
    end

    test "a public page's invoke is held to its public profile's flows", %{source: source} do
      name = "flow-pub"
      tincture!(source, name, %{"connect" => [@origin]}, [@echo])
      public = %{athanor: "test", publisher: "local", name: name}

      grant!(source, name, :public, [])
      conn = invoke(public: public)

      assert conn.status == 403
      assert %{class: "forbidden", message: message} = refused(conn, :invoke)
      assert message == Prima.Flow.sentence(Prima.Source.classes(), @origin)
      assert invoked("invoke_public") == []

      grant!(source, name, :public, every_class_to(@origin), 2)
      conn = invoke(public: public)

      refute conn.resp_body =~ "declares no flow"
      assert [_called] = invoked("invoke_public")
    end

    test "a grant that cannot be trusted refuses the read as damage", %{source: source} do
      name = "flow-damaged"
      digest = tincture!(source, name, %{"connect" => [@origin]}, [@echo])

      # A head whose grant holds no node of its own, so no ingress.
      revision =
        grant!(source, name, :owner, [], 1, ~s({"canonical":"jcs-1","nodes":{}}))

      conn = invoke(bearer: frame!(source, name, digest, revision).bearer)

      assert %{class: "corrupt"} = refused(conn, :invoke)
      assert invoked("invoke_protected") == []
    end

    test "a tincture that connects nowhere, and a canvas, read nothing of the grant",
         %{source: source} do
      # A head whose ingress declares no flow at all, which the frame's
      # revision names: nothing it reads needs one.
      digest = declared!(source, "plain-flows")
      revision = grant!(source, "plain-flows", :owner, [])
      frame = frame!(source, "plain-flows", digest, revision)

      assert action(frame.bearer, "system.status").status == 200

      canvas = canvas!(source, "flow-canvas", [%{"name" => "mcp_servers.changes"}])
      grant!(source, "flow-canvas", :owner, [])
      mine = frame!(source, "flow-canvas", canvas, 1)

      stream =
        Task.async(fn ->
          canvas_stream(mine.frame_id, "mcp_servers.changes", nil, bearer: mine.bearer)
        end)

      wait_until(fn -> subscribed?(source) end, @stream_ms)
      {:ok, _} = TinctureAuth.revoke_frame(source, mine.id)
      assert Task.await(stream, 10_000).status == 200
    end
  end

  # ---------------------------------------------------------------------------
  # A canvas
  # ---------------------------------------------------------------------------

  # A request on the canvas data path of the open `frame_id` names.
  defp canvas_stream(frame_id, stream, subject, opts \\ []) do
    body = TinctureWire.request(:stream_open, %{stream: stream, subject: subject})
    data(:stream_open, body, Keyword.put(opts, :path, Prima.TinctureWire.stream_path(frame_id)))
  end

  # The hidden trial the shell opens a canvas version in: its credential,
  # row id and frame id.
  defp validation!(source, name, digest) do
    reference = %{publisher: "local", name: name, version: @version}
    frame = frame_id()
    revision = standing_revision!(source, name)

    {:ok, %{credential: bearer, id: id}} =
      TinctureAuth.mint_validation_credential(source, reference, digest, revision, frame)

    %{bearer: bearer, id: id, frame_id: frame}
  end

  # Every stream decision the gate recorded: an open admitted or refused.
  defp stream_decisions,
    do: Arca.Repo.all(from(d in Arca.Schemas.DecisionLog, where: like(d.tool, "stream:%")))

  # The probes a canvas's streams need here, planted for `fun` beside the
  # configured providers. The feeds' results stand in for their provider's
  # declaration only while that provider does not exist; once it does,
  # nothing is planted for them, and the table must name the stream as the
  # canvas declares it.
  defp with_streams(fun) do
    feed_provider? = Code.ensure_loaded?(Opus.Providers.Feed)
    planted = if feed_provider?, do: [ShapedProbe], else: [ShapedProbe, FeedProbe]

    Sanctum.Catalog.with_providers(planted, fn ->
      if feed_provider?,
        do:
          assert(
            {:ok, _declared} =
              Prima.Provider.fetch_stream(Sanctum.Catalog.streams(), "feed.results")
          )

      fun.()
    end)
  end

  defp feed_binding(name) do
    {:ok, binding} =
      Prima.Feed.Binding.validate(%{
        "name" => name,
        "label" => "Feed #{name}",
        "reference" => "catalyst:local.markets",
        "operation" => "quote",
        "args" => %{"symbol" => String.upcase(name)},
        "interval_minutes" => 5,
        "result_shape" => %{
          "type" => "object",
          "fields" => %{
            "price" => %{"type" => "number"},
            "at" => %{"type" => "time"},
            "tags" => %{"type" => "list", "of" => %{"type" => "string", "max" => 16}}
          },
          "required" => ["price"]
        },
        "actions" => [%{"name" => "refresh", "label" => "Refresh", "kind" => "refresh"}]
      })

    binding
  end

  describe "a canvas path" do
    setup %{source: source} do
      digest = canvas!(source, "home-canvas", [%{"name" => "mcp_servers.changes"}])
      {:ok, digest: digest, mine: frame!(source, "home-canvas", digest)}
    end

    test "a canvas path refuses another frame's bearer before any charge or grant", %{
      source: source,
      digest: digest,
      mine: mine
    } do
      Cyfr.Test.Settings.put("frame_invocation_max", 1)
      Cyfr.Test.Settings.put("frame_invocation_window_ms", 60_000)

      # Another open of the same canvas, and a frame of a tincture that is
      # not a canvas: neither bearer opens this open's path.
      other = frame!(source, "home-canvas", digest)
      plain = frame!(source, "plain-dash", declared!(source, "plain-dash"))

      for bearer <- [other.bearer, plain.bearer, other.bearer] do
        conn = canvas_stream(mine.frame_id, "mcp_servers.changes", nil, bearer: bearer)
        assert conn.status == 403

        assert %{class: "forbidden", stage: "admission", message: message} =
                 refused(conn, :stream_open)

        assert message =~ "(frame_path_mismatch)"
        refute message =~ mine.frame_id
        refute message =~ other.frame_id
      end

      # No authority was derived: each refusal is recorded under no person,
      # and nothing reached the gate.
      assert [_, _, _] = refusals = decisions("tincture")

      assert Enum.all?(
               refusals,
               &(&1.action == "canvas_stream" and &1.admission == "refused" and
                   is_nil(&1.user_id))
             )

      assert stream_decisions() == []

      # Nothing was charged: the other open's one request in the window is
      # still its own, and is spent on its own path, where the charge then
      # holds.
      undeclared =
        canvas_stream(other.frame_id, "executions.deltas", "exec_1", bearer: other.bearer)

      assert undeclared.status == 403
      assert %{message: message} = refused(undeclared, :stream_open)
      assert message =~ "does not declare that stream"

      over = canvas_stream(other.frame_id, "executions.deltas", "exec_1", bearer: other.bearer)
      assert over.status == 429

      # Before the grant: with the canvas's version moved, the bearer of this
      # open is refused on another open's path for the path, its version
      # unread, and on its own path for the version.
      {1, _} =
        Arca.Repo.update_all(
          from(c in Arca.Schemas.Component, where: c.name == "home-canvas"),
          set: [release_digest: "sha256:" <> String.duplicate("f", 64)]
        )

      elsewhere = canvas_stream(other.frame_id, "mcp_servers.changes", nil, bearer: mine.bearer)
      assert %{message: message} = refused(elsewhere, :stream_open)
      assert message =~ "(frame_path_mismatch)"

      own = canvas_stream(mine.frame_id, "mcp_servers.changes", nil, bearer: mine.bearer)
      assert own.status == 403
      assert %{message: message} = refused(own, :stream_open)
      assert message =~ "changed since its frame opened"
    end

    test "a canvas path refuses a non-canvas frame", %{source: source} do
      plain = frame!(source, "plain-path", declared!(source, "plain-path"))

      conn = canvas_stream(plain.frame_id, "mcp_servers.changes", nil, bearer: plain.bearer)
      assert conn.status == 403
      assert %{class: "forbidden", message: message} = refused(conn, :stream_open)
      assert message =~ "(not_a_canvas)"

      # Its own frame, refused for where it asked: recorded as its person's,
      # and nothing opened.
      assert [row] = decisions("tincture")

      assert {row.action, row.admission, row.user_id} ==
               {"canvas_stream", "refused", source.user_id}

      assert stream_decisions() == []
    end

    test "takes no public page's request", %{mine: mine} do
      public = %{athanor: "test", publisher: "local", name: "home-canvas"}
      path = Prima.TinctureWire.stream_path(mine.frame_id)

      body =
        TinctureWire.request(:stream_open, %{
          stream: "mcp_servers.changes",
          subject: nil,
          public: public
        })

      none = data(:stream_open, body, path: path)
      assert none.status == 401
      assert %{class: "unauthenticated"} = refused(none, :stream_open)

      both = data(:stream_open, body, path: path, bearer: mine.bearer)
      assert both.status == 400
      assert %{class: "invalid_argument"} = refused(both, :stream_open)

      bare = canvas_stream(mine.frame_id, "mcp_servers.changes", nil)
      assert bare.status == 401
      assert stream_decisions() == []
    end

    test "a live canvas frame's stream is opened through the gate on its own path", %{
      source: source,
      mine: mine
    } do
      stream =
        Task.async(fn ->
          canvas_stream(mine.frame_id, "mcp_servers.changes", nil, bearer: mine.bearer)
        end)

      wait_until(fn -> subscribed?(source) end, @stream_ms)
      {:ok, _} = TinctureAuth.revoke_frame(source, mine.id)
      conn = Task.await(stream, 10_000)

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == [TinctureWire.stream_content_type()]
      assert [%{event: "refusal"}] = EventStream.decode(conn.resp_body)
      refute subscribed?(source)

      assert [%{admission: "admitted"}] =
               Enum.filter(stream_decisions(), &(&1.tool == "stream:mcp_servers.changes"))
    end

    test "the shared routes refuse a canvas credential", %{
      source: source,
      digest: digest,
      mine: mine
    } do
      Cyfr.Test.Settings.put("frame_invocation_max", 1)
      Cyfr.Test.Settings.put("frame_invocation_window_ms", 60_000)
      trial = validation!(source, "home-canvas", digest)

      requests = [
        invoke:
          TinctureWire.request(:invoke, %{
            ref: "reagent:local.echo:1.0.0",
            operation: "run",
            args: %{}
          }),
        action: TinctureWire.request(:action, %{operation: "system.status", args: %{}}),
        stream_open:
          TinctureWire.request(:stream_open, %{stream: "mcp_servers.changes", subject: nil})
      ]

      for frame <- [mine, trial], {kind, body} <- requests do
        conn = data(kind, body, bearer: frame.bearer)
        assert conn.status == 403
        assert %{class: "forbidden", stage: "admission", message: message} = refused(conn, kind)
        assert message =~ "(canvas_path_required)"
      end

      # Nothing ran and nothing opened: every decision is this route's
      # refusal, recorded as the frame's person's.
      assert [_, _, _, _, _, _] = refusals = decisions("tincture")
      assert Enum.all?(refusals, &(&1.admission == "refused" and &1.user_id == source.user_id))
      assert decisions("system") == []
      assert stream_decisions() == []

      # The refusals came before the charge: the open's one request in the
      # window is spent on its own path.
      undeclared =
        canvas_stream(mine.frame_id, "executions.deltas", "exec_1", bearer: mine.bearer)

      assert undeclared.status == 403
      over = canvas_stream(mine.frame_id, "executions.deltas", "exec_1", bearer: mine.bearer)
      assert over.status == 429
    end

    test "a canvas path has no invoke or action route", %{mine: mine} do
      requests = [
        {"invoke",
         TinctureWire.request(:invoke, %{
           ref: "reagent:local.echo:1.0.0",
           operation: "run",
           args: %{}
         })},
        {"action", TinctureWire.request(:action, %{operation: "system.status", args: %{}})}
      ]

      for {route, body} <- requests do
        path = Prima.TinctureWire.data_path(mine.frame_id) <> route
        conn = data(:action, body, bearer: mine.bearer, path: path)
        assert conn.status == 404, path
        refute Map.has_key?(conn.private, :phoenix_action)
      end

      # The router answered: no route reached a controller, and nothing was
      # decided or run.
      assert decisions("tincture") == []
      assert decisions("system") == []
      assert mcp_rows("tincture") == []
    end
  end

  describe "a canvas's validation trial" do
    test "a validation credential is answered from fixtures without an admission", %{
      source: source
    } do
      with_streams(fn ->
        digest =
          canvas!(source, "trial-canvas", [
            %{"name" => "probe.shaped"},
            %{"name" => "mcp_servers.changes"}
          ])

        trial = validation!(source, "trial-canvas", digest)
        Cyfr.Test.Settings.put("frame_invocation_max", 3)
        Cyfr.Test.Settings.put("frame_invocation_window_ms", 60_000)
        Cyfr.Test.Settings.put("frame_stream_max_concurrent", 1)

        # The trial's one open-stream slot is taken here, under the data
        # routes' slot tag, so an open that claimed one would be refused for
        # it: an answer proves no slot was claimed.
        {:ok, trial_ctx} =
          Sanctum.Caller.establish({:frame_credential, trial.bearer}, client_ip: "127.0.0.1")

        assert trial_ctx.frame.mode == :validation
        :ok = CyfrWeb.SSE.claim_slot(:frame_stream, trial_ctx, :frame_stream_max_concurrent)

        {:ok, %{shape: shape}} =
          Prima.Provider.fetch_stream(Sanctum.Catalog.streams(), "probe.shaped")

        shaped = canvas_stream(trial.frame_id, "probe.shaped", nil, bearer: trial.bearer)
        assert shaped.status == 200
        assert get_resp_header(shaped, "content-type") == [TinctureWire.stream_content_type()]

        # One event, its data the fixture of the stream's shape, then the end.
        assert [%{id: nil, event: "probe.shaped", data: data}] =
                 EventStream.decode(shaped.resp_body)

        assert data == Shape.fixture(shape)
        assert Shape.check(shape, data) == :ok

        # A stream that declares no shape is answered with no event, and ends.
        shapeless =
          canvas_stream(trial.frame_id, "mcp_servers.changes", nil, bearer: trial.bearer)

        assert shapeless.status == 200
        assert EventStream.decode(shapeless.resp_body) == []

        # Charged as any request is: the third is the window's last.
        assert canvas_stream(trial.frame_id, "probe.shaped", nil, bearer: trial.bearer).status ==
                 200

        over = canvas_stream(trial.frame_id, "probe.shaped", nil, bearer: trial.bearer)
        assert over.status == 429

        # Nothing was admitted: the gate decided nothing, opened no stream,
        # and no request of the trial was recorded as admitted.
        assert stream_decisions() == []

        refute Arca.Repo.exists?(
                 from(d in Arca.Schemas.DecisionLog, where: d.admission == "admitted")
               )

        CyfrWeb.SSE.release_slot(:frame_stream, trial_ctx)
      end)
    end

    test "a feed fixture follows the binding's result shape", %{source: source} do
      with_streams(fn ->
        digest =
          canvas!(source, "feed-canvas", [
            %{"name" => "feed.results", "subject" => "btc"},
            %{"name" => "feed.results", "subject" => "eth"}
          ])

        trial = validation!(source, "feed-canvas", digest)
        binding = feed_binding("btc")

        {:ok, feed} =
          Arca.CronSchedule.create_feed(Sanctum.Context.actor(source), %{
            binding: binding,
            resolved_reference: "catalyst:local.markets:1.0.0",
            profile_id: "prof_canvas_feed",
            cap: 1_000
          })

        bound = canvas_stream(trial.frame_id, "feed.results", "btc", bearer: trial.bearer)
        assert bound.status == 200

        assert [%{id: nil, event: "feed.results", data: data}] =
                 EventStream.decode(bound.resp_body)

        # The binding's envelope at its first revision and the epoch, its
        # result the fixture of the binding's result shape.
        result = Shape.fixture(binding.result_shape)
        envelope = Prima.Feed.envelope(feed.id, binding, 0, ~U[1970-01-01 00:00:00Z], result)
        assert data == Jason.decode!(Jason.encode!(envelope))

        assert %{"binding" => id, "feed" => "btc", "revision" => 0} = data
        assert data["at"] == "1970-01-01T00:00:00Z"
        assert id == feed.id
        assert Shape.check(binding.result_shape, data["result"]) == :ok
        refute Enum.any?(~w(operation args reference), &Map.has_key?(data, &1))

        # A name the canvas declares and the athanor does not bind: no event.
        unbound = canvas_stream(trial.frame_id, "feed.results", "eth", bearer: trial.bearer)
        assert unbound.status == 200
        assert EventStream.decode(unbound.resp_body) == []

        # A name the canvas does not declare is refused by its declaration.
        undeclared = canvas_stream(trial.frame_id, "feed.results", "doge", bearer: trial.bearer)
        assert undeclared.status == 403

        assert stream_decisions() == []
      end)
    end

    test "a feeds read that cannot answer is refused unavailable before the stream opens", %{
      source: source
    } do
      with_streams(fn ->
        digest =
          canvas!(source, "outage-canvas", [%{"name" => "feed.results", "subject" => "btc"}])

        trial = validation!(source, "outage-canvas", digest)

        # The feeds' table fails, and the test's transaction gives it back:
        # nothing is read after the request.
        Arca.Repo.query!("ALTER TABLE cron_schedules RENAME TO cron_schedules_unavailable")
        conn = canvas_stream(trial.frame_id, "feed.results", "btc", bearer: trial.bearer)

        # The wire's refusal, not an event stream that says nothing.
        assert conn.status == 503
        refute get_resp_header(conn, "content-type") == [TinctureWire.stream_content_type()]

        assert %{class: "unavailable", stage: "admission"} = refused(conn, :stream_open)
      end)
    end
  end

  describe "a renewed credential" do
    test "keeps a canvas's open stream past the deadline of the bearer it opened with, in its one slot, until the credential is revoked",
         %{source: source} do
      Cyfr.Test.Settings.put("frame_stream_max_concurrent", 1)

      # Every revalidation tick re-establishes the stream, so it reads the
      # renewal well inside the first bearer's four seconds.
      bound = Application.get_env(:sanctum, :caller_memo_ttl_ms)

      on_exit(fn ->
        if bound,
          do: Application.put_env(:sanctum, :caller_memo_ttl_ms, bound),
          else: Application.delete_env(:sanctum, :caller_memo_ttl_ms)
      end)

      Application.put_env(:sanctum, :caller_memo_ttl_ms, 200)

      # The first bearer lives four seconds; its renewal, an hour.
      Cyfr.Test.Settings.put("frame_credential_deadline_s", 4)
      digest = canvas!(source, "renewed-stream", [%{"name" => "mcp_servers.changes"}])
      frame = frame!(source, "renewed-stream", digest)

      stream =
        Task.async(fn ->
          canvas_stream(frame.frame_id, "mcp_servers.changes", nil, bearer: frame.bearer)
        end)

      on_exit(fn ->
        if Process.alive?(stream.pid), do: Process.exit(stream.pid, :kill)
      end)

      wait_until(
        fn ->
          Enum.any?(Registry.lookup(Cyfr.PubSub, topic(source)), &(elem(&1, 0) == stream.pid))
        end,
        @stream_ms
      )

      Cyfr.Test.Settings.put("frame_credential_deadline_s", 3_600)
      {:ok, %{credential: renewed}} = TinctureAuth.renew_frame(source, frame.id)

      # Past the first bearer's deadline, and through more than one
      # revalidation after it, the stream stands on its one connection.
      monitor = Process.monitor(stream.pid)

      assert {:error, :expired_credential} =
               wait_for_expiry(frame.bearer, :timer.seconds(8))

      refute_receive {:DOWN, ^monitor, :process, _pid, _reason}, 2_500
      assert Enum.any?(Registry.lookup(Cyfr.PubSub, topic(source)), &(elem(&1, 0) == stream.pid))

      # Its slot is the frame's one: the renewed bearer opens no second.
      second = canvas_stream(frame.frame_id, "mcp_servers.changes", nil, bearer: renewed)
      assert %{class: "rate_limited"} = refused(second, :stream_open)

      {:ok, _} = TinctureAuth.revoke_frame(source, frame.id)
      conn = Task.await(stream, @stream_ms)
      assert [%{event: "refusal"}] = EventStream.decode(conn.resp_body)
    end

    defp wait_for_expiry(bearer, within_ms) do
      wait_until(
        fn -> TinctureAuth.verify_frame_credential(bearer) == {:error, :expired_credential} end,
        within_ms
      )

      TinctureAuth.verify_frame_credential(bearer)
    end
  end
end
