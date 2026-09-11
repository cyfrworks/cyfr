# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.RunApprovedTest do
  # An approved virtual-tool card runs the wrapped catalyst as a CHILD of
  # the card's pinned authority — the hop the formula host makes for the
  # guest, with the assistant as the invoking reference — never as a fresh
  # root and never through the registry, which refuses a guest-planed
  # `execution.run` by design.
  use ExUnit.Case, async: false

  alias Aqua.Turn

  defmodule Engine do
    @behaviour Cyfr.Execution

    def run_root(_ctx, _sel, ref, input, _opts), do: {:ok, %{root: ref, input: input}}
    def run_root_edge(_ctx, src, ref, _input, _opts), do: {:ok, %{src: src, ref: ref}}

    def authority_for(_ctx, selector, ref, _opts),
      do: {:ok, %{selector: selector, ref: ref, profile_id: "prof_x"}}

    def run_child(authority, reference, need, input, opts) do
      send(:run_approved_probe, {:child, authority, reference, need, input, opts})
      {:ok, %{child: reference}}
    end

    def subscribe_events(_id, _ctx), do: :ok
    def unsubscribe_events(_id, _ctx), do: :ok
    def events_since(_id, _seq, _athanor), do: []

    def claim_turn_root(_ctx, ref, opts),
      do: {:ok, %{execution_id: "exec_turn", attempt: "att_turn", ref: ref, opts: opts}}

    def pause_turn_root(_ctx, id, _opts), do: {:ok, %{execution_id: id}}
    def resume_turn_root(_ctx, id, _opts), do: {:ok, %{execution_id: id}}
    def adopt_turn_root(_ctx, id, _opts), do: {:ok, %{execution_id: id}}
    def release_turn_root(_ctx, _id, _opts), do: :ok
    def cancel(_ctx, id), do: {:ok, id}
    def cancel_for_restart(_ctx, _id, _payload), do: {:ok, %{}}
    def get(_ctx, id), do: {:ok, %{id: id}}
    def list(_ctx, _opts), do: {:ok, []}
    def ready?, do: true
  end

  setup do
    previous = Application.get_env(:cyfr, :execution_impl)
    Application.put_env(:cyfr, :execution_impl, Engine)
    Process.register(self(), :run_approved_probe)
    on_exit(fn -> Application.put_env(:cyfr, :execution_impl, previous) end)
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  test "files.delete runs the files catalyst as a child under the pinned profile with the card's lineage",
       %{ctx: ctx} do
    proposal = %{
      tool: "files",
      action: "delete",
      args: %{"path" => "a.md"},
      lineage: %{execution_id: "exec_card"}
    }

    assert {:ok, %{child: "catalyst:local.files"}} = Turn.run_approved(proposal, ctx, "prof_x")

    assert_receive {:child, %{selector: {:id, "prof_x"}}, "catalyst:local.files", nil,
                    %{"action" => "delete", "path" => "a.md"}, opts}

    assert opts[:parent_execution_id] == "exec_card"
    assert opts[:root_execution_id] == "exec_card"
    assert opts[:parent_reference] == "formula:local.aqua"
    assert %Sanctum.Context{plane: :guest} = opts[:ctx]
  end

  test "an approved MCP action's lineage is the card's execution as parent and root, and its conversation" do
    # The registry stamps these onto the in-chain call (`put_lineage/2`);
    # a card decided after its turn finished still names its own execution.
    assert Turn.registry_lineage(%{
             lineage: %{execution_id: "exec_card", conversation_id: "conv_1"}
           }) ==
             %{
               parent_execution_id: "exec_card",
               root_execution_id: "exec_card",
               conversation_id: "conv_1"
             }

    assert Turn.registry_lineage(%{lineage: %{execution_id: nil}}) == %{}
    assert Turn.registry_lineage(%{tool: "notes", action: "keep"}) == %{}
  end

  test "http.delete builds the http catalyst's fetch and storage.delete the storage path", %{
    ctx: ctx
  } do
    assert {:ok, _} =
             Turn.run_approved(
               %{tool: "http", action: "delete", args: %{"url" => "http://x"}},
               ctx,
               "prof_x"
             )

    assert_receive {:child, _, "catalyst:local.http", nil,
                    %{
                      "operation" => "fetch",
                      "params" => %{"method" => "DELETE", "url" => "http://x"}
                    }, _}

    assert {:ok, _} =
             Turn.run_approved(
               %{tool: "storage", action: "delete", args: %{"key" => "k"}},
               ctx,
               "prof_x"
             )

    assert_receive {:child, _, "catalyst:local.files", nil,
                    %{"action" => "delete", "path" => "data/storage/k.json"}, _}
  end

  test "an execution.run card naming a wrapped catalyst is run as the virtual action, and the assistant itself never",
       %{ctx: ctx} do
    card = %{
      tool: "execution",
      action: "run",
      args: %{
        "reference" => "catalyst:local.files:0.5.1",
        "input" => %{"action" => "delete", "path" => "data/storage/k.json"}
      }
    }

    assert {:ok, _} = Turn.run_approved(card, ctx, "prof_x")

    assert_receive {:child, _, "catalyst:local.files", nil,
                    %{"action" => "delete", "path" => "data/storage/k.json"}, opts}

    # The assistant is the invoking reference, so the child's row keeps a
    # digest of its reply rather than the reply.
    assert opts[:parent_reference] == "formula:local.aqua"

    self_card = %{
      tool: "execution",
      action: "run",
      args: %{
        "reference" => "formula:local.aqua",
        "input" => %{"tool_policy" => %{"files.delete" => "auto"}}
      }
    }

    assert {:error, {:invalid_argument, msg}} = Turn.run_approved(self_card, ctx, "prof_x")
    assert msg =~ "not a tool"
    refute_receive {:child, _, _, _, _, _}, 50
  end

  test "a UI event has no card to run", %{ctx: ctx} do
    assert {:error, {:invalid_argument, _}} =
             Turn.run_approved(%{tool: "request_setup", action: "open", args: %{}}, ctx, "prof_x")
  end
end
