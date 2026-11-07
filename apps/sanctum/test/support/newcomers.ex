# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Test.Newcomers do
  @moduledoc """
  The directory a deployment pins, for a test of an admission
  (`Sanctum.Newcomer`): `directory!/1` pins it for the calling test and
  restores the setting on exit; an admission names it on the person's
  identity row and sends nothing to it.
  """

  @directory "https://dir-a.test"

  @doc "The directory `directory!/0` pins."
  def directory, do: @directory

  @doc "Pin `url` as this deployment's directory for the calling test."
  def directory!(url \\ @directory),
    do: Prima.Test.Env.put_app_env(:sanctum, :directory_url, url)
end
