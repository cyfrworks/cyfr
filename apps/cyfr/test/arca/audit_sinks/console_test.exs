# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.AuditSinks.ConsoleTest do
  use ExUnit.Case, async: true

  alias Arca.AuditSinks.Console

  describe "handle_audit_event/3" do
    test "returns :ok for valid event" do
      assert :ok =
               Console.handle_audit_event(
                 [:cyfr, :sanctum, :auth],
                 %{count: 1},
                 %{user_id: "user_1", execution_id: "exec_1"}
               )
    end

    test "handles missing optional metadata fields" do
      assert :ok =
               Console.handle_audit_event(
                 [:cyfr, :opus, :execute, :start],
                 %{duration: 100},
                 %{}
               )
    end
  end
end
