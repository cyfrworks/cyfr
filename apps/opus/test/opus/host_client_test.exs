# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.HostClientTest do
  @moduledoc """
  A runner's client reaches its attempt only over the wire: one signed
  `POST` per call to the callback's route, a JSON body naming the
  operation, and a JSON answer read as the worker protocol spells it. A
  lost answer is retried as the callback's class allows — once, under a
  fresh header, as the same body — or ends uncertain; an answer CYFR gave
  is never retried. A client's inspection and the transport's log show
  nothing a call carried.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Cyfr.{Assignment, WorkerWire}
  alias Opus.HostClient
  alias Opus.Test.ScriptedHost

  setup do
    host = ScriptedHost.start!()
    attempt = ScriptedHost.attempt!(host)
    {:ok, host: host, attempt: attempt, client: attempt.client}
  end

  test "every host call crosses as one signed request to its route and answers as read", %{
    host: host,
    attempt: attempt,
    client: client
  } do
    ScriptedHost.script(host, "oauth_token", {:error, {:guest_error, "vault_denied", "no vault"}})
    ScriptedHost.script(host, "storage", {:error, {:guest_error, "action_denied", "denied"}})
    ScriptedHost.script(host, "admit_child", {:error, {:guest_error, "dispatch_error", "no"}})
    ScriptedHost.script(host, "tool_call", {:error, {:guest_error, "dispatch_error", "no"}})
    ScriptedHost.script(host, "complete", {:ok, %{"done" => true}})
    ScriptedHost.script(host, "fail", {:error, :lost})

    assert {:ok, %{}} = HostClient.attach(client, attempt.assignment)
    assert {:ok, %{} = renewals} = HostClient.renew(client, [client.attempt])
    assert {:ok, until} = renewals[client.attempt]
    assert is_integer(until)
    assert {:ok, [_reply]} = HostClient.push_deltas(client, [~s({"type":"note"})])

    assert {:error, {:guest_error, "vault_denied", "no vault"}} =
             HostClient.oauth_token(client, "google")

    assert :ok = HostClient.take_rate(client, "http:" <> attempt.component_ref)

    assert {:error, {:guest_error, "action_denied", _}} =
             HostClient.storage(client, :read, %{"path" => "data/a.txt"})

    assert {:error, :not_found} = HostClient.fetch_artifact(client, attempt.digest)
    assert :ok = HostClient.record_denial(client, "invalid_json", "Invalid JSON request")

    assert {:error, {:guest_error, "dispatch_error", _}} =
             HostClient.admit_child(client, "reagent:local.missing:0.1.0", nil, %{}, :call)

    assert {:error, {:guest_error, "dispatch_error", _}} =
             HostClient.tool_call(client, "tools", %{"action" => "list"}, :call)

    assert :ok = HostClient.release_child(client, "exec_child")
    assert {:ok, %{"done" => true}} = HostClient.complete(client, %{"done" => true})
    assert {:error, :lost} = HostClient.fail(client, "after the close")

    ops = for %{op: op} <- ScriptedHost.requests(host), do: op

    assert ops ==
             ~w(attach renew push_deltas oauth_token take_rate storage fetch_artifact record_denial admit_child tool_call release_child complete fail)

    for %{op: op, header: header, body: body, caller: caller} <- ScriptedHost.requests(host) do
      assert String.starts_with?(header, "v1 kind=call ")
      assert %{"op" => ^op, "args" => %{}} = Jason.decode!(body)
      assert caller.execution_id == attempt.execution_id
      assert caller.runner == client.runner
      assert caller.boot == client.boot
    end
  end

  test "a lost answer to an idempotent call is asked once more, under a fresh header, as the same body",
       %{
         host: host,
         client: client
       } do
    ScriptedHost.script(host, "renew", [:drop, {:ok, %{client.attempt => %{"lease_until" => 5}}}])

    assert {:ok, %{}} = HostClient.renew(client, [client.attempt])

    assert [first, second] = ScriptedHost.requests(host, "renew")
    assert first.body == second.body
    assert first.caller.nonce != second.caller.nonce
    assert first.header != second.header
  end

  test "a lost push_deltas answer sends the same batch again, in order", %{
    host: host,
    client: client
  } do
    ScriptedHost.script(host, "push_deltas", [:drop, {:ok, ["a", "b"]}])
    events = [~s({"n":1}), ~s({"n":2})]

    assert {:ok, ["a", "b"]} = HostClient.push_deltas(client, events)

    assert [first, second] = ScriptedHost.requests(host, "push_deltas")
    assert first.body == second.body
    assert Enum.map(second.args["deltas"], & &1["event"]) == events
  end

  test "a lost admit_child answer is asked again under the same child key", %{
    host: host,
    client: client
  } do
    ScriptedHost.script(host, "admit_child", [
      :drop,
      {:error, {:guest_error, "dispatch_error", "no"}}
    ])

    assert {:error, {:guest_error, "dispatch_error", "no"}} =
             HostClient.admit_child(client, "reagent:local.x:0.1.0", "need", %{"a" => 1}, :spawn)

    assert [first, second] = ScriptedHost.requests(host, "admit_child")
    assert first.body == second.body
    assert Cyfr.HostAPI.valid_child_key?(first.args["child_key"])
    assert first.args["child_key"] == second.args["child_key"]

    # A new admission mints a new key.
    ScriptedHost.script(host, "admit_child", {:error, {:guest_error, "dispatch_error", "no"}})
    HostClient.admit_child(client, "reagent:local.x:0.1.0", "need", %{"a" => 1}, :spawn)
    [_, _, third] = ScriptedHost.requests(host, "admit_child")
    assert third.args["child_key"] != first.args["child_key"]
  end

  test "a lost answer to a call that is never retried ends uncertain, asked once", %{
    host: host,
    client: client
  } do
    for op <- ~w(take_rate storage oauth_token tool_call record_denial) do
      ScriptedHost.script(host, op, :drop)
    end

    assert {:error, {:uncertain, sentence}} = HostClient.take_rate(client, "http:x")
    assert sentence =~ "lost"
    assert {:error, {:uncertain, _}} = HostClient.storage(client, :read, %{"path" => "a"})
    assert {:error, {:uncertain, _}} = HostClient.oauth_token(client, "google")
    assert {:error, {:uncertain, _}} = HostClient.tool_call(client, "t", %{}, :call)
    assert {:error, {:uncertain, _}} = HostClient.record_denial(client, "t", "m")

    ops = for %{op: op} <- ScriptedHost.requests(host), do: op
    assert ops == ~w(take_rate storage oauth_token tool_call record_denial)
  end

  test "a second lost answer is lost", %{host: host, client: client} do
    ScriptedHost.script(host, "renew", :drop)
    assert {:error, :lost} = HostClient.renew(client, [client.attempt])
    assert length(ScriptedHost.requests(host, "renew")) == 2
  end

  test "an answer CYFR gave is never retried, lost and unavailable included", %{
    host: host,
    client: client
  } do
    ScriptedHost.script(host, "renew", [{:error, :unavailable}, {:error, :lost}])

    assert {:error, :unavailable} = HostClient.renew(client, [client.attempt])
    assert {:error, :lost} = HostClient.renew(client, [client.attempt])
    assert length(ScriptedHost.requests(host, "renew")) == 2
  end

  test "an answer past the answer bound, or not an answer, is lost", %{host: host, client: client} do
    ScriptedHost.script(
      host,
      "renew",
      {:raw, 200, String.duplicate("x", Cyfr.HostAPI.max_answer_bytes() + 1)}
    )

    assert {:error, :lost} = HostClient.renew(client, [client.attempt])

    ScriptedHost.script(host, "renew", {:raw, 200, "not json"})
    assert {:error, :lost} = HostClient.renew(client, [client.attempt])

    ScriptedHost.script(host, "renew", {:raw, 200, ~s({"neither": "ok"})})
    assert {:error, :lost} = HostClient.renew(client, [client.attempt])
  end

  test "a host that cannot be reached loses every call", %{host: host} do
    attempt = ScriptedHost.attempt!(host)
    client = %{attempt.client | host_url: "http://127.0.0.1:9"}

    assert {:error, :lost} = HostClient.renew(client, [client.attempt])
    assert {:error, {:uncertain, _}} = HostClient.storage(client, :read, %{"path" => "a"})
    assert ScriptedHost.requests(host) == []
  end

  test "a client whose key is not its attempt's is refused by the host and answered lost", %{
    host: host,
    attempt: attempt,
    client: client
  } do
    stranger = %{client | call_key: :crypto.strong_rand_bytes(32)}

    assert {:error, :lost} = HostClient.push_deltas(stranger, [~s({"type":"note"})])
    assert {:error, :lost} = HostClient.renew(stranger, [attempt.attempt])

    # A refusal by status is a lost answer: each retried class asked once more.
    assert [
             {:refused, "push_deltas", :bad_mac},
             {:refused, "push_deltas", :bad_mac},
             {:refused, "renew", :bad_mac},
             {:refused, "renew", :bad_mac}
           ] = ScriptedHost.requests(host)
  end

  test "a child CYFR admits is opened under this attempt's seal key and runs as the same runner",
       %{
         host: host,
         attempt: attempt,
         client: client
       } do
    child =
      ScriptedHost.attempt!(host,
        boot: client.boot,
        runner: client.runner,
        input: %{"child" => 1}
      )

    ScriptedHost.script(host, "admit_child", fn _args, _caller ->
      {:ok,
       %{
         "assignment" => child.assignment,
         "attempt_keys" => sealed_for(attempt.keys.seal, child.keys),
         "input" => child.input,
         "secrets" => %{"KEY" => "k"}
       }}
    end)

    assert {:ok, admitted} =
             HostClient.admit_child(client, child.component_ref, nil, %{"child" => 1}, :call)

    assert admitted.assignment.execution_id == child.execution_id
    assert admitted.input == %{"child" => 1}
    assert admitted.secrets == %{"KEY" => "k"}
    assert admitted.client.runner == client.runner
    assert admitted.client.host_url == client.host_url
    assert admitted.client.execution_id == child.execution_id
  end

  test "a child whose keys do not open under this attempt's seal key is given back at once", %{
    host: host,
    attempt: attempt,
    client: client
  } do
    child = ScriptedHost.attempt!(host, boot: client.boot, runner: client.runner)
    other_seal = :crypto.strong_rand_bytes(32)

    ScriptedHost.script(host, "admit_child", fn _args, _caller ->
      {:ok,
       %{
         "assignment" => child.assignment,
         "attempt_keys" => sealed_for(other_seal, child.keys),
         "input" => child.input,
         "secrets" => %{}
       }}
    end)

    assert {:error, :lost} = HostClient.admit_child(client, child.component_ref, nil, %{}, :call)

    assert [%{args: %{"execution_id" => released}}] = ScriptedHost.requests(host, "release_child")
    assert released == child.execution_id
    assert attempt.execution_id != released
  end

  test "a worker service's exit report is signed with its dispatch key and posted to the host", %{
    host: host
  } do
    {:ok, credentials} =
      Opus.Credentials.load(
        service_id: "wrk_local",
        service_key: Base.encode16(worker_key(host, "wrk_local"), case: :lower),
        host_url: host.url,
        bind: "127.0.0.1",
        port: 0
      )

    at = %{member: host.member, host_url: host.url}
    assert :ok = HostClient.runner_exited(credentials, at, "boot_x", "runner_1", ["att_1"])

    assert [%{op: "runner_exited", args: args, caller: report, header: header}] =
             ScriptedHost.requests(host)

    # The report names the member whose attempts the runner held, so a
    # member it was not posted to lapses nothing.
    assert args == %{
             "member" => host.member,
             "runner" => "runner_1",
             "attempts" => ["att_1"]
           }

    assert %{service: "wrk_local", boot: "boot_x"} = report
    assert String.starts_with?(header, "v1 kind=report ")

    # A stranger's report is refused by the host, once more on the retry.
    stranger = %{credentials | dispatch_key: :crypto.strong_rand_bytes(32)}

    assert {:error, :lost} =
             HostClient.runner_exited(stranger, at, "boot_x", "runner_1", ["att_1"])

    assert [_, {:refused, "runner_exited", :bad_mac}, {:refused, "runner_exited", :bad_mac}] =
             ScriptedHost.requests(host)
  end

  describe "where an attempt's calls go" do
    test "is the member its assignment names, not the address the service is configured with",
         %{host: issuer} do
      # Two members of one cell: the same worker root, so either verifies
      # any attempt's key schedule, and a boot and an address of its own.
      peer = ScriptedHost.start!(root: issuer.root)
      attempt = ScriptedHost.attempt!(issuer)
      {:ok, assignment} = Assignment.read(attempt.assignment)

      # The worker service is configured with the peer's address. The
      # assignment wins: it is the only one of the two that knows which
      # member issued the work.
      at = HostClient.at(assignment, peer.url)
      assert at == %{member: issuer.member, host_url: issuer.url}

      client = HostClient.new(attempt.keys, attempt.runner, attempt.boot, at)
      assert {:ok, %{}} = HostClient.renew(client, [attempt.attempt])
      assert [%{caller: caller}] = ScriptedHost.requests(issuer, "renew")
      assert caller.member == issuer.member
      assert ScriptedHost.requests(peer) == []
    end

    test "is the configured address when the assignment names none", %{host: host} do
      attempt = ScriptedHost.attempt!(host, host_url: nil)
      {:ok, assignment} = Assignment.read(attempt.assignment)

      assert assignment.host_url == nil
      assert HostClient.at(assignment, host.url) == %{member: host.member, host_url: host.url}

      # A deployment of one member that was never told its own address:
      # the worker posts where its credentials say, and the member it
      # names is still the member that issued the work.
      assert attempt.client.host_url == host.url
      assert attempt.client.member == host.member
      assert {:ok, %{}} = HostClient.renew(attempt.client, [attempt.attempt])
    end

    test "is refused by a member the call does not name, twice over", %{host: issuer} do
      peer = ScriptedHost.start!(root: issuer.root)
      attempt = ScriptedHost.attempt!(issuer, member: peer.member, host_url: peer.url)

      # The call names the peer and is posted at the peer, so the issuer
      # sees none of it — and a call naming the issuer that reached the
      # peer would be refused there. Either way one member answers.
      client =
        HostClient.new(attempt.keys, attempt.runner, attempt.boot, %{
          member: issuer.member,
          host_url: peer.url
        })

      assert {:error, :lost} = HostClient.renew(client, [attempt.attempt])

      # Idempotent, so the lost answer is asked once more, and refused
      # again: a member that does not hold the attempt never answers it.
      assert [
               {:refused, "renew", :member_mismatch},
               {:refused, "renew", :member_mismatch}
             ] = ScriptedHost.requests(peer)
    end
  end

  test "a client's inspection names its attempt and host, and never its keys", %{
    attempt: attempt,
    client: client
  } do
    shown = inspect(client, limit: :infinity)

    assert shown =~ attempt.attempt
    assert shown =~ client.host_url
    refute shown =~ "_key:"

    for key <- [attempt.keys.call, attempt.keys.seal],
        do: refute(shown =~ inspect(key, limit: :infinity))
  end

  test "the transport's log carries nothing a call carried", %{host: host, client: client} do
    ScriptedHost.script(host, "storage", :drop)
    canary = "CANARY-" <> Base.encode16(:crypto.strong_rand_bytes(8))

    log =
      capture_log(fn ->
        assert {:error, {:uncertain, _}} =
                 HostClient.storage(client, :write, %{"path" => "a", "content" => canary})
      end)

    assert log =~ "storage"
    refute log =~ canary
    refute log =~ client.host_url
    refute log =~ Base.encode16(client.call_key, case: :lower)
  end

  defp sealed_for(seal_key, keys) do
    {:ok, sealed} = Cyfr.WorkerAuth.seal_attempt_keys(seal_key, keys)
    sealed
  end

  defp worker_key(host, service) do
    {:ok, key} = Cyfr.WorkerAuth.worker_key(host.root, service)
    key
  end

  # The answer envelope the client reads is the one `Cyfr.WorkerWire` builds.
  test "the answers read are the worker protocol's envelopes" do
    assert WorkerWire.ok(1) == %{"ok" => 1}
    assert WorkerWire.error(:lost) == %{"error" => "lost"}
  end
end
