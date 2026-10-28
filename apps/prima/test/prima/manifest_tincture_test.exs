# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.ManifestTinctureTest do
  @moduledoc """
  The frame, streams and actions blocks: their shapes, read into
  `Prima.Manifest.Tincture`, refused at every manifest write when wrong,
  and their digest — the same for two declarations that mean the same
  thing, and moved by a declaration that asks for more.
  """

  use ExUnit.Case, async: true

  alias Prima.Manifest
  alias Prima.Manifest.Tincture
  alias Prima.Manifest.Tincture.Frame

  @declared %{
    "frame" => %{"capabilities" => ["pointer_lock", "fullscreen"], "placement" => "float"},
    "actions" => ["execution.list", "records.get"],
    "streams" => [%{"name" => "executions.deltas", "subject" => "*"}]
  }

  defp manifest(tincture), do: %{"type" => "tincture", "tincture" => tincture}

  defp refused(tincture) do
    assert {:error, {:invalid_tincture, sentence}} = Tincture.from_manifest(manifest(tincture))
    assert is_binary(sentence)

    assert {:error, {:invalid_manifest, [{:invalid_tincture, ^sentence}]}} =
             Manifest.validate(manifest(tincture), fn _ -> true end)

    sentence
  end

  test "a declaration reads into the struct" do
    assert {:ok, %Tincture{} = decl} = Tincture.from_manifest(manifest(@declared))

    assert decl.frame == %Frame{
             capabilities: ["pointer_lock", "fullscreen"],
             placement: "float",
             background: false
           }

    assert decl.actions == ["execution.list", "records.get"]
    assert [%Tincture.Stream{name: "executions.deltas", subject: "*"}] = decl.streams

    assert Manifest.validate(manifest(@declared), fn _ -> true end) == :ok
  end

  test "a manifest that declares none of the blocks reads as the empty declaration, and is not declared" do
    assert {:ok, %Tincture{frame: %Frame{capabilities: []}, streams: [], actions: []}} =
             Tincture.from_manifest(manifest(%{"entry" => "index.html"}))

    assert {:ok, %Tincture{}} = Tincture.from_manifest(%{"type" => "catalyst"})
    refute Tincture.declared?(manifest(%{"entry" => "index.html"}))
    refute Tincture.declared?(%{})
    assert Tincture.declared?(manifest(%{"actions" => []}))
  end

  # The seed's immutable versions still declare `window` hints, which
  # nothing reads: an extra of any shape, never a refusal.
  test "a declared window is an ignored extra, whatever its shape" do
    for window <- [%{"width" => 800, "height" => 600}, "800x600", 800, ["w"], true] do
      tincture = Map.put(@declared, "window", window)

      assert Manifest.validate(manifest(tincture), fn _ -> true end) == :ok, inspect(window)

      assert Tincture.from_manifest(manifest(tincture)) ==
               Tincture.from_manifest(manifest(@declared)),
             inspect(window)
    end
  end

  test "each malformed block is refused at every manifest write, with a sentence" do
    refused(%{"frame" => "yes"})
    refused(%{"frame" => %{"capabilities" => "pointer_lock"}})
    refused(%{"frame" => %{"capabilities" => ["Pointer Lock"]}})
    refused(%{"frame" => %{"background" => "yes"}})
    refused(%{"frame" => %{"sandbox" => "allow-same-origin"}})
    refused(%{"actions" => ["list"]})
    refused(%{"actions" => "execution.list"})
    refused(%{"streams" => [%{"name" => "deltas"}]})
    refused(%{"streams" => [%{"name" => "executions.deltas", "subject" => "a b"}]})
    refused(%{"streams" => [%{"name" => "executions.deltas", "topic" => "x"}]})
  end

  test "the digest is the same for declarations that mean the same thing" do
    {:ok, one} = Tincture.from_manifest(manifest(@declared))

    reordered =
      @declared
      |> put_in(["frame", "capabilities"], ["fullscreen", "pointer_lock", "fullscreen"])
      |> Map.put("actions", ["records.get", "execution.list"])

    {:ok, two} = Tincture.from_manifest(manifest(reordered))

    assert Tincture.digest(one) == Tincture.digest(two)
    assert "sha256:" <> hex = Tincture.digest(one)
    assert byte_size(hex) == 64

    # Background defaults to false: absent and false are one declaration.
    {:ok, explicit} =
      Tincture.from_manifest(manifest(put_in(@declared, ["frame", "background"], false)))

    assert Tincture.digest(explicit) == Tincture.digest(one)
  end

  test "a declaration that asks for more moves the digest" do
    {:ok, base} = Tincture.from_manifest(manifest(@declared))
    digest = Tincture.digest(base)

    for more <- [
          put_in(@declared, ["frame", "capabilities"], ["pointer_lock", "fullscreen", "gamepad"]),
          put_in(@declared, ["frame", "background"], true),
          Map.update!(@declared, "actions", &["records.delete" | &1]),
          Map.update!(@declared, "streams", &[%{"name" => "builds.progress"} | &1]),
          put_in(@declared, ["streams"], [%{"name" => "executions.deltas", "subject" => "exec_1"}])
        ] do
      {:ok, wider} = Tincture.from_manifest(manifest(more))
      refute Tincture.digest(wider) == digest
    end
  end

  test "the canonical form is what the digest is taken over" do
    {:ok, decl} = Tincture.from_manifest(manifest(@declared))
    canonical = Tincture.canonical(decl)

    assert canonical["frame"]["capabilities"] == ["fullscreen", "pointer_lock"]
    assert canonical["actions"] == ["execution.list", "records.get"]
    assert {:ok, Tincture.digest(decl)} == Prima.JCS.hash(canonical)
  end

  describe "the blocks" do
    test "a canvas declares its frame, streams and actions as any tincture does" do
      canvas = %{
        "frame" => %{"placement" => "canvas"},
        "streams" => [%{"name" => "runs.changes"}]
      }

      assert Tincture.blocks() == ~w(frame streams actions)
      assert {:ok, %Tincture{} = decl} = Tincture.from_manifest(manifest(canvas))
      assert decl.frame.placement == "canvas"
      assert decl.streams == [%Tincture.Stream{name: "runs.changes", subject: nil}]
      assert Manifest.validate(manifest(canvas), fn _ -> true end) == :ok
      assert Map.keys(Tincture.canonical(decl)) |> Enum.sort() == ~w(actions frame streams)
    end

    # Every declaration writes exactly its frame, streams and actions: this
    # digest is the JCS of that canonical form, with no other block.
    test "the canonical form is a declaration's frame, streams and actions" do
      {:ok, decl} = Tincture.from_manifest(manifest(@declared))

      assert Map.keys(Tincture.canonical(decl)) |> Enum.sort() ==
               ~w(actions frame streams)

      assert Tincture.digest(decl) ==
               "sha256:49de96ba563cdb7b366b82d5ba9e5af36ea08f835332b543300f155389067c59"
    end
  end

  test "the name grammars the wire and the provider declarations share" do
    assert Tincture.stream_name?("executions.deltas")
    refute Tincture.stream_name?("executions")
    assert Tincture.operation_name?("execution.list")
    refute Tincture.operation_name?("execution.list.all")
    assert Tincture.literal_subject?("exec_1:2")
    refute Tincture.literal_subject?(Tincture.any_subject())
  end
end
