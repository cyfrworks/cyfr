# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.AuditSinks.JSONLTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Arca.AuditSinks.JSONL

  setup do
    rand_id = :rand.uniform(100_000)
    test_path = Path.join(System.tmp_dir!(), "jsonl_audit_test_#{rand_id}")
    original_base_path = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)

    ctx =
      Sanctum.Context.build(
        user_id: "audit_user_#{rand_id}",
        namespace: "audit_user_#{rand_id}",
        project_id: "default",
        permissions: [:*],
        scope: :project,
        auth_method: :oidc,
        authenticated: true
      )

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original_base_path,
        do: Application.put_env(:cyfr, :base_path, original_base_path),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    {:ok, ctx: ctx, test_path: test_path}
  end

  describe "handle_audit_event/3" do
    test "writes JSONL entry to file with context", %{ctx: ctx} do
      JSONL.handle_audit_event(
        [:cyfr, :sanctum, :auth],
        %{count: 1},
        %{context: ctx, user_id: ctx.user_id, outcome: :success}
      )

      date = Date.utc_today() |> Date.to_iso8601()
      {:ok, content} = Arca.get(ctx, ["audit", date <> ".jsonl"])
      assert content =~ "cyfr.sanctum.auth"
      assert content =~ "success"
    end

    test "skips write when context is nil" do
      log =
        capture_log(fn ->
          JSONL.handle_audit_event(
            [:cyfr, :sanctum, :auth],
            %{count: 1},
            %{user_id: "anon"}
          )
        end)

      assert log =~ "Skipping audit write"
    end

    test "appends to existing file", %{ctx: ctx} do
      JSONL.handle_audit_event(
        [:cyfr, :sanctum, :auth],
        %{count: 1},
        %{context: ctx, user_id: ctx.user_id}
      )

      JSONL.handle_audit_event(
        [:cyfr, :sanctum, :policy],
        %{count: 1},
        %{context: ctx, user_id: ctx.user_id}
      )

      date = Date.utc_today() |> Date.to_iso8601()
      {:ok, content} = Arca.get(ctx, ["audit", date <> ".jsonl"])
      lines = String.split(content, "\n", trim: true)
      assert length(lines) == 2
    end
  end
end
