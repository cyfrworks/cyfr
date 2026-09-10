# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.TurnPersistenceTest do
  @moduledoc """
  What a chat turn leaves on its execution row. The row's `input` is an
  envelope — the reference, a digest, sizes and the top-level keys of what
  the formula was handed — and never the person's line, the prompt or the
  transcript. Driven through the runner against the real engine and the
  real shipped bundle, provisioned offline.
  """
  use ExUnit.Case, async: false

  import Cyfr.Test.Wait

  alias Arca.ConversationStorage, as: Conversations
  alias Aqua.ConversationRunner
  alias Sanctum.Provisioning
  alias Sanctum.Tenancy.Athanors

  @repo_root Path.expand("../../../..", __DIR__)
  @bundle Path.join(@repo_root, "seed/components")

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_dir = Path.join(System.tmp_dir!(), "cyfr_turn_row_#{System.unique_integer([:positive])}")
    seed_dir = Path.join(test_dir, "seed")
    copy_bundle!(Path.join(seed_dir, "components"))
    File.cp_r!(Path.join(@repo_root, "seed/aqua"), Path.join(seed_dir, "aqua"))

    keys = [:base_path, :seed_path, :registry_url, :oci_registry_url, :aqua_turn, :consent_source]
    prev = Map.new(keys, &{&1, Application.get_env(:cyfr, &1)})
    Application.put_env(:cyfr, :base_path, test_dir)
    Application.put_env(:cyfr, :seed_path, seed_dir)
    Application.put_env(:cyfr, :registry_url, Compendium.RegistryHost.none())
    Application.put_env(:cyfr, :oci_registry_url, Compendium.RegistryHost.none())
    # The real engine, not the fake the runner suite drives, and the durable
    # consent source the fill minted the baseline consent into.
    Application.delete_env(:cyfr, :aqua_turn)
    Application.put_env(:cyfr, :consent_source, Sanctum.Consent.Source.DB)

    on_exit(fn ->
      for {key, value} <- prev do
        if value,
          do: Application.put_env(:cyfr, key, value),
          else: Application.delete_env(:cyfr, key)
      end

      File.rm_rf!(test_dir)
    end)

    n = System.unique_integer([:positive])

    ctx =
      Sanctum.Context.build(
        user_id: "github|https://github.com|row-#{n}",
        athanor_id: Sanctum.TestContext.athanor_id(),
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    {:ok, group} = Athanors.create_group(ctx.user_id, "Row #{n}")
    ctx = %{ctx | athanor_id: group.id}
    :ok = Provisioning.start_provisioning(ctx)
    {:ok, group} = Athanors.get(group.id)
    assert %DateTime{} = group.provisioned_at, inspect(Athanors.settings(group))

    # The shipped soul pins a model catalyst this estate does not hold;
    # unpinned, the turn composes on the engine default and starts.
    {:ok, _} =
      Aqua.AgentConfig.call_aqua(ctx, %{
        "action" => "update",
        "name" => "aqua",
        "catalyst_ref" => ""
      })

    {:ok, conv} = Conversations.create(ctx)
    {:ok, ctx: ctx, conv: conv}
  end

  test "a chat turn's execution row keeps an envelope of its input, never the line itself",
       %{ctx: ctx, conv: conv} do
    line = "the line nobody should find on a row #{System.unique_integer([:positive])}"
    :ok = ConversationRunner.send_message(ctx, conv.id, "@aqua " <> line)

    # The runner starts the turn off its own process; the conversation
    # names the execution once it is admitted, and the row follows.
    wait_until(
      fn ->
        match?({:ok, %{execution_id: id}} when is_binary(id), Conversations.get(ctx, conv.id))
      end,
      15_000,
      "the turn's execution to start"
    )

    {:ok, %{execution_id: execution_id}} = Conversations.get(ctx, conv.id)

    try do
      wait_until(
        fn -> match?(%Arca.Execution{}, Arca.Execution.get_tenant(ctx, execution_id)) end,
        10_000,
        "the execution row to be written"
      )

      row = Arca.Execution.get_tenant(ctx, execution_id)
      envelope = decode(row.input)

      assert envelope["envelope"] == "v1"
      assert envelope["reference"] =~ "formula:local.aqua"
      assert is_binary(envelope["input_hash"])
      assert is_integer(envelope["bytes"]) and envelope["bytes"] > 0
      assert "task" in envelope["keys"]
      assert "system" in envelope["keys"]

      # Nothing of what was said: not the line, not the prompt, not the
      # transcript.
      refute Jason.encode!(envelope) =~ line
      refute Map.has_key?(envelope, "task")
      refute Map.has_key?(envelope, "system")
      refute Map.has_key?(envelope, "messages")
    after
      # Stop the turn and let the cancel settle — the runner, the row and
      # the cancel task — before the sandbox goes away with the test.
      _ = ConversationRunner.stop_turn(ctx, conv.id)

      wait_until(
        fn ->
          not ConversationRunner.turn_running?(ctx, conv.id) and
            match?(
              %Arca.Execution{status: status} when status != "running",
              Arca.Execution.get_tenant(ctx, execution_id)
            ) and
            Task.Supervisor.children(Aqua.TaskSupervisor) == []
        end,
        15_000,
        "the cancelled turn to settle"
      )
    end
  end

  defp decode(input) when is_binary(input), do: Jason.decode!(input)
  defp decode(input) when is_map(input), do: input

  # The tracked bundle, minus Rust build output that may sit beside a source tree.
  defp copy_bundle!(dest) do
    @bundle
    |> Path.join("**")
    |> Path.wildcard(match_dot: false)
    |> Enum.reject(&(String.contains?(&1, "/target/") or File.dir?(&1)))
    |> Enum.each(fn src ->
      rel = Path.relative_to(src, @bundle)
      target = Path.join(dest, rel)
      File.mkdir_p!(Path.dirname(target))
      File.cp!(src, target)
    end)
  end
end
