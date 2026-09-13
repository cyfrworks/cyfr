# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.HandsTest do
  # The host's copy of the guest's virtual-tool contract, held to the one
  # fixture the guest's own tests run (`virtual_tools.json` beside
  # `tools.rs`): every virtual call builds the catalyst request the guest
  # builds, and every catalyst request names the virtual actions the
  # guest's guard would judge it as.
  use ExUnit.Case, async: true

  alias Aqua.Hands

  @fixture Path.expand("../support/fixtures/hands_cases.json", __DIR__)

  defp fixture, do: @fixture |> File.read!() |> Jason.decode!()

  test "the shared fixture holds on both directions" do
    cases = fixture()
    assert length(cases) > 20

    for case <- cases do
      canonical =
        case Hands.canonical(case["catalyst"], case["input"]) do
          {:ok, ops} -> Enum.map(ops, &"#{&1.tool}.#{&1.action}")
          {:error, _} -> []
        end

      assert canonical == case["canonical"], "reverse of #{inspect(case["input"])}"

      unless case["reverse_only"] do
        assert {:ok, %{catalyst: catalyst, input: input}} =
                 Hands.child_call(case["tool"], case["action"], case["args"])

        assert catalyst == case["catalyst"], "#{case["tool"]}.#{case["action"]}"
        assert input == case["input"], "#{case["tool"]}.#{case["action"]}"
      end
    end
  end

  test "a canonical operation carries the virtual tool's own args, so a card can run it again" do
    assert {:ok, [%{tool: "files", action: "delete", args: %{"path" => "a.md"}}]} =
             Hands.canonical("catalyst:local.files", %{
               "action" => "delete",
               "path" => "a.md"
             })

    assert {:ok,
            [%{tool: "storage", action: "write", args: %{"key" => "k", "value" => %{"a" => 1}}}]} =
             Hands.canonical("catalyst:local.files:0.5.1", %{
               "action" => "write_text",
               "path" => "data/storage/k.json",
               "content" => ~s({"a": 1})
             })

    assert {:ok, [%{tool: "http", action: "post", args: %{"url" => "http://x", "body" => "b"}}]} =
             Hands.canonical("catalyst:local.http", %{
               "operation" => "fetch",
               "params" => %{"url" => "http://x", "method" => "POST", "body" => "b"}
             })

    # And round-trips through the child call.
    assert {:ok, %{input: %{"action" => "delete", "path" => "data/storage/k.json"}}} =
             Hands.child_call("storage", "delete", %{"key" => "k"})
  end

  test "references are judged at name level, and only a hand's catalyst is a hand" do
    assert Hands.name_level("catalyst:local.files:0.5.1") == "catalyst:local.files"
    assert Hands.name_level("catalyst:local.files") == "catalyst:local.files"
    assert Hands.hand_catalyst?("catalyst:local.files:0.5.1")
    refute Hands.hand_catalyst?("formula:local.other")
    assert {:error, :not_virtual} = Hands.canonical("formula:local.other", %{})
  end

  test "a files call inside the storage boundary is the storage operation" do
    assert {:ok, %{tool: "storage", action: "delete", args: %{"key" => "k"}}} =
             Hands.canonical_files("delete", %{"path" => "data/storage/k.json"})

    assert {:ok, %{tool: "storage", action: "list", args: %{"key" => "notes"}}} =
             Hands.canonical_files("tree", %{"path" => "data/storage/notes"})

    assert {:ok, %{tool: "files", action: "delete"}} =
             Hands.canonical_files("delete", %{"path" => "a.md"})

    assert {:error, :not_a_storage_operation} =
             Hands.canonical_files("grep", %{"path" => "data/storage", "pattern" => "x"})
  end

  test "request_setup.open is auto-only and builds no child call" do
    assert Hands.auto_only?("request_setup", "open")
    refute Hands.auto_only?("files", "read")
    assert {:error, _} = Hands.child_call("request_setup", "open", %{})
  end
end
