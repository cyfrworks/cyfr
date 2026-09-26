# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.ManifestTinctureTest do
  @moduledoc """
  The frame, cards, streams and actions blocks: their shapes, read into
  `Prima.Manifest.Tincture`, refused at every manifest write when wrong,
  and their digest — the same for two declarations that mean the same
  thing, and moved by a declaration that asks for more.
  """

  use ExUnit.Case, async: true

  alias Prima.Manifest
  alias Prima.Manifest.Tincture
  alias Prima.Manifest.Tincture.{Button, Card, Frame}

  @declared %{
    "frame" => %{"capabilities" => ["pointer_lock", "fullscreen"], "placement" => "desktop"},
    "actions" => ["execution.list", "records.get"],
    "streams" => [%{"name" => "executions.deltas", "subject" => "*"}],
    "cards" => [
      %{
        "name" => "status",
        "title" => "Status",
        "number" => "count",
        "list" => "recent",
        "image" => "public/media/icon.svg",
        "buttons" => [%{"label" => "Refresh", "action" => "execution.list"}],
        "stream" => "executions.deltas"
      }
    ]
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
             placement: "desktop",
             background: false
           }

    assert decl.actions == ["execution.list", "records.get"]
    assert [%Tincture.Stream{name: "executions.deltas", subject: "*"}] = decl.streams

    assert [
             %Card{
               name: "status",
               number: "count",
               list: "recent",
               stream: "executions.deltas",
               buttons: [%Button{label: "Refresh", action: "execution.list", args: %{}}]
             }
           ] = decl.cards

    assert Manifest.validate(manifest(@declared), fn _ -> true end) == :ok
  end

  test "a manifest that declares none of the blocks reads as the empty declaration, and is not declared" do
    assert {:ok, %Tincture{frame: %Frame{capabilities: []}, cards: [], streams: [], actions: []}} =
             Tincture.from_manifest(manifest(%{"entry" => "index.html"}))

    assert {:ok, %Tincture{}} = Tincture.from_manifest(%{"type" => "catalyst"})
    refute Tincture.declared?(manifest(%{"entry" => "index.html"}))
    refute Tincture.declared?(%{})
    assert Tincture.declared?(manifest(%{"actions" => []}))
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
    refused(%{"cards" => [%{"name" => "status"}]})
    refused(%{"cards" => [%{"name" => "Status", "title" => "x"}]})
    refused(%{"cards" => [%{"name" => "s", "title" => "x", "image" => "../out.svg"}]})
    refused(%{"cards" => [%{"name" => "s", "title" => "x", "buttons" => [%{"label" => "Go"}]}]})

    refused(%{
      "cards" => [
        %{
          "name" => "s",
          "title" => "x",
          "buttons" => List.duplicate(%{"label" => "a", "action" => "a.b"}, 5)
        }
      ]
    })

    sentence = refused(%{"cards" => [%{"name" => "s", "title" => String.duplicate("t", 81)}]})
    assert sentence =~ "at most 80"
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
    refute Map.has_key?(hd(canonical["cards"]), "missing")
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
