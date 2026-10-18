# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

# The other adapter's tests are excluded (`Arca.Test.Adapter`).
ExUnit.configure(exclude: Arca.Test.Adapter.exclusions())

# The cap port every capped write asks. In an umbrella run the host's boot
# (`Cyfr.Application`) installed it before this file runs; Sanctum's own
# build has no host, so the suite installs the one implementation itself,
# before the first test that writes a tenant byte — only when nothing has,
# as arca's suite does.
try do
  Prima.Caps.impl!()
rescue
  Prima.Caps.NotInstalledError -> Prima.Caps.install!(Sanctum.Tenancy.Caps)
end

# The component-facts port, which every sign-in asks to fill the person's
# athanor. Sanctum's own build has no component domain, so the suite
# installs one that fills nothing (`Sanctum.Test.Components`) where no
# boot installed the host's.
Sanctum.Test.Components.install!()

# The platform settings Sanctum reads (the caps, the session idle timeout,
# the webhook skew window). The host installs every setting's declaration
# at its boot, which an umbrella run has done and Sanctum's own build has
# not: the suite keeps a boot's declaration and installs these defaults
# where there is none (`Sanctum.Test.Settings.install!/0`).
Sanctum.Test.Settings.install!()

# The one redaction vocabulary, which the host feeds Phoenix at boot.
# Sanctum's own build boots no host, so the suite does what the boot does,
# before any test reads a filtered parameter; in an umbrella run it puts
# the same value back.
Application.put_env(:phoenix, :filter_parameters, Prima.Sanitizer.filter_parameters())

# The boot identity, the storage roots, the schema check, the sandbox mode
# and the seeded athanors, as every database app's suite has them.
Arca.Test.SuiteBoot.boot!(seed: &Sanctum.TestContext.seed_athanors!/0, stand_ins: true)

ExUnit.start()
