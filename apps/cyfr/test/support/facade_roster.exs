# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

# The facade roster: for each foundation and domain root, the facade
# modules its Boundary `exports` must hold beyond the additions
# `Cyfr.BoundaryDeclarationsTest` rosters with their reasons. Generated
# from the tree at `a9dddcfb`; a change to a facade's exports is made here
# in the same change.
%{
  "Arca" => ["Arca.Files", "Arca.Retention"],
  "Sanctum" => [
    "Sanctum.Consent",
    "Sanctum.RegistryCredentials",
    "Sanctum.TinctureAccess",
    "Sanctum.ToolGrants",
    "Sanctum.Webhook"
  ],
  "Grimoire" => ["Grimoire.Proxy", "Grimoire.RequestLog", "Grimoire.RunningTasks"],
  "Compendium" => ["Compendium.Providers.Component"],
  "Crucible" => [],
  "Aqua" => ["Aqua.Text"]
}
