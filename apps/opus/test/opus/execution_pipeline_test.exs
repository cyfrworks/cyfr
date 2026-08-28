# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.ExecutionPipelineTest do
  use ExUnit.Case, async: false

  alias Opus.ExecutionPipeline

  describe "secrets/1" do
    test "collects preloaded vault fields and dispensed OAuth tokens" do
      execution_id = "exec_pipeline_secrets_#{:rand.uniform(100_000)}"
      :ok = Opus.OAuthTokenTracker.put(execution_id, "oauth-token-abc")

      p = %ExecutionPipeline{
        preloaded_fields: %{"api_key" => "vault-value-xyz"},
        record: %Opus.ExecutionRecord{id: execution_id}
      }

      assert Enum.sort(ExecutionPipeline.secrets(p)) ==
               ["oauth-token-abc", "vault-value-xyz"]

      # The OAuth half drains on collect; the vault half is always available.
      assert ExecutionPipeline.secrets(p) == ["vault-value-xyz"]
    end

    test "a pipeline without a record still exposes its vault fields" do
      p = %ExecutionPipeline{preloaded_fields: %{"k" => "v"}, record: nil}
      assert ExecutionPipeline.secrets(p) == ["v"]
    end
  end
end
