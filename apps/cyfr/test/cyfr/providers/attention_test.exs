# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Providers.AttentionTest do
  @moduledoc """
  The stream `attention.changes`: what waits for one person, first as the
  refresh lists it and then as the bridge tells it when its record moves.
  Every refresh item and live payload is read as a canvas reads it:
  projected by the grant, passed through JSON and held to the declared
  shape. Each kind enters and leaves; another person hears and lists none
  of it; an operator's item is never one; and no item names a person, a
  message, an argument or a diagnostic.
  """

  # The bus subscriptions and the telemetry the bridge handles are the
  # node's, and the rows are written through the shared sandbox.
  use ExUnit.Case, async: false

  alias Cyfr.Bus
  alias Cyfr.Bus.Attention
  alias Cyfr.Providers.Attention, as: Provider
  alias Prima.Canvas.Shape
  alias Sanctum.Context

  @stream "attention.changes"
  @private "PRIVATE-ATTENTION-5e2b"

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    Sanctum.Test.Newcomers.directory!()
    %{ctx: ctx} = me = person!("me")
    %{ctx: other_ctx} = person!("other")

    :ok = Bus.subscribe(Context.actor(ctx), Bus.attention(Context.actor(ctx), ctx.user_id))

    {:ok, ctx: ctx, actor: Context.actor(ctx), user: me.user, other_ctx: other_ctx}
  end

  # A person with their own athanor, and the context their session
  # establishes there.
  defp person!(label) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Sanctum.Test.People.linked(%{
        id: "github|https://github.com|attention-#{label}-#{n}",
        provider: "github",
        email: "attention-#{label}-#{n}@example.com",
        verified: true
      })

    athanor = Sanctum.Test.People.athanor!(user)

    built =
      Context.build(
        user_id: user.id,
        email: user.email,
        provider: "passkey",
        athanor_id: athanor.id,
        permissions: [:*],
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, session} = Sanctum.TestContext.create_session(built)
    {:ok, ctx} = Sanctum.Caller.establish(session.token, focus: athanor.id, refresh: false)
    %{user: user, athanor: athanor, ctx: ctx}
  end

  # ---------------------------------------------------------------------------
  # The declaration
  # ---------------------------------------------------------------------------

  describe "the declaration" do
    test "is one holder-bound, canvas-readable stream on the attention topic, refreshed" do
      assert [stream] = Provider.streams()
      assert Prima.Provider.Stream.valid?(stream)
      assert stream.name == @stream
      assert stream.topic == :attention
      assert stream.projection == ~w(kind id label since destination outcome revision at)

      assert {stream.key, stream.removal, stream.reread, stream.stale_after} ==
               {"id", "removed", [], 300}

      assert stream.bind == :holder
      assert stream.subject == ~S"\Ausr_[A-Za-z0-9_-]{1,128}\z"
      assert stream.filter == nil
      assert stream.deadline_bound == 86_400
      assert Cyfr.Bus.grantable?(stream.topic, true)

      assert {:ok, stream.shape} == Shape.validate(stream.shape)
      assert Enum.sort(Map.keys(stream.shape["fields"])) == Enum.sort(stream.projection)
      assert Enum.sort(stream.shape["required"]) == Enum.sort(stream.projection)

      assert stream.shape["fields"]["kind"]["values"] ==
               Enum.map(Attention.kinds(), &Atom.to_string/1)

      assert stream.shape["fields"]["outcome"] == %{
               "type" => "enum",
               "values" => ~w(resolved expired withdrawn),
               "nullable" => true
             }

      destination = stream.shape["fields"]["destination"]
      assert destination["fields"]["kind"]["values"] == ["page", "ref"]
      assert destination["fields"]["page"]["values"] == ~w(aqua executions schedules files)

      assert {Provider, :waiting} = stream.refresh
      assert function_exported?(Provider, :waiting, 2)
      assert {:ok, {Provider, ^stream}} = Sanctum.Catalog.lookup_stream(@stream)
      assert Provider.tools() == []
      assert Provider in Sanctum.Catalog.configured_providers()
    end

    test "the canvas catalog lists it with its shape", %{ctx: ctx} do
      {:ok, %{streams: streams}} = Compendium.Canvas.catalog(ctx)
      [listed] = Enum.filter(streams, &(&1.name == @stream))
      [stream] = Provider.streams()
      assert listed.shape == stream.shape
      assert listed.refresh == true
    end

    test "the gate binds it to its holder and refuses another person's subject", %{
      ctx: ctx,
      other_ctx: other_ctx
    } do
      assert {:ok, grant} = Sanctum.Gate.open_stream(ctx, @stream)
      assert grant.subject == ctx.user_id
      assert grant.topic == :attention

      assert Bus.granted_topic(Context.actor(ctx), grant) ==
               Bus.attention(Context.actor(ctx), ctx.user_id)

      assert {:error, %Prima.Refusal{}} =
               Sanctum.Gate.open_stream(ctx, @stream, other_ctx.user_id)
    end
  end

  # ---------------------------------------------------------------------------
  # The refresh
  # ---------------------------------------------------------------------------

  describe "the refresh" do
    test "is empty for a person nothing waits for", %{ctx: ctx} do
      assert {:ok, []} = Provider.waiting(ctx, ctx.user_id)
    end

    test "lists a pending approval with its thread's title, until it is decided or expires", %{
      ctx: ctx,
      actor: actor
    } do
      thread = thread!(actor, "Plan the trip")
      waiting = approval!(actor, thread)
      decided = approval!(actor, thread, status: "approved")
      expired = approval!(actor, thread, expires_at: DateTime.add(DateTime.utc_now(), -60))

      assert [item] = refreshed(ctx)
      assert item["kind"] == "approval"
      assert item["id"] == waiting.id
      assert item["label"] == "Plan the trip"
      assert item["destination"] == %{"kind" => "page", "page" => "aqua", "ref" => thread.id}
      refute item["id"] in [decided.id, expired.id]
    end

    test "lists an open confirmation by its ref and operation", %{ctx: ctx} do
      ref = confirmation!(ctx)

      assert [item] = refreshed(ctx)

      assert %{
               "kind" => "confirmation",
               "id" => ^ref,
               "label" => "vault.create",
               "destination" => %{"kind" => "ref", "page" => nil, "ref" => ^ref}
             } = item

      refute inspect(item) =~ @private
    end

    test "lists the newest failed top-level run of a reference no later run ended after", %{
      ctx: ctx,
      actor: actor
    } do
      me = ctx.user_id
      t = ~U[2026-11-01 10:00:00.000000Z]

      # settled: failed, then completed later.
      run!(actor, me, "reagent:local.settled:1.0.0", "failed", t)
      run!(actor, me, "reagent:local.settled:1.0.0", "completed", DateTime.add(t, 60))
      # standing: completed, then failed twice; the newest failure stands.
      run!(actor, me, "reagent:local.standing:1.0.0", "completed", t)
      run!(actor, me, "reagent:local.standing:1.0.0", "failed", DateTime.add(t, 60))
      newest = run!(actor, me, "reagent:local.standing:1.0.0", "failed", DateTime.add(t, 120))
      # a child's failure is its root's work; another person's is theirs.
      run!(actor, me, "reagent:local.child:1.0.0", "failed", t, parent: newest.id)
      run!(actor, "usr_someone_else", "reagent:local.theirs:1.0.0", "failed", t)

      assert [item] = refreshed(ctx)

      assert item == %{
               "kind" => "failed_run",
               "id" => "reagent:local.standing:1.0.0",
               "label" => "reagent:local.standing:1.0.0",
               "since" => DateTime.to_iso8601(DateTime.add(t, 120)),
               "destination" => %{"kind" => "page", "page" => "executions", "ref" => newest.id},
               "outcome" => nil
             }
    end

    test "lists at most twenty failed runs, the newest", %{ctx: ctx, actor: actor} do
      t = ~U[2026-11-01 10:00:00.000000Z]

      for n <- 1..22,
          do: run!(actor, ctx.user_id, "reagent:local.r#{n}:1.0.0", "failed", DateTime.add(t, n))

      ids = ctx |> refreshed() |> Enum.map(& &1["id"])
      assert length(ids) == 20
      refute "reagent:local.r1:1.0.0" in ids
      refute "reagent:local.r2:1.0.0" in ids
      assert "reagent:local.r22:1.0.0" in ids
    end

    test "lists a schedule whose latest ended occurrence failed, and no other", %{
      ctx: ctx,
      actor: actor
    } do
      t = ~U[2026-11-01 10:00:00.000000Z]
      failing = schedule!(actor, ctx.user_id, "nightly report")
      occurrence!(actor, failing.id, t, "completed")
      occurrence!(actor, failing.id, DateTime.add(t, 60), "failed")
      # A run claimed since has not ended: it still reads failing.
      occurrence!(actor, failing.id, DateTime.add(t, 120), "started")

      recovered = schedule!(actor, ctx.user_id, "recovered")
      occurrence!(actor, recovered.id, t, "uncertain")
      occurrence!(actor, recovered.id, DateTime.add(t, 60), "completed")

      deleted = schedule!(actor, ctx.user_id, "deleted")
      occurrence!(actor, deleted.id, t, "failed")
      {:ok, _} = Arca.CronSchedule.soft_delete(actor, deleted.id)

      theirs = schedule!(actor, "usr_someone_else", "theirs")
      occurrence!(actor, theirs.id, t, "failed")

      assert [item] = refreshed(ctx)

      assert item == %{
               "kind" => "failed_schedule",
               "id" => failing.id,
               "label" => "nightly report",
               "since" => DateTime.to_iso8601(DateTime.add(t, 60)),
               "destination" => %{"kind" => "page", "page" => "schedules", "ref" => failing.id},
               "outcome" => nil
             }
    end

    test "lists an offer to the person once, by its first file, while it is offered and unexpired",
         %{ctx: ctx, other_ctx: other_ctx} do
      offer = offer!(other_ctx, ctx.user_id, ["zeta.csv", "alpha.csv"])
      offer!(other_ctx, ctx.user_id, ["gone.csv"], status: "declined")

      offer!(other_ctx, ctx.user_id, ["late.csv"],
        expires_at: DateTime.add(DateTime.utc_now(), -60)
      )

      offer!(ctx, other_ctx.user_id, ["mine-to-them.csv"])

      assert [item] = refreshed(ctx)

      assert %{
               "kind" => "file_offer",
               "id" => ^offer,
               "label" => "alpha.csv",
               "destination" => %{"kind" => "page", "page" => "files", "ref" => ^offer}
             } = item
    end

    test "is every kind at once, oldest first", %{ctx: ctx, actor: actor, other_ctx: other_ctx} do
      approval!(actor, thread!(actor, "t"))
      confirmation!(ctx)
      run!(actor, ctx.user_id, "reagent:local.x:1.0.0", "failed", ~U[2026-01-01 00:00:00.000000Z])
      schedule = schedule!(actor, ctx.user_id, "s")
      occurrence!(actor, schedule.id, ~U[2026-01-02 00:00:00.000000Z], "failed")
      offer!(other_ctx, ctx.user_id, ["f.csv"])

      items = refreshed(ctx)

      assert items |> Enum.map(& &1["kind"]) |> Enum.sort() ==
               ~w(approval confirmation failed_run failed_schedule file_offer)

      times = Enum.map(items, &elem(DateTime.from_iso8601(&1["since"]), 1))
      assert times == Enum.sort(times, DateTime)
    end

    test "lists none of another person's items, and answers only its holder", %{
      ctx: ctx,
      other_ctx: other_ctx
    } do
      other = Context.actor(other_ctx)
      approval!(other, thread!(other, "theirs"))
      confirmation!(other_ctx)
      run!(other, other_ctx.user_id, "reagent:local.x:1.0.0", "failed", DateTime.utc_now())
      offer!(ctx, other_ctx.user_id, ["to-them.csv"])

      assert {:ok, []} = Provider.waiting(ctx, ctx.user_id)
      assert {:ok, theirs} = Provider.waiting(other_ctx, other_ctx.user_id)
      assert length(theirs) == 4
      assert {:error, :not_holder} = Provider.waiting(ctx, other_ctx.user_id)
      assert {:error, :no_athanor} = Provider.waiting(%{ctx | athanor_id: nil}, ctx.user_id)
    end

    test "lists an athanor's approvals and offers only to the athanor's own person", %{
      ctx: ctx,
      actor: actor,
      other_ctx: other_ctx
    } do
      approval!(actor, thread!(actor, "mine"))
      offer!(other_ctx, ctx.user_id, ["f.csv"])

      # The other person's context focused here: not their athanor.
      stranger = %{ctx | user_id: other_ctx.user_id}
      assert {:ok, []} = Provider.waiting(stranger, other_ctx.user_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Live, from the bridge
  # ---------------------------------------------------------------------------

  describe "live" do
    test "an approval enters when it opens, as the refresh lists it, and leaves when resolved",
         %{ctx: ctx, actor: actor} do
      thread = thread!(actor, "Ship it")
      approval = approval!(actor, thread)

      :ok =
        Sanctum.Notify.broadcast(actor.athanor_id, :approval_pending, %{
          thread_id: thread.id,
          message_id: "msg_1",
          approval_id: approval.id
        })

      assert_receive %Attention{kind: :approval} = entered
      assert [read_as(entered)] == refreshed(ctx)

      resolve!(actor, approval.id)

      :ok =
        Sanctum.Notify.broadcast(actor.athanor_id, :approval_resolved, %{
          thread_id: thread.id,
          message_id: "msg_1",
          approval_id: approval.id,
          decision: "approved"
        })

      assert_receive %Attention{kind: :removed} = left
      assert removed?(left, approval.id, "resolved")
      assert refreshed(ctx) == []
    end

    test "an approval's removal names how its decision ended it", %{actor: actor} do
      for {decision, outcome} <- [
            {"declined", "resolved"},
            {"error", "resolved"},
            {"expired", "expired"},
            {"withdrawn", "withdrawn"}
          ] do
        :ok =
          Sanctum.Notify.broadcast(actor.athanor_id, :approval_resolved, %{
            thread_id: "thr_decided",
            approval_id: "apr_#{decision}",
            decision: decision
          })

        assert_receive %Attention{kind: :removed} = left
        assert removed?(left, "apr_#{decision}", outcome), decision
      end
    end

    test "deleting a thread removes its waiting approval from attention",
         %{ctx: ctx, actor: actor} do
      thread = thread!(actor, "Gone soon")
      approval = approval!(actor, thread)
      assert [%{"kind" => "approval", "id" => id}] = refreshed(ctx)
      assert id == approval.id

      assert {:ok, _deleted} = Aqua.Tape.delete_thread(ctx, thread.id)

      assert_receive %Attention{kind: :removed, id: ^id} = left
      assert removed?(left, id, "withdrawn")
      assert refreshed(ctx) == []
    end

    test "an approval decided before its announcement is read no more, and enters nothing", %{
      actor: actor
    } do
      thread = thread!(actor, "Gone")
      approval = approval!(actor, thread, status: "approved")

      :ok =
        Sanctum.Notify.broadcast(actor.athanor_id, :approval_pending, %{
          thread_id: thread.id,
          approval_id: approval.id
        })

      refute_receive %Attention{}, 200
    end

    test "a confirmation enters on its opening and leaves on each end, never on its proof", %{
      ctx: ctx,
      actor: actor
    } do
      ref = confirmation!(ctx)
      assert_receive %Attention{kind: :confirmation} = entered
      assert [read_as(entered)] == refreshed(ctx)
      refute inspect(entered) =~ @private

      fields = %{
        ref: ref,
        operation: "vault.create",
        opened_at: DateTime.utc_now(),
        expires_at: DateTime.utc_now()
      }

      :ok = Sanctum.Telemetry.confirmation(:confirmed, actor.athanor_id, ctx.user_id, fields)
      refute_receive %Attention{}, 200

      for {stage, outcome} <- [
            consumed: "resolved",
            cancelled: "resolved",
            voided: "withdrawn",
            expired: "expired"
          ] do
        :ok = Sanctum.Telemetry.confirmation(stage, actor.athanor_id, ctx.user_id, fields)
        assert_receive %Attention{kind: :removed} = left
        assert removed?(left, ref, outcome), inspect(stage)
      end
    end

    test "a failed top-level run enters as its reference's item, and the reference's next end settles it",
         %{ctx: ctx, actor: actor} do
      reference = "reagent:local.flaky:1.0.0"
      failed = run!(actor, ctx.user_id, reference, "failed", DateTime.utc_now())
      execute(:exception, actor, ctx.user_id, failed.id, reference, error: "boom #{@private}")

      assert_receive %Attention{kind: :failed_run} = entered
      assert [read_as(entered)] == refreshed(ctx)
      assert entered.id == reference
      assert entered.destination.ref == failed.id
      refute inspect(entered) =~ @private

      execute(:stop, actor, ctx.user_id, "exec_next", reference)
      assert_receive %Attention{kind: :removed} = left
      assert removed?(left, reference, "resolved")
    end

    test "a child's failure or completion, and a cancel, tell nothing", %{ctx: ctx, actor: actor} do
      reference = "reagent:local.child:1.0.0"
      run!(actor, ctx.user_id, reference, "failed", DateTime.utc_now())

      execute(:exception, actor, ctx.user_id, "exec_child", reference, parent_execution_id: "e0")
      execute(:stop, actor, ctx.user_id, "exec_child2", reference, parent_execution_id: "e0")
      execute(:exception, actor, ctx.user_id, "exec_c", reference, status: :cancelled)

      refute_receive %Attention{}, 200
    end

    test "a schedule's failure enters, its completed run settles it, and so does its deletion", %{
      ctx: ctx,
      actor: actor
    } do
      schedule = schedule!(actor, ctx.user_id, "hourly")
      due = ~U[2026-11-01 10:00:00.000000Z]
      occurrence = occurrence!(actor, schedule.id, due, "failed")

      :telemetry.execute([:cyfr, :schedules, :failed], %{count: 1}, %{
        schedule_id: schedule.id,
        kind: "schedule",
        occurrence_id: occurrence.id,
        scheduled_for: due,
        athanor_id: actor.athanor_id,
        user_id: ctx.user_id,
        reason: :damaged_reference
      })

      assert_receive %Attention{kind: :failed_schedule} = entered
      assert [read_as(entered)] == refreshed(ctx)
      refute inspect(entered) =~ @private

      :telemetry.execute([:cyfr, :schedules, :completed], %{duration_ms: 1}, %{
        schedule_id: schedule.id,
        kind: "schedule",
        athanor_id: actor.athanor_id,
        user_id: ctx.user_id
      })

      assert_receive %Attention{kind: :removed} = left
      assert removed?(left, schedule.id, "resolved")

      {:ok, row} = Arca.CronSchedule.soft_delete(actor, schedule.id)
      :ok = Opus.Schedules.Changes.removed(actor, row)
      assert_receive %Attention{kind: :removed} = deleted
      assert removed?(deleted, schedule.id, "withdrawn")
    end

    test "a feed's failure and completion tell nothing", %{ctx: ctx, actor: actor} do
      for event <- [:failed, :completed] do
        :telemetry.execute([:cyfr, :schedules, event], %{count: 1}, %{
          schedule_id: "sch_feed",
          kind: "feed",
          athanor_id: actor.athanor_id,
          user_id: ctx.user_id
        })
      end

      refute_receive %Attention{}, 200
    end

    test "an offer enters its recipient's own attention once per offer and leaves on each end", %{
      ctx: ctx,
      other_ctx: other_ctx
    } do
      offer = offer!(other_ctx, ctx.user_id, ["b.csv", "a.csv"])
      other = Context.actor(other_ctx)
      :ok = Bus.subscribe(other, Bus.attention(other, other_ctx.user_id))

      for filename <- ["b.csv", "a.csv"], do: offered(:offered, offer, other_ctx, ctx, filename)

      assert_receive %Attention{kind: :file_offer} = first
      assert_receive %Attention{kind: :file_offer} = second
      assert read_as(first) == read_as(second)
      assert [read_as(first)] == refreshed(ctx)
      assert first.athanor_id == ctx.athanor_id

      for kind <- [:landed, :failed], do: offered(kind, offer, other_ctx, ctx, "a.csv")
      refute_receive %Attention{}, 200

      for {kind, outcome} <- [
            accepted: "resolved",
            declined: "resolved",
            withdrawn: "withdrawn",
            expired: "expired"
          ] do
        offered(kind, offer, other_ctx, ctx, "a.csv")
        assert_receive %Attention{kind: :removed, athanor_id: athanor} = left
        assert athanor == ctx.athanor_id
        assert removed?(left, offer, outcome), inspect(kind)
      end

      # The sender hears nothing of it on their own attention topic.
      refute_received %Attention{}
    end
  end

  # ---------------------------------------------------------------------------
  # Who hears it
  # ---------------------------------------------------------------------------

  describe "who hears it" do
    test "another person hears none of the person's items", %{
      ctx: ctx,
      actor: actor,
      other_ctx: other_ctx
    } do
      :ok = Bus.unsubscribe(actor, Bus.attention(actor, ctx.user_id))
      other = Context.actor(other_ctx)
      :ok = Bus.subscribe(other, Bus.attention(other, other_ctx.user_id))
      # The other person's topic in this athanor, too.
      :ok = Bus.subscribe(actor, Bus.attention(actor, other_ctx.user_id))

      thread = thread!(actor, "mine")
      approval = approval!(actor, thread)

      :ok =
        Sanctum.Notify.broadcast(actor.athanor_id, :approval_pending, %{approval_id: approval.id})

      confirmation!(ctx)
      failed = run!(actor, ctx.user_id, "reagent:local.x:1.0.0", "failed", DateTime.utc_now())
      execute(:exception, actor, ctx.user_id, failed.id, "reagent:local.x:1.0.0")

      refute_receive %Attention{}, 300
    end

    test "an operator's announcement is never an item", %{actor: actor} do
      for {kind, payload} <- [
            allowlist_request: %{email: "someone@example.com"},
            allowlist_changed: %{},
            passkey_recovered: %{name: "someone"}
          ] do
        :ok = Sanctum.Notify.broadcast_platform(kind, payload)
      end

      # A tray entry of the athanor is not one either.
      :ok = Sanctum.Notify.broadcast(actor.athanor_id, :athanor_changed, %{name: "x"})
      :ok = Sanctum.Notify.broadcast(actor.athanor_id, :execution_failed, %{execution_id: "e1"})

      refute_receive %Attention{}, 200
    end

    test "no item names a person", %{ctx: ctx, actor: actor, other_ctx: other_ctx} do
      approval!(actor, thread!(actor, "t"))
      confirmation!(ctx)
      run!(actor, ctx.user_id, "reagent:local.x:1.0.0", "failed", DateTime.utc_now())
      offer!(other_ctx, ctx.user_id, ["f.csv"])

      text = inspect(refreshed(ctx))
      refute text =~ ctx.user_id
      refute text =~ other_ctx.user_id
      refute text =~ @private
    end
  end

  # ---------------------------------------------------------------------------

  # The refresh as a canvas reads it.
  defp refreshed(ctx) do
    {:ok, items} = Provider.waiting(ctx, ctx.user_id)
    Enum.map(items, &read_as/1)
  end

  # A refresh item or a live payload as a canvas reads it: projected by the
  # grant, passed through JSON, and held to the declared shape, its
  # delivery fields (its revision, its time in microseconds) checked and
  # set aside.
  defp read_as(payload) do
    {:ok, {Provider, stream}} = Sanctum.Catalog.lookup_stream(@stream)

    grant = %Prima.StreamGrant{
      topic: stream.topic,
      projection: stream.projection,
      subject: "usr_reader",
      deadline: DateTime.utc_now(),
      grant_id: "sgr_attention"
    }

    data = grant |> Prima.StreamGrant.project(payload) |> Jason.encode!() |> Jason.decode!()
    assert :ok = Shape.check(stream.shape, data), inspect(data)
    assert Enum.sort(Map.keys(data)) == Enum.sort(stream.projection)
    {:ok, at, 0} = DateTime.from_iso8601(data["at"])
    assert data["revision"] == DateTime.to_unix(at, :microsecond)
    Map.drop(data, ~w(revision at))
  end

  defp removed?(payload, id, outcome) do
    read_as(payload) == %{
      "kind" => "removed",
      "id" => id,
      "label" => nil,
      "since" => nil,
      "destination" => nil,
      "outcome" => outcome
    }
  end

  defp thread!(actor, title) do
    {:ok, thread} = Arca.ThreadStorage.create(actor, %{title: title})
    thread
  end

  defp approval!(actor, thread, opts \\ []) do
    now = DateTime.utc_now()
    turn_id = Prima.UUID7.generate_id("turn")

    Arca.Repo.insert!(%Arca.Schemas.Turn{
      id: turn_id,
      athanor_id: actor.athanor_id,
      thread_id: thread.id,
      status: "running",
      origin: "interactive",
      accepted_at: now,
      fence: 1
    })

    Arca.Repo.insert!(%Arca.Schemas.Approval{
      id: Prima.UUID7.generate_id("apr"),
      athanor_id: actor.athanor_id,
      turn_id: turn_id,
      thread_id: thread.id,
      status: Keyword.get(opts, :status, "pending"),
      proposal_digest: "digest #{@private}",
      expires_at: Keyword.get(opts, :expires_at),
      inserted_at: now
    })
  end

  defp resolve!(actor, approval_id) do
    import Ecto.Query, only: [from: 2]

    {1, _} =
      Arca.Repo.update_all(
        from(a in Arca.Schemas.Approval,
          where: a.athanor_id == ^actor.athanor_id and a.id == ^approval_id
        ),
        set: [status: "approved"]
      )
  end

  # An open confirmation of the person's, asked through the gate as a page
  # asks for a sensitive change: answers its ref.
  defp confirmation!(ctx) do
    entry = %{
      "name" => "key-#{System.unique_integer([:positive])}",
      "kind" => "api_key",
      "fields" => %{"KEY" => @private},
      "destination" => %{"hosts" => ["api.example.com"]}
    }

    assert {:error, {:confirmation_required, %{id: id, operation: "vault.create"}}} =
             Sanctum.Gate.call_external("vault", ctx, Map.put(entry, "action", "create"))

    Prima.Confirmation.ref(id)
  end

  defp run!(actor, user_id, reference, status, completed_at, opts \\ []) do
    id = Prima.UUID7.generate_id("exec")
    parent = Keyword.get(opts, :parent)

    Arca.Repo.insert!(%Arca.Schemas.Execution{
      id: id,
      root_execution_id: parent || id,
      parent_execution_id: parent,
      reference: reference,
      user_id: user_id,
      athanor_id: actor.athanor_id,
      request_id: Prima.UUID7.request_id(),
      started_at: DateTime.add(completed_at, -1),
      completed_at: completed_at,
      status: status,
      error_message: if(status == "failed", do: "boom #{@private}")
    })
  end

  # A run's lifecycle event as `Opus.Telemetry` emits it.
  defp execute(stage, actor, user_id, id, reference, extra \\ []) do
    meta =
      Map.merge(
        %{
          execution_id: id,
          component: reference,
          reference: reference,
          component_type: :reagent,
          user_id: user_id,
          athanor_id: actor.athanor_id,
          parent_execution_id: nil,
          duration_ms: 1
        },
        Map.new(extra)
      )

    :telemetry.execute([:cyfr, :opus, :execute, stage], %{duration: 1}, meta)
  end

  defp schedule!(actor, user_id, name) do
    {:ok, row} =
      Arca.CronSchedule.create(actor, %{
        user_id: user_id,
        athanor_id: actor.athanor_id,
        name: name,
        cron_expression: "0 * * * *",
        reference: "reagent:local.test:1.0.0",
        resolved_reference: "reagent:local.test:1.0.0",
        input: Jason.encode!(%{"secret" => @private}),
        next_run_at: DateTime.add(DateTime.utc_now(), 3_600, :second),
        profile_id: "prof-cron",
        cap: 0
      })

    row
  end

  defp occurrence!(actor, schedule_id, at, state) do
    %Arca.Schemas.ScheduleOccurrence{}
    |> Arca.Schemas.ScheduleOccurrence.changeset(%{
      id: "occ_" <> String.pad_leading("#{System.unique_integer([:positive])}", 12, "0"),
      athanor_id: actor.athanor_id,
      schedule_id: schedule_id,
      scheduled_for: at,
      state: state,
      claimed_at: at
    })
    |> Arca.Repo.insert!()
  end

  # An offer of `files` from `from_ctx`'s person to `recipient`, its rows in
  # the sender's athanor as `Arca.FileOffers.offer/3` writes them: answers
  # the offer's id.
  defp offer!(from_ctx, recipient, files, opts \\ []) do
    offer_id = Prima.UUID7.generate_id("ofr")
    now = DateTime.utc_now()

    for filename <- files do
      Arca.Repo.insert!(%Arca.Schemas.FileOffer{
        id: Prima.UUID7.generate_id("fof"),
        athanor_id: from_ctx.athanor_id,
        offer_id: offer_id,
        sender_user_id: from_ctx.user_id,
        recipient_user_id: recipient,
        filename: filename,
        digest: "sha256:" <> String.duplicate("0", 64),
        size: 1,
        status: Keyword.get(opts, :status, "offered"),
        expires_at: Keyword.get(opts, :expires_at, DateTime.add(now, 3_600)),
        inserted_at: now,
        updated_at: now
      })
    end

    offer_id
  end

  # An offer's transition as `Arca.FileOffers` emits it, per file.
  defp offered(kind, offer_id, from_ctx, to_ctx, filename) do
    :telemetry.execute([:cyfr, :arca, :file_offer, kind], %{system_time: 0}, %{
      offer_id: offer_id,
      kind: kind,
      sender_user_id: from_ctx.user_id,
      recipient_user_id: to_ctx.user_id,
      filename: filename
    })
  end
end
