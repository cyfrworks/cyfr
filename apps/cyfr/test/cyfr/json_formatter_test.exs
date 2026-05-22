# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.JsonFormatterTest do
  use ExUnit.Case, async: true

  alias Cyfr.JsonFormatter

  describe "format/4" do
    test "produces valid JSON with required fields" do
      output =
        JsonFormatter.format(
          :info,
          "hello world",
          {{2026, 3, 15}, {12, 30, 45, 0}},
          []
        )

      json = output |> IO.iodata_to_binary() |> String.trim() |> Jason.decode!()
      assert json["level"] == "info"
      assert json["message"] == "hello world"
      assert json["timestamp"] == "2026-03-15T12:30:45Z"
    end

    test "includes metadata fields" do
      output =
        JsonFormatter.format(
          :warning,
          "test message",
          {{2026, 1, 1}, {0, 0, 0, 0}},
          user_id: "u_123",
          org_id: "org_456",
          request_id: "req_789"
        )

      json = output |> IO.iodata_to_binary() |> String.trim() |> Jason.decode!()
      assert json["user_id"] == "u_123"
      assert json["org_id"] == "org_456"
      assert json["request_id"] == "req_789"
    end

    test "handles iodata messages" do
      output =
        JsonFormatter.format(
          :debug,
          ["multi", "part"],
          {{2026, 1, 1}, {0, 0, 0, 0}},
          []
        )

      json = output |> IO.iodata_to_binary() |> String.trim() |> Jason.decode!()
      assert json["message"] == "multipart"
    end

    test "output ends with newline" do
      output =
        JsonFormatter.format(:info, "msg", {{2026, 1, 1}, {0, 0, 0, 0}}, [])
        |> IO.iodata_to_binary()

      assert String.ends_with?(output, "\n")
    end
  end
end
