# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.HostAPITest do
  @moduledoc """
  A field name a `secret_denied` `record_denial` carries is the guest's, so
  the contract bounds it: 1 to 256 bytes of UTF-8 without a control
  character, which the runner reports and CYFR records, and nothing else.

  Every host call of `tests/fixtures/host_api.json` reproduces from its
  fields and the vector keys: its sealed body, its header over the sealed
  bytes and its sealed answer, and it verifies at the vector standing. Each
  header a listener refuses before the body is refused with its error, in
  `Prima.WorkerAuth`'s order; the report verifies under its service's
  dispatch key and names its member; a retried call is the same body under
  a fresh header; and every `egress_pin` case's args and answer read
  through `Prima.PinnedTarget`.

  Every `egress_policy` case reproduces and reads the same way, and its
  answer is the policy's: pinned only for a host its `domains` match
  (`Prima.Network.domain_allowed?/2`) and, for a redirect, a URL with the
  origin of the pin it follows (`Prima.Network.same_origin?/2`); the
  headers a hop to another origin keeps are
  `Prima.Network.strip_credentials/1`'s.

  The `attached_fetch` call reads as a `Prima.AttachedRequest`, carries no
  single answer and is refused only by sealed guest errors naming its
  call id; every frame case reads frame by frame to its expected frames
  and refusal; and an `egress_pin` naming the purpose CYFR alone takes is
  refused `malformed`.
  """

  use ExUnit.Case, async: true

  alias Prima.{AttachedRequest, HostAPI, Network, PinnedTarget, Refusal, WorkerAuth, WorkerWire}

  @vectors Path.expand("../../../../tests/fixtures/host_api.json", __DIR__)
           |> File.read!()
           |> Jason.decode!()

  @call_fields ~w(athanor_id execution_id attempt fence generation service boot runner member ts nonce)a
  @dispatch_fields ~w(service boot ts nonce)a

  defp root, do: Base.decode16!(@vectors["keys"]["root_hex"], case: :lower)
  defp atoms(wire, names), do: Map.new(names, &{&1, Map.fetch!(wire, Atom.to_string(&1))})
  defp standing(wire), do: %{generation: wire["generation"], member: wire["member"]}

  defp keys!(fields) do
    {:ok, keys} = WorkerAuth.attempt_keys(root(), fields)
    keys
  end

  defp dispatch_key do
    {:ok, worker_key} = WorkerAuth.worker_key(root(), @vectors["report"]["fields"]["service"])
    WorkerAuth.dispatch_key(worker_key)
  end

  # A call reproduces from its fields and verifies at the vector standing,
  # header first and then over its body; its answer, where it has one,
  # opens as its own.
  defp reproduces(call) do
    fields = atoms(call["fields"], @call_fields)
    keys = keys!(fields)
    body_iv = Base.decode16!(call["body_iv_hex"], case: :lower)

    assert {:ok, call["body_sealed"]} ==
             WorkerAuth.seal_call(keys.seal, :body, fields, call["body"], body_iv)

    assert {:ok, call["header"]} ==
             WorkerAuth.host_call_header(keys.call, fields, call["body_sealed"])

    standing = standing(@vectors["standing"])

    assert {:ok, ^fields, hash} =
             WorkerAuth.verify_host_call_header(root(), call["header"], fields.ts, standing)

    assert :ok = WorkerAuth.verify_body(hash, call["body_sealed"])
    assert {:ok, body} = WorkerAuth.open_call(keys.seal, :body, fields, call["body_sealed"])
    assert body == call["body"]

    {:ok, callback, args} = WorkerWire.read_request_body(HostAPI, Jason.decode!(body))
    assert Atom.to_string(callback) == call["callback"]
    {fields, args, answer_of_call(call, keys, fields)}
  end

  defp answer_of_call(%{"answer" => _} = call, keys, fields),
    do: sealed_answer(call, keys, fields) |> Jason.decode!() |> WorkerWire.read_answer()

  defp answer_of_call(_call, _keys, _fields), do: nil

  # An answer reproduces from its iv, opens as its call's answer and as
  # nothing else.
  defp sealed_answer(answer, keys, fields) do
    iv = Base.decode16!(answer["answer_iv_hex"], case: :lower)

    assert {:ok, answer["answer_sealed"]} ==
             WorkerAuth.seal_call(keys.seal, :answer, fields, answer["answer"], iv)

    assert {:ok, opened} =
             WorkerAuth.open_call(keys.seal, :answer, fields, answer["answer_sealed"])

    assert opened == answer["answer"]

    assert {:error, :unsealable} =
             WorkerAuth.open_call(keys.seal, :body, fields, answer["answer_sealed"])

    opened
  end

  describe "the host API vectors" do
    test "name every callback's route, retry class and timeout, the bounds and the window" do
      names = Enum.map(HostAPI.callbacks(), &Atom.to_string/1)

      assert Enum.sort(Map.keys(@vectors["routes"])) == Enum.sort(names)

      for callback <- HostAPI.callbacks(), name = Atom.to_string(callback) do
        assert @vectors["routes"][name] == WorkerWire.host_route(callback)
        assert @vectors["retries"][name] == Atom.to_string(HostAPI.retry(callback))
        assert @vectors["timeouts_ms"][name] == HostAPI.request_timeout_ms(callback)
      end

      assert @vectors["max_body_bytes"] == HostAPI.max_body_bytes()
      assert @vectors["max_answer_bytes"] == HostAPI.max_answer_bytes()
      assert @vectors["window_ms"] == WorkerAuth.window_ms()
    end

    test "hold one call of every runner callback, each reproducing and verifying" do
      callbacks = Enum.map(@vectors["calls"], & &1["callback"])

      assert callbacks ==
               HostAPI.callbacks() |> List.delete(:runner_exited) |> Enum.map(&Atom.to_string/1)

      for call <- @vectors["calls"] do
        assert {_fields, _args, answer} = reproduces(call)

        # An attached request's success is its frames, not one answer.
        if call["callback"] == "attached_fetch",
          do: assert(answer == nil),
          else: assert(match?({:ok, _value}, answer), call["callback"])

        assert call["refusals"] != [], call["callback"]

        for %{"answer" => refused, "why" => why} <- call["refusals"] do
          assert {:error, name, _fields} = WorkerWire.read_answer(Jason.decode!(refused))
          assert is_binary(why) and why != ""
          assert name in ["lost", "unavailable"] or refusal_of?(call["callback"], name), why
        end
      end
    end

    test "refuse each pre-body header with its error, in the documented order" do
      names = Enum.map(@vectors["pre_body_refusals"], & &1["error"])

      assert names == ~w(unknown_version malformed outside_window bad_mac generation_mismatch
                         member_mismatch replayed)

      [storage] = Enum.filter(@vectors["calls"], &(&1["callback"] == "storage"))

      for %{"name" => name, "header" => header, "now" => now, "standing" => standing} = vector <-
            @vectors["pre_body_refusals"] do
        assert vector["status"] == 401, name

        case vector["error"] do
          "replayed" ->
            # The header verifies: the refusal is the listener's, for a nonce
            # a call that is never retried already presented for its attempt.
            assert {:ok, fields, _hash} =
                     WorkerAuth.verify_host_call_header(root(), header, now, standing(standing))

            assert fields.nonce == storage["fields"]["nonce"]
            assert fields.attempt == storage["fields"]["attempt"]
            assert HostAPI.retry(:storage) == :never

          error ->
            expected = String.to_existing_atom(error)

            assert {:error, ^expected} =
                     WorkerAuth.verify_host_call_header(root(), header, now, standing(standing)),
                   name
        end
      end
    end

    test "a report verifies under its service's dispatch key and names its member" do
      report = @vectors["report"]
      fields = atoms(report["fields"], @dispatch_fields)

      assert {:ok, report["header"]} ==
               WorkerAuth.report_header(dispatch_key(), fields, report["body"])

      assert {:ok, ^fields} =
               WorkerAuth.verify_report(root(), report["header"], report["body"], fields.ts)

      assert {:ok, :runner_exited, %{"member" => member}} =
               WorkerWire.read_request_body(HostAPI, Jason.decode!(report["body"]))

      assert member == @vectors["standing"]["member"]
      assert {:ok, true} = WorkerWire.read_answer(Jason.decode!(report["answer"]))

      cross = report["cross_member"]
      cross_fields = atoms(cross["fields"], @dispatch_fields)

      assert {:ok, cross["header"]} ==
               WorkerAuth.report_header(dispatch_key(), cross_fields, cross["body"])

      assert {:ok, _} =
               WorkerAuth.verify_report(root(), cross["header"], cross["body"], cross_fields.ts)

      assert {:ok, :runner_exited, %{"member" => other}} =
               WorkerWire.read_request_body(HostAPI, Jason.decode!(cross["body"]))

      assert other != member
      assert cross["error"] == "lost"
    end

    test "a retried call is the same body under a fresh header" do
      %{"first" => first, "second" => second} = @vectors["retry_identity"]

      assert first["body"] == second["body"]
      assert first["header"] != second["header"]
      assert first["fields"]["nonce"] != second["fields"]["nonce"]

      for try <- [first, second] do
        fields = atoms(try["fields"], @call_fields)
        keys = keys!(fields)
        iv = Base.decode16!(try["body_iv_hex"], case: :lower)

        assert {:ok, try["body_sealed"]} ==
                 WorkerAuth.seal_call(keys.seal, :body, fields, try["body"], iv)

        assert {:ok, try["header"]} ==
                 WorkerAuth.host_call_header(keys.call, fields, try["body_sealed"])
      end

      assert {:ok, :admit_child, %{"child_key" => key}} =
               WorkerWire.read_request_body(HostAPI, Jason.decode!(first["body"]))

      assert HostAPI.valid_child_key?(key)
      assert HostAPI.retry(:admit_child) == :keyed
    end

    test "every egress_pin case reads through Prima.PinnedTarget, pinned or refused by name" do
      cases = Map.new(@vectors["egress_pin_cases"], &{&1["name"], &1})

      assert Enum.sort(Map.keys(cases)) ==
               Enum.sort(
                 ~w(fetch stream redirect denied metadata resolution redirect_credentials)
               )

      for {name, call} <- cases do
        {fields, args, answer} = reproduces(call)
        assert call["callback"] == "egress_pin"
        assert {:ok, request} = PinnedTarget.read_request(args), name

        assert {:ok, ^args} =
                 PinnedTarget.request_args(request.url, request.purpose, request.from)

        case answer do
          {:ok, wire} ->
            assert {:ok, pin} = PinnedTarget.read(wire), name
            assert PinnedTarget.to_wire(pin) == wire
            assert pin.expires_at == fields.ts + WorkerAuth.window_ms()
            uri = URI.parse(request.url)
            assert pin.scheme == uri.scheme and pin.port == uri.port, name
            assert String.trim(pin.host, "[") |> String.trim("]") == uri.host, name

          {:error, error, fields} ->
            assert fields == %{}
            assert error == name
            assert String.to_existing_atom(error) in PinnedTarget.refusals()
        end
      end

      assert cases["stream"] |> answer_of() |> Map.fetch!("family") == 6
      assert cases["fetch"] |> answer_of() |> Map.fetch!("family") == 4

      for hop <- ["redirect", "redirect_credentials"] do
        {:ok, request} = cases[hop] |> args_of() |> PinnedTarget.read_request()
        assert request.purpose == :redirect
        assert request.from == answer_of(cases["fetch"])["id"]
      end
    end
  end

  describe "the egress policy vectors" do
    test "pin only a host in domains and a hop on its pin's origin, refused by name otherwise" do
      cases = @vectors["egress_policy_cases"]

      assert Enum.map(cases, & &1["name"]) ==
               ~w(fetch outside_domains redirect_other_port redirect_default_port
                  redirect_strip_credentials fetch_ipv6 redirect_ipv6_spelling)

      # The URL each pin was answered for, by its id, for the hops naming it.
      pinned_urls =
        for call <- cases,
            {:ok, %{"id" => id}} <- [answer_result(call)],
            into: %{},
            do: {id, args_of(call)["url"]}

      for call <- cases, name = call["name"] do
        {fields, args, answer} = reproduces(call)
        assert call["callback"] == "egress_pin"
        assert call["refusals"] == []
        assert {:ok, request} = PinnedTarget.read_request(args), name
        uri = URI.parse(request.url)
        expect = call["expect"]

        assert Network.domain_allowed?(uri.host, call["domains"]) == expect["domain_allowed"],
               name

        same_origin = same_origin(request, uri, expect, pinned_urls, name)

        case answer do
          {:ok, wire} ->
            assert expect["domain_allowed"] and same_origin, name
            assert {:ok, pin} = PinnedTarget.read(wire), name
            assert pin.expires_at == fields.ts + WorkerAuth.window_ms()
            assert pin.scheme == uri.scheme and pin.port == uri.port, name
            assert Network.same_origin?(uri, "#{pin.scheme}://#{pin.host}:#{pin.port}"), name

          {:error, error, %{}} ->
            refute expect["domain_allowed"] and same_origin, name
            expected = if expect["domain_allowed"], do: "redirect_credentials", else: "denied"
            assert error == expected, name
        end
      end
    end

    test "a hop to another origin keeps the headers that carry no credential, in order" do
      [call] = Enum.filter(@vectors["egress_policy_cases"], &Map.has_key?(&1, "headers_before"))
      assert call["expect"]["same_origin"] == false
      before = Enum.map(call["headers_before"], fn [name, value] -> {name, value} end)
      kept = Enum.map(call["headers_after"], fn [name, value] -> {name, value} end)

      assert Network.strip_credentials(before) == kept
      refute Enum.any?(kept, fn {name, _value} -> Network.credential_header?(name) end)

      # The hop carries every name of the roster, and some in another case
      # than the roster's.
      dropped = Enum.map(before -- kept, fn {name, _value} -> name end)
      assert Network.credential_headers() -- Enum.map(dropped, &String.downcase/1) == []
      assert Enum.any?(dropped, &(&1 != String.downcase(&1)))
    end
  end

  # A redirect's hop names a pin of an earlier case and is on its origin or
  # not, as the case expects; a first request is on no pin's origin to check.
  defp same_origin(%{purpose: :redirect, from: from}, uri, expect, pinned_urls, name) do
    assert Map.has_key?(pinned_urls, from), name
    assert Network.same_origin?(pinned_urls[from], uri) == expect["same_origin"], name
    expect["same_origin"]
  end

  defp same_origin(_first, _uri, expect, _pinned_urls, name) do
    refute Map.has_key?(expect, "same_origin"), name
    true
  end

  defp answer_result(call), do: call["answer"] |> Jason.decode!() |> WorkerWire.read_answer()

  defp args_of(call), do: Jason.decode!(call["body"])["args"]
  defp answer_of(call), do: Jason.decode!(call["answer"])["ok"]

  # The refusals a callback answers beyond the ones every call may.
  defp refusal_of?("attach", name),
    do: name in ~w(replayed claim_expired bad_mac unknown_version malformed setup_required)

  defp refusal_of?("complete", name), do: name == "failed"
  defp refusal_of?("fetch_artifact", name), do: name == "not_found"

  defp refusal_of?("egress_pin", name),
    do: name in Enum.map(PinnedTarget.refusals(), &Atom.to_string/1)

  defp refusal_of?(callback, name)
       when callback in ~w(oauth_token take_rate storage admit_child tool_call attached_fetch),
       do: name == "guest_error"

  defp refusal_of?(_callback, _name), do: false

  test "a field name is 1 to 256 bytes of UTF-8 without a control character" do
    for name <- ["K", "PROBE_KEY", "api key", "clé-ünïcode", String.duplicate("N", 256)] do
      assert HostAPI.valid_field_name?(name), inspect(name)
    end

    for name <-
          [
            "",
            String.duplicate("N", 257),
            "PROBE\nKEY",
            "tab\tbed",
            "nul\0byte",
            "del\x7Fbyte",
            "esc\e[31m",
            <<0xFF, 0xFE>>,
            :PROBE_KEY,
            nil,
            42
          ] do
      refute HostAPI.valid_field_name?(name), inspect(name)
    end
  end

  test "a multi-byte name is bounded by its bytes, not its characters" do
    assert HostAPI.valid_field_name?(String.duplicate("é", 128))
    refute HostAPI.valid_field_name?(String.duplicate("é", 129))
  end

  test "a denial reported to CYFR is never retried: its effect may have happened" do
    assert HostAPI.retry(:record_denial) == :never
  end

  describe "an attached request" do
    setup do
      [call] = Enum.filter(@vectors["calls"], &(&1["callback"] == "attached_fetch"))
      %{call: call}
    end

    test "is never retried, at its own route, within the window", %{call: call} do
      assert HostAPI.retry(:attached_fetch) == :never
      assert WorkerWire.host_route(:attached_fetch) == "/host/v1/attached_fetch"
      assert HostAPI.request_timeout_ms(:attached_fetch) == WorkerAuth.window_ms()
      assert :attached_fetch in HostAPI.callbacks()
      assert WorkerWire.attached_frames_content_type() == "application/vnd.cyfr.frames"
      refute Map.has_key?(call, "answer")
    end

    test "its args read as the attached request, and back", %{call: call} do
      {_fields, args, nil} = reproduces(call)
      assert {:ok, %AttachedRequest{} = request} = AttachedRequest.read(args)
      assert AttachedRequest.to_args(request) == args
      assert request.purpose == :stream and request.body == ~s({"q":1})
    end

    test "is refused only by sealed guest errors naming its call id", %{call: call} do
      {fields, args, nil} = reproduces(call)
      keys = keys!(fields)

      types =
        for refusal <- call["refusals"] do
          opened = sealed_answer(refusal, keys, fields)

          assert {:error, "guest_error", %{"type" => type, "message" => message, "call_id" => id}} =
                   opened |> Jason.decode!() |> WorkerWire.read_answer()

          assert id == args["call_id"] and refusal["call_id"] == id

          reason = String.to_existing_atom(type)

          assert reason in Refusal.credential_reasons() or reason == :attach_unavailable
          assert message == Refusal.message(reason)

          type
        end

      assert types ==
               ~w(credential_header_refused connection_not_granted destination_mismatch
                  connection_cap component_not_admitted attach_unavailable)

      assert [unavailable] =
               Enum.filter(call["refusals"], &(&1["answer"] =~ "attach_unavailable"))

      assert Jason.decode!(unavailable["answer"]) == %{
               "v" => 1,
               "error" => "guest_error",
               "type" => "attach_unavailable",
               "message" => "Attached requests are not built yet.",
               "call_id" => args["call_id"]
             }
    end

    test "every frame case reads, frame by frame, to its frames and refusal" do
      cases = @vectors["frame_cases"]
      seal = keys!(atoms(hd(@vectors["calls"])["fields"], @call_fields)).seal
      assert cases["max_frame_bytes"] == WorkerAuth.max_frame_bytes()
      assert cases["max_chunk_bytes"] == WorkerAuth.max_chunk_bytes()

      assert Enum.map(cases["cases"], & &1["name"]) ==
               ~w(head_chunk_end head_end error_after_head error_first out_of_sequence
                  chunk_first after_end another_call bad_tag kind_byte_changed unknown_kind
                  oversize)

      for kase <- cases["cases"] do
        stream = Enum.map_join(kase["frames"], &Base.decode16!(&1["frame_hex"], case: :lower))

        for %{"sealed_for" => sealed_for, "frame_hex" => frame_hex} <- kase["frames"] do
          kind = String.to_existing_atom(sealed_for["kind"])
          iv = Base.decode16!(sealed_for["iv_hex"], case: :lower)
          plaintext = Base.decode64!(sealed_for["plaintext_b64"])

          assert {:ok, Base.decode16!(frame_hex, case: :lower)} ==
                   WorkerAuth.seal_frame(
                     seal,
                     :answer,
                     sealed_for["call_id"],
                     sealed_for["seq"],
                     kind,
                     plaintext,
                     iv
                   ),
                 kase["name"]
        end

        assert frames_read(seal, cases["call_id"], stream) ==
                 {kase["expect"]["read"], kase["expect"]["error"]},
               kase["name"]
      end
    end
  end

  # The frames a runner reads from `stream`, one at a time, and the refusal
  # that ended it, both as the vectors write them.
  defp frames_read(seal, call_id, stream) do
    reader = WorkerAuth.frame_reader(seal, call_id)

    case WorkerAuth.split_frames(stream) do
      {:error, reason} ->
        {[], Atom.to_string(reason)}

      {:ok, frames, ""} ->
        Enum.reduce_while(frames, {reader, []}, fn frame, {reader, read} ->
          case WorkerAuth.read_frame(reader, frame) do
            {:ok, one, reader} -> {:cont, {reader, read ++ [wire(one)]}}
            {:error, reason} -> {:halt, {:refused, read, Atom.to_string(reason)}}
          end
        end)
        |> case do
          {:refused, read, reason} -> {read, reason}
          {_reader, read} -> {read, nil}
        end
    end
  end

  defp wire(%{kind: :head, status: status, headers: headers}),
    do: %{"kind" => "head", "status" => status, "headers" => Enum.map(headers, &Tuple.to_list/1)}

  defp wire(%{kind: :chunk, body: body}),
    do: %{"kind" => "chunk", "body_b64" => Base.encode64(body)}

  defp wire(%{kind: :end}), do: %{"kind" => "end"}

  defp wire(%{kind: :error, type: type, message: message}),
    do: %{"kind" => "error", "type" => type, "message" => message}

  test "an egress_pin naming the purpose CYFR alone takes is refused malformed" do
    assert [%{"name" => "attached"} = call] = @vectors["egress_pin_internal_purposes"]
    {_fields, args, answer} = reproduces(call)
    assert args["purpose"] == "attached"
    assert answer == {:error, "malformed", %{}}
    assert PinnedTarget.read_request(args) == {:error, :malformed}
    assert PinnedTarget.request_args(args["url"], :attached) == :error
    refute :attached in PinnedTarget.purposes()
  end

  test "a field denial is secret_denied or disclosure_refused, each naming a field" do
    assert HostAPI.field_denials() == ["secret_denied", "disclosure_refused"]
    assert HostAPI.retry(:record_denial) == :never
  end

  test "a pin is asked again freely, within the window" do
    assert HostAPI.retry(:egress_pin) == :idempotent
    assert HostAPI.request_timeout_ms(:egress_pin) == WorkerAuth.window_ms()
    assert WorkerWire.host_route(:egress_pin) == "/host/v1/egress_pin"
  end
end
