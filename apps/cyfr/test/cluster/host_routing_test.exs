# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

Code.require_file("support/support.exs", __DIR__)

defmodule Cyfr.Cluster.HostRoutingTest do
  @moduledoc """
  Where a worker's host call lands, and what the other member does with
  one that lands on it.

  `cell-ownership.md` §5 classes an attempt's host-call state **shared by
  construction** — "an attempt has exactly one process in the cell, on the
  member holding it" — and says so conditionally:

  > This holds **only if a host call reaches that member**: the assignment
  > carries the issuing member's own address, and a worker calls that
  > address directly rather than the cell's balancer.

  It does now, and this file is where that is true. An assignment names
  the member that issued it and the address that member's host API is
  reached at; a runner posts that attempt's calls there and names the
  member in every header. What each case proves:

    * the address is the issuing member's, and the two members' differ, so
      a worker holding both assignments posts each where it belongs;
    * a call posted at that address is answered — the ordinary path, over
      HTTP, through the member's own listener;
    * the same signed call posted at the peer is refused **whatever it
      asks for**. This is the repair: a completion was already lost on a
      peer, but a lease renewal is answered from the row, and in a freshly
      formed cell every member holds generation 1, so the peer used to
      renew the lease of work it held none of — the half that worked, and
      made a misrouted worker silent rather than broken;
    * a member that is *gone* fails differently from a member that
      *refuses*: the post never becomes an answer at all, and the
      surviving member settles the attempt from the rows within §4.3's
      bound;
    * an address or a member rewritten in an assignment fails its MAC
      before a single call is made to it, so the address inside the signed
      envelope is not a redirect anyone but CYFR can aim.

  The calls are made from the control node rather than from a member: an
  attempt's keys derive from the shared worker root and the identifiers
  its holder answers, so this case can be that attempt's worker — and go
  on being it after the member that issued the work has died.
  """

  use Cyfr.Cluster.Case, async: false

  alias Cyfr.{Assignment, WorkerAuth, WorkerWire}

  # §4.3: the attempt lease (180 s) plus the sweeper's interval (60 s) is
  # the maximum recovery for an execution whose member is gone. The case
  # expires the lease and drives the sweep rather than waiting both out;
  # what it measures is that the surviving member settles it, and that
  # nothing but the lease and a sweep was needed.
  @recovery_bound_ms 240_000

  describe "an assignment" do
    test "carries the member that issued it and the address that member is reached at" do
      here = attempt(:a, :addressed)
      there = attempt(:b, :addressed_b)

      assert {:ok, %Assignment{} = mine} = Assignment.read(here.assignment)
      assert {:ok, %Assignment{} = theirs} = Assignment.read(there.assignment)

      # Each member names itself, not one configured address the two share.
      assert mine.member == here.member
      assert mine.host_url == Cell.member(:a).host_api
      assert theirs.member == there.member
      assert theirs.host_url == Cell.member(:b).host_api
      refute mine.member == theirs.member
      refute mine.host_url == theirs.host_url

      Cell.call(:b, Cyfr.Cluster.Holder, :release!, [])
    end

    test "cannot have its address or its member moved without the assign key" do
      held = attempt(:a, :sealed_address)

      for change <- [
            &Map.put(&1, "host_url", Cell.member(:b).host_api),
            &Map.put(&1, "member", "cyfr@elsewhere#boot_forged")
          ] do
        redirected = resigned(held.assignment, change)

        # The token still reads — reading is worth nothing — and the attach
        # that would act on it is refused for its MAC, before any call is
        # made to the address it names.
        assert {:ok, %Assignment{}} = Assignment.read(redirected)

        assert {200, %{"error" => "bad_mac"}} =
                 post(call(held, "attach", %{"assignment" => redirected}), address(held))
      end

      assert Observer.attempt(held.attempt)["state"] == "running"
    end
  end

  describe "a host call posted at the address its assignment names" do
    test "is answered by the member that issued the attempt" do
      held = attempt(:a, :served)

      row = Observer.attempt(held.attempt)
      assert row["state"] == "running"
      assert row["boot_id"] =~ to_string(Cell.member(:a).node)
      assert address(held) == Cell.member(:a).host_api

      assert {200, %{"ok" => renewals}} =
               post(call(held, "renew", %{"attempts" => [held.attempt]}), address(held))

      assert Map.has_key?(renewals, held.attempt)
    end

    test "carries the run's answer to the member that holds its process" do
      held = attempt(:a, :finished)

      assert {200, %{"ok" => _}} = post(completion(held), address(held))

      Wait.until!(
        fn -> Observer.execution(held.execution_id)["status"] == "completed" end,
        "the member its assignment addressed did not finish its own run"
      )
    end
  end

  describe "the same signed call posted at the peer" do
    # A freshly formed cell has every member at generation 1, since a
    # slot's generation rises only when that slot is taken over. This
    # database outlives the run, so the two members have drifted apart;
    # the peer is put back at the issuer's generation for every case
    # here, which is the state a new deployment starts in. With the
    # generations equal there is nothing left between the peer and the
    # rows but the member the call names — and that is the whole of this
    # repair, so a case that let the generations differ would be proving
    # the fence that was already there.
    setup do
      {:ok, generation: same_generation!()}
    end

    test "is refused, and the run is still the holding member's to finish", context do
      held = attempt(:a, :strayed)

      # The same call, made once, delivered to the peer. Nothing about it
      # differs; only which member is asked to answer it. The peer refuses
      # it on the header alone, before it reads the body.
      assert {401, %{"error" => "lost"}} = refused_by_peer!(completion(held), context.generation)

      # A completion an attempt's process never saw is a completion that
      # did not happen: the execution is still running, and the guest's
      # answer is not lost to it.
      assert Observer.execution(held.execution_id)["status"] == "running"
      assert Observer.execution(held.execution_id)["output"] == nil
      assert Observer.attempt(held.attempt)["state"] == "running"

      # And the member its assignment addresses finishes the run, so the
      # peer refused a call that was in every other way good.
      assert {200, %{"ok" => _}} = post(completion(held), address(held))

      Wait.until!(
        fn -> Observer.execution(held.execution_id)["status"] == "completed" end,
        "the holding member did not finish its own run"
      )
    end

    test "cannot attach a runner on the peer either", context do
      held = attempt(:a, :unattached, attach: false)
      attach = call(held, "attach", %{"assignment" => held.assignment})

      assert {401, %{"error" => "lost"}} = refused_by_peer!(attach, context.generation)

      # The attempt is still unclaimed, so nothing about the peer's refusal
      # left it half-held, and the member it names still claims it.
      assert Observer.attempt(held.attempt)["claimed_by"] == nil
      assert Observer.attempt(held.attempt)["state"] == "running"
      assert {200, %{"ok" => %{}}} = post(attach, address(held))
      assert Observer.attempt(held.attempt)["claimed_by"] == held.runner
    end

    test "is refused a lease renewal it could have written from the rows", context do
      held = attempt(:a, :renewed)
      before = Observer.attempt(held.attempt)["lease_until"]
      renew = call(held, "renew", %{"attempts" => [held.attempt]})

      assert {401, %{"error" => "lost"}} = refused_by_peer!(renew, context.generation),
             "the peer renewed the lease of an attempt it holds none of the work for"

      assert Observer.attempt(held.attempt)["lease_until"] == before

      # `renew` is idempotent, so the very same call — same nonce, same
      # timestamp, same MAC — is answered by the member it names. Only
      # which member was asked differs.
      assert {200, %{"ok" => renewals}} = post(renew, address(held))
      assert Map.has_key?(renewals, held.attempt)
      assert NaiveDateTime.compare(Observer.attempt(held.attempt)["lease_until"], before) == :gt
    end

    test "is refused a runner's exit report, so the peer lapses nothing", context do
      held = attempt(:a, :reported)
      before = Observer.attempt(held.attempt)["lease_until"]
      report = exit_report(held)

      # A report carries its member in its args rather than its header —
      # the header's kind is shared with the requests CYFR sends a worker,
      # which name no member — so the peer reads it and refuses it, rather
      # than refusing it unread. Its header carries no generation either,
      # so the member is the only thing that can refuse it.
      assert {200, %{"error" => "lost"}} = refused_by_peer!(report, context.generation)
      assert Observer.attempt(held.attempt)["state"] == "running"
      assert Observer.attempt(held.attempt)["lease_until"] == before

      # The member that issued the attempts the runner held lapses them.
      assert {200, %{"ok" => true}} = post(report, address(held))

      Wait.until!(
        fn -> Observer.attempt(held.attempt)["state"] == "lapsed" end,
        "the member its report named did not lapse its own runner's attempts"
      )
    end
  end

  describe "a member that is gone" do
    test "fails a worker's calls differently from one that refuses, and its run is recovered" do
      generation = same_generation!()
      held = attempt(:a, :orphaned)

      # A refusal is an answer: the peer is reached, verifies the call and
      # says `lost`. The worker knows CYFR heard it and said no.
      assert {401, %{"error" => "lost"}} =
               refused_by_peer!(call(held, "renew", %{"attempts" => [held.attempt]}), generation)

      Cell.kill(:a)

      # A member that is gone answers nothing. The post never becomes an
      # answer at all, which is what `Opus.HostClient` reads as a lost
      # answer — retried where the callback's class allows it and
      # `uncertain` where it does not — rather than as CYFR's word.
      lost = post(call(held, "renew", %{"attempts" => [held.attempt]}), address(held))

      assert {:error, {:transport, _reason}} = lost,
             "a dead member answered something: #{inspect(lost)}"

      # And the work is the cell's to settle, not the dead member's: the
      # attempt's lease runs out and the surviving member's sweep closes
      # it. The lease is expired rather than waited out; §4.3's bound is
      # the lease plus one sweep, and what this measures is the sweep.
      Observer.expire_attempt!(held.attempt)
      Cell.call(:b, Cyfr.Cluster.Boot, :sweep, [])

      {settled_ms, _} =
        Wait.measure!(
          fn -> Observer.attempt(held.attempt)["state"] == "lapsed" end,
          "the surviving member did not settle the dead member's attempt"
        )

      Wait.report("a dead member's addressed attempt is settled", settled_ms, @recovery_bound_ms)
      assert settled_ms <= @recovery_bound_ms
      assert Observer.attempt(held.attempt)["outcome"] == "uncertain"
      assert Observer.execution(held.execution_id)["status"] == "failed"
    end
  end

  # ---------------------------------------------------------------------------
  # This case's worker
  #
  # An attempt's call and seal keys derive from the shared worker root and
  # the six fields its holder answers, so the control node can make that
  # attempt's host calls itself. That is what lets a case post one signed
  # call at two members, and go on posting after the member that issued the
  # assignment has died.
  # ---------------------------------------------------------------------------

  @header_fields [
    :athanor_id,
    :execution_id,
    :attempt,
    :fence,
    :generation,
    :service,
    :boot,
    :runner,
    :member
  ]

  # The peer put back at the issuer's generation, and put back as it was
  # when the case ends. A refusal measured while the generations differ
  # would be the generation's, not the member's.
  defp same_generation!(issuer \\ :a, peer \\ :b) do
    assert {:ok, generation} = Cell.call(issuer, Arca.ControlPlane, :generation, [])
    was = Cell.call(peer, Arca.ControlPlane, :generation, [])
    Cell.call(peer, Arca.ControlPlane, :record_generation, [generation])

    on_exit(fn ->
      case was do
        {:ok, previous} -> Cell.call(peer, Arca.ControlPlane, :record_generation, [previous])
        _none -> :ok
      end
    end)

    generation
  end

  # Post at the peer, with the peer's generation read on both sides of the
  # post and asserted equal to the issuer's. A call refused while the two
  # differ was refused by the generation, which fenced it before this
  # repair; with them equal the only thing left to refuse it is the member
  # the call names.
  defp refused_by_peer!(call, generation) do
    assert {:ok, ^generation} = Cell.call(:b, Arca.ControlPlane, :generation, [])
    answer = post(call, Cell.member(:b).host_api)
    assert {:ok, ^generation} = Cell.call(:b, Arca.ControlPlane, :generation, [])
    answer
  end

  # An attempt held open on `id` under `label`, with nothing of an earlier
  # case still held there.
  defp attempt(id, label, opts \\ []) do
    Cell.call(id, Cyfr.Cluster.Holder, :release!, [])
    Cell.call(id, Cyfr.Cluster.Holder, :attach!, [label, opts])
  end

  # The address `held`'s own assignment names: where its host calls go.
  defp address(held) do
    {:ok, %Assignment{host_url: url}} = Assignment.read(held.assignment)
    url
  end

  # One host call of `held`'s attempt, sealed and signed as its runner
  # makes it, ready to post at any member.
  defp call(held, op, args) do
    fields =
      held
      |> Map.take(@header_fields)
      |> Map.merge(%{ts: System.system_time(:millisecond), nonce: nonce()})

    {:ok, keys} = WorkerAuth.attempt_keys(root(), fields)
    json = Jason.encode!(%{"op" => op, "args" => args})
    {:ok, sealed} = WorkerAuth.seal_call(keys.seal, :body, fields, json)
    {:ok, header} = WorkerAuth.host_call_header(keys.call, fields, sealed)

    %{
      route: WorkerWire.host_route(String.to_existing_atom(op)),
      header: header,
      body: sealed,
      open: &WorkerAuth.open_call(keys.seal, :answer, fields, &1)
    }
  end

  # A completion of `held`'s run, as its runner reports one.
  defp completion(held) do
    outcome = %{
      "execution_id" => held.execution_id,
      "attempt" => held.attempt,
      "fence" => held.fence,
      "status" => "completed",
      "output" => Jason.encode!(%{"ok" => true}),
      "duration_ms" => 1
    }

    call(held, "complete", %{"outcome" => outcome})
  end

  # A worker service's report that the runner holding `held` exited. It
  # crosses plain under that service's dispatch key, and names the member
  # whose attempts the runner held.
  defp exit_report(held) do
    body =
      Jason.encode!(%{
        "op" => "runner_exited",
        "args" => %{
          "member" => held.member,
          "runner" => held.runner,
          "attempts" => [held.attempt]
        }
      })

    {:ok, worker_key} = WorkerAuth.worker_key(root(), held.service)

    report = %{
      service: held.service,
      boot: held.boot,
      ts: System.system_time(:millisecond),
      nonce: nonce()
    }

    {:ok, header} = WorkerAuth.report_header(WorkerAuth.dispatch_key(worker_key), report, body)

    %{route: WorkerWire.host_route(:runner_exited), header: header, body: body, open: &{:ok, &1}}
  end

  # Post one call at `url` over HTTP, as a runner posts it, and answer the
  # status and the JSON CYFR answered: a `200` opens as this call's sealed
  # answer, and a listener's own refusal is plain. A post that never became
  # an answer is `{:error, {:transport, reason}}` — what a member that is
  # gone gives, and what no member that refuses ever gives.
  defp post(call, url) do
    request = [
      method: :post,
      url: url <> call.route,
      headers: [{WorkerWire.auth_header(), call.header}, {"content-type", "application/json"}],
      body: call.body,
      receive_timeout: 10_000,
      connect_options: [timeout: 10_000],
      retry: false,
      redirect: false,
      decode_body: false
    ]

    case Req.request(request) do
      {:ok, %Req.Response{status: 200, body: raw}} ->
        case call.open.(raw) do
          {:ok, json} -> {200, Jason.decode!(json)}
          {:error, reason} -> {:error, {:unsealable, reason}}
        end

      {:ok, %Req.Response{status: status, body: raw}} ->
        {status, Jason.decode!(raw)}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  # An assignment's payload changed and signed again with a key that is not
  # the assign key: what a worker, or anyone who can rewrite what a worker
  # was handed, can produce.
  defp resigned(token, change) do
    [payload64, _mac] = String.split(token, ".")

    {:ok, bytes} =
      payload64
      |> Base.url_decode64!(padding: false)
      |> Jason.decode!()
      |> change.()
      |> Cyfr.JCS.encode()

    mac = :crypto.mac(:hmac, :sha256, "a worker's key", bytes)
    Base.url_encode64(bytes, padding: false) <> "." <> Base.url_encode64(mac, padding: false)
  end

  defp root, do: Application.fetch_env!(:cyfr, :worker_key)

  defp nonce, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
end
