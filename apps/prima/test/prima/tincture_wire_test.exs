# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.TinctureWireTest do
  @moduledoc """
  The frame's wire as data: every request body of
  `tests/fixtures/tincture_wire.json` decodes and encodes back to itself
  and carries its credential as a bearer, and the public request names its
  tincture in place of one; every answer reads back; the refusal is a
  `Prima.Refusal`'s projection and nothing more; the event stream is the
  one the encoders write and reads back as its events; every shell
  message decodes and every refused one is refused; a canvas's handshake
  replies are the ones the builder writes, and no refused reply is; and
  a canvas's paths are the fixture's, a value outside its grammar
  raising. Beside them, the tincture URL grammar of
  `tests/fixtures/component_refs.json`.
  """

  use ExUnit.Case, async: true

  alias Prima.{StreamGrant, TinctureUrl, TinctureWire}
  alias Prima.Test.EventStream

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
    [invoke, action, stream] = vectors()["requests"] |> Enum.map(& &1["body"])

    assert {:error, _} = TinctureWire.decode_request(:invoke, Map.delete(invoke, "v"))
    assert {:error, _} = TinctureWire.decode_request(:invoke, %{invoke | "v" => 2})
    assert {:error, _} = TinctureWire.decode_request(:invoke, Map.put(invoke, "credential", "x"))
    assert {:error, _} = TinctureWire.decode_request(:invoke, %{invoke | "ref" => "not a ref"})
    assert {:error, _} = TinctureWire.decode_request(:action, %{action | "operation" => "list"})
    assert {:error, _} = TinctureWire.decode_request(:action, %{action | "args" => [1]})
    assert {:error, _} = TinctureWire.decode_request(:stream_open, %{stream | "stream" => "x"})
    assert {:error, _} = TinctureWire.decode_request(:stream_open, %{stream | "subject" => "*"})
    assert {:error, _} = TinctureWire.decode_request(:action, "not an object")

    assert {:ok, %{subject: nil}} =
             TinctureWire.decode_request(:stream_open, %{stream | "subject" => nil})
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

    assert TinctureWire.public_identity?(%{athanor: "home", publisher: "local", name: "w"})
    refute TinctureWire.public_identity?(%{athanor: "home", publisher: "local"})
  end

  test "an admitted stream is the event stream the encoders write, and reads back as its events" do
    %{"kind" => "stream_open", "content_type" => type, "body" => body, "events" => events} =
      vectors()["stream"]

    assert type == TinctureWire.stream_content_type()

    expected =
      for %{"id" => id, "event" => event, "data" => data} <- events,
          do: %{id: id, event: event, data: data}

    assert EventStream.decode(body) == expected

    {deliveries, [%{event: "refusal", data: projection}]} =
      Enum.split_while(expected, &(&1.event != TinctureWire.refusal_event()))

    refusal = %Prima.Refusal{
      class: String.to_existing_atom(projection["class"]),
      reason: :stream_overflow,
      message: projection["message"],
      stage: String.to_existing_atom(projection["stage"])
    }

    written =
      Enum.map_join(deliveries, &TinctureWire.stream_event(&1.id, &1.event, &1.data)) <>
        TinctureWire.stream_refusal(refusal)

    assert ": open\n\n" <> written == body
    refute body =~ "stream_overflow"
  end

  test "a stream event not ended by its blank line, without data or with data that is not JSON is dropped" do
    assert EventStream.decode("event: a\ndata: {\"x\":1}") == []
    assert EventStream.decode("event: a\n\n") == []
    assert EventStream.decode("event: a\ndata: {x\n\n") == []

    assert EventStream.decode("id: 7\r\nretry: 5\r\ndata: {\"a\":\r\ndata: 1}\r\n\r\n") ==
             [%{id: 7, event: "message", data: %{"a" => 1}}]
  end

  test "a bearer is `Bearer <credential>` and nothing else" do
    assert TinctureWire.read_bearer("Bearer abc.def") == {:ok, "abc.def"}
    assert TinctureWire.read_bearer("Bearer ") == :error
    assert TinctureWire.read_bearer("Bearer a b") == :error
    assert TinctureWire.read_bearer("bearer abc") == :error
    assert TinctureWire.read_bearer(nil) == :error
  end

  test "every answer reads back, and the stream answer is the grant without its topic" do
    for %{"kind" => name, "body" => body} <- vectors()["answers"] do
      assert {:ok, _value} = TinctureWire.decode_answer(kind(name), body)
    end

    %{"body" => %{"stream" => stream} = body} =
      Enum.find(vectors()["answers"], &(&1["kind"] == "stream_open"))

    {:ok, deadline, 0} = DateTime.from_iso8601(stream["deadline"])

    grant = %StreamGrant{
      topic: :execution_events,
      projection: stream["projection"],
      subject: stream["subject"],
      deadline: deadline,
      grant_id: stream["grant_id"]
    }

    assert TinctureWire.stream(grant, stream["stream"]) == body
    # The bus key the grant rides stays on the server.
    refute inspect(TinctureWire.stream(grant, stream["stream"])) =~ "execution_events"

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

  test "each stream rejection's refusal body is a Prima.Refusal's projection, which reads back as itself" do
    %{"cases" => cases} = vectors()["stream_rejections"]
    classes = Enum.map(Prima.Refusal.classes(), &Atom.to_string/1)
    bodies = for %{"answer" => %{"body" => body}} <- cases, do: body
    assert bodies != []

    for %{"error" => %{"class" => class, "message" => message, "stage" => stage}} = body <- bodies do
      assert class in classes, class

      refusal = %Prima.Refusal{
        class: String.to_existing_atom(class),
        reason: :vector,
        message: message,
        stage: String.to_existing_atom(stage)
      }

      assert TinctureWire.refusal(refusal) == body

      assert TinctureWire.decode_answer(:stream_open, body) ==
               {:refused, %{class: class, message: message, stage: stage}}
    end

    # Every case says how the SDK rejects it, with a stage only for a
    # refusal it rejects as itself.
    for %{"answer" => answer, "rejects" => rejects} <- cases do
      assert Map.keys(rejects) -- ["stage"] == ["class", "message"], inspect(answer)

      case answer do
        %{"body" => %{"error" => error}} when is_map_key(rejects, "stage") ->
          assert rejects == error

        _no_refusal_of_its_own ->
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

  test "a press, a failure and a grant are the verbs the shell takes from a canvas alone" do
    assert TinctureWire.canvas_verbs() == [:press, :failed, :grant]

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
                 canvas["streams"]
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
              canvas["streams"]
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
        assert TinctureWire.stream_path(row["frame"]) == row["stream_path"]
      end

      for %{"why" => why, "credential" => credential, "frame" => frame} <- invalid do
        assert_raise ArgumentError, fn -> TinctureWire.page_path(credential, frame) end

        if TinctureWire.frame_id?(frame) do
          assert is_binary(TinctureWire.data_path(frame)), why
        else
          assert_raise ArgumentError, fn -> TinctureWire.data_path(frame) end
          assert_raise ArgumentError, fn -> TinctureWire.stream_path(frame) end
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
