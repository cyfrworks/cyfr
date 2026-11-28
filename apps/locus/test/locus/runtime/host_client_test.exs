# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Runtime.HostClientTest do
  @moduledoc """
  The worker service's own calls for an attempt, and the runners' it
  posts for them (`post_call/5`), reach CYFR only over the wire: one
  signed `POST` per call to the callback's route, a JSON body naming the
  operation, and a JSON answer read as the worker protocol spells it. A
  lost answer is retried as the callback's class allows — once, under a
  fresh header, as the same body — or ends uncertain; an answer CYFR gave
  is never retried. A client's inspection and the transport's log show
  nothing a call carried.

  An attached request is posted once and its answer handed over as it
  arrives, unopened: each frame as it completes, nothing more read until
  the caller takes it, the body bounded by the response size and every
  wait by the deadline; a refusal is handed over once, as posted and as
  received.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Prima.{Assignment, AttachedRequest, PinnedTarget, WorkerWire}
  alias Locus.Runtime.HostClient
  alias Locus.Runtime.Test.ScriptedHost

  # Read as this module compiles, so a checkout without the file fails
  # here, naming it, rather than running without the vectors.
  @host_api Path.expand("../../../../../tests/fixtures/host_api.json", __DIR__)
            |> File.read!()
            |> Jason.decode!()

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
    ScriptedHost.pins(host, %{"api.test" => "203.0.113.10"})

    assert :ok = HostClient.take_rate(client, "http:" <> attempt.component_ref)

    assert {:ok, %PinnedTarget{ip: "203.0.113.10"}} =
             HostClient.egress_pin(client, "https://api.test/")

    ops = for %{op: op} <- ScriptedHost.requests(host), do: op
    assert ops == ~w(take_rate egress_pin)

    for %{op: op, header: header, body: body, caller: caller} <- ScriptedHost.requests(host) do
      assert String.starts_with?(header, "v1 kind=call ")
      assert %{"v" => 3, "op" => ^op, "args" => %{}} = Jason.decode!(body)
      assert String.starts_with?(body, ~s({"v":3,))
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
    pin = fn args, _caller -> ScriptedHost.pin(%{"api.test" => "203.0.113.10"}, args, 30_000) end
    ScriptedHost.script(host, "egress_pin", [:drop, pin])

    assert {:ok, %PinnedTarget{}} = HostClient.egress_pin(client, "https://api.test/")

    assert [first, second] = ScriptedHost.requests(host, "egress_pin")
    assert first.body == second.body
    assert first.caller.nonce != second.caller.nonce
    assert first.header != second.header
  end

  test "a lost answer to a call that is never retried ends uncertain, asked once", %{
    host: host,
    client: client
  } do
    ScriptedHost.script(host, "take_rate", :drop)

    assert {:error, {:uncertain, sentence}} = HostClient.take_rate(client, "http:x")
    assert sentence =~ "lost"

    ops = for %{op: op} <- ScriptedHost.requests(host), do: op
    assert ops == ~w(take_rate)
  end

  test "an answer CYFR gave is never retried, lost and unavailable included", %{
    host: host,
    client: client
  } do
    ScriptedHost.script(host, "egress_pin", [{:error, :unavailable}, {:error, :lost}])

    assert {:error, :unavailable} = HostClient.egress_pin(client, "https://api.test/")
    assert {:error, :lost} = HostClient.egress_pin(client, "https://api.test/")
    assert length(ScriptedHost.requests(host, "egress_pin")) == 2
  end

  # The callbacks of the outcomes vector the worker service makes itself,
  # as its client makes each; the runner's are its crate's to play
  # (`apps/locus/runner/tests/vectors.rs`).
  defp outcome_call("take_rate", client), do: HostClient.take_rate(client, "http:x")

  defp outcome_call("egress_pin", client),
    do: HostClient.egress_pin(client, "https://api.example.test/x")

  # What the client answers for a vector's reading of an answer.
  defp reading(%{"ok" => value}), do: {:ok, value}
  defp reading(%{"ok_json" => text}), do: {:ok, Jason.decode!(text)}
  defp reading(%{"refused" => name}), do: {:error, String.to_existing_atom(name)}

  defp reading(%{"guest_error" => %{"remediation" => remediation} = error}),
    do: {:error, {:guest_error, error["type"], error["message"], remediation}}

  defp reading(%{"guest_error" => error}),
    do: {:error, {:guest_error, error["type"], error["message"]}}

  defp reading(%{"setup_required" => payload}), do: {:error, {:setup_required, payload}}
  defp reading(%{"failed" => message}), do: {:error, {:failed, message}}

  defp scripted(%{"status" => nil}), do: :drop
  defp scripted(%{"status" => 200, "answer" => json}), do: {:answer, json}
  defp scripted(%{"status" => status, "plain" => body}), do: {:raw, status, body}

  test "each answer outcome of the vectors the service's own calls meet: what a call makes of what each try met",
       %{
         host: host,
         client: client
       } do
    cases =
      for %{"callback" => callback} = c <- @host_api["answer_outcomes"],
          callback in ~w(take_rate egress_pin),
          do: c

    assert length(cases) >= 11

    # One case for each class the service's own calls are of.
    classes = cases |> Enum.map(&@host_api["retries"][Map.fetch!(&1, "callback")]) |> Enum.uniq()

    assert Enum.sort(classes) == ~w(idempotent never)

    for vector <- cases do
      assert %{"why" => why, "callback" => callback, "answers" => answers} = vector
      assert %{"outcome" => outcome, "posted" => posted} = vector
      assert is_binary(outcome) and is_integer(posted), why
      # A case is these members and, for an answer, its reading: none more.
      assert Map.keys(vector) -- ~w(why callback answers outcome posted reading) == [], why
      assert Map.has_key?(vector, "reading") == (outcome == "answer"), why

      ScriptedHost.script(host, callback, Enum.map(answers, &scripted/1))
      before = length(ScriptedHost.requests(host, callback))

      {result, _log} = with_log(fn -> outcome_call(callback, client) end)

      assert length(ScriptedHost.requests(host, callback)) - before == vector["posted"], why

      case vector["outcome"] do
        "lost" ->
          assert result == {:error, :lost}, why

        "uncertain" ->
          assert {:error, {:uncertain, _sentence}} = result, why

        "too_large" ->
          assert result == {:error, :too_large}, why

        "answer" ->
          assert result == reading(vector["reading"]), why
      end
    end
  end

  describe "a body past the host's bound" do
    test "is refused for good: posted once, whatever the call's class or the refusal's body",
         %{host: host, client: client} do
      # An idempotent call and one never retried, whose refusal is final
      # rather than uncertain.
      ScriptedHost.script(host, "egress_pin", {:raw, 413, "not json"})
      ScriptedHost.script(host, "take_rate", {:raw, 413, ""})

      log =
        capture_log(fn ->
          assert {:error, :too_large} = HostClient.egress_pin(client, "https://api.test/")
          assert {:error, :too_large} = HostClient.take_rate(client, "http:x")
        end)

      ops = for %{op: op} <- ScriptedHost.requests(host), do: op
      assert ops == ~w(egress_pin take_rate)
      assert log =~ "egress_pin was refused: its body is past the host's bound"
      refute log =~ "not json"
    end

    test "with a refusal past the answer bound is refused for good, and none of that body is kept",
         %{host: host, attempt: attempt, client: client} do
      over = String.duplicate("x", Prima.HostAPI.max_answer_bytes() + 1)
      ScriptedHost.script(host, "egress_pin", {:raw, 413, over})

      assert {:error, :too_large} = HostClient.egress_pin(client, "https://api.test/")
      assert [_once] = ScriptedHost.requests(host, "egress_pin")

      # The status crosses without the body, for a runner's call the
      # service posts too; a 200 answer past the bound is still no answer.
      ScriptedHost.script(host, "renew", {:raw, 413, over})
      json = Jason.encode!(Prima.WorkerWire.request_body(:renew, %{"attempts" => []}))

      posted = fn ->
        fields = call_fields(attempt)
        {:ok, sealed} = Prima.WorkerAuth.seal_call(attempt.keys.seal, :body, fields, json)
        {:ok, header} = Prima.WorkerAuth.host_call_header(attempt.keys.call, fields, sealed)
        HostClient.post_call(host.url, :renew, header, sealed)
      end

      assert {:ok, 413, ""} = posted.()
      ScriptedHost.script(host, "renew", {:raw, 200, over})
      assert :error = posted.()
    end

    test "after a lost answer is the answer of the one retry, and nothing more is posted", %{
      host: host,
      client: client
    } do
      ScriptedHost.script(host, "egress_pin", [:drop, {:raw, 413, ~s({"v":3,"error":"lost"})}])

      assert {:error, :too_large} = HostClient.egress_pin(client, "https://api.test/")
      assert [first, second] = ScriptedHost.requests(host, "egress_pin")
      assert first.body == second.body
    end
  end

  test "each answer bound of the vectors: an answer is kept to the answer bound as its status says",
       %{host: host, attempt: attempt} do
    json = Jason.encode!(Prima.WorkerWire.request_body(:renew, %{"attempts" => []}))

    assert length(@host_api["answer_bounds"]) >= 6

    for c <- @host_api["answer_bounds"] do
      assert Map.keys(c) |> Enum.sort() === ~w(arrived body_bytes kept_bytes status why),
             inspect(c)

      # A lost answer keeps nothing: its kept bytes are 0.
      assert c["arrived"] or c["kept_bytes"] === 0, c["why"]

      ScriptedHost.script(
        host,
        "renew",
        {:raw, c["status"], String.duplicate("x", c["body_bytes"])}
      )

      fields = call_fields(attempt)
      {:ok, sealed} = Prima.WorkerAuth.seal_call(attempt.keys.seal, :body, fields, json)
      {:ok, header} = Prima.WorkerAuth.host_call_header(attempt.keys.call, fields, sealed)

      expected =
        if c["arrived"],
          do: {:ok, c["status"], String.duplicate("x", c["kept_bytes"])},
          else: :error

      assert HostClient.post_call(host.url, :renew, header, sealed) === expected, c["why"]
    end
  end

  test "an answer past the answer bound, or not an answer, is lost", %{host: host, client: client} do
    ScriptedHost.script(
      host,
      "egress_pin",
      {:raw, 200, String.duplicate("x", Prima.HostAPI.max_answer_bytes() + 1)}
    )

    assert {:error, :lost} = HostClient.egress_pin(client, "https://api.test/")

    ScriptedHost.script(host, "egress_pin", {:raw, 200, "not json"})
    assert {:error, :lost} = HostClient.egress_pin(client, "https://api.test/")

    ScriptedHost.script(host, "egress_pin", {:raw, 200, ~s({"neither": "ok"})})
    assert {:error, :lost} = HostClient.egress_pin(client, "https://api.test/")
  end

  describe "the wire's version" do
    test "an answer without v, or at another version, is no answer: lost under the retry class",
         %{host: host, client: client} do
      ScriptedHost.script(host, "egress_pin", [
        {:answer, ~s({"ok":{}})},
        {:answer, ~s({"v":4,"ok":{}})}
      ])

      assert {:error, :lost} = HostClient.egress_pin(client, "https://api.test/")
      assert length(ScriptedHost.requests(host, "egress_pin")) == 2

      ScriptedHost.script(host, "take_rate", {:answer, ~s({"v":"2","ok":true})})
      assert {:error, {:uncertain, _}} = HostClient.take_rate(client, "http:x")
      assert length(ScriptedHost.requests(host, "take_rate")) == 1

      ScriptedHost.script(host, "take_rate", {:answer, ~s({"v":3,"ok":true,"extra":true})})
      assert {:error, {:uncertain, _}} = HostClient.take_rate(client, "http:x")
    end

    test "a host at another version is not this engine's: its refusal stops the attempt, asked once",
         %{host: host, client: client} do
      # Refused before the body, plain, whatever version the host speaks.
      for refusal <- [
            ~s({"v":3,"error":"unknown_version"}),
            ~s({"v":4,"error":"unknown_version"})
          ] do
        ScriptedHost.script(host, "egress_pin", {:raw, 401, refusal})
        before = length(ScriptedHost.requests(host, "egress_pin"))

        log =
          capture_log(fn ->
            assert {:error, :lost} = HostClient.egress_pin(client, "https://api.test/")
          end)

        assert log =~ "another version"
        assert length(ScriptedHost.requests(host, "egress_pin")) == before + 1
      end

      # Refused after the body was opened, sealed.
      ScriptedHost.script(host, "take_rate", {:error, :unknown_version})

      capture_log(fn ->
        assert {:error, :lost} = HostClient.take_rate(client, "http:x")
      end)

      # Any other refusal by status is lost, and asked again as its class allows.
      ScriptedHost.script(host, "egress_pin", {:raw, 401, ~s({"v":3,"error":"bad_mac"})})
      before = length(ScriptedHost.requests(host, "egress_pin"))
      assert {:error, :lost} = HostClient.egress_pin(client, "https://api.test/")
      assert length(ScriptedHost.requests(host, "egress_pin")) == before + 2
    end
  end

  describe "egress_pin/3" do
    test "every egress_pin vector crosses as its body and reads as its answer", %{
      host: host,
      client: client
    } do
      cases = @host_api["egress_pin_cases"] ++ @host_api["egress_policy_cases"]

      assert Enum.map(@host_api["egress_pin_cases"], & &1["name"]) ==
               ~w(fetch stream redirect denied metadata resolution redirect_credentials)

      assert Enum.map(@host_api["egress_policy_cases"], & &1["name"]) ==
               ~w(fetch outside_domains redirect_other_port redirect_default_port
                  redirect_other_host fetch_ipv6 redirect_ipv6_spelling)

      for vector <- cases do
        %{"v" => 3, "op" => "egress_pin", "args" => args} = Jason.decode!(vector["body"])
        ScriptedHost.script(host, "egress_pin", {:answer, vector["answer"]})

        opts =
          [purpose: String.to_existing_atom(args["purpose"])] ++
            if(args["from"], do: [from: args["from"]], else: [])

        result = HostClient.egress_pin(client, args["url"], opts)

        assert %{body: body} = List.last(ScriptedHost.requests(host, "egress_pin"))
        assert body == vector["body"], vector["name"]

        case Jason.decode!(vector["answer"]) do
          %{"ok" => wire} ->
            assert {:ok, %PinnedTarget{} = pin} = result, vector["name"]
            assert PinnedTarget.to_wire(pin) == wire

          %{"error" => name} ->
            assert result == {:error, String.to_existing_atom(name)}, vector["name"]
        end
      end

      assert length(ScriptedHost.requests(host, "egress_pin")) == length(cases)
    end

    test "a pin answer that is not a pin is lost, and a lost answer is asked once more", %{
      host: host,
      client: client
    } do
      ScriptedHost.script(host, "egress_pin", [
        {:ok, %{"id" => "pin_x", "ip" => "not an address"}},
        :drop,
        :drop
      ])

      assert {:error, :lost} = HostClient.egress_pin(client, "https://api.test/")
      assert length(ScriptedHost.requests(host, "egress_pin")) == 1

      assert {:error, :lost} = HostClient.egress_pin(client, "https://api.test/")
      assert [_, first, second] = ScriptedHost.requests(host, "egress_pin")
      assert first.body == second.body
    end

    test "a request the contract refuses is malformed, asked of no one", %{
      host: host,
      client: client
    } do
      assert {:error, :malformed} = HostClient.egress_pin(client, "ftp://api.test/")

      assert {:error, :malformed} =
               HostClient.egress_pin(client, "https://api.test/", purpose: :x)

      assert {:error, :malformed} =
               HostClient.egress_pin(client, "https://api.test/", purpose: :redirect)

      assert {:error, :malformed} =
               HostClient.egress_pin(client, "https://api.test/", purpose: :fetch, from: "pin_1")

      assert ScriptedHost.requests(host, "egress_pin") == []
    end

    test "a pin refusal answers only an egress_pin", %{host: host, client: client} do
      ScriptedHost.script(host, "take_rate", {:error, :denied})
      assert {:error, {:uncertain, _}} = HostClient.take_rate(client, "http:x")
    end
  end

  test "a host that cannot be reached loses an idempotent call, and leaves one never retried unsent",
       %{host: host} do
    attempt = ScriptedHost.attempt!(host)
    client = %{attempt.client | host_url: "http://127.0.0.1:9"}

    assert {:error, :lost} = HostClient.egress_pin(client, "https://api.test/")
    assert {:error, :unsent} = HostClient.take_rate(client, "http:x")
    assert ScriptedHost.requests(host) == []
  end

  test "a client whose key is not its attempt's is refused by the host and answered lost", %{
    host: host,
    client: client
  } do
    stranger = %{client | call_key: :crypto.strong_rand_bytes(32)}

    assert {:error, :lost} = HostClient.egress_pin(stranger, "https://api.test/")

    # A refusal by status is a lost answer: a retried class asked once more.
    assert [
             {:refused, "egress_pin", :bad_mac},
             {:refused, "egress_pin", :bad_mac}
           ] = ScriptedHost.requests(host)
  end

  test "a worker service's exit report is signed with its dispatch key and posted to the host", %{
    host: host
  } do
    {:ok, credentials} =
      Locus.Runtime.Credentials.load(
        service_id: "wrk_local",
        service_key: Base.encode16(worker_key(host, "wrk_local"), case: :lower),
        host_url: host.url,
        bind: "127.0.0.1",
        port: 0
      )

    at = %{member: host.member, host_url: host.url}

    assert :ok =
             HostClient.runner_exited(credentials, at, "boot_x", "runner_1", ["att_1"], nil, nil)

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
             HostClient.runner_exited(stranger, at, "boot_x", "runner_1", ["att_1"], nil, nil)

    assert [_, {:refused, "runner_exited", :bad_mac}, {:refused, "runner_exited", :bad_mac}] =
             ScriptedHost.requests(host)
  end

  test "a report of a runner the keeper refused carries the refusal's code alone", %{
    host: host
  } do
    {:ok, credentials} =
      Locus.Runtime.Credentials.load(
        service_id: "wrk_local",
        service_key: Base.encode16(worker_key(host, "wrk_local"), case: :lower),
        host_url: host.url,
        bind: "127.0.0.1",
        port: 0
      )

    at = %{member: host.member, host_url: host.url}

    assert :ok =
             HostClient.runner_exited(
               credentials,
               at,
               "boot_x",
               "runner_1",
               ["att_1"],
               "capacity",
               nil
             )

    assert [%{op: "runner_exited", args: %{"refusal" => "capacity"}}] =
             ScriptedHost.requests(host)

    # A code CYFR has no words for is sent as none.
    assert :ok =
             HostClient.runner_exited(
               credentials,
               at,
               "boot_x",
               "runner_1",
               ["att_1"],
               "uid_busy",
               nil
             )

    assert [_, %{op: "runner_exited", args: args}] = ScriptedHost.requests(host)
    refute Map.has_key?(args, "refusal")
  end

  test "a report of a runner ended for memory carries the limit that ended it", %{host: host} do
    {:ok, credentials} =
      Locus.Runtime.Credentials.load(
        service_id: "wrk_local",
        service_key: Base.encode16(worker_key(host, "wrk_local"), case: :lower),
        host_url: host.url,
        bind: "127.0.0.1",
        port: 0
      )

    at = %{member: host.member, host_url: host.url}

    for memory <- [:cap, :machine, :either] do
      assert :ok =
               HostClient.runner_exited(
                 credentials,
                 at,
                 "boot_x",
                 "runner_1",
                 ["att_1"],
                 nil,
                 memory
               )
    end

    assert ["cap", "machine", "either"] ==
             for(
               %{op: "runner_exited", args: args} <- ScriptedHost.requests(host),
               do: args["memory"]
             )
  end

  describe "a runner's calls, posted by the service" do
    test "post_call/4 answers CYFR's status and bytes, once", %{host: host} do
      attempt = ScriptedHost.attempt!(host)
      fields = call_fields(attempt)
      json = Jason.encode!(Prima.WorkerWire.request_body(:renew, %{"attempts" => []}))
      {:ok, sealed} = Prima.WorkerAuth.seal_call(attempt.keys.seal, :body, fields, json)
      {:ok, header} = Prima.WorkerAuth.host_call_header(attempt.keys.call, fields, sealed)

      assert {:ok, 200, answer} = HostClient.post_call(host.url, :renew, header, sealed)
      assert {:ok, _json} = Prima.WorkerAuth.open_call(attempt.keys.seal, :answer, fields, answer)

      assert {:ok, 401, _refusal} = HostClient.post_call(host.url, :renew, header, "tampered")
      assert :unsent = HostClient.post_call("http://127.0.0.1:9", :renew, header, sealed)
    end

    test "post_call/5 asks its room once for the whole answer before it keeps any, and no room is an answer that did not arrive",
         %{host: host} do
      attempt = ScriptedHost.attempt!(host)
      json = Jason.encode!(Prima.WorkerWire.request_body(:renew, %{"attempts" => []}))
      test = self()

      posted = fn room ->
        fields = call_fields(attempt)
        {:ok, sealed} = Prima.WorkerAuth.seal_call(attempt.keys.seal, :body, fields, json)
        {:ok, header} = Prima.WorkerAuth.host_call_header(attempt.keys.call, fields, sealed)
        HostClient.post_call(host.url, :renew, header, sealed, room: room)
      end

      asking = fn answer ->
        fn bytes ->
          send(test, {:asked, bytes})
          answer
        end
      end

      # An answer read in many pieces asks once, for the length it declares.
      answer = :binary.copy("0123456789abcdef", 65_536)
      ScriptedHost.script(host, "renew", {:raw, 200, answer})
      assert {:ok, 200, ^answer} = posted.(asking.(:ok))
      assert asked() == [byte_size(answer)]

      # No room: a 200 answer is no answer, and a refusal keeps its status
      # with none of its body, as one past the answer bound does.
      assert :error = posted.(asking.(:full))
      assert asked() == [byte_size(answer)]

      refusal = ~s({"v":3,"error":"unknown_version"})
      ScriptedHost.script(host, "renew", {:raw, 401, refusal})
      assert {:ok, 401, ""} = posted.(asking.(:full))
      assert asked() == [byte_size(refusal)]
    end
  end

  # What a room was asked, in order.
  defp asked do
    receive do
      {:asked, bytes} -> [bytes | asked()]
    after
      0 -> []
    end
  end

  defp call_fields(attempt) do
    {:ok, assignment} = Assignment.read(attempt.assignment)

    attempt.keys.attempt
    |> Map.merge(%{
      boot: attempt.boot,
      runner: attempt.runner,
      member: assignment.member,
      ts: System.system_time(:millisecond),
      nonce: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    })
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
      assert :ok = HostClient.take_rate(client, "http:x")
      assert [%{caller: caller}] = ScriptedHost.requests(issuer, "take_rate")
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
      assert :ok = HostClient.take_rate(attempt.client, "http:x")
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

      assert {:error, :lost} = HostClient.egress_pin(client, "https://api.test/")

      # Idempotent, so the lost answer is asked once more, and refused
      # again: a member that does not hold the attempt never answers it.
      assert [
               {:refused, "egress_pin", :member_mismatch},
               {:refused, "egress_pin", :member_mismatch}
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
    ScriptedHost.script(host, "take_rate", :drop)
    canary = "CANARY-" <> Base.encode16(:crypto.strong_rand_bytes(8))

    log =
      capture_log(fn ->
        assert {:error, {:uncertain, _}} = HostClient.take_rate(client, "http:" <> canary)
      end)

    assert log =~ "take_rate"
    refute log =~ canary
    refute log =~ client.host_url
    refute log =~ Base.encode16(client.call_key, case: :lower)
  end

  defp worker_key(host, service) do
    {:ok, key} = Prima.WorkerAuth.worker_key(host.root, service)
    key
  end

  describe "attached_fetch/3" do
    # An attached request of the attempt, as a runner names one.
    defp attached(url \\ "https://api.example.com/v1/x") do
      %AttachedRequest{
        call_id: AttachedRequest.call_id(:crypto.strong_rand_bytes(16)),
        connection: "api_key",
        method: "POST",
        url: url,
        headers: [{"content-type", "application/json"}],
        body: ~s({"q":1}),
        purpose: :fetch
      }
    end

    # A sink that tells the test each event and answers what `answer`
    # makes of it.
    defp sink(answer \\ fn _event -> :ok end) do
      test = self()

      fn event ->
        send(test, {:event, event})
        answer.(event)
      end
    end

    defp options(sink, opts \\ []) do
      %{
        sink: sink,
        max_response_size: Keyword.get(opts, :max, 1_000_000),
        deadline: System.system_time(:millisecond) + Keyword.get(opts, :within, 10_000)
      }
    end

    defp events do
      receive do
        {:event, event} -> [event | events()]
      after
        0 -> []
      end
    end

    # The frames handed over, read in order under the attempt's seal key.
    defp read(attempt, request, events) do
      reader = Prima.WorkerAuth.frame_reader(attempt.keys.seal, request.call_id)

      {read, reader} =
        Enum.reduce(events, {[], reader}, fn {:frame, frame}, {read, reader} ->
          {:ok, one, reader} = Prima.WorkerAuth.read_frame(reader, frame)
          {read ++ [one], reader}
        end)

      {read, reader.state}
    end

    test "crosses once as the sealed host call, and its frames are handed over unopened, in order",
         %{host: host, attempt: attempt, client: client} do
      request = attached()

      ScriptedHost.script(
        host,
        "attached_fetch",
        {:frames,
         [
           {:head, 200, [{"content-type", "text/plain"}]},
           {:chunk, "hello "},
           {:chunk, "world"},
           :end
         ]}
      )

      assert :ok = HostClient.attached_fetch(client, request, options(sink()))

      events = events()
      assert length(events) == 4 and Enum.all?(events, &match?({:frame, _bytes}, &1))

      assert {[
                %{kind: :head, status: 200, headers: [{"content-type", "text/plain"}]},
                %{kind: :chunk, body: "hello "},
                %{kind: :chunk, body: "world"},
                %{kind: :end}
              ], :done} = read(attempt, request, events)

      assert [%{args: args, header: header, caller: caller}] =
               ScriptedHost.requests(host, "attached_fetch")

      assert args == AttachedRequest.to_args(request)
      assert String.starts_with?(header, "v1 kind=call ")
      assert caller.runner == client.runner and caller.attempt == attempt.attempt
    end

    test "a refusal before admission is handed over once, as posted and as received", %{
      host: host,
      attempt: attempt,
      client: client
    } do
      request = attached()

      ScriptedHost.script(
        host,
        "attached_fetch",
        {:error, {:guest_error, "destination_mismatch", "outside"}}
      )

      assert :ok = HostClient.attached_fetch(client, request, options(sink()))
      assert [{:refusal, header, body}] = events()
      assert [%{header: ^header, caller: caller}] = ScriptedHost.requests(host, "attached_fetch")

      {:ok, json} = Prima.WorkerAuth.open_call(attempt.keys.seal, :answer, caller, body)

      assert {:error, "guest_error",
              %{"type" => "destination_mismatch", "message" => "outside", "call_id" => call_id}} =
               json |> Jason.decode!() |> WorkerWire.read_answer()

      assert call_id == request.call_id

      # Unscripted, it is the scripted host's dispatch_error, naming the call too.
      ScriptedHost.script(host, "attached_fetch", nil)
      assert :ok = HostClient.attached_fetch(client, request, options(sink()))
      assert [{:refusal, _header, _body}] = events()
    end

    test "any other status is lost, and nothing is asked again", %{host: host, client: client} do
      for answer <- [:drop, {:raw, 401, ~s({"v":3,"error":"lost"})}] do
        ScriptedHost.script(host, "attached_fetch", answer)
        assert {:error, "lost"} = HostClient.attached_fetch(client, attached(), options(sink()))
        assert events() == []
      end

      assert length(ScriptedHost.requests(host, "attached_fetch")) == 2
    end

    test "a member that does not hold the attempt refuses it under the member fence: lost", %{
      host: issuer
    } do
      peer = ScriptedHost.start!(root: issuer.root)
      attempt = ScriptedHost.attempt!(issuer)
      stale = %{attempt.client | host_url: peer.url}

      assert {:error, "lost"} = HostClient.attached_fetch(stale, attached(), options(sink()))
      assert events() == []
      assert [{:refused, "attached_fetch", :member_mismatch}] = ScriptedHost.requests(peer)
    end

    test "no status reaching the service is uncertain", %{client: client} do
      unreachable = %{client | host_url: "http://127.0.0.1:9"}

      assert {:error, "uncertain"} =
               HostClient.attached_fetch(unreachable, attached(), options(sink()))

      # A host that answers nothing before the deadline.
      # sleep-ok: the host answers nothing for 2 s, past the fetch's 300 ms deadline under test
      {port, _server} = raw_host!(fn socket -> Process.sleep(2_000) && socket end)

      assert {:error, "uncertain"} =
               HostClient.attached_fetch(
                 %{client | host_url: "http://127.0.0.1:#{port}"},
                 attached(),
                 options(sink(), within: 300)
               )

      assert events() == []
    end

    test "the chunks' body bytes are bounded by max_response_size, and a frame past it is never handed over",
         %{host: host, client: client} do
      ScriptedHost.script(
        host,
        "attached_fetch",
        {:frames, [{:head, 200, []}, {:chunk, "0123456789"}, {:chunk, "0123456789"}, :end]}
      )

      assert {:error, "response_too_large"} =
               HostClient.attached_fetch(client, attached(), options(sink(), max: 15))

      assert [{:frame, <<?h, _::binary>>}, {:frame, <<?c, _::binary>>}] = events()
    end

    test "a sink that halts stops the answer, and nothing more is handed over", %{
      host: host,
      client: client
    } do
      ScriptedHost.script(
        host,
        "attached_fetch",
        {:frames, [{:head, 200, []}, {:chunk, "a"}, {:chunk, "b"}, :end]}
      )

      halting =
        sink(fn
          {:frame, <<?c, _::binary>>} -> :halt
          _head -> :ok
        end)

      assert :halted = HostClient.attached_fetch(client, attached(), options(halting))
      assert [{:frame, <<?h, _::binary>>}, {:frame, <<?c, _::binary>>}] = events()
    end

    test "a refusal asks its room once, whole, by the length it declares, as its reading begins, and no room halts it with nothing handed over",
         %{client: client} do
      test = self()
      refusal = :binary.copy("r", 200_000)

      head =
        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n" <>
          "content-length: #{byte_size(refusal)}\r\n\r\n"

      # The host sends the refusal's first piece and holds the rest until
      # the test lets it go: the room is asked before the rest arrives.
      {port, host} =
        raw_host!(fn socket ->
          :gen_tcp.send(socket, head <> binary_part(refusal, 0, 1_000))

          receive do
            :rest ->
              :gen_tcp.send(socket, binary_part(refusal, 1_000, byte_size(refusal) - 1_000))
          end
        end)

      room = fn answer ->
        fn bytes ->
          send(test, {:asked, bytes})
          answer
        end
      end

      at = %{client | host_url: "http://127.0.0.1:#{port}"}
      options = Map.put(options(sink()), :room, room.(:ok))
      calling = Task.async(fn -> HostClient.attached_fetch(at, attached(), options) end)

      assert_receive {:asked, 200_000}, 5_000
      assert events() == []
      send(host, :rest)
      assert :ok = Task.await(calling, 10_000)
      assert [{:refusal, _header, ^refusal}] = events()
      assert asked() == []

      {port, _host} = raw_host!(fn socket -> :gen_tcp.send(socket, head <> refusal) end)
      at = %{client | host_url: "http://127.0.0.1:#{port}"}

      assert :halted =
               HostClient.attached_fetch(
                 at,
                 attached(),
                 Map.put(options(sink()), :room, room.(:full))
               )

      assert asked() == [200_000]
      assert events() == []
    end

    test "a sink that halts CYFR's refusal halts the answer", %{host: host, client: client} do
      ScriptedHost.script(
        host,
        "attached_fetch",
        {:error, {:guest_error, "destination_mismatch", "outside"}}
      )

      halting = sink(fn {:refusal, _header, _body} -> :halt end)
      assert :halted = HostClient.attached_fetch(client, attached(), options(halting))
      assert [{:refusal, _header, _body}] = events()
    end

    test "a length the frames' split refuses, or a body ending inside a frame, is bad_frame", %{
      client: client
    } do
      for body <- [<<65_537::32, ?c, "x">>, <<1::32, ?c>>, <<10::32, ?c, "short">>] do
        {port, _server} =
          raw_host!(fn socket ->
            :gen_tcp.send(socket, frames_head() <> chunked(body) <> "0\r\n\r\n")
          end)

        assert {:error, "bad_frame"} =
                 HostClient.attached_fetch(
                   %{client | host_url: "http://127.0.0.1:#{port}"},
                   attached(),
                   options(sink())
                 ),
               inspect(body)

        assert events() == []
      end
    end

    test "the deadline after the status is a timeout, and a transport failure after it an http_error",
         %{client: client} do
      frame = <<6::32, ?c, "abcde">>

      # The host answers its status and one frame, and holds the response
      # open until the call has been answered: nothing but the deadline
      # ends it.
      {port, host} =
        raw_host!(fn socket ->
          :gen_tcp.send(socket, frames_head() <> chunked(frame))
          receive do: (:answered -> :ok)
        end)

      # The deadline is counted from before the request, so it is long
      # enough for the status to arrive inside it on a loaded host, and is
      # waited out. The frame handed over says the status came first.
      options = options(sink(), within: 2_000)

      calling =
        Task.async(fn ->
          answer =
            HostClient.attached_fetch(
              %{client | host_url: "http://127.0.0.1:#{port}"},
              attached(),
              options
            )

          {answer, System.system_time(:millisecond)}
        end)

      assert_receive {:event, {:frame, <<?c, "abcde">>}}, 2_000
      assert {{:error, "timeout"}, answered} = Task.await(calling, 10_000)

      # The deadline ended the call, and nothing before it. The client
      # reads the same clock in the same unit for the deadline it was
      # given, and that clock does not run back, so no margin is allowed.
      assert answered >= options.deadline
      send(host, :answered)
      assert events() == []

      {port, _server} =
        raw_host!(fn socket ->
          :gen_tcp.send(socket, frames_head() <> chunked(frame))
          :gen_tcp.close(socket)
        end)

      assert {:error, "http_error"} =
               HostClient.attached_fetch(
                 %{client | host_url: "http://127.0.0.1:#{port}"},
                 attached(),
                 options(sink())
               )

      assert [{:frame, <<?c, "abcde">>}] = events()
    end

    test "a halted or failed answer closes its connection", %{client: client} do
      test = self()

      {port, _server} =
        raw_host!(fn socket ->
          :gen_tcp.send(socket, frames_head() <> chunked(<<6::32, ?c, "abcde">>))
          send(test, {:closed?, :gen_tcp.recv(socket, 0, 5_000)})
        end)

      assert :halted =
               HostClient.attached_fetch(
                 %{client | host_url: "http://127.0.0.1:#{port}"},
                 attached(),
                 options(sink(fn _ -> :halt end))
               )

      assert_receive {:closed?, {:error, :closed}}, 5_000
    end
  end

  # A host speaking HTTP/1.1 byte for byte: one connection, its request
  # read whole, then `answer` run on the socket.
  defp raw_host!(answer) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    server =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen, 10_000)
        read_request(socket, "")
        answer.(socket)
        # sleep-ok: the raw host keeps the socket open after its answer, so the client, not a
        # close, ends the exchange
        Process.sleep(5_000)
      end)

    on_exit(fn -> :gen_tcp.close(listen) end)
    {port, server}
  end

  defp read_request(socket, read) do
    case :binary.split(read, "\r\n\r\n") do
      [head, body] ->
        [_, length] = Regex.run(~r/content-length: (\d+)/i, head)
        missing = String.to_integer(length) - byte_size(body)
        if missing > 0, do: {:ok, _rest} = :gen_tcp.recv(socket, missing, 5_000)

      [_partial] ->
        {:ok, more} = :gen_tcp.recv(socket, 0, 5_000)
        read_request(socket, read <> more)
    end
  end

  defp frames_head do
    "HTTP/1.1 200 OK\r\ncontent-type: #{WorkerWire.attached_frames_content_type()}\r\n" <>
      "transfer-encoding: chunked\r\n\r\n"
  end

  defp chunked(bytes), do: Integer.to_string(byte_size(bytes), 16) <> "\r\n" <> bytes <> "\r\n"

  # The answer envelope the client reads is the one `Prima.WorkerWire` builds.
  test "the answers read are the worker protocol's envelopes" do
    assert WorkerWire.ok(1) |> Jason.encode!() |> Jason.decode!() == %{"v" => 3, "ok" => 1}

    assert WorkerWire.error(:lost) |> Jason.encode!() |> Jason.decode!() ==
             %{"v" => 3, "error" => "lost"}
  end
end

defmodule Locus.Runtime.HostClientPoolTest do
  @moduledoc """
  The HTTP client starts a pool of connections for each set of connect
  options it is given, and keeps it: an attached fetch connects under the
  host calls' options whatever its deadline, so fetches at many deadlines
  start no pool each. It counts the client's pools, which any test may
  start, so it runs alone.
  """

  use ExUnit.Case, async: false

  alias Prima.AttachedRequest
  alias Locus.Runtime.HostClient
  alias Locus.Runtime.Test.ScriptedHost

  test "attached fetches at different deadlines start no connection pool each" do
    host = ScriptedHost.start!()
    attempt = ScriptedHost.attempt!(host)
    ScriptedHost.script(host, "attached_fetch", {:frames, [{:head, 200, []}, :end]})

    fetch = fn within ->
      request = %AttachedRequest{
        call_id: AttachedRequest.call_id(:crypto.strong_rand_bytes(16)),
        connection: "api_key",
        method: "GET",
        url: "https://api.example.com/v1/x",
        headers: [],
        body: "",
        purpose: :fetch
      }

      HostClient.attached_fetch(attempt.client, request, %{
        sink: fn _event -> :ok end,
        max_response_size: 1_000,
        deadline: System.system_time(:millisecond) + within
      })
    end

    pools = fn -> DynamicSupervisor.count_children(Req.FinchSupervisor).active end

    assert :ok = fetch.(10_000)
    before = pools.()
    for within <- [5_001, 6_002, 7_003], do: assert(:ok = fetch.(within))
    assert pools.() == before
  end
end
