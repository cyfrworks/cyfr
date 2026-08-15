# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.LimitsTest do
  use ExUnit.Case, async: true

  alias Sanctum.Limits
  alias Sanctum.Policy.Ceiling

  doctest Sanctum.Limits

  @valid %{
    timeout: "30s",
    max_memory_bytes: 67_108_864,
    max_request_size: 1_048_576,
    max_response_size: 5_242_880,
    rate_limit: %{requests: 100, window: "1m"},
    max_concurrent_tasks: 1,
    batch_timeout: "30s"
  }

  # ============================================================================
  # Field lock — Limits and Ceiling cannot drift
  # ============================================================================

  describe "field lock" do
    test "fields/0 equals Ceiling.clamped_fields/0" do
      assert Enum.sort(Limits.fields()) == Enum.sort(Ceiling.clamped_fields())
    end

    test "struct keys equal Ceiling.clamped_fields/0" do
      struct_keys = Map.keys(%Limits{}) -- [:__struct__]
      assert Enum.sort(struct_keys) == Enum.sort(Ceiling.clamped_fields())
    end
  end

  # ============================================================================
  # new/1
  # ============================================================================

  describe "new/1" do
    test "accepts a complete atom-keyed map" do
      assert {:ok, %Limits{} = limits} = Limits.new(@valid)
      assert limits.timeout == "30s"
      assert limits.max_memory_bytes == 67_108_864
      assert limits.rate_limit == %{requests: 100, window: "1m"}
    end

    test "requires every one of the seven fields" do
      for field <- Limits.fields() do
        assert {:error, {:invalid_limit, ^field, "is required"}} =
                 @valid |> Map.delete(field) |> Limits.new(),
               "expected missing #{field} to be rejected"
      end
    end

    test "rejects negative durations" do
      # parse_duration accepts a leading minus, so "does it parse" alone let
      # "-1s" through — a deadline that already fired.
      for {field, value} <- [{:timeout, "-1s"}, {:batch_timeout, "-500ms"}] do
        assert {:error, {:invalid_limit, ^field, msg}} =
                 @valid |> Map.put(field, value) |> Limits.new()

        assert msg =~ "non-negative"
      end
    end

    test "rejects unknown keys" do
      assert {:error, {:invalid_limit, :unknown_field, _}} =
               @valid |> Map.put(:allowed_domains, ["x.com"]) |> Limits.new()

      assert {:error, {:invalid_limit, :unknown_field, _}} =
               @valid |> Map.put("is_public", true) |> Limits.new()
    end

    test "rejects the same field spelled twice" do
      assert {:error, {:invalid_limit, :timeout, "duplicate key"}} =
               @valid |> Map.put("timeout", "1m") |> Limits.new()
    end

    test "rejects floats and negative integers on numeric fields" do
      assert {:error, {:invalid_limit, :max_memory_bytes, _}} =
               @valid |> Map.put(:max_memory_bytes, 1.5) |> Limits.new()

      assert {:error, {:invalid_limit, :max_concurrent_tasks, _}} =
               @valid |> Map.put(:max_concurrent_tasks, -1) |> Limits.new()

      assert {:error, {:invalid_limit, :max_request_size, _}} =
               @valid |> Map.put(:max_request_size, "big") |> Limits.new()
    end

    test "rejects unparseable durations" do
      assert {:error, {:invalid_limit, :timeout, _}} =
               @valid |> Map.put(:timeout, "soon") |> Limits.new()

      assert {:error, {:invalid_limit, :batch_timeout, _}} =
               @valid |> Map.put(:batch_timeout, 30) |> Limits.new()
    end

    test "validates rate_limit shape" do
      assert {:error, {:invalid_limit, :rate_limit, _}} =
               @valid |> Map.put(:rate_limit, nil) |> Limits.new()

      assert {:error, {:invalid_limit, :rate_limit, _}} =
               @valid |> Map.put(:rate_limit, %{requests: 100}) |> Limits.new()

      assert {:error, {:invalid_limit, :rate_limit, _}} =
               @valid
               |> Map.put(:rate_limit, %{requests: 100, window: "1m", burst: 5})
               |> Limits.new()

      assert {:error, {:invalid_limit, :rate_limit, _}} =
               @valid |> Map.put(:rate_limit, %{requests: -1, window: "1m"}) |> Limits.new()

      assert {:error, {:invalid_limit, :rate_limit, _}} =
               @valid |> Map.put(:rate_limit, %{requests: 100, window: "never"}) |> Limits.new()
    end

    test "normalizes string-keyed rate_limit to atom keys" do
      {:ok, limits} =
        @valid
        |> Map.put(:rate_limit, %{"requests" => 7, "window" => "10s"})
        |> Limits.new()

      assert limits.rate_limit == %{requests: 7, window: "10s"}
    end

    test "rejects non-map input" do
      assert {:error, {:invalid_limit, :input, _}} = Limits.new("30s")
      assert {:error, {:invalid_limit, :input, _}} = Limits.new(nil)
    end
  end

  # ============================================================================
  # Duration accessors
  # ============================================================================

  describe "duration accessors" do
    test "timeout_ms/1 and batch_timeout_ms/1 parse to milliseconds" do
      {:ok, limits} = Limits.new(%{@valid | timeout: "15m", batch_timeout: "500ms"})
      assert Limits.timeout_ms(limits) == {:ok, 900_000}
      assert Limits.batch_timeout_ms(limits) == {:ok, 500}
    end
  end

  # ============================================================================
  # Clamp — delegated to the one Ceiling implementation
  # ============================================================================

  describe "clamp/2" do
    @ceiling %{
      timeout: "10s",
      batch_timeout: "20s",
      max_memory_bytes: 1_000_000,
      max_request_size: 500_000,
      max_response_size: 2_000_000,
      rate_limit_requests: 50,
      max_concurrent_tasks: 3
    }

    test "clamps every field that exceeds the ceiling" do
      {:ok, limits} = Limits.new(@valid)
      clamped = Limits.clamp(limits, @ceiling)

      assert clamped.timeout == "10s"
      assert clamped.batch_timeout == "20s"
      assert clamped.max_memory_bytes == 1_000_000
      assert clamped.max_request_size == 500_000
      assert clamped.max_response_size == 2_000_000
      assert clamped.rate_limit == %{requests: 50, window: "1m"}
      assert clamped.max_concurrent_tasks == 1
    end

    test "leaves fields at or under the ceiling untouched" do
      {:ok, limits} = Limits.new(@valid)
      assert Limits.clamp(limits, %{}) == limits

      roomy = Map.put(@ceiling, :max_concurrent_tasks, 10)
      assert Limits.clamp(limits, roomy).max_concurrent_tasks == 1
    end
  end

  # ============================================================================
  # Characterization: parse_duration/1 trailing-suffix quirk
  # ============================================================================

  describe "parse_duration characterization" do
    # parse_int_unit uses String.trim_trailing, which strips *every* trailing
    # occurrence of the suffix — so "5mm" parses as 5 minutes and "30ss" as
    # 30 seconds. Pinned because Limits validation leans on parse_duration;
    # if this ever tightens, the canonical duration grammar in the freeze doc
    # must be revisited alongside it.
    test "repeated trailing suffixes are tolerated" do
      assert Limits.parse_duration("5mm") == {:ok, 300_000}
      assert Limits.parse_duration("30ss") == {:ok, 30_000}
    end

    test "inner garbage is still rejected" do
      assert {:error, _} = Limits.parse_duration("5m30s")
      assert {:error, _} = Limits.parse_duration("1.5m")
      assert {:error, _} = Limits.parse_duration("30 s")
    end
  end

  # ============================================================================
  # Type defaults
  # ============================================================================

  describe "defaults/1" do
    # These literals are the only source of type defaults; the pins are what
    # keep a refactor from silently loosening what an empty ask grants.
    test "the per-type literals are pinned" do
      for type <- Sanctum.ComponentRef.valid_type_atoms() do
        limits = Limits.defaults(type)

        assert limits.max_memory_bytes == 64 * 1024 * 1024
        assert limits.max_request_size == 1_048_576
        assert limits.max_response_size == 5_242_880
        assert limits.rate_limit == %{requests: 100, window: "1m"}
        assert limits.max_concurrent_tasks == 10
        assert limits.batch_timeout == "5m"
      end

      assert Limits.defaults(:catalyst).timeout == "3m"
      assert Limits.defaults(:formula).timeout == "5m"
      assert Limits.defaults(:reagent).timeout == "1m"
      assert Limits.defaults(:tincture).timeout == "1m"
    end

    test "every default is a complete, valid Limits" do
      for type <- Sanctum.ComponentRef.valid_type_atoms() do
        limits = Limits.defaults(type)

        map =
          limits
          |> Map.from_struct()
          |> Map.new(fn
            {:rate_limit, %{requests: r, window: w}} ->
              {"rate_limit", %{"requests" => r, "window" => w}}

            {k, v} ->
              {Atom.to_string(k), v}
          end)

        assert {:ok, ^limits} = Limits.new(map)
      end
    end
  end
end
