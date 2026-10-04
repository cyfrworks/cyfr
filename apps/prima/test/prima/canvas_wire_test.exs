# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.CanvasWireTest do
  @moduledoc """
  The canvas wire against `tests/fixtures/canvas_wire.json`: the version
  and each direction's verbs are the module's, every valid message decodes
  to its direction's verb and encodes back to itself, every refused message
  is refused, and the path builders answer the fixture's paths and raise
  on a credential or frame id outside its grammar. Beside them, the bounds
  the fixture would spell at length.
  """

  use ExUnit.Case, async: true

  alias Prima.CanvasWire

  @vectors Path.expand("../../../../tests/fixtures/canvas_wire.json", __DIR__)

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
  end
end
