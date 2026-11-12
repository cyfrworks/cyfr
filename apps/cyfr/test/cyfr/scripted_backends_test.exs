# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.ScriptedBackendsTest do
  @moduledoc """
  The scripted backends service lapses an owner as Locus does
  (`Locus.Backends.Owners`): once the lease its sync set has run out, the
  session message that finds it is refused `lapsed` and every later one
  `unknown_owner`, since a scripted owner drains at once; a renewal
  answers it unknown and a release and a status name it no more, until a
  sync admits it again. A client that went on using
  an owner whose lease it let run out is refused here as the service
  refuses it.
  """

  use ExUnit.Case, async: false

  alias Cyfr.Test.ScriptedBackends, as: Scripted
  alias Prima.LocusBackends, as: Wire

  @owner %{athanor: "ath_scripted_lapse", server: "srv_scripted_lapse", generation: 1, epoch: 1}
  @boot "bb_first"
  @lease_ms 300
  # A session id of the wire's form that no open answered.
  @session "ss_" <> String.duplicate("0", 32)
  @home "vlt_01a09fee-2c3d-7e4f-8a5b-6c7d8e9f0a1b"

  setup do
    root = :crypto.strong_rand_bytes(32)
    fake = Scripted.start(self(), root)
    %{fake: fake, root: root}
  end

  test "an owner a renewal found lapsed is gone: every session message is refused unknown_owner, and no control names it",
       %{fake: fake, root: root} do
    assert %{status: 200} = control(fake, root, 1, sync(root))
    assert %{status: 200, body: %{"status" => "running"}} = open(fake, root, "before")
    lapse!(fake)

    assert %{status: 200, body: %{"renewed" => [], "unknown" => [_]}} =
             control(fake, root, 2, %{type: :renew, lease_ms: @lease_ms, owners: [entry()]})

    for message <- [
          open_message(),
          %{type: :send, owner: owner(), e: 1, session: @session, lines: ["{}"]},
          %{type: :recv, owner: owner(), e: 1, session: @session, after: 0, max_wait_ms: 0},
          %{type: :close, owner: owner(), e: 1, session: @session}
        ] do
      assert %{status: 409, body: %{"error" => "unknown_owner"}} = session(fake, root, message),
             "#{message.type} was answered for a gone owner"
    end

    assert %{status: 200, body: %{"released" => []}} =
             control(fake, root, 3, %{type: :release, owners: [entry()]})

    assert %{status: 200, body: %{"owners" => []}} =
             control(fake, root, 4, %{type: :status, owners: [owner()]})
  end

  # Locus's own admission lapses an owner whose lease it finds run out,
  # and answers that message `lapsed`; once the owner has drained it is
  # gone, and a later message is answered `unknown_owner`.
  test "the session message that finds the lease run out is refused lapsed, the next unknown_owner, and a sync admits the owner again",
       %{fake: fake, root: root} do
    assert %{status: 200} = control(fake, root, 1, sync(root))
    lapse!(fake)
    assert %{status: 409, body: %{"error" => "lapsed"}} = open(fake, root, "lapsed")
    assert %{status: 409, body: %{"error" => "unknown_owner"}} = open(fake, root, "gone")

    assert %{status: 200} = control(fake, root, 2, sync(root))
    assert %{status: 200, body: %{"status" => "running"}} = open(fake, root, "again")
  end

  test "a gone owner confirms a late close as unknown, rather than draining forever", %{
    fake: fake,
    root: root
  } do
    assert %{status: 200} = control(fake, root, 1, sync(root))
    assert %{status: 200, body: %{"session" => id}} = open(fake, root, "late-close")
    lapse!(fake)

    assert %{status: 200, body: %{"owners" => []}} =
             control(fake, root, 2, %{type: :status, owners: [owner()]})

    assert %{status: 409, body: %{"error" => "unknown_owner"}} =
             session(fake, root, %{type: :close, owner: owner(), e: 1, session: id})
  end

  for ending <- [:exit, :close, :retire, :lapse] do
    @tag :send_end_race
    @tag ending: ending
    test "a session's #{ending} stands when an in-flight line resumes", ctx do
      %{fake: fake, root: root, ending: ending} = ctx
      message = sync(root)

      message = %{
        message
        | lease_ms: if(ending == :lapse, do: @lease_ms, else: 30_000),
          programs: Enum.map(message.programs, &%{&1 | home: :kept})
      }

      assert %{status: 200} = control(fake, root, 1, message)
      open = Map.put(open_message(), :home_id, @home)
      assert %{status: 200, body: %{"session" => id}} = session(fake, root, open)

      Scripted.hold(fake, "send")

      sending =
        Task.async(fn ->
          session(fake, root, %{
            type: :send,
            owner: owner(),
            e: 1,
            session: id,
            lines: List.duplicate(Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "ping"}), 1_000)
          })
        end)

      assert_receive {:held, "send", handler}, 2_000
      priority = Process.flag(:priority, :high)
      send(handler, :go)

      # The first invoke follows the session read. Pause the handler while
      # the remaining batch is delivered, before a split write can land.
      assert_receive {:invoke, "ping", _fields}, 2_000
      assert :erlang.suspend_process(handler)

      try do
        case ending do
          :exit ->
            Scripted.end_sessions(fake, @owner.server, 0)

          :close ->
            assert %{status: 200, body: %{"status" => "closed"}} =
                     session(fake, root, %{type: :close, owner: owner(), e: 1, session: id})

          :retire ->
            assert %{status: 200} =
                     control(fake, root, 2, %{
                       type: :home,
                       op: :retire,
                       athanor: @owner.athanor,
                       home_id: @home
                     })

          :lapse ->
            lapse!(fake)

            assert %{status: 200, body: %{"owners" => []}} =
                     control(fake, root, 2, %{type: :status, owners: [owner()]})
        end
      after
        :erlang.resume_process(handler)
        Process.flag(:priority, priority)
      end

      assert %{status: 200, body: %{"status" => status}} = Task.await(sending)
      assert status in ["running", "ended"]

      if ending == :lapse do
        assert %{status: 409, body: %{"error" => "unknown_owner"}} =
                 session(fake, root, %{
                   type: :recv,
                   owner: owner(),
                   e: 1,
                   session: id,
                   after: 0,
                   max_wait_ms: 0
                 })

        assert %{status: 200} = control(fake, root, 3, sync(root))
      else
        assert %{status: 200, body: %{"running" => false} = received} =
                 session(fake, root, %{
                   type: :recv,
                   owner: owner(),
                   e: 1,
                   session: id,
                   after: 0,
                   max_wait_ms: 0
                 })

        if ending == :exit, do: assert(received["exit_code"] == 0)
      end

      assert %{status: 200, body: %{"session" => fresh, "resumed" => false}} =
               session(fake, root, open)

      assert fresh != id
    end
  end

  defp owner, do: Map.take(@owner, [:athanor, :server])
  defp entry, do: Map.put(owner(), :e, 1)

  # Until the lease the sync set has run out on the service's own clock.
  defp lapse!(fake) do
    Prima.Test.Wait.wait_until(
      fn ->
        Agent.get(fake.agent, & &1.leases[{@owner.athanor, @owner.server}]) <=
          System.monotonic_time(:millisecond)
      end,
      5_000
    )
  end

  defp sync(root) do
    {:ok, sealed} =
      Wire.seal(Wire.seal_key(root), @owner, @boot, Jason.encode!(%{"cat" => %{}}))

    %{
      type: :sync,
      owner: owner(),
      e: 1,
      lease_ms: @lease_ms,
      idle_ms: 60_000,
      sealed: sealed,
      programs: [%{name: "cat", command: "cat", env_names: [], home: :scratch}]
    }
  end

  defp open_message,
    do: %{type: :open, owner: owner(), e: 1, program: "cat", key: "key", mode: :run, argv: []}

  defp open(fake, root, nonce),
    do: session(fake, root, %{open_message() | key: "key-#{nonce}"})

  defp session(fake, root, message) do
    {:ok, body} = Wire.encode_session(message)
    {:ok, key} = Wire.owner_key(root, @owner)
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

    {:ok, header} =
      Wire.invoke_header(
        key,
        Map.merge(@owner, %{boot: @boot, ts: System.os_time(:millisecond), nonce: nonce}),
        body
      )

    Req.post!(fake.url <> Wire.route(:session),
      body: body,
      headers: [{Wire.auth_header(), header}],
      retry: false
    )
  end

  defp control(fake, root, sequence, message) do
    {:ok, body} = Wire.encode_control(message)

    fields = %{
      generation: 1,
      seq: sequence,
      cyfr_boot: "cyfr_scripted",
      boot: @boot,
      ts: System.os_time(:millisecond)
    }

    {:ok, header} = Wire.control_header(Wire.control_key(root), fields, body)

    Req.post!(fake.url <> Wire.route(:control),
      body: body,
      headers: [{Wire.auth_header(), header}],
      retry: false
    )
  end
end
