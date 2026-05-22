# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.S7RedactionTest do
  @moduledoc """
  Phase 2 S7: credential query params (`_t`, `_key`, `_session`) are redacted
  before any log sink / error report can observe them (defense-in-depth).
  """
  use ExUnit.Case, async: true

  alias Sanctum.TinctureAuth

  describe "redact_query_string/1" do
    test "replaces sensitive values with [REDACTED], keeps the rest" do
      out = TinctureAuth.redact_query_string("_session=abc&foo=bar&_key=cyfr_ak_xyz&_t=tok")
      decoded = URI.decode_query(out)

      assert decoded["_session"] == "[REDACTED]"
      assert decoded["_key"] == "[REDACTED]"
      assert decoded["_t"] == "[REDACTED]"
      assert decoded["foo"] == "bar"
    end

    test "empty / nil → empty string" do
      assert TinctureAuth.redact_query_string("") == ""
      assert TinctureAuth.redact_query_string(nil) == ""
    end

    test "no sensitive keys → values preserved" do
      out = TinctureAuth.redact_query_string("a=1&b=2")
      assert URI.decode_query(out) == %{"a" => "1", "b" => "2"}
    end
  end

  describe "scrub_conn/1" do
    test "rewrites conn.query_string to the redacted form" do
      conn = %Plug.Conn{query_string: "_key=cyfr_ak_secret&keep=1"}
      scrubbed = TinctureAuth.scrub_conn(conn)

      decoded = URI.decode_query(scrubbed.query_string)
      assert decoded["_key"] == "[REDACTED]"
      assert decoded["keep"] == "1"
      refute scrubbed.query_string =~ "cyfr_ak_secret"
    end
  end
end
