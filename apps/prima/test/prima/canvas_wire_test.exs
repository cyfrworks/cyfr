# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.CanvasWireTest do
  @moduledoc """
  The canvas wire against `tests/fixtures/canvas_wire.json`: the version
  and each direction's verbs are the module's, every valid message decodes
  to its direction's verb and encodes back to itself, every refused message
  is refused, and the path builders answer the fixture's paths and raise
  on a credential or frame id outside its grammar. Beside them, the bounds
  the fixture would spell at length, a boot's streams held to the tincture
  wire's stream-name grammar, and refusals that name no key or value the
  message carries, whatever term it is.
  """

  use ExUnit.Case, async: true

  alias Prima.CanvasWire

  @vectors Path.expand("../../../../tests/fixtures/canvas_wire.json", __DIR__)

  # A value no refusal may carry.
  @canary "c4n4ry-wire-7d1e"

  @frame "frm_8f3c2a1b9d"

  defp vectors, do: @vectors |> File.read!() |> Jason.decode!()

  defp verbs(names), do: Enum.map(names, &String.to_existing_atom/1)

  # The report an ArgumentError `fun` raises would print, its stacktrace
  # included; any other exception fails the test.
  defp refusal(fun) do
    fun.()
    flunk("expected an ArgumentError")
  rescue
    e in ArgumentError -> Exception.format(:error, e, __STACKTRACE__)
  end

  # Whether `text` carries the canary, as its bytes or as the byte list
  # `inspect/1` prints for a binary that is not UTF-8 text.
  defp carries_canary?(text) do
    String.contains?(text, [@canary, @canary |> :binary.bin_to_list() |> Enum.join(", ")])
  end

  # A refused decode answers a sentence that is text and without the
  # canary, and the encode of the same message raises an ArgumentError
  # whose report, stacktrace included, is without it too.
  defp refused_without_canary(%{"verb" => verb, "args" => args} = message) do
    assert {:error, sentence} = CanvasWire.decode(message)
    assert String.valid?(sentence)
    refute carries_canary?(sentence)

    decoded = %{verb: String.to_existing_atom(verb), frame: message["frame"], args: args}
    refute carries_canary?(refusal(fn -> CanvasWire.encode(decoded) end))
  end

  defp message(verb, args), do: %{"v" => 1, "verb" => verb, "frame" => @frame, "args" => args}

  defp boot(streams) do
    message("boot", %{
      "mode" => "live",
      "credential" => "frm.v1.c2lnbmVkLWZyYW1lLWNyZWRlbnRpYWw",
      "data_path" => CanvasWire.data_path(@frame),
      "module_url" => "/_s/ast.v1.c2lnbmVkLWFzc2V0LWNyZWRlbnRpYWw/canvas.js",
      "toolkit" => 1,
      "streams" => streams
    })
  end

  describe "the fixture" do
    test "the version and each direction's verbs are the module's" do
      v = vectors()
      assert v["version"] == CanvasWire.version()
      assert verbs(v["to_prism_verbs"]) == CanvasWire.to_prism_verbs()
      assert verbs(v["to_toolkit_verbs"]) == CanvasWire.to_toolkit_verbs()

      assert CanvasWire.to_prism_verbs() -- CanvasWire.to_toolkit_verbs() ==
               CanvasWire.to_prism_verbs()
    end

    test "every valid message decodes to its direction's verb and encodes back to itself" do
      valid = vectors()["messages"]["valid"]
      every = CanvasWire.to_prism_verbs() ++ CanvasWire.to_toolkit_verbs()

      assert valid |> Enum.map(& &1["message"]["verb"]) |> verbs() |> Enum.uniq() |> Enum.sort() ==
               Enum.sort(every)

      for %{"direction" => direction, "message" => message} <- valid do
        assert {:ok, %{verb: verb, frame: frame, args: args} = decoded} =
                 CanvasWire.decode(message)

        directed =
          case direction do
            "to_prism" -> CanvasWire.to_prism_verbs()
            "to_toolkit" -> CanvasWire.to_toolkit_verbs()
          end

        assert verb in directed, inspect(message)
        assert frame == message["frame"]
        assert args == message["args"]
        assert CanvasWire.encode(decoded) == message
      end
    end

    test "every refused message is refused" do
      for %{"why" => why, "message" => message} <- vectors()["messages"]["invalid"] do
        assert {:error, sentence} = CanvasWire.decode(message), why
        assert is_binary(sentence) and sentence != "", why
      end
    end

    test "the paths are the fixture's, and a value outside its grammar raises" do
      %{"valid" => valid, "invalid" => invalid} = vectors()["paths"]

      for row <- valid do
        assert CanvasWire.page_path(row["credential"], row["frame"]) == row["page_path"]
        assert CanvasWire.data_path(row["frame"]) == row["data_path"]
        assert CanvasWire.stream_path(row["frame"]) == row["stream_path"]
        assert row["stream_path"] == row["data_path"] <> "stream"
      end

      for %{"why" => why, "credential" => credential, "frame" => frame} <- invalid do
        assert_raise ArgumentError, fn -> CanvasWire.page_path(credential, frame) end

        if CanvasWire.frame_id?(frame) do
          assert is_binary(CanvasWire.data_path(frame)), why
        else
          assert_raise ArgumentError, fn -> CanvasWire.data_path(frame) end
          assert_raise ArgumentError, fn -> CanvasWire.stream_path(frame) end
        end
      end
    end
  end

  describe "messages" do
    setup do
      boot =
        Enum.find_value(vectors()["messages"]["valid"], fn
          %{"message" => %{"verb" => "boot"} = message} -> message
          _ -> nil
        end)

      %{boot: boot}
    end

    test "boot carries no worker URL, and its data path is its own frame's", %{boot: boot} do
      assert {:ok, %{verb: :boot}} = CanvasWire.decode(boot)

      assert {:error, _} =
               CanvasWire.decode(put_in(boot, ["args", "worker_url"], boot["args"]["module_url"]))

      other = "frm_ffffffffff"
      assert {:error, _} = CanvasWire.decode(%{boot | "frame" => other})

      moved = %{
        boot
        | "frame" => other,
          "args" => %{boot["args"] | "data_path" => CanvasWire.data_path(other)}
      }

      assert {:ok, %{frame: ^other}} = CanvasWire.decode(moved)
    end

    test "a press names a binding id and an action, and nothing else" do
      id = Prima.UUID7.generate_id("feed")

      press = %{
        "v" => 1,
        "verb" => "press",
        "frame" => "frm_8f3c2a1b9d",
        "args" => %{"binding" => id, "action" => "refresh"}
      }

      assert {:ok, %{verb: :press, args: %{"binding" => ^id}}} = CanvasWire.decode(press)

      assert {:error, _} =
               CanvasWire.decode(%{press | "args" => Map.delete(press["args"], "binding")})

      assert {:error, _} = CanvasWire.decode(put_in(press, ["args", "label"], "Buy"))

      assert {:error, _} =
               CanvasWire.decode(%{press | "args" => %{press["args"] | "binding" => "btc"}})
    end

    test "covered takes 64 rects and installed 512 tinctures, and no more" do
      frame = "frm_8f3c2a1b9d"
      rect = %{"x" => 0, "y" => 0, "width" => 1.5, "height" => 2}
      tincture = %{"ref" => "tincture:local.vault", "name" => String.duplicate("é", 128)}

      covered = fn n ->
        %{
          "v" => 1,
          "verb" => "covered",
          "frame" => frame,
          "args" => %{"rects" => List.duplicate(rect, n)}
        }
      end

      installed = fn n ->
        %{
          "v" => 1,
          "verb" => "installed",
          "frame" => frame,
          "args" => %{"tinctures" => List.duplicate(tincture, n)}
        }
      end

      assert {:ok, _} = CanvasWire.decode(covered.(64))
      assert {:error, _} = CanvasWire.decode(covered.(65))
      assert {:ok, _} = CanvasWire.decode(installed.(512))
      assert {:error, _} = CanvasWire.decode(installed.(513))
    end

    test "an encoder never writes a message the decoder refuses" do
      assert_raise ArgumentError, fn ->
        CanvasWire.encode(%{verb: :navigate, frame: "frm_8f3c2a1b9d", args: %{}})
      end

      assert_raise ArgumentError, fn ->
        CanvasWire.encode(%{verb: :ready, frame: "x", args: %{}})
      end

      assert_raise ArgumentError, fn ->
        CanvasWire.encode(%{verb: :state, frame: "frm_8f3c2a1b9d", args: %{"state" => "paused"}})
      end

      assert CanvasWire.encode(%{verb: :ready, frame: "frm_8f3c2a1b9d", args: %{}}) ==
               %{"v" => 1, "verb" => "ready", "frame" => "frm_8f3c2a1b9d", "args" => %{}}
    end

    test "an encoder refusal never carries the boot's credential", %{boot: boot_row} do
      credential = boot_row["args"]["credential"]
      {:ok, decoded} = CanvasWire.decode(boot_row)

      # The wire form itself, which decode/1 accepts, is not encode/1's input.
      refute refusal(fn -> CanvasWire.encode(boot_row) end) =~ credential

      refused = [
        Map.put(decoded, :extra, true),
        %{decoded | verb: "boot"},
        %{decoded | verb: {:boot}},
        %{decoded | frame: "x"},
        %{decoded | args: Map.put(decoded.args, "worker_url", "/_s/x/w.js")},
        %{decoded | args: Map.put(decoded.args, %{credential => credential}, 1)},
        Map.to_list(decoded),
        {:boot, credential}
      ]

      for message <- refused do
        refute refusal(fn -> CanvasWire.encode(message) end) =~ credential
      end
    end

    test "the frame id grammar is the tincture wire's" do
      for id <- ["frm_8f3c2a1b9d", "x", "../frm_8f3c2a1b9d", nil, String.duplicate("a", 65)] do
        assert CanvasWire.frame_id?(id) == Prima.TinctureWire.frame_id?(id), inspect(id)
      end
    end

    test "boot names its streams, at most 64 distinct pairs, and [] declares none",
         %{boot: boot} do
      streams = fn list -> put_in(boot, ["args", "streams"], list) end
      stream = &%{"name" => "feed.results", "subject" => "feed-#{&1}"}

      assert {:ok, %{args: %{"streams" => []}}} = CanvasWire.decode(streams.([]))
      assert {:ok, _} = CanvasWire.decode(streams.(Enum.map(1..64, stream)))
      assert {:error, _} = CanvasWire.decode(streams.(Enum.map(1..65, stream)))

      # A pair is distinct, not a name: one stream under two subjects, and
      # one subject spelt as two streams' names, are four pairs.
      pairs = [
        %{"name" => "feed.results", "subject" => "btc"},
        %{"name" => "feed.results", "subject" => nil},
        %{"name" => "runs.changes", "subject" => nil},
        %{"name" => "runs.changes", "subject" => ""}
      ]

      assert {:ok, decoded} = CanvasWire.decode(streams.(pairs))
      assert CanvasWire.encode(decoded) == streams.(pairs)
      assert {:error, _} = CanvasWire.decode(streams.(pairs ++ [hd(pairs)]))

      assert {:error, _} =
               CanvasWire.decode(%{boot | "args" => Map.delete(boot["args"], "streams")})

      assert {:error, _} = CanvasWire.decode(streams.(nil))

      for subject <- [7, true, ["btc"], %{"feed" => "btc"}, <<0xFF>>] do
        assert {:error, _} =
                 CanvasWire.decode(streams.([%{"name" => "feed.results", "subject" => subject}])),
               inspect(subject)
      end
    end

    test "a boot stream's name is what the tincture wire's stream_open admits", %{boot: boot} do
      names = [
        "feed.results",
        "runs.changes",
        "a.b.c",
        "feed",
        "Feed.results",
        "feed.",
        ".feed",
        "feed..results",
        "1feed.results",
        "feed.results-x",
        "",
        nil,
        7
      ]

      for name <- names do
        stream_open = %{"v" => 1, "stream" => name, "subject" => nil}
        streams = [%{"name" => name, "subject" => nil}]

        assert match?({:ok, _}, CanvasWire.decode(put_in(boot, ["args", "streams"], streams))) ==
                 match?({:ok, _}, Prima.TinctureWire.decode_request(:stream_open, stream_open)),
               inspect(name)
      end
    end
  end

  describe "refusals name no key or value the message carries" do
    test "an improper list of rects, tinctures or streams" do
      rect = %{"x" => 0, "y" => 0, "width" => 1, "height" => 1}
      tincture = %{"ref" => "tincture:local.vault", "name" => "Vault"}
      stream = %{"name" => "feed.results", "subject" => "btc"}

      for {verb, key, element} <- [
            {"covered", "rects", rect},
            {"installed", "tinctures", tincture}
          ],
          list <- [[@canary | :bad_tail], [element | @canary], [element, element | {@canary}]] do
        refused_without_canary(message(verb, %{key => list}))
      end

      for list <- [[@canary | :bad_tail], [stream | @canary]] do
        refused_without_canary(boot(list))
      end
    end

    test "the reviewer's case: covered with rects [canary | :bad_tail]" do
      message = %{verb: :covered, frame: @frame, args: %{"rects" => [@canary | :bad_tail]}}
      refute carries_canary?(refusal(fn -> CanvasWire.encode(message) end))
    end

    test "a key that is not a string, or a string key the verb does not take" do
      keys = [
        @canary,
        {:key, @canary},
        [@canary],
        %{@canary => 1},
        String.to_atom(@canary),
        <<0xFF>> <> @canary,
        @canary <> <<0xC3>>
      ]

      for key <- keys do
        refused_without_canary(message("ready", %{key => 1}))
        refused_without_canary(message("covered", %{"rects" => [%{key => 1}]}))
        refused_without_canary(boot([%{"name" => "feed.results", "subject" => nil, key => 1}]))

        assert {:error, sentence} = CanvasWire.decode(Map.put(message("ready", %{}), key, 1))
        assert String.valid?(sentence)
        refute carries_canary?(sentence)
      end
    end

    test "a struct, a tuple or a value of another type where the grammar wants one" do
      struct = %URI{path: @canary}

      for args <- [
            %{"rects" => struct},
            %{"rects" => [struct]},
            %{"rects" => {@canary}},
            %{"rects" => [%{"x" => @canary, "y" => 0, "width" => 1, "height" => 1}]}
          ] do
        refused_without_canary(message("covered", args))
      end

      for streams <- [struct, [struct], [%{"name" => @canary, "subject" => nil}]] do
        refused_without_canary(boot(streams))
      end

      for subject <- [{@canary}, [@canary], %{"s" => @canary}] do
        refused_without_canary(boot([%{"name" => "feed.results", "subject" => subject}]))
      end

      assert {:error, sentence} = CanvasWire.decode(%{message("ready", %{}) | "args" => struct})
      assert String.valid?(sentence)
      refute carries_canary?(sentence)
      refute carries_canary?(refusal(fn -> CanvasWire.encode(struct) end))
    end
  end
end
