# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.NotesTest do
  # The notes domain owns the text rendered for each write outcome.
  use ExUnit.Case, async: true

  alias Aqua.Notes

  test "describe/1 has one sentence per outcome the writes can answer with" do
    assert Notes.describe(%{kept: "flight", athanor_id: "ath_1", replaced: false}) ==
             "📝 Kept a note: flight"

    assert Notes.describe(%{kept: "flight", athanor_id: "ath_1", replaced: true}) ==
             "📝 Replaced the note: flight"

    assert Notes.describe(%{pinned: "about-us", athanor_id: "ath_1"}) == "📝 Pinned about-us"
    assert Notes.describe(%{cleared: "about-us", athanor_id: "ath_1"}) == "📝 Cleared about-us"
    assert Notes.describe(%{forgot: "flight", athanor_id: "ath_1"}) == "📝 Forgot the note: flight"
  end

  test "describe/1 reads either key spelling — an answer may have crossed the wire" do
    assert Notes.describe(%{"kept" => "flight", "replaced" => true}) ==
             "📝 Replaced the note: flight"

    assert Notes.describe(%{"forgot" => "flight"}) == "📝 Forgot the note: flight"
  end

  test "describe/1 is nil for anything that is not a write's answer" do
    assert is_nil(Notes.describe(%{name: "flight", content: "BA117"}))
    assert is_nil(Notes.describe(%{"status" => "ok"}))
    assert is_nil(Notes.describe(:ok))
    assert is_nil(Notes.describe(nil))
  end
end
