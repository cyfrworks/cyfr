# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.Layouts do
  @moduledoc """
  Layout components for Prism.

  Provides the root HTML skeleton and the app layout with
  sidebar navigation, top bar, and content area.
  """

  use PrismWeb, :html

  embed_templates "layouts/*"
end
