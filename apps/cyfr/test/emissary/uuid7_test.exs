defmodule Emissary.UUID7Test do
  use ExUnit.Case, async: true

  alias Emissary.UUID7

  # ============================================================================
  # Format Tests
  # ============================================================================

  describe "generate/0" do
    test "returns a valid UUID string format" do
      uuid = UUID7.generate()

      # UUID format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx (36 chars)
      assert String.length(uuid) == 36
      assert Regex.match?(~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/, uuid)
    end

    test "returns version 7 UUID" do
      uuid = UUID7.generate()

      # Character at position 14 should be '7' (version)
      assert String.at(uuid, 14) == "7"
    end

    test "returns variant 1 UUID" do
      uuid = UUID7.generate()

      # Character at position 19 should be 8, 9, a, or b (variant 1)
      variant_char = String.at(uuid, 19)
      assert variant_char in ["8", "9", "a", "b"]
    end

    test "generates unique UUIDs" do
      uuids = for _ <- 1..1000, do: UUID7.generate()
      unique_uuids = Enum.uniq(uuids)

      assert length(uuids) == length(unique_uuids)
    end
  end

  # ============================================================================
  # Time-Ordering Tests
  # ============================================================================

  describe "time-ordering" do
    test "UUIDs are time-ordered (later UUIDs sort after earlier ones)" do
      uuid1 = UUID7.generate()
      :timer.sleep(1)
      uuid2 = UUID7.generate()

      # String comparison should maintain time order for UUID v7
      assert uuid1 < uuid2
    end

    test "generate_at/1 creates UUIDs with specific timestamps" do
      ts1 = 1_000_000_000_000
      ts2 = 1_000_000_001_000

      uuid1 = UUID7.generate_at(ts1)
      uuid2 = UUID7.generate_at(ts2)

      assert uuid1 < uuid2
    end

    test "extract_timestamp/1 returns the embedded timestamp" do
      # Known timestamp
      timestamp = System.system_time(:millisecond)
      uuid = UUID7.generate_at(timestamp)

      {:ok, extracted} = UUID7.extract_timestamp(uuid)
      assert extracted == timestamp
    end

    test "before?/2 compares UUID timestamps" do
      uuid1 = UUID7.generate_at(1_000_000_000_000)
      uuid2 = UUID7.generate_at(1_000_000_001_000)

      assert UUID7.before?(uuid1, uuid2) == true
      assert UUID7.before?(uuid2, uuid1) == false
    end
  end

  # ============================================================================
  # Prefixed ID Tests
  # ============================================================================

  describe "generate_id/1" do
    test "generates prefixed ID" do
      id = UUID7.generate_id("test")
      assert String.starts_with?(id, "test_")

      # Extract UUID part
      [_prefix, uuid] = String.split(id, "_", parts: 2)
      assert String.length(uuid) == 36
    end

    test "preserves UUID format after prefix" do
      id = UUID7.generate_id("prefix")
      [_prefix, uuid] = String.split(id, "_", parts: 2)

      assert String.at(uuid, 14) == "7"  # Version
    end
  end

  describe "request_id/0" do
    test "generates request ID with req_ prefix" do
      id = UUID7.request_id()
      assert String.starts_with?(id, "req_")
    end

    test "format matches PRD specification" do
      id = UUID7.request_id()
      # PRD format: req_<uuid7>
      assert Regex.match?(~r/^req_[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/, id)
    end
  end

  describe "execution_id/0" do
    test "generates execution ID with exec_ prefix" do
      id = UUID7.execution_id()
      assert String.starts_with?(id, "exec_")
    end

    test "format matches PRD specification" do
      id = UUID7.execution_id()
      # PRD format: exec_<uuid7>
      assert Regex.match?(~r/^exec_[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/, id)
    end
  end

  describe "session_id/0" do
    test "generates session ID with sess_ prefix" do
      id = UUID7.session_id()
      assert String.starts_with?(id, "sess_")
    end

    test "format matches PRD specification" do
      id = UUID7.session_id()
      # PRD format: sess_<uuid7>
      assert Regex.match?(~r/^sess_[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/, id)
    end
  end

  describe "build_id/0" do
    test "generates build ID with build_ prefix" do
      id = UUID7.build_id()
      assert String.starts_with?(id, "build_")
    end

    test "format matches PRD specification" do
      id = UUID7.build_id()
      # PRD format: build_<uuid7>
      assert Regex.match?(~r/^build_[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/, id)
    end
  end

  # ============================================================================
  # Timestamp Extraction Tests
  # ============================================================================

  describe "extract_timestamp/1" do
    test "extracts timestamp from raw UUID" do
      uuid = UUID7.generate()
      {:ok, ts} = UUID7.extract_timestamp(uuid)

      # Should be within 1 second of current time
      now = System.system_time(:millisecond)
      assert abs(ts - now) < 1000
    end

    test "extracts timestamp from prefixed ID" do
      id = UUID7.request_id()
      {:ok, ts} = UUID7.extract_timestamp(id)

      now = System.system_time(:millisecond)
      assert abs(ts - now) < 1000
    end

    test "returns error for invalid UUID" do
      assert {:error, :invalid_uuid} = UUID7.extract_timestamp("invalid")
      assert {:error, :invalid_uuid} = UUID7.extract_timestamp("not-a-uuid")
      assert {:error, :invalid_uuid} = UUID7.extract_timestamp("")
    end

    test "returns error for malformed UUID" do
      # Wrong length segments
      assert {:error, :invalid_uuid} = UUID7.extract_timestamp("12345678-1234-1234-1234-12345678901")
      # Invalid hex characters
      assert {:error, :invalid_uuid} = UUID7.extract_timestamp("gggggggg-gggg-7ggg-8ggg-gggggggggggg")
    end
  end

  # ============================================================================
  # RFC 9562 Compliance Tests
  # ============================================================================

  describe "RFC 9562 compliance" do
    test "timestamp occupies first 48 bits" do
      timestamp = 0x123456789ABC
      uuid = UUID7.generate_at(timestamp)

      # First 12 hex chars (48 bits) should encode the timestamp
      [time_high, time_low, _rest] = String.split(uuid, "-", parts: 3)
      time_hex = time_high <> time_low

      # The first 48 bits are the timestamp, but the format splits it as:
      # 32 bits (8 chars) - 16 bits (4 chars)
      extracted = String.to_integer(time_hex, 16)
      assert extracted == timestamp
    end

    test "version field is 7 (bits 48-51)" do
      for _ <- 1..100 do
        uuid = UUID7.generate()

        # Parse the third segment (after second dash)
        [_a, _b, version_segment | _rest] = String.split(uuid, "-")

        # First character of version segment should be '7'
        assert String.at(version_segment, 0) == "7"
      end
    end

    test "variant field is RFC 4122 variant (bits 64-65 = 10)" do
      for _ <- 1..100 do
        uuid = UUID7.generate()

        # Parse the fourth segment (variant segment)
        [_a, _b, _c, variant_segment | _rest] = String.split(uuid, "-")

        # First character should be 8, 9, a, or b (binary 10xx)
        first_char = String.at(variant_segment, 0)
        assert first_char in ["8", "9", "a", "b"]
      end
    end
  end

  # ============================================================================
  # Performance Tests
  # ============================================================================

  describe "performance" do
    test "can generate many UUIDs quickly" do
      start = System.monotonic_time(:millisecond)
      for _ <- 1..10_000, do: UUID7.generate()
      elapsed = System.monotonic_time(:millisecond) - start

      # Should generate 10k UUIDs in under 1 second
      assert elapsed < 1000
    end

    test "maintains uniqueness under high concurrency" do
      # Generate UUIDs from multiple processes
      tasks = for _ <- 1..100 do
        Task.async(fn ->
          for _ <- 1..100, do: UUID7.generate()
        end)
      end

      all_uuids = tasks |> Enum.flat_map(&Task.await/1)
      unique_uuids = Enum.uniq(all_uuids)

      assert length(all_uuids) == 10_000
      assert length(unique_uuids) == 10_000
    end
  end
end
