# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.JsonFormatterTest do
  # One test rewrites the global :logger formatter config to prove the
  # roster is read from it; that is not safe to run beside anything else.
  use ExUnit.Case, async: false

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
          athanor_id: "ath_456",
          request_id: "req_789"
        )

      json = output |> IO.iodata_to_binary() |> String.trim() |> Jason.decode!()
      assert json["user_id"] == "u_123"
      assert json["athanor_id"] == "ath_456"
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

    test "metadata values with no String.Chars implementation do not crash the handler" do
      # `:pid` and `:mfa` are standard Logger metadata; a roster that names
      # one used to raise Protocol.UndefinedError inside the formatter, which
      # takes the logger handler down with it.
      original = Application.get_env(:logger, :default_formatter)

      on_exit(fn ->
        Application.put_env(:logger, :default_formatter, original)
        :persistent_term.erase({Cyfr.JsonFormatter, :metadata_keys})
      end)

      Application.put_env(:logger, :default_formatter,
        format: {Cyfr.JsonFormatter, :format},
        metadata: [:pid, :mfa, :count]
      )

      :persistent_term.erase({Cyfr.JsonFormatter, :metadata_keys})

      output =
        JsonFormatter.format(
          :error,
          "boom",
          {{2026, 1, 1}, {0, 0, 0, 0}},
          pid: self(),
          mfa: {String, :split, 2},
          count: 3
        )

      json = output |> IO.iodata_to_binary() |> String.trim() |> Jason.decode!()
      assert json["pid"] == inspect(self())
      assert json["mfa"] == inspect({String, :split, 2})
      assert json["count"] == "3"
    end

    test "output ends with newline" do
      output =
        JsonFormatter.format(:info, "msg", {{2026, 1, 1}, {0, 0, 0, 0}}, [])
        |> IO.iodata_to_binary()

      assert String.ends_with?(output, "\n")
    end
  end
end
