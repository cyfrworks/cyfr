# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.TinctureUrl do
  @moduledoc """
  The shape of a tincture's public URL: `/t/:athanor/:publisher/:name`.

  Two sides agree on it — the console and the controller build the href a
  browser follows, the registry stores it on an entry, and the assistant's
  visibility tool tells a person where their tincture is — so the shape is
  written once here and composed, never spelled out again.

  `:athanor` is the athanor's route segment: `@<namespace>` names a
  person's athanor, a bare slug a group's.
  """

  @doc """
  The canonical tincture path.

  Refuses an empty athanor segment in the head rather than building
  `/t//publisher/name`, which would route to a different thing.
  """
  @spec path(String.t(), String.t(), String.t()) :: String.t()
  def path(athanor_segment, publisher, name)
      when is_binary(athanor_segment) and athanor_segment != "" do
    "/t/#{athanor_segment}/#{publisher}/#{name}"
  end
end
