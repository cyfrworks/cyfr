# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.TinctureWireTest do
  @moduledoc """
  The frame's wire as data: every request body of
  `tests/fixtures/tincture_wire.json` decodes and encodes back to itself
  and carries its credential as a bearer, and the public request names its
  tincture in place of one; every answer reads back; the refusal is a
  `Prima.Refusal`'s projection and nothing more; the stream connection's
  messages are the ones the encoders write, each refused one is refused
  for the subscription or the connection, and each rejection's refusal
  reads back as itself; the delivery contract's messages are the ones
  their encoders write; every shell
  message decodes and every refused one is refused; a canvas's handshake
  replies are the ones the builder writes, and no refused reply is; and
  a canvas's paths are the fixture's, a value outside its grammar
  raising. Beside them, the tincture URL grammar of
  `tests/fixtures/component_refs.json`.
  """

  use ExUnit.Case, async: true

  alias Prima.{TinctureUrl, TinctureWire}

  @vectors Path.expand("../../../../tests/fixtures/tincture_wire.json", __DIR__)
  @refs Path.expand("../../../../tests/fixtures/component_refs.json", __DIR__)

  defp vectors, do: @vectors |> File.read!() |> Jason.decode!()

  defp kind(name), do: Enum.find(TinctureWire.kinds(), &(Atom.to_string(&1) == name))

  test "the version, header and routes are the fixture's" do
    v = vectors()
    assert v["version"] == TinctureWire.version()
    assert v["bearer_header"] == TinctureWire.bearer_header()

    assert v["routes"] ==
             Map.new(TinctureWire.routes(), fn {kind, route} -> {Atom.to_string(kind), route} end)

    routes = Map.values(TinctureWire.routes())
    assert Enum.uniq(routes) == routes
  end

  test "every request decodes, encodes back to its body and carries a bearer" do
    requests = vectors()["requests"]
    assert Enum.sort(Enum.map(requests, &kind(&1["kind"]))) == TinctureWire.kinds()

    for %{"kind" => name, "headers" => headers, "body" => body} <- requests do
      kind = kind(name)
      assert {:ok, decoded} = TinctureWire.decode_request(kind, body)
      assert TinctureWire.request(kind, decoded) == body

      assert {:ok, credential} = TinctureWire.read_bearer(headers[TinctureWire.bearer_header()])
      assert TinctureWire.bearer(credential) == headers[TinctureWire.bearer_header()]
      refute Enum.any?(Map.values(body), &(&1 == credential))
    end
  end

  test "a body at another version, with a field its kind does not carry, or a malformed field is refused" do
    [invoke, action] = vectors()["requests"] |> Enum.map(& &1["body"])

    assert {:error, _} = TinctureWire.decode_request(:invoke, Map.delete(invoke, "v"))
    assert {:error, _} = TinctureWire.decode_request(:invoke, %{invoke | "v" => 2})
    assert {:error, _} = TinctureWire.decode_request(:invoke, Map.put(invoke, "credential", "x"))
    assert {:error, _} = TinctureWire.decode_request(:invoke, %{invoke | "ref" => "not a ref"})
    assert {:error, _} = TinctureWire.decode_request(:action, %{action | "operation" => "list"})
    assert {:error, _} = TinctureWire.decode_request(:action, %{action | "args" => [1]})
    assert {:error, _} = TinctureWire.decode_request(:action, "not an object")
  end

  test "a public request names its tincture and carries no bearer" do
    %{"kind" => name, "headers" => headers, "body" => body} = vectors()["public_request"]
    kind = kind(name)
    assert headers == %{}

    assert {:ok,
            %{public: %{athanor: "@alice", publisher: "local", name: "weather-lookup"}} = decoded} =
             TinctureWire.decode_request(kind, body)

    assert TinctureWire.request(kind, decoded) == body

    public = body["public"]

    for bad <- [
          Map.put(public, "athanor_id", "ath_x"),
          Map.delete(public, "name"),
          %{public | "athanor" => "Not A Segment"},
          %{public | "publisher" => "../x"},
          "@alice/local/weather-lookup"
        ] do
      assert {:error, _} = TinctureWire.decode_request(kind, %{body | "public" => bad})
    end

    assert TinctureWire.public_identity?(%{athanor: "@home", publisher: "local", name: "w"})
    refute TinctureWire.public_identity?(%{athanor: "home", publisher: "local", name: "w"})
    refute TinctureWire.public_identity?(%{athanor: "@home", publisher: "local"})
  end

  describe "the stream connection" do
    defp connection, do: vectors()["connection"]

    test "its path, bounds and close codes are the fixture's" do
      c = connection()
      assert c["paths"]["app"] == TinctureWire.socket_path()
      assert c["max_subscriptions"] == TinctureWire.max_subscriptions()
      assert c["max_message_bytes"] == TinctureWire.max_message_bytes()
      assert c["idle_ms"] == TinctureWire.idle_ms()

      for {reason, code} <- c["close_codes"],
          do: assert(TinctureWire.close_code(String.to_existing_atom(reason)) == code)
    end

    test "every message a frame sends decodes and encodes back to itself" do
      for message <- connection()["from_frame"] do
        case TinctureWire.decode_message(message) do
          {:ok,
           {:subscribe, %{sub: sub, credential: credential, stream: stream, subject: subject}}} ->
            assert TinctureWire.subscribe(sub, credential, stream, subject) == message

          {:ok, {:unsubscribe, sub}} ->
            assert TinctureWire.unsubscribe(sub) == message
        end
      end
    end

    test "a refused message refuses its subscription when its number reads, and the connection otherwise" do
      refused = connection()["refused"]
      assert Enum.any?(refused, &(&1["refuses"] == "subscription"))
      assert Enum.any?(refused, &(&1["refuses"] == "connection"))

      for %{"why" => why, "message" => message, "refuses" => refuses} <- refused do
        case {refuses, TinctureWire.decode_message(message)} do
          {"subscription", {:refused, sub, sentence}} ->
            assert sub == message["sub"], why
            assert is_binary(sentence), why

          {"connection", {:error, sentence}} ->
            assert is_binary(sentence), why

          {_refuses, other} ->
            flunk("#{why}: #{inspect(other)}")
        end
      end
    end

    test "every answer is the one its encoder writes, and an error is a refusal's projection" do
      for message <- connection()["to_frame"] do
        written =
          case message do
            %{"type" => "subscribed", "sub" => sub} ->
              TinctureWire.subscribed(sub)

            %{"type" => "event"} = event ->
              TinctureWire.event(
                event["sub"],
                event["stream"],
                event["subject"],
                event["id"],
                event["data"]
              )

            %{"type" => "ended", "error" => _error} = ended ->
              ended_of(ended)

            %{"type" => "ended", "sub" => sub} ->
              TinctureWire.ended(sub, nil)
          end

        assert written == message
      end
    end

    test "what the handler hears of each subscription ends with the refusal event its error names" do
      to_frame = connection()["to_frame"]

      for %{"sub" => sub, "events" => events} <- connection()["heard"] do
        mine = Enum.filter(to_frame, &(&1["sub"] == sub))

        heard =
          for %{"type" => "event"} = event <- mine,
              do: %{"id" => event["id"], "event" => event["stream"], "data" => event["data"]}

        last =
          for %{"type" => "ended", "error" => error} <- mine,
              do: %{"id" => nil, "event" => TinctureWire.refusal_event(), "data" => error}

        assert heard ++ last == events
      end
    end
  end

  describe "the delivery contract's messages" do
    test "each message a canvas-readable stream is sent is the one its encoder writes" do
      for message <- vectors()["delivery"]["to_frame"] do
        written =
          case message do
            %{"type" => "subscribed", "sub" => sub} ->
              TinctureWire.subscribed(sub)

            %{"type" => "event"} = event ->
              TinctureWire.event(
                event["sub"],
                event["stream"],
                event["subject"],
                event["id"],
                event["data"]
              )

            %{"type" => "snapshot", "sub" => sub, "at" => at} ->
              TinctureWire.snapshot(sub, time(at))

            %{"type" => "resync", "sub" => sub} ->
              TinctureWire.resync(sub)

            %{"type" => "stale", "sub" => sub, "at" => at} ->
              TinctureWire.stale(sub, time(at))

            %{"type" => "ended", "error" => _error} = ended ->
              ended_of(ended)
          end

        assert written == message
      end
    end

    test "a change carries its revision and time, and every heard state is one the vectors show" do
      %{"to_frame" => to_frame, "heard" => heard} = vectors()["delivery"]

      for %{"type" => "event", "data" => data} <- to_frame do
        assert is_integer(data["revision"])
        assert data["revision"] == data["at"] |> time() |> DateTime.to_unix(:microsecond)
      end

      assert heard |> Enum.map(& &1["state"]) |> Enum.sort() ==
               ~w(denied stale suspended unavailable)
    end

    test "an end names a reason beside its refusal only for a reason the frame acts on" do
      assert TinctureWire.ended_reasons() == vectors()["delivery"]["ended_reasons"]

      for reason <- TinctureWire.ended_reasons() do
        refusal = %{refusal_of(error_vector()) | reason: reason_of(reason)}
        assert %{"reason" => ^reason, "error" => error} = TinctureWire.ended(1, refusal)
        refute Map.has_key?(error, "reason")
      end

      for reason <- [:frame_moved, :vector, {:frame_suspended, :nested}, nil] do
        refute Map.has_key?(
                 TinctureWire.ended(1, %{refusal_of(error_vector()) | reason: reason}),
                 "reason"
               )
      end
    end
  end

  defp time(iso) do
    {:ok, at, 0} = DateTime.from_iso8601(iso)
    at
  end

  # The `ended` a vector shows, built from its refusal and the reason it
  # names beside it, if any.
  defp ended_of(%{"sub" => sub, "error" => error} = ended),
    do: TinctureWire.ended(sub, refusal_of(error, ended["reason"]))

  # The refusal reason an end names: the reasons are FrameAdmission's, which
  # this app does not load, so each is named here.
  defp reason_of(reason), do: Map.fetch!(%{"frame_suspended" => :frame_suspended}, reason)

  defp error_vector, do: hd(for %{"error" => e} <- vectors()["delivery"]["to_frame"], do: e)

  # The refusal a vector's error projects: the reason its end names, or a
  # reason of its own, which the projection never carries.
  defp refusal_of(%{"class" => class, "message" => message, "stage" => stage}, reason \\ nil) do
    %Prima.Refusal{
      class: String.to_existing_atom(class),
      reason: if(reason, do: reason_of(reason), else: :vector),
      message: message,
      stage: String.to_existing_atom(stage)
    }
  end

  test "a bearer is `Bearer <credential>` and nothing else" do
    assert TinctureWire.read_bearer("Bearer abc.def") == {:ok, "abc.def"}
    assert TinctureWire.read_bearer("Bearer ") == :error
    assert TinctureWire.read_bearer("Bearer a b") == :error
    assert TinctureWire.read_bearer("bearer abc") == :error
    assert TinctureWire.read_bearer(nil) == :error
  end

  test "every answer reads back" do
    for %{"kind" => name, "body" => body} <- vectors()["answers"] do
      assert {:ok, _value} = TinctureWire.decode_answer(kind(name), body)
    end

    assert TinctureWire.result(%{"temperature" => 21}) ==
             Enum.find(vectors()["answers"], &(&1["kind"] == "invoke"))["body"]
  end

  test "the refusal is the projection of a Prima.Refusal: its class, message and stage, never its reason" do
    %{"kind" => name, "refusal" => r, "body" => body} = vectors()["refusal"]
    assert {r["class"], r["stage"]} == {"forbidden", "admission"}

    refusal = %Prima.Refusal{
      class: :forbidden,
      reason: :undeclared_action,
      message: r["message"],
      stage: :admission
    }

    assert TinctureWire.refusal(refusal) == body
    refute inspect(body) =~ r["reason"]

    assert {:refused, %{class: "forbidden", stage: "admission"}} =
             TinctureWire.decode_answer(kind(name), body)

    assert {:error, :invalid_answer} =
             TinctureWire.decode_answer(kind(name), put_in(body, ["error", "class"], "nope"))

    assert {:error, :invalid_answer} =
             TinctureWire.decode_answer(kind(name), put_in(body, ["error", "reason"], "x"))
  end

  test "each subscription rejection is an `ended` before `subscribed` whose error reads back as itself" do
    %{"cases" => cases, "no_answer_classes" => no_answer} = vectors()["stream_rejections"]
    classes = Enum.map(Prima.Refusal.classes(), &Atom.to_string/1)
    assert no_answer -- classes == []

    answers = for %{"answer" => %{} = answer} <- cases, do: answer
    assert answers != []

    for answer <- answers, do: assert(ended_of(answer) == answer)

    # Every case says how the SDK rejects it, with a stage only for a
    # refusal it rejects as itself.
    for %{"answer" => answer, "rejects" => rejects} <- cases do
      assert Map.keys(rejects) -- ["stage"] == ["class", "message"], inspect(answer)

      case answer do
        %{"error" => %{"class" => class} = error} ->
          if class in no_answer,
            do: assert(rejects == %{"class" => "unavailable", "message" => error["message"]}),
            else: assert(rejects == error)

        nil ->
          refute Map.has_key?(rejects, "stage")
      end
    end
  end

  test "every shell verb has a message, and each decodes to its verb and frame" do
    shell = vectors()["shell"]

    assert shell |> Enum.map(& &1["verb"]) |> Enum.uniq() |> Enum.sort() ==
             Enum.sort(Enum.map(TinctureWire.verbs(), &Atom.to_string/1))

    for %{"verb" => verb, "message" => message} <- shell do
      assert {:ok, %{verb: decoded, frame: frame, args: args}} =
               TinctureWire.decode_shell_message(message)

      assert Atom.to_string(decoded) == verb
      assert TinctureWire.shell_message(decoded, frame, args) == message
    end
  end

  test "a shell message with another verb, no frame id or arguments its verb does not take is refused" do
    message = TinctureWire.shell_message(:ready, "frm_01a09fee2e4f")

    assert {:error, _} = TinctureWire.decode_shell_message(%{message | "verb" => "navigate"})
    assert {:error, _} = TinctureWire.decode_shell_message(%{message | "frame" => "short"})
    assert {:error, _} = TinctureWire.decode_shell_message(%{message | "args" => %{"x" => 1}})
    assert {:error, _} = TinctureWire.decode_shell_message(%{message | "v" => 2})

    open = TinctureWire.shell_message(:open, "frm_01a09fee2e4f", %{"ref" => "c:local.x"})
    assert {:error, _} = TinctureWire.decode_shell_message(open)

    long =
      TinctureWire.shell_message(:title, "frm_01a09fee2e4f", %{
        "title" => String.duplicate("a", 121)
      })

    assert {:error, _} = TinctureWire.decode_shell_message(long)

    for args <- [%{}, %{"name" => ""}, %{"name" => 7}, %{"name" => "api", "value" => "secret"}] do
      credential = %{message | "verb" => "credential", "args" => args}
      assert {:error, _} = TinctureWire.decode_shell_message(credential), inspect(args)
    end
  end

  test "every refused shell message is refused, for the reason the fixture gives" do
    invalid = vectors()["shell_invalid"]
    assert invalid != []

    for %{"why" => why, "message" => message} <- invalid do
      assert {:error, sentence} = TinctureWire.decode_shell_message(message), why
      assert is_binary(sentence), why
    end
  end

  test "a press names exactly a binding id and an action, and a failure exactly its stage" do
    press = %{"binding" => "feed_01a09fee-2e4f-7a5b-9c6d-7e8f9a0b1c2d", "action" => "refresh"}

    assert {:ok, %{verb: :press, args: ^press}} =
             TinctureWire.decode_shell_message(
               TinctureWire.shell_message(:press, "frm_01a09fee2e4f", press)
             )

    for args <- [%{}, Map.delete(press, "action"), %{press | "action" => 7}] do
      message = TinctureWire.shell_message(:press, "frm_01a09fee2e4f", args)
      assert {:error, _} = TinctureWire.decode_shell_message(message), inspect(args)
    end

    assert TinctureWire.stages() == vectors()["canvas"]["stages"]

    for stage <- TinctureWire.stages() do
      message = TinctureWire.shell_message(:failed, "frm_01a09fee2e4f", %{"stage" => stage})
      assert {:ok, %{verb: :failed}} = TinctureWire.decode_shell_message(message)
    end

    for args <- [%{}, %{"stage" => "load", "error" => "x"}, %{"stage" => nil}] do
      message = TinctureWire.shell_message(:failed, "frm_01a09fee2e4f", args)
      assert {:error, _} = TinctureWire.decode_shell_message(message), inspect(args)
    end
  end

  test "a press, a failure, a grant, prefs, ask and settings are the verbs the shell takes from a canvas alone" do
    assert TinctureWire.canvas_verbs() == [:press, :failed, :grant, :prefs, :ask, :settings]

    assert Enum.map(TinctureWire.canvas_verbs(), &Atom.to_string/1) ==
             vectors()["canvas"]["verbs"]

    assert TinctureWire.canvas_verbs() -- TinctureWire.verbs() == []
  end

  test "a grant names exactly one component reference, of any component type, at a version or none" do
    for ref <- [
          "catalyst:local.openai:1.4.1",
          "c:local.openai",
          "reagent:local.notes",
          "formula:example.com.digest:0.2.0",
          "tincture:local.vault"
        ] do
      message = TinctureWire.shell_message(:grant, "frm_01a09fee2e4f", %{"ref" => ref})

      assert {:ok, %{verb: :grant, args: %{"ref" => ^ref}}} =
               TinctureWire.decode_shell_message(message)
    end

    for args <- [
          %{},
          %{"ref" => 7},
          %{"ref" => "openai"},
          %{"ref" => "agent:local.helper"},
          %{"ref" => "catalyst:local.openai", "label" => "OpenAI"}
        ] do
      message = TinctureWire.shell_message(:grant, "frm_01a09fee2e4f", args)

      assert {:error, "grant names a component reference"} =
               TinctureWire.decode_shell_message(message),
             inspect(args)
    end
  end

  test "a request names grant or an operation, its args and its call, and nothing else" do
    frame = "frm_01a09fee2e4f"

    for {operation, args} <- [
          {"schedule.create", %{"name" => "digest", "cron_expression" => "0 8 * * *"}},
          {"layout.edit", %{}},
          {"grant", %{"ref" => "c:local.openai"}},
          {"grant", %{"ref" => "tincture:local.vault:0.2.0"}}
        ] do
      request = %{"operation" => operation, "args" => args, "call" => 1}
      message = TinctureWire.shell_message(:request, frame, request)

      assert {:ok, %{verb: :request, args: ^request}} =
               TinctureWire.decode_shell_message(message)
    end

    for args <- [
          %{"operation" => "schedule.create", "args" => %{}},
          %{"operation" => "schedule", "args" => %{}, "call" => 1},
          %{"operation" => 7, "args" => %{}, "call" => 1},
          %{"operation" => "schedule.create", "args" => "digest", "call" => 1},
          %{"operation" => "grant", "args" => %{"ref" => "agent:local.helper"}, "call" => 1},
          %{"operation" => "grant", "args" => %{"ref" => "c:local.x", "y" => 1}, "call" => 1},
          %{"operation" => "layout.edit", "args" => %{}, "call" => 1, "why" => "x"}
        ] do
      message = TinctureWire.shell_message(:request, frame, args)
      assert {:error, _} = TinctureWire.decode_shell_message(message), inspect(args)
    end

    assert TinctureWire.request_operation?(TinctureWire.grant_operation())
    refute TinctureWire.request_operation?("grant.commit.now")
  end

  test "settings names a page and, optionally, the record on it to open at" do
    for args <- [%{"page" => "aqua"}, %{"page" => "chat", "ref" => "sth_1"}] do
      message = TinctureWire.shell_message(:settings, "frm_01a09fee2e4f", args)
      assert {:ok, %{verb: :settings, args: ^args}} = TinctureWire.decode_shell_message(message)
    end

    for args <- [%{"page" => "aqua", "ref" => ""}, %{"ref" => "thr_1"}] do
      message = TinctureWire.shell_message(:settings, "frm_01a09fee2e4f", args)
      assert {:error, _} = TinctureWire.decode_shell_message(message), inspect(args)
    end
  end

  test "a request id the identifier generator mints is one the wire reads, and no two are the same" do
    ids = for _ <- 1..32, do: Prima.UUID7.request_id()
    assert Enum.all?(ids, &TinctureWire.request_id?/1)
    assert Enum.uniq(ids) == ids
    refute TinctureWire.request_id?("req_short")
    refute TinctureWire.request_id?("sch_0190f3a27b1c7d2e8f3a")
  end

  test "every installed tincture the fixture sends a canvas is the wire's entry, and the refused ones break it" do
    rows = vectors()["canvas"]["to_frame"]
    keys = TinctureWire.installed_keys()
    code_points = &(&1 |> String.codepoints() |> length())

    entries =
      for %{"message" => %{"verb" => "installed", "args" => %{"tinctures" => tinctures}}} <-
            rows["valid"],
          entry <- tinctures,
          do: entry

    assert entries != []
    assert Enum.any?(entries, &is_nil(&1["icon"]))
    assert Enum.any?(entries, &(&1["open"] == true))

    assert Enum.any?(
             entries,
             &(is_binary(&1["icon"]) and
                 code_points.(&1["icon"]) == TinctureWire.max_installed_icon())
           )

    for entry <- entries do
      assert entry |> Map.keys() |> Enum.sort() == keys
      assert is_boolean(entry["open"])
      assert code_points.(entry["name"]) in 1..TinctureWire.max_installed_name()

      assert is_nil(entry["icon"]) or
               code_points.(entry["icon"]) in 1..TinctureWire.max_installed_icon()
    end

    refused =
      for %{"why" => why, "message" => %{"verb" => "installed"}} <- rows["invalid"], do: why

    for why <- [
          "an installed entry lacking open",
          "an installed entry lacking its icon",
          "an icon past 16 code points"
        ],
        do: assert(why in refused, why)
  end

  test "no verb raises a frame: focus is no verb" do
    refute :focus in TinctureWire.verbs()
    message = TinctureWire.shell_message(:ready, "frm_01a09fee2e4f")
    assert {:error, _} = TinctureWire.decode_shell_message(%{message | "verb" => "focus"})
  end

  describe "a desktop's verbs and answers" do
    test "a press names a control, with a value when it picks one, beside its feed form" do
      frame = "frm_01a09fee2e4f"
      decode = &TinctureWire.decode_shell_message(TinctureWire.shell_message(:press, frame, &1))

      assert {:ok, %{args: %{"control" => "pause-digest", "call" => 1}}} =
               decode.(%{"control" => "pause-digest", "call" => 1})

      assert {:ok, %{args: %{"value" => "lisbon-1"}}} =
               decode.(%{"control" => "vpn-connect", "value" => "lisbon-1", "call" => 2})

      max = TinctureWire.max_press_value()
      long = String.duplicate("é", max)
      assert {:ok, _} = decode.(%{"control" => "c", "value" => long, "call" => 3})
      assert {:error, _} = decode.(%{"control" => "c", "value" => long <> "é", "call" => 3})
      assert {:error, _} = decode.(%{"control" => "c", "value" => "a\u0000b", "call" => 3})
      assert {:error, _} = decode.(%{"control" => "c", "extra" => "x", "call" => 3})

      # A press of a control names the call its answer carries back.
      assert {:error, _} = decode.(%{"control" => "c"})
      assert {:error, _} = decode.(%{"control" => "c", "call" => 0})
      assert TinctureWire.call?(1) and not TinctureWire.call?(2_147_483_648)
    end

    test "prefs, ask and settings are a canvas's alone, and open may carry a typed subject" do
      assert Enum.all?([:prefs, :ask, :settings], &(&1 in TinctureWire.canvas_verbs()))

      for kind <- Prima.Manifest.Tincture.subject_kinds() do
        assert TinctureWire.subject?(%{"kind" => kind, "id" => "id_1"})
      end

      refute TinctureWire.subject?(%{"kind" => "url", "id" => "id_1"})
      refute TinctureWire.subject?(%{"kind" => "run", "id" => "../x"})
      refute TinctureWire.subject?(%{"kind" => "run", "id" => "a", "label" => "b"})
    end

    test "an app's handshake is its credential and the subject it was opened on, each as the fixture spells it" do
      %{"valid" => valid, "invalid" => invalid} = vectors()["app_handshake"]

      for %{"reply" => reply} <- valid,
          do: assert(TinctureWire.frame_handshake(reply["credential"], reply["subject"]) == reply)

      for %{"why" => why, "reply" => reply} <- invalid do
        built =
          try do
            TinctureWire.frame_handshake(reply["credential"], reply["subject"])
          rescue
            ArgumentError -> :raised
          end

        refute built == reply, why
      end
    end

    test "every answer the fixture posts a canvas is the one the builders write, and refused ones raise" do
      rows = vectors()["canvas"]["to_frame"]

      for %{"message" => %{"verb" => "pressed", "args" => args}} <- rows["valid"] do
        assert TinctureWire.pressed(
                 args["control"],
                 args["call"],
                 args["outcome"],
                 args["reason"]
               ) ==
                 args
      end

      for %{"message" => %{"verb" => "prefs", "args" => args}} <- rows["valid"] do
        assert TinctureWire.prefs_answer(
                 args["call"],
                 args["outcome"],
                 args["document"],
                 args["revision"],
                 args["reason"]
               ) == args
      end

      for %{"why" => why, "message" => %{"verb" => verb, "args" => args}} <- rows["invalid"],
          verb in ["pressed", "prefs"] do
        built =
          try do
            if verb == "pressed",
              do:
                TinctureWire.pressed(
                  args["control"],
                  args["call"],
                  args["outcome"],
                  args["reason"]
                ),
              else:
                TinctureWire.prefs_answer(
                  args["call"],
                  args["outcome"],
                  args["document"],
                  args["revision"],
                  args["reason"]
                )
          rescue
            ArgumentError -> :raised
          end

        refute built == args, why
      end

      for %{"message" => %{"verb" => "requested", "args" => args}} <- rows["valid"] do
        assert TinctureWire.requested(args["call"], args["request"]) == args
      end

      decided =
        for %{"message" => %{"verb" => "decided", "args" => args}} <- rows["valid"], do: args

      assert decided |> Enum.map(& &1["outcome"]) |> Enum.uniq() |> Enum.sort() ==
               Enum.sort(TinctureWire.request_outcomes())

      for args <- decided do
        assert TinctureWire.decided(args["call"], args["outcome"], args["reason"]) == args
      end

      for %{"why" => why, "message" => %{"verb" => verb, "args" => args}} <- rows["invalid"],
          verb in ["requested", "decided"] do
        built =
          try do
            if verb == "requested",
              do: TinctureWire.requested(args["call"], args["request"]),
              else: TinctureWire.decided(args["call"], args["outcome"], args["reason"])
          rescue
            ArgumentError -> :raised
          end

        refute built == args, why
      end

      assert TinctureWire.press_outcomes() == ~w(accepted refused cancelled)
      assert TinctureWire.prefs_outcomes() == ~w(saved stale refused cancelled)
      assert TinctureWire.request_outcomes() == ~w(approved refused cancelled)
      assert TinctureWire.request_cancel_reasons() == ~w(too_soon busy expired dismissed)
    end
  end

  describe "a canvas" do
    test "every valid handshake reply is the one the builder writes for its frame" do
      valid = vectors()["canvas"]["handshake"]["valid"]
      assert valid != []

      for %{"frame" => frame, "reply" => reply} <- valid do
        %{"credential" => credential, "canvas" => canvas} = reply

        assert TinctureWire.canvas_handshake(
                 frame,
                 credential,
                 canvas["mode"],
                 canvas["streams"],
                 Map.take(canvas, ~w(prefs appearance person))
               ) == reply

        assert canvas["mode"] in TinctureWire.canvas_modes()
        assert canvas["data_path"] == TinctureWire.data_path(frame)
      end

      assert Enum.max(Enum.map(valid, &length(&1["reply"]["canvas"]["streams"]))) ==
               TinctureWire.max_canvas_streams()
    end

    test "no refused handshake reply is one the builder writes: it raises or writes another" do
      invalid = vectors()["canvas"]["handshake"]["invalid"]
      assert invalid != []

      for %{"why" => why, "frame" => frame, "reply" => reply} <- invalid do
        canvas = reply["canvas"]

        built =
          try do
            TinctureWire.canvas_handshake(
              frame,
              reply["credential"],
              canvas["mode"],
              canvas["streams"],
              Map.take(canvas || %{}, ~w(prefs appearance person))
            )
          rescue
            e in ArgumentError ->
              # The sentence names no value: the credential is one.
              refute Exception.message(e) =~ "c2lnbmVkLWZyYW1lLWNyZWRlbnRpYWw", why
              :raised
          end

        refute built == reply, why
      end
    end

    test "the paths are the fixture's, and a value outside its grammar raises" do
      %{"valid" => valid, "invalid" => invalid} = vectors()["canvas"]["paths"]
      assert valid != [] and invalid != []

      for row <- valid do
        assert TinctureWire.page_path(row["credential"], row["frame"]) == row["page_path"]

        assert row["page_path"] ==
                 TinctureWire.page_prefix() <> row["credential"] <> "/" <> row["frame"]

        assert TinctureWire.data_path(row["frame"]) == row["data_path"]
        assert TinctureWire.socket_path(row["frame"]) == row["socket_path"]
      end

      for %{"why" => why, "credential" => credential, "frame" => frame} <- invalid do
        assert_raise ArgumentError, fn -> TinctureWire.page_path(credential, frame) end

        if TinctureWire.frame_id?(frame) do
          assert is_binary(TinctureWire.data_path(frame)), why
        else
          assert_raise ArgumentError, fn -> TinctureWire.data_path(frame) end
          assert_raise ArgumentError, fn -> TinctureWire.socket_path(frame) end
        end
      end
    end
  end

  describe "the tincture URL grammar (component_refs.json)" do
    defp urls, do: @refs |> File.read!() |> Jason.decode!() |> Map.fetch!("tincture_urls")

    test "a public path is composed as the fixture spells it" do
      for %{"athanor" => a, "publisher" => p, "name" => n, "path" => path} <- urls()["public"] do
        assert TinctureUrl.path(a, p, n) == path
      end
    end

    test "a served-file path reads back as the fixture says, and a readable one is rebuilt exactly" do
      served = urls()["served"]
      assert Enum.any?(served, &is_nil(&1["parse"]))

      for %{"path" => path, "parse" => expected} = row <- served do
        case expected do
          nil ->
            assert TinctureUrl.parse_asset_path(path) == :error, "#{path}: #{row["why"]}"

          %{"credential" => credential, "path" => segments} ->
            assert TinctureUrl.parse_asset_path(path) ==
                     {:ok, %{credential: credential, path: segments}}

            assert TinctureUrl.asset_path(credential, segments) == path
        end
      end
    end

    test "a served-file path is refused at build for a credential or a segment outside the grammar" do
      assert_raise ArgumentError, fn -> TinctureUrl.asset_path("short", ["index.html"]) end

      assert_raise ArgumentError, fn ->
        TinctureUrl.asset_path(String.duplicate("a", 20), [".."])
      end
    end
  end
end
