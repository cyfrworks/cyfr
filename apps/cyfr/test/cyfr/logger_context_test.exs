# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.LoggerContextTest do
  use ExUnit.Case, async: true

  alias Cyfr.LoggerContext

  describe "set_from_context/1" do
    test "sets correct Logger metadata" do
      ctx =
        Sanctum.Context.build(
          user_id: "user_123",
          org_id: "org_abc",
          project_id: "proj_xyz",
          permissions: [:execute],
          auth_method: :oidc,
          namespace: "testns",
          authenticated: true
        )

      LoggerContext.set_from_context(ctx)

      metadata = Logger.metadata()
      assert metadata[:user_id] == "user_123"
      assert metadata[:org_id] == "org_abc"
      assert metadata[:project_id] == "proj_xyz"
      assert metadata[:auth_method] == :oidc
    end
  end

  describe "set_request_id/1" do
    test "sets request_id metadata" do
      LoggerContext.set_request_id("req_abc123")
      metadata = Logger.metadata()
      assert metadata[:request_id] == "req_abc123"
    end
  end

  describe "capture/0 and restore/1" do
    test "cross-process propagation" do
      LoggerContext.set_from_context(
        Sanctum.Context.build(
          user_id: "parent_user",
          permissions: [:execute],
          auth_method: :oidc,
          namespace: "testns",
          authenticated: true
        )
      )

      LoggerContext.set_request_id("req_parent")

      captured = LoggerContext.capture()

      task =
        Task.async(fn ->
          # Metadata should be empty in new process
          assert Logger.metadata()[:user_id] == nil

          LoggerContext.restore(captured)

          metadata = Logger.metadata()
          assert metadata[:user_id] == "parent_user"
          assert metadata[:request_id] == "req_parent"
          :ok
        end)

      assert Task.await(task) == :ok
    end
  end
end
