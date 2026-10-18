# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.CloseAfterCancelTest do
  @moduledoc """
  A run whose output arrives after a cancel closed its row is answered as
  the row stands: its caller (a scheduler, a parent, an MCP client) reads
  the cancel, never a completion the record does not hold.
  """

  use ExUnit.Case, async: false

  alias Opus.{Close, Record}

  setup tags do
    Cyfr.Test.Sandbox.setup!(tags)
    Sanctum.TestContext.athanor!()
    {:ok, ctx: Sanctum.TestContext.local(:api)}
  end

  describe "a completion after a cancel closed the row" do
    test "answers the cancel and leaves the cancelled row standing", %{ctx: ctx} do
      record = Record.new(ctx, "catalyst:local.test:1.0.0", %{}, component_type: :catalyst)
      :ok = Record.write_started(record)
      assert {:ok, %{status: :cancelled}} = Record.cancel(ctx, record.id)

      close = %Close{
        ctx: ctx,
        record: record,
        limits: Prima.Authority.zero_limits(),
        started: true
      }

      assert {:error, "Execution cancelled"} =
               Close.complete(close, [], %{"late" => true}, %{})

      assert %{status: "cancelled", output: nil} =
               Arca.Repo.get!(Arca.Schemas.Execution, record.id)
    end

    test "a completion whose write lands still answers its result", %{ctx: ctx} do
      record = Record.new(ctx, "catalyst:local.test:1.0.0", %{}, component_type: :catalyst)
      :ok = Record.write_started(record)

      close = %Close{
        ctx: ctx,
        record: record,
        limits: Prima.Authority.zero_limits(),
        started: true
      }

      assert {:ok, %{status: :completed, output: %{"ok" => true}}} =
               Close.complete(close, [], %{"ok" => true}, %{})

      assert %{status: "completed"} = Arca.Repo.get!(Arca.Schemas.Execution, record.id)
    end
  end
end
