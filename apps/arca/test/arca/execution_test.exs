defmodule Arca.ExecutionTest do
  use ExUnit.Case, async: false

  alias Arca.Execution

  setup do
    # Start the repo for testing
    # This assumes Arca.Repo is started by the application
    :ok
  end

  describe "start_changeset/1" do
    test "creates valid changeset with required fields" do
      attrs = %{
        id: "exec_test123",
        reference: ~s({"local": "./test.wasm"}),
        user_id: "user_abc",
        started_at: DateTime.utc_now(),
        status: "running"
      }

      changeset = Execution.start_changeset(attrs)
      assert changeset.valid?
    end

    test "requires id" do
      attrs = %{
        reference: ~s({"local": "./test.wasm"}),
        user_id: "user_abc",
        started_at: DateTime.utc_now(),
        status: "running"
      }

      changeset = Execution.start_changeset(attrs)
      refute changeset.valid?
      assert {:id, _} = hd(changeset.errors)
    end

    test "requires reference" do
      attrs = %{
        id: "exec_test123",
        user_id: "user_abc",
        started_at: DateTime.utc_now(),
        status: "running"
      }

      changeset = Execution.start_changeset(attrs)
      refute changeset.valid?
      assert {:reference, _} = hd(changeset.errors)
    end

    test "validates status inclusion" do
      attrs = %{
        id: "exec_test123",
        reference: ~s({"local": "./test.wasm"}),
        user_id: "user_abc",
        started_at: DateTime.utc_now(),
        status: "invalid_status"
      }

      changeset = Execution.start_changeset(attrs)
      refute changeset.valid?
      assert {:status, _} = hd(changeset.errors)
    end

    test "validates component_type inclusion" do
      attrs = %{
        id: "exec_test123",
        reference: ~s({"local": "./test.wasm"}),
        user_id: "user_abc",
        started_at: DateTime.utc_now(),
        status: "running",
        component_type: "invalid_type"
      }

      changeset = Execution.start_changeset(attrs)
      refute changeset.valid?
      assert {:component_type, _} = hd(changeset.errors)
    end

    test "accepts optional fields" do
      attrs = %{
        id: "exec_test123",
        reference: ~s({"local": "./test.wasm"}),
        user_id: "user_abc",
        started_at: DateTime.utc_now(),
        status: "running",
        component_type: "catalyst",
        component_digest: "sha256:abc123",
        input_hash: "def456"
      }

      changeset = Execution.start_changeset(attrs)
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :component_type) == "catalyst"
      assert Ecto.Changeset.get_field(changeset, :component_digest) == "sha256:abc123"
    end
  end

  describe "complete_changeset/2" do
    test "creates valid changeset for completion" do
      execution = %Execution{
        id: "exec_test123",
        reference: ~s({"local": "./test.wasm"}),
        user_id: "user_abc",
        started_at: DateTime.utc_now(),
        status: "running"
      }

      attrs = %{
        completed_at: DateTime.utc_now(),
        duration_ms: 150,
        status: "completed"
      }

      changeset = Execution.complete_changeset(execution, attrs)
      assert changeset.valid?
    end

    test "accepts error_message for failed status" do
      execution = %Execution{
        id: "exec_test123",
        reference: ~s({"local": "./test.wasm"}),
        user_id: "user_abc",
        started_at: DateTime.utc_now(),
        status: "running"
      }

      attrs = %{
        completed_at: DateTime.utc_now(),
        duration_ms: 50,
        status: "failed",
        error_message: "Component crashed"
      }

      changeset = Execution.complete_changeset(execution, attrs)
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :error_message) == "Component crashed"
    end

    test "validates status for completion" do
      execution = %Execution{id: "exec_test123", status: "running"}

      # Invalid status for completion
      attrs = %{
        completed_at: DateTime.utc_now(),
        duration_ms: 100,
        status: "invalid_status"
      }

      changeset = Execution.complete_changeset(execution, attrs)
      refute changeset.valid?
      assert {:status, _} = hd(changeset.errors)
    end
  end

  describe "hash_input/1" do
    test "returns consistent hash for same input" do
      input = %{"method" => "GET", "url" => "https://example.com"}

      hash1 = Execution.hash_input(input)
      hash2 = Execution.hash_input(input)

      assert hash1 == hash2
      assert is_binary(hash1)
      assert String.length(hash1) == 64  # SHA256 hex is 64 chars
    end

    test "returns different hash for different input" do
      input1 = %{"method" => "GET"}
      input2 = %{"method" => "POST"}

      hash1 = Execution.hash_input(input1)
      hash2 = Execution.hash_input(input2)

      refute hash1 == hash2
    end

    test "returns nil for non-map input" do
      assert Execution.hash_input(nil) == nil
      assert Execution.hash_input("string") == nil
      assert Execution.hash_input(123) == nil
    end
  end
end
