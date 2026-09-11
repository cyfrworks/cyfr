# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.Loop.BindingTest do
  @moduledoc """
  One table from a model-visible call to what runs it: hands on their
  catalysts with the canonical operation, catalog actions in-chain,
  external servers under their wire name, roles as clones, the `ui`
  event, and an `execution.run` that is a hand, a refused agent, or a
  launch.
  """

  use ExUnit.Case, async: true

  alias Aqua.Loop.Binding
  alias Aqua.Loop.Binding.Call

  test "a hand resolves to its catalyst with the canonical operation" do
    assert {:ok,
            %Call{kind: :hand, tool: "files", action: "read", target: "catalyst:local.files"} =
              call} =
             Binding.resolve("files.read", %{"path" => "notes/a.md"}, tool_call_id: "c1")

    assert call.tool_call_id == "c1" and call.model_name == "files.read"

    assert {:ok,
            %{
              catalyst: "catalyst:local.files",
              input: %{"action" => "read_lines", "path" => "notes/a.md"}
            }} =
             Binding.child_input(call)

    # Inside the storage boundary a files call is the storage operation.
    assert {:ok, %Call{kind: :hand, tool: "storage", action: "read"}} =
             Binding.resolve("files.read", %{"path" => "data/storage/k.json"})

    assert {:error, message} = Binding.resolve("files.edit", %{"path" => "data/storage/k.json"})
    assert message =~ "no storage equivalent"

    assert {:ok, %Call{kind: :hand, tool: "http", action: "get", target: "catalyst:local.http"}} =
             Binding.resolve("http.get", %{"url" => "https://example.com"})
  end

  test "an execution.run is a hand, a refused agent, or a launch" do
    assert {:ok, %Call{kind: :hand, tool: "files", action: "read"}} =
             Binding.resolve("execution.run", %{
               "reference" => "catalyst:local.files:0.1.0",
               "input" => %{"action" => "read_lines", "path" => "a.txt"}
             })

    assert {:error, message} =
             Binding.resolve("execution.run", %{"reference" => "agent:local.builder"})

    assert message =~ "cloned as a role"

    assert {:ok,
            %Call{
              kind: :launch,
              tool: "execution",
              action: "run",
              target: "formula:local.demo:1.0.0"
            }} =
             Binding.resolve("execution.run", %{
               "reference" => "formula:local.demo:1.0.0",
               "input" => %{}
             })
  end

  test "a tool named without a dot carries its action in the arguments" do
    assert {:ok, %Call{kind: :hand, tool: "files", action: "read", args: %{"path" => "a"}}} =
             Binding.resolve("files", %{"action" => "read", "path" => "a"})

    assert {:ok, %Call{kind: :catalog, tool: "notes", action: "read"}} =
             Binding.resolve("notes", %{"action" => "read"})

    assert {:error, "unknown tool: notes"} = Binding.resolve("notes", %{})
  end

  test "roles, the ui event, external servers and catalog actions resolve to their kinds" do
    assert {:ok, %Call{kind: :clone, target: "builder"}} =
             Binding.resolve("builder", %{"task" => "x"}, roles: ["builder"])

    assert {:ok, %Call{kind: :ui, tool: "ui", action: "navigate"}} =
             Binding.resolve("ui", %{"action" => "navigate"})

    assert {:ok, %Call{kind: :ui, tool: "request_setup", action: "open"}} =
             Binding.resolve("request_setup.open", %{})

    assert {:ok, %Call{kind: :external, tool: "github:search", target: "github:search"}} =
             Binding.resolve("github__search", %{"q" => "x"})

    assert Binding.model_name("github:search") == "github__search"
    assert Binding.host_name("github__search") == "github:search"

    assert {:ok, %Call{kind: :catalog, tool: "notes", action: "read"}} =
             Binding.resolve("notes.read", %{"id" => "n"})

    assert {:error, "unknown tool: nope.thing"} = Binding.resolve("nope.thing", %{})
    assert {:error, "unknown tool: bare"} = Binding.resolve("bare", %{})
  end

  test "a result renders as the text the model reads, bounded" do
    {:ok, hand} = Binding.resolve("files.read", %{"path" => "a"})

    assert %{text: "line 1", is_error: false} =
             Binding.render(hand, {:ok, %{output: %{"data" => "line 1"}}})

    assert %{text: "line 1", is_error: false} =
             Binding.render(hand, {:ok, %{output: ~s({"data":"line 1"})}})

    assert %{text: "Error: " <> _, is_error: true} = Binding.render(hand, {:error, "boom"})

    {:ok, ext} = Binding.resolve("github__search", %{})

    assert %{text: "Error from external server 'github:search': " <> _, is_error: true} =
             Binding.render(ext, {:error, :timeout})

    {:ok, cat} = Binding.resolve("notes.read", %{})
    long = String.duplicate("x", Binding.max_result_bytes() + 10)
    assert %{text: text} = Binding.render(cat, {:ok, long})
    assert byte_size(text) < byte_size(long) + 100
    assert text =~ "truncated: 10 more bytes"
  end

  test "a launch, a clone and the ui event are not dispatched by the table" do
    {:ok, launch} = Binding.resolve("execution.run", %{"reference" => "formula:local.demo:1.0.0"})
    assert {:error, {:not_dispatchable, :launch}} = Binding.dispatch(launch, %{})
    {:ok, clone} = Binding.resolve("builder", %{}, roles: ["builder"])
    assert {:error, {:not_dispatchable, :clone}} = Binding.dispatch(clone, %{})
  end

  test "the charge identity is the step's key and generation under the turn's attempt" do
    step = %{idempotency_key: "call:t:1:c1", generation: 2, child_execution_id: "exec_c"}

    assert %{id: "call:t:1:c1:g2", attempt: "att_1", generation: 2, holder_execution_id: "exec_c"} =
             Binding.charge(step, %{attempt: "att_1"})
  end
end
