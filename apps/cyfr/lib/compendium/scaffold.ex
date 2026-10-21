# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Compendium.Scaffold do
  @moduledoc """
  Scaffolds new component projects with directory structure, WIT files,
  manifest, and starter Rust source; a tincture starts from one of the
  frame's templates (`Compendium.tincture_templates/0`): vanilla HTML, JS
  and CSS, or Vite, or React on Vite, the built two with the lockfile
  their build installs from.

  Creates the standard layout under the athanor's
  `components/{type}s/local/{name}/{version}/`.
  """

  alias Sanctum.{Context, Refusals}

  # A built template's npm packages, and the lockfile its build installs
  # from: a tincture builds only from its lockfile, so a scaffold that ships
  # a package manifest ships the lockfile that pins it. `@lock_packages` is
  # the `packages` object of the lockfile `npm install --package-lock-only`
  # writes for the React template's package manifest, one package a line;
  # the Vite template's lockfile is the closure of `vite` within it, which is
  # exactly what npm writes for a manifest that asks for `vite` alone.
  # Changing a version below means regenerating those lines from the new
  # manifest. The lockfile's name is the frame rules' (the scaffold test
  # holds it to `Compendium.Tincture.Rules.lockfile/0`).
  @lockfile "package-lock.json"

  @react_packages %{
    "dependencies" => %{"react" => "^19.1.0", "react-dom" => "^19.1.0"},
    "devDependencies" => %{
      "@types/react" => "^19.1.0",
      "@types/react-dom" => "^19.1.0",
      "@vitejs/plugin-react" => "^6.1.2",
      "typescript" => "^7.0.2",
      "vite" => "^8.3.4"
    }
  }

  @vite_packages %{"devDependencies" => %{"vite" => "^8.3.4"}}

  @lock_packages_json ~S"""
  {
  "node_modules/@oxc-project/types": {"version":"0.153.0","resolved":"https://registry.npmjs.org/@oxc-project/types/-/types-0.153.0.tgz","integrity":"sha512-jSNrRIyvPVLL5E1z/tS5zLAprosGz/FuI1PWwEOz59j3E4TTTzSpqKb/RDGqJhhW0QHYISGXxq582wGx6T11Tw==","dev":true,"license":"MIT","funding":{"url":"https://github.com/sponsors/oxc-project"}},
  "node_modules/@rolldown/binding-android-arm-eabi": {"version":"1.2.13","resolved":"https://registry.npmjs.org/@rolldown/binding-android-arm-eabi/-/binding-android-arm-eabi-1.2.13.tgz","integrity":"sha512-Vu/NICrgdRvUOeaJZIyB2FP63s6fO/4ud5l8dXmxDx9yDyn+mN0y+gsvsVviSli+T361Aqo0h46EuMoobrwawA==","cpu":["arm"],"dev":true,"license":"MIT","optional":true,"os":["android"],"engines":{"node":"^20.19.0 || >=22.12.0"}},
  "node_modules/@rolldown/binding-android-arm64": {"version":"1.2.13","resolved":"https://registry.npmjs.org/@rolldown/binding-android-arm64/-/binding-android-arm64-1.2.13.tgz","integrity":"sha512-6LEoIrGy5vvCd2boNnv2soPSUZj/PRvhp8R/t9KlX+mIZxThIE/ZqxrGXxmuNX0FuvQFvLdZr7S4HrYpYBVhEQ==","cpu":["arm64"],"dev":true,"license":"MIT","optional":true,"os":["android"],"engines":{"node":"^20.19.0 || >=22.12.0"}},
  "node_modules/@rolldown/binding-darwin-arm64": {"version":"1.2.13","resolved":"https://registry.npmjs.org/@rolldown/binding-darwin-arm64/-/binding-darwin-arm64-1.2.13.tgz","integrity":"sha512-CaJSRzlQ6Q+zkDMVA9OkVxBjVoPRCDEE3v0FSJ9kIQBgRjFApA3Si4ijhbNVUji7ZJt+PfO0e46qy4nPInHUPA==","cpu":["arm64"],"dev":true,"license":"MIT","optional":true,"os":["darwin"],"engines":{"node":"^20.19.0 || >=22.12.0"}},
  "node_modules/@rolldown/binding-darwin-x64": {"version":"1.2.13","resolved":"https://registry.npmjs.org/@rolldown/binding-darwin-x64/-/binding-darwin-x64-1.2.13.tgz","integrity":"sha512-e4r340I5hxSzJkD3YJBxgzq/rJ3wwxwdLLb2FPt1Zpyem20nrQPT11DDEEkazwxaHumH8wpglsp/Ozgj/wT6mw==","cpu":["x64"],"dev":true,"license":"MIT","optional":true,"os":["darwin"],"engines":{"node":"^20.19.0 || >=22.12.0"}},
  "node_modules/@rolldown/binding-freebsd-x64": {"version":"1.2.13","resolved":"https://registry.npmjs.org/@rolldown/binding-freebsd-x64/-/binding-freebsd-x64-1.2.13.tgz","integrity":"sha512-hoBWDZ4/K/mJKVMbsgUd1jfpA2DiOrJ54mpegObU9TBHBBrtX4FLIXJJQRDPZ/2Dn91GvPob+Z2hwKJzf4E5SQ==","cpu":["x64"],"dev":true,"license":"MIT","optional":true,"os":["freebsd"],"engines":{"node":"^20.19.0 || >=22.12.0"}},
  "node_modules/@rolldown/binding-linux-arm-gnueabihf": {"version":"1.2.13","resolved":"https://registry.npmjs.org/@rolldown/binding-linux-arm-gnueabihf/-/binding-linux-arm-gnueabihf-1.2.13.tgz","integrity":"sha512-oF9fZu3vTWnTiVAkDFxU9PJLt1nh20K9RRpuHsR7ZnE2L7XookBbDBVLojCVSLGbvtSlxeUNnjAj6DbNsKyzbg==","cpu":["arm"],"dev":true,"license":"MIT","optional":true,"os":["linux"],"engines":{"node":"^20.19.0 || >=22.12.0"}},
  "node_modules/@rolldown/binding-linux-arm64-gnu": {"version":"1.2.13","resolved":"https://registry.npmjs.org/@rolldown/binding-linux-arm64-gnu/-/binding-linux-arm64-gnu-1.2.13.tgz","integrity":"sha512-DTpb/+jMiqWMPgphn4ksW1zW+XLJ6dJJ9FMvnIk9I291LhCctMPhMYJrP5t9p6C9qa3KXadDdUEZHBaPh3kNxQ==","cpu":["arm64"],"dev":true,"libc":["glibc"],"license":"MIT","optional":true,"os":["linux"],"engines":{"node":"^20.19.0 || >=22.12.0"}},
  "node_modules/@rolldown/binding-linux-arm64-musl": {"version":"1.2.13","resolved":"https://registry.npmjs.org/@rolldown/binding-linux-arm64-musl/-/binding-linux-arm64-musl-1.2.13.tgz","integrity":"sha512-xU+Kvv9N2A3SY35zFh1FWWNjxbadE/BKeqnkXe7vScU4GZsw757BlVmDLITZEq8DPpk6m7uoDYkK7P+x/uU5Ow==","cpu":["arm64"],"dev":true,"libc":["musl"],"license":"MIT","optional":true,"os":["linux"],"engines":{"node":"^20.19.0 || >=22.12.0"}},
  "node_modules/@rolldown/binding-linux-ppc64-gnu": {"version":"1.2.13","resolved":"https://registry.npmjs.org/@rolldown/binding-linux-ppc64-gnu/-/binding-linux-ppc64-gnu-1.2.13.tgz","integrity":"sha512-XMk/hnhh25oQ756Lclb1Q11h4ll0xC0Esa5w4Vzp+mAE2S3AGJgeM0SonrIgY8fHhjarb6hcoTuwoFG0VVP2ig==","cpu":["ppc64"],"dev":true,"libc":["glibc"],"license":"MIT","optional":true,"os":["linux"],"engines":{"node":"^20.19.0 || >=22.12.0"}},
  "node_modules/@rolldown/binding-linux-s390x-gnu": {"version":"1.2.13","resolved":"https://registry.npmjs.org/@rolldown/binding-linux-s390x-gnu/-/binding-linux-s390x-gnu-1.2.13.tgz","integrity":"sha512-U1BoTHYmlywE2n3HUWjzZ+8EQsKr+OwpxYuDWaubx42tUL8QSL7nOqRz/NVHanibbFP3M1Rxuprz/wNcbMKjqw==","cpu":["s390x"],"dev":true,"libc":["glibc"],"license":"MIT","optional":true,"os":["linux"],"engines":{"node":"^20.19.0 || >=22.12.0"}},
  "node_modules/@rolldown/binding-linux-x64-gnu": {"version":"1.2.13","resolved":"https://registry.npmjs.org/@rolldown/binding-linux-x64-gnu/-/binding-linux-x64-gnu-1.2.13.tgz","integrity":"sha512-J4cm80Pc6wEwV5AZ42o62sIQgDk+Y7R2s646jIwuvO+4V46QB58N4vVuMPWCBaNgursXLpmUWJV//WQAkPvHBQ==","cpu":["x64"],"dev":true,"libc":["glibc"],"license":"MIT","optional":true,"os":["linux"],"engines":{"node":"^20.19.0 || >=22.12.0"}},
  "node_modules/@rolldown/binding-linux-x64-musl": {"version":"1.2.13","resolved":"https://registry.npmjs.org/@rolldown/binding-linux-x64-musl/-/binding-linux-x64-musl-1.2.13.tgz","integrity":"sha512-W0euZS40U4V6JkmEnVCIX9mcsL6cbXQ4X8c2w+MMOIjFg68TXUW+u3RT+2e1t1pv9mg/EP3pDtK3POXdQ7Rxyw==","cpu":["x64"],"dev":true,"libc":["musl"],"license":"MIT","optional":true,"os":["linux"],"engines":{"node":"^20.19.0 || >=22.12.0"}},
  "node_modules/@rolldown/binding-openharmony-arm64": {"version":"1.2.13","resolved":"https://registry.npmjs.org/@rolldown/binding-openharmony-arm64/-/binding-openharmony-arm64-1.2.13.tgz","integrity":"sha512-do/AF/4n9MRshia3a5aXoy8xM2c6mgfT6D7H/dY6my5z+hfCIR4ab7mk4IRj++nsEQpKy39kd0DQnDq+r692tw==","cpu":["arm64"],"dev":true,"license":"MIT","optional":true,"os":["openharmony"],"engines":{"node":"^20.19.0 || >=22.12.0"}},
  "node_modules/@rolldown/binding-win32-arm64-msvc": {"version":"1.2.13","resolved":"https://registry.npmjs.org/@rolldown/binding-win32-arm64-msvc/-/binding-win32-arm64-msvc-1.2.13.tgz","integrity":"sha512-6FtUf2cJZobutJdxnGYX8z0vtbgqU0b2v8vfBhkXb9wp2MppMFtkunE+IaOntyi01rkIQoPW2GHABtfzsC0BRQ==","cpu":["arm64"],"dev":true,"license":"MIT","optional":true,"os":["win32"],"engines":{"node":"^20.19.0 || >=22.12.0"}},
  "node_modules/@rolldown/binding-win32-x64-msvc": {"version":"1.2.13","resolved":"https://registry.npmjs.org/@rolldown/binding-win32-x64-msvc/-/binding-win32-x64-msvc-1.2.13.tgz","integrity":"sha512-UKhFaZTeTcbKrb3iU82m17jVcPEAoqDkCN5MBqgPyZSwp/cQmib21crTS0DdH7T1B7wZRWEI89YQAOJMet5yhg==","cpu":["x64"],"dev":true,"license":"MIT","optional":true,"os":["win32"],"engines":{"node":"^20.19.0 || >=22.12.0"}},
  "node_modules/@rolldown/pluginutils": {"version":"1.0.1","resolved":"https://registry.npmjs.org/@rolldown/pluginutils/-/pluginutils-1.0.1.tgz","integrity":"sha512-2j9bGt5Jh8hj+vPtgzPtl72j0yRxHAyumoo6TNfAjsLB04UtpSvPbPcDcBMxz7n+9CYB0c1GxQFxYRg2jimqGw==","dev":true,"license":"MIT"},
  "node_modules/@types/react": {"version":"19.3.0","resolved":"https://registry.npmjs.org/@types/react/-/react-19.3.0.tgz","integrity":"sha512-N0rFCuH9YoxG9/m61l9MfpJKfmLOVU0em7ipIz6TRgSSkvReLB9vL85GB+yr8Bs5leqpvg96JSwF4ZS1s4viQg==","dev":true,"license":"MIT","dependencies":{"csstype":"^3.2.2"}},
  "node_modules/@types/react-dom": {"version":"19.3.0","resolved":"https://registry.npmjs.org/@types/react-dom/-/react-dom-19.3.0.tgz","integrity":"sha512-ZI7bU42mZXXKHn/qNLEw2IrbiINU7X5+vfgdixBHkCNpYWXjKgfQ/P+uyGb5CjOLB9UcnTeg3rylQtV2hym44Q==","dev":true,"license":"MIT","peerDependencies":{"@types/react":"^19.3.0"}},
  "node_modules/@typescript/typescript-aix-ppc64": {"version":"7.0.2","resolved":"https://registry.npmjs.org/@typescript/typescript-aix-ppc64/-/typescript-aix-ppc64-7.0.2.tgz","integrity":"sha512-MTKKkWB7p/0E9xi1d1tHtZ5PiLkGEMIq88pK2CubZjOsLtYTLqhgIgi6zepFa+9GHZ6h05NMCkQxGKiPXMxXtQ==","cpu":["ppc64"],"dev":true,"license":"Apache-2.0","optional":true,"os":["aix"],"engines":{"node":">=16.20.0"}},
  "node_modules/@typescript/typescript-darwin-arm64": {"version":"7.0.2","resolved":"https://registry.npmjs.org/@typescript/typescript-darwin-arm64/-/typescript-darwin-arm64-7.0.2.tgz","integrity":"sha512-gowzar9MwS/aRWp6f3a4KUqzRjAZjOsmGNCM6LcTgXum+dBfgsBVMN+AgvOCCbguXyick6LJhpBszxMebJ8syA==","cpu":["arm64"],"dev":true,"license":"Apache-2.0","optional":true,"os":["darwin"],"engines":{"node":">=16.20.0"}},
  "node_modules/@typescript/typescript-darwin-x64": {"version":"7.0.2","resolved":"https://registry.npmjs.org/@typescript/typescript-darwin-x64/-/typescript-darwin-x64-7.0.2.tgz","integrity":"sha512-SZ9xZInqApNlNGc9s0W1VSsktYSOe9cFqNOIqmN1Gs8SmkjKZYFt017G4VwPxASInODuAdbTW7sXiFUf893RgA==","cpu":["x64"],"dev":true,"license":"Apache-2.0","optional":true,"os":["darwin"],"engines":{"node":">=16.20.0"}},
  "node_modules/@typescript/typescript-freebsd-arm64": {"version":"7.0.2","resolved":"https://registry.npmjs.org/@typescript/typescript-freebsd-arm64/-/typescript-freebsd-arm64-7.0.2.tgz","integrity":"sha512-W5NH4y/J0plIIS5b2xvTEkU7JFxyqdMAOgf+Ilhl0vHQXKO5dZoxd+C/jEtq56c4F3wk71RB4BMRQ2XdI+bwYQ==","cpu":["arm64"],"dev":true,"license":"Apache-2.0","optional":true,"os":["freebsd"],"engines":{"node":">=16.20.0"}},
  "node_modules/@typescript/typescript-freebsd-x64": {"version":"7.0.2","resolved":"https://registry.npmjs.org/@typescript/typescript-freebsd-x64/-/typescript-freebsd-x64-7.0.2.tgz","integrity":"sha512-UMGDx5sTpzNw3WiPebH7l90IWfJggEd+egHt/q6p7/Cm3zqoV7VxkGXt+3DxPIw8CcmvAB0j3sVVfbhX+M4Tpw==","cpu":["x64"],"dev":true,"license":"Apache-2.0","optional":true,"os":["freebsd"],"engines":{"node":">=16.20.0"}},
  "node_modules/@typescript/typescript-linux-arm": {"version":"7.0.2","resolved":"https://registry.npmjs.org/@typescript/typescript-linux-arm/-/typescript-linux-arm-7.0.2.tgz","integrity":"sha512-gffT3xPz9sR7j/YJExkyPntrI0P2EP9XbOyWzth2/Gs0RstK+90RBcO0ncXoXy/beYll1SXw846Nf2zdnEz0QQ==","cpu":["arm"],"dev":true,"license":"Apache-2.0","optional":true,"os":["linux"],"engines":{"node":">=16.20.0"}},
  "node_modules/@typescript/typescript-linux-arm64": {"version":"7.0.2","resolved":"https://registry.npmjs.org/@typescript/typescript-linux-arm64/-/typescript-linux-arm64-7.0.2.tgz","integrity":"sha512-Qh4eU4/y3yDjnfjjyPYihMj5/ODIlmt+Bzu17OI+fiSRDW57QmU5SiN63exPRNJPKUzcc1INa1NXdrJ+MqHjUQ==","cpu":["arm64"],"dev":true,"license":"Apache-2.0","optional":true,"os":["linux"],"engines":{"node":">=16.20.0"}},
  "node_modules/@typescript/typescript-linux-loong64": {"version":"7.0.2","resolved":"https://registry.npmjs.org/@typescript/typescript-linux-loong64/-/typescript-linux-loong64-7.0.2.tgz","integrity":"sha512-uEHck9i8hoAzXPiYRib1O7miOnz23SxIeVl6F4LXox+qov1K35jHcEW6VHKvZI+pyvl7fZEP4MCU5LYvIq1GuQ==","cpu":["loong64"],"dev":true,"license":"Apache-2.0","optional":true,"os":["linux"],"engines":{"node":">=16.20.0"}},
  "node_modules/@typescript/typescript-linux-mips64el": {"version":"7.0.2","resolved":"https://registry.npmjs.org/@typescript/typescript-linux-mips64el/-/typescript-linux-mips64el-7.0.2.tgz","integrity":"sha512-R4KvAMnE43W5Qeqb0Ly56O3mWMWIAgsMyz36DCaycd5nbg/9kzm0liw3JocfRqyJY0KPmzFjbswozXyW0DnIYA==","cpu":["mips64el"],"dev":true,"license":"Apache-2.0","optional":true,"os":["linux"],"engines":{"node":">=16.20.0"}},
  "node_modules/@typescript/typescript-linux-ppc64": {"version":"7.0.2","resolved":"https://registry.npmjs.org/@typescript/typescript-linux-ppc64/-/typescript-linux-ppc64-7.0.2.tgz","integrity":"sha512-DORx5b3sd/4S7eayxm4FQv+A7CrkUIGRaHiwI8oiHTAI1fAPWhF4J0vAlkC8biAlHSVVwxMQ3tjZ2/DVbnQiiA==","cpu":["ppc64"],"dev":true,"license":"Apache-2.0","optional":true,"os":["linux"],"engines":{"node":">=16.20.0"}},
  "node_modules/@typescript/typescript-linux-riscv64": {"version":"7.0.2","resolved":"https://registry.npmjs.org/@typescript/typescript-linux-riscv64/-/typescript-linux-riscv64-7.0.2.tgz","integrity":"sha512-wf0jqEDOjrPRnKwYRyyJDRo11KMbvMFrU+q4zqKyChODBzvlkbhNQfKvLxQCcwTpdDaXSHZTVuh0JoCrKCUMHQ==","cpu":["riscv64"],"dev":true,"license":"Apache-2.0","optional":true,"os":["linux"],"engines":{"node":">=16.20.0"}},
  "node_modules/@typescript/typescript-linux-s390x": {"version":"7.0.2","resolved":"https://registry.npmjs.org/@typescript/typescript-linux-s390x/-/typescript-linux-s390x-7.0.2.tgz","integrity":"sha512-IkwJc3L7yhytWd/ewjyxNDfOmswCm9GWMJT/ue/dU4aZNbwZeYAetq42VyLmsmSjvoX7z74X6ZaYCtzAr0EuGw==","cpu":["s390x"],"dev":true,"license":"Apache-2.0","optional":true,"os":["linux"],"engines":{"node":">=16.20.0"}},
  "node_modules/@typescript/typescript-linux-x64": {"version":"7.0.2","resolved":"https://registry.npmjs.org/@typescript/typescript-linux-x64/-/typescript-linux-x64-7.0.2.tgz","integrity":"sha512-EYdf2cNg7rgCWJnxCdJ+F3V39O8ihb37eHAu1LK8oAFizgTQbPOK7zHHXbPt8rX24COqODXeI3sIf0fCXG7H/A==","cpu":["x64"],"dev":true,"license":"Apache-2.0","optional":true,"os":["linux"],"engines":{"node":">=16.20.0"}},
  "node_modules/@typescript/typescript-netbsd-arm64": {"version":"7.0.2","resolved":"https://registry.npmjs.org/@typescript/typescript-netbsd-arm64/-/typescript-netbsd-arm64-7.0.2.tgz","integrity":"sha512-+polYF4MF04aPpO5FTkHran9yUQDSXqy5GiSDKpsll5jy3l3+g9QLhpf39T+ePtefhXLOGrLl0QIjkQP6VnelA==","cpu":["arm64"],"dev":true,"license":"Apache-2.0","optional":true,"os":["netbsd"],"engines":{"node":">=16.20.0"}},
  "node_modules/@typescript/typescript-netbsd-x64": {"version":"7.0.2","resolved":"https://registry.npmjs.org/@typescript/typescript-netbsd-x64/-/typescript-netbsd-x64-7.0.2.tgz","integrity":"sha512-8YIT0EHM/3dq10ZOVF/A7pc/YSMtbcecct4rWtexrnSCHOPcpC2KTLXfTCR6vDpnSiY12heNb1GiN/wu+T/FyA==","cpu":["x64"],"dev":true,"license":"Apache-2.0","optional":true,"os":["netbsd"],"engines":{"node":">=16.20.0"}},
  "node_modules/@typescript/typescript-openbsd-arm64": {"version":"7.0.2","resolved":"https://registry.npmjs.org/@typescript/typescript-openbsd-arm64/-/typescript-openbsd-arm64-7.0.2.tgz","integrity":"sha512-APT8+ClYnuYm1u9+kgGXoMj2VzWzcymwh2gNSQVySHfkRDGOTVkoWLjCmOQSaO+PoqQ57B0flRp9SA+7GnnkzQ==","cpu":["arm64"],"dev":true,"license":"Apache-2.0","optional":true,"os":["openbsd"],"engines":{"node":">=16.20.0"}},
  "node_modules/@typescript/typescript-openbsd-x64": {"version":"7.0.2","resolved":"https://registry.npmjs.org/@typescript/typescript-openbsd-x64/-/typescript-openbsd-x64-7.0.2.tgz","integrity":"sha512-yX7s+Q0Dln0Dt9tEzZsAjXXR/+ytBM7AlglaqyeMPxQszJ1JhlJdZ6jLA+IzldHtflX81em7lDao1xXu+aRRkg==","cpu":["x64"],"dev":true,"license":"Apache-2.0","optional":true,"os":["openbsd"],"engines":{"node":">=16.20.0"}},
  "node_modules/@typescript/typescript-sunos-x64": {"version":"7.0.2","resolved":"https://registry.npmjs.org/@typescript/typescript-sunos-x64/-/typescript-sunos-x64-7.0.2.tgz","integrity":"sha512-dLJDGaLZ1D4HPQn62u1n8mBDkJREwMsAkCdkwd4Ieqw+x3TUyTsqY0YiBCtE6H6OzzgGk3iuZ3vFWRS+E8/d1g==","cpu":["x64"],"dev":true,"license":"Apache-2.0","optional":true,"os":["sunos"],"engines":{"node":">=16.20.0"}},
  "node_modules/@typescript/typescript-win32-arm64": {"version":"7.0.2","resolved":"https://registry.npmjs.org/@typescript/typescript-win32-arm64/-/typescript-win32-arm64-7.0.2.tgz","integrity":"sha512-Gyl1Vy6OsWesLzmq+EP0Fb7b4Nid5232AvcA2SFcdYreldpNtYFFofPjnt62y9hQy7VTaZp65ICJjuAQRaVcIQ==","cpu":["arm64"],"dev":true,"license":"Apache-2.0","optional":true,"os":["win32"],"engines":{"node":">=16.20.0"}},
  "node_modules/@typescript/typescript-win32-x64": {"version":"7.0.2","resolved":"https://registry.npmjs.org/@typescript/typescript-win32-x64/-/typescript-win32-x64-7.0.2.tgz","integrity":"sha512-0BQ3HkAHHlKLSp1qRvf3SUhGpGsDuhB/jgFw75guyqbxJqEaS0Cw/VFO8i2nHglJUzQCRtMMR/IBAKE3ETMC4g==","cpu":["x64"],"dev":true,"license":"Apache-2.0","optional":true,"os":["win32"],"engines":{"node":">=16.20.0"}},
  "node_modules/@vitejs/plugin-react": {"version":"6.1.2","resolved":"https://registry.npmjs.org/@vitejs/plugin-react/-/plugin-react-6.1.2.tgz","integrity":"sha512-fhJNGUdscQa4HkI0xFxwonWyhnVReCPDbXI7FH7jmzpnVCrFQI7PRrhWecO263610vOrs9tr2Y4xcf8uAdFxbw==","dev":true,"license":"MIT","dependencies":{"@rolldown/pluginutils":"^1.0.1"},"engines":{"node":"^20.19.0 || >=22.12.0"},"peerDependencies":{"@rolldown/plugin-babel":"^0.1.7 || ^0.2.0","babel-plugin-react-compiler":"^1.0.0","oxc-transform-react":"^0.152.0","vite":"^8.0.0"},"peerDependenciesMeta":{"@rolldown/plugin-babel":{"optional":true},"babel-plugin-react-compiler":{"optional":true},"oxc-transform-react":{"optional":true}}},
  "node_modules/csstype": {"version":"3.2.3","resolved":"https://registry.npmjs.org/csstype/-/csstype-3.2.3.tgz","integrity":"sha512-z1HGKcYy2xA8AGQfwrn0PAy+PB7X/GSj3UVJW9qKyn43xWa+gl5nXmU4qqLMRzWVLFC8KusUX8T/0kCiOYpAIQ==","dev":true,"license":"MIT"},
  "node_modules/detect-libc": {"version":"2.1.2","resolved":"https://registry.npmjs.org/detect-libc/-/detect-libc-2.1.2.tgz","integrity":"sha512-Btj2BOOO83o3WyH59e8MgXsxEQVcarkUOpEYrubB0urwnN10yQ364rsiByU11nZlqWYZm05i/of7io4mzihBtQ==","dev":true,"license":"Apache-2.0","engines":{"node":">=8"}},
  "node_modules/fdir": {"version":"6.5.0","resolved":"https://registry.npmjs.org/fdir/-/fdir-6.5.0.tgz","integrity":"sha512-tIbYtZbucOs0BRGqPJkshJUYdL+SDH7dVM8gjy+ERp3WAUjLEFJE+02kanyHtwjWOnwrKYBiwAmM0p4kLJAnXg==","dev":true,"license":"MIT","engines":{"node":">=12.0.0"},"peerDependencies":{"picomatch":"^3 || ^4"},"peerDependenciesMeta":{"picomatch":{"optional":true}}},
  "node_modules/fsevents": {"version":"2.3.3","resolved":"https://registry.npmjs.org/fsevents/-/fsevents-2.3.3.tgz","integrity":"sha512-5xoDfX+fL7faATnagmWPpbFtwh/R77WmMMqqHGS65C3vvB0YHrgF+B1YmZ3441tMj5n63k0212XNoJwzlhffQw==","dev":true,"hasInstallScript":true,"license":"MIT","optional":true,"os":["darwin"],"engines":{"node":"^8.16.0 || ^10.6.0 || >=11.0.0"}},
  "node_modules/lightningcss": {"version":"1.33.0","resolved":"https://registry.npmjs.org/lightningcss/-/lightningcss-1.33.0.tgz","integrity":"sha512-WkUDrojuJs0xkgGf2udWxa3yGBRxPtxUkB79i6aCZLRgc7PM8fZe9TosfPDcvEpQZbuFASnHYmRLBLUbmLOIIA==","dev":true,"license":"MPL-2.0","dependencies":{"detect-libc":"^2.0.3"},"engines":{"node":">= 12.0.0"},"funding":{"type":"opencollective","url":"https://opencollective.com/parcel"},"optionalDependencies":{"lightningcss-android-arm64":"1.33.0","lightningcss-darwin-arm64":"1.33.0","lightningcss-darwin-x64":"1.33.0","lightningcss-freebsd-x64":"1.33.0","lightningcss-linux-arm-gnueabihf":"1.33.0","lightningcss-linux-arm64-gnu":"1.33.0","lightningcss-linux-arm64-musl":"1.33.0","lightningcss-linux-x64-gnu":"1.33.0","lightningcss-linux-x64-musl":"1.33.0","lightningcss-win32-arm64-msvc":"1.33.0","lightningcss-win32-x64-msvc":"1.33.0"}},
  "node_modules/lightningcss-android-arm64": {"version":"1.33.0","resolved":"https://registry.npmjs.org/lightningcss-android-arm64/-/lightningcss-android-arm64-1.33.0.tgz","integrity":"sha512-gEpRTalKdosp4Bb8qWtc2iOgE5SeIHlpS1up9bFq2wAyYhl1UdTObYiHe98zEM9SQvSoqQZ1IQD0JNpg3Ml5pg==","cpu":["arm64"],"dev":true,"license":"MPL-2.0","optional":true,"os":["android"],"engines":{"node":">= 12.0.0"},"funding":{"type":"opencollective","url":"https://opencollective.com/parcel"}},
  "node_modules/lightningcss-darwin-arm64": {"version":"1.33.0","resolved":"https://registry.npmjs.org/lightningcss-darwin-arm64/-/lightningcss-darwin-arm64-1.33.0.tgz","integrity":"sha512-Sciaz8eenNTKn9b3t7+xr0ipTp9YxKQY4npwQ3mrRuL0BAVHBLyZxofhaKBAVtzmtRZ/zTyo0/to4B1uWG/Djg==","cpu":["arm64"],"dev":true,"license":"MPL-2.0","optional":true,"os":["darwin"],"engines":{"node":">= 12.0.0"},"funding":{"type":"opencollective","url":"https://opencollective.com/parcel"}},
  "node_modules/lightningcss-darwin-x64": {"version":"1.33.0","resolved":"https://registry.npmjs.org/lightningcss-darwin-x64/-/lightningcss-darwin-x64-1.33.0.tgz","integrity":"sha512-Z5UPAxzrjlWNNyGy6i65cJzzvgJ5D3T6wMvs+gWpY9d7qRhANrxqAp6LhxIgZhWEw18RfJTGcRxjuLIBr+m8XQ==","cpu":["x64"],"dev":true,"license":"MPL-2.0","optional":true,"os":["darwin"],"engines":{"node":">= 12.0.0"},"funding":{"type":"opencollective","url":"https://opencollective.com/parcel"}},
  "node_modules/lightningcss-freebsd-x64": {"version":"1.33.0","resolved":"https://registry.npmjs.org/lightningcss-freebsd-x64/-/lightningcss-freebsd-x64-1.33.0.tgz","integrity":"sha512-QQM/Ti/hQajJwCY+RiWuCZ9sdtI/XQk7nDK5vC8kkdwixezOlDgvDx7+RT+QjK6FcFT4MpsuoBnHIo/O3StRRg==","cpu":["x64"],"dev":true,"license":"MPL-2.0","optional":true,"os":["freebsd"],"engines":{"node":">= 12.0.0"},"funding":{"type":"opencollective","url":"https://opencollective.com/parcel"}},
  "node_modules/lightningcss-linux-arm-gnueabihf": {"version":"1.33.0","resolved":"https://registry.npmjs.org/lightningcss-linux-arm-gnueabihf/-/lightningcss-linux-arm-gnueabihf-1.33.0.tgz","integrity":"sha512-N7FVBe6iS24MlM6R/4RBTxGhQheZGs7tiQ9U32UtF75NzP5Q7xWPRqLBCKxlRQRk3rY1jCIPLzx7WzOhuUIRLQ==","cpu":["arm"],"dev":true,"license":"MPL-2.0","optional":true,"os":["linux"],"engines":{"node":">= 12.0.0"},"funding":{"type":"opencollective","url":"https://opencollective.com/parcel"}},
  "node_modules/lightningcss-linux-arm64-gnu": {"version":"1.33.0","resolved":"https://registry.npmjs.org/lightningcss-linux-arm64-gnu/-/lightningcss-linux-arm64-gnu-1.33.0.tgz","integrity":"sha512-j2v/itmy4HlNxlc6voKXYgBqNi0Ng2LShg4z7GufpEgs05P+2suBVyi9I6YHq5uoVFx9ETin3eCEhLVyXGQnKg==","cpu":["arm64"],"dev":true,"libc":["glibc"],"license":"MPL-2.0","optional":true,"os":["linux"],"engines":{"node":">= 12.0.0"},"funding":{"type":"opencollective","url":"https://opencollective.com/parcel"}},
  "node_modules/lightningcss-linux-arm64-musl": {"version":"1.33.0","resolved":"https://registry.npmjs.org/lightningcss-linux-arm64-musl/-/lightningcss-linux-arm64-musl-1.33.0.tgz","integrity":"sha512-yiO5ROMuYQgXbC60yjZU5CYSFZGKXL0HFATXt9mHJn1+zW55oCtMI9NfcVhYLMFDL7gV7oBPon/EmMMGg2OvtQ==","cpu":["arm64"],"dev":true,"libc":["musl"],"license":"MPL-2.0","optional":true,"os":["linux"],"engines":{"node":">= 12.0.0"},"funding":{"type":"opencollective","url":"https://opencollective.com/parcel"}},
  "node_modules/lightningcss-linux-x64-gnu": {"version":"1.33.0","resolved":"https://registry.npmjs.org/lightningcss-linux-x64-gnu/-/lightningcss-linux-x64-gnu-1.33.0.tgz","integrity":"sha512-ar+Ju7LmcN0Jo4FpL4hpFybwNG9/3A/Br5KW2n2jyODg3MEZXaDYADdemoNS+BDNfMgKvylJLj4S5tyRActuAg==","cpu":["x64"],"dev":true,"libc":["glibc"],"license":"MPL-2.0","optional":true,"os":["linux"],"engines":{"node":">= 12.0.0"},"funding":{"type":"opencollective","url":"https://opencollective.com/parcel"}},
  "node_modules/lightningcss-linux-x64-musl": {"version":"1.33.0","resolved":"https://registry.npmjs.org/lightningcss-linux-x64-musl/-/lightningcss-linux-x64-musl-1.33.0.tgz","integrity":"sha512-RYiYbkokw0trfKqqzfF55lginwEPrD3OJDfTuJzFs1MK6iFnDenaz1fqLLtX4ITG3OktJQXOeTaw1awrBAlZPw==","cpu":["x64"],"dev":true,"libc":["musl"],"license":"MPL-2.0","optional":true,"os":["linux"],"engines":{"node":">= 12.0.0"},"funding":{"type":"opencollective","url":"https://opencollective.com/parcel"}},
  "node_modules/lightningcss-win32-arm64-msvc": {"version":"1.33.0","resolved":"https://registry.npmjs.org/lightningcss-win32-arm64-msvc/-/lightningcss-win32-arm64-msvc-1.33.0.tgz","integrity":"sha512-1K+MPfLSFVpphzpdbfkhlWk6wBrTObBzS2T6db10PNOZgR9GoVsAWzwNyuhUYYbTp23j+4RrncfujZ4uAzXvwA==","cpu":["arm64"],"dev":true,"license":"MPL-2.0","optional":true,"os":["win32"],"engines":{"node":">= 12.0.0"},"funding":{"type":"opencollective","url":"https://opencollective.com/parcel"}},
  "node_modules/lightningcss-win32-x64-msvc": {"version":"1.33.0","resolved":"https://registry.npmjs.org/lightningcss-win32-x64-msvc/-/lightningcss-win32-x64-msvc-1.33.0.tgz","integrity":"sha512-OlEICDx/Xl0FqSp4bry8zFnCvGpig3Gl4gCquvYwHuqJKEC1+n9NgDniFvqHGmMv1ZkqDJrDqKKSykTDX+ehuA==","cpu":["x64"],"dev":true,"license":"MPL-2.0","optional":true,"os":["win32"],"engines":{"node":">= 12.0.0"},"funding":{"type":"opencollective","url":"https://opencollective.com/parcel"}},
  "node_modules/nanoid": {"version":"3.3.20","resolved":"https://registry.npmjs.org/nanoid/-/nanoid-3.3.20.tgz","integrity":"sha512-uKdg2G3GNCKQn9byYOpxbGqrT2fGO5KRt5J/8b3pok8rT6qxGWF6hxMyJiEYtAf+FVyYuD9hRaDqX5uPFYJ4ZQ==","dev":true,"funding":[{"type":"github","url":"https://github.com/sponsors/ai"}],"license":"MIT","bin":{"nanoid":"bin/nanoid.cjs"},"engines":{"node":"^10 || ^12 || ^13.7 || ^14 || >=15.0.1"}},
  "node_modules/picocolors": {"version":"1.1.1","resolved":"https://registry.npmjs.org/picocolors/-/picocolors-1.1.1.tgz","integrity":"sha512-xceH2snhtb5M9liqDsmEw56le376mTZkEX/jEb/RxNFyegNul7eNslCXP9FDj/Lcu0X8KEyMceP2ntpaHrDEVA==","dev":true,"license":"ISC"},
  "node_modules/picomatch": {"version":"4.0.7","resolved":"https://registry.npmjs.org/picomatch/-/picomatch-4.0.7.tgz","integrity":"sha512-qcJu88Q2IWqJsDD529JKMdwGm/dvInW4HvQnRwiH9JtihJvzGOscDtHE3x1pBKeUOTysQ8kVmLnJ2kJu7yhcGA==","dev":true,"license":"MIT","engines":{"node":">=12"},"funding":{"url":"https://github.com/sponsors/jonschlinkert"}},
  "node_modules/postcss": {"version":"8.5.29","resolved":"https://registry.npmjs.org/postcss/-/postcss-8.5.29.tgz","integrity":"sha512-49cGhUbXj8Qenv0iTMxA1cFBzxXoctpC9Ujd77t1WcbJIr6nF/eI7g/8MgxrYldFRuAXvja7xQRwavoW7kgrxQ==","dev":true,"funding":[{"type":"opencollective","url":"https://opencollective.com/postcss/"},{"type":"tidelift","url":"https://tidelift.com/funding/github/npm/postcss"},{"type":"github","url":"https://github.com/sponsors/ai"}],"license":"MIT","dependencies":{"nanoid":"^3.3.19","picocolors":"^1.1.1","source-map-js":"^1.2.2"},"engines":{"node":"^10 || ^12 || >=14"}},
  "node_modules/react": {"version":"19.3.0","resolved":"https://registry.npmjs.org/react/-/react-19.3.0.tgz","integrity":"sha512-E8LUcbtBWt20bbl2YoHfx4ZDBdxVTfOKtCZn9cDSJ4l6/nuoApcpIBcj47t2wZoVX8g2ZHuMHbiShgCR1T5Sog==","license":"MIT","engines":{"node":">=0.10.0"}},
  "node_modules/react-dom": {"version":"19.3.0","resolved":"https://registry.npmjs.org/react-dom/-/react-dom-19.3.0.tgz","integrity":"sha512-JDk8dgif51OjFoDE70+OT9ICyYr+69HlmihNwp1+Nsfbna3t5sIiCa9ZJktDmQ4/1b/rn26hIAR2uYXDMr5r0Q==","license":"MIT","dependencies":{"scheduler":"^0.28.0"},"peerDependencies":{"react":"^19.3.0"}},
  "node_modules/rolldown": {"version":"1.2.13","resolved":"https://registry.npmjs.org/rolldown/-/rolldown-1.2.13.tgz","integrity":"sha512-/5apOkwWxtACcQtZ5WlrAsKS4JwXVThQPJZ3RqIruRY9UG9M8e0VlXN068xum/JRKA4aIUoJ13ghe/kGCvidiQ==","dev":true,"license":"MIT","dependencies":{"@oxc-project/types":"=0.153.0","@rolldown/pluginutils":"^1.0.0"},"bin":{"rolldown":"bin/cli.mjs"},"engines":{"node":"^20.19.0 || >=22.12.0"},"optionalDependencies":{"@rolldown/binding-android-arm-eabi":"1.2.13","@rolldown/binding-android-arm64":"1.2.13","@rolldown/binding-darwin-arm64":"1.2.13","@rolldown/binding-darwin-x64":"1.2.13","@rolldown/binding-freebsd-x64":"1.2.13","@rolldown/binding-linux-arm-gnueabihf":"1.2.13","@rolldown/binding-linux-arm64-gnu":"1.2.13","@rolldown/binding-linux-arm64-musl":"1.2.13","@rolldown/binding-linux-ppc64-gnu":"1.2.13","@rolldown/binding-linux-s390x-gnu":"1.2.13","@rolldown/binding-linux-x64-gnu":"1.2.13","@rolldown/binding-linux-x64-musl":"1.2.13","@rolldown/binding-openharmony-arm64":"1.2.13","@rolldown/binding-win32-arm64-msvc":"1.2.13","@rolldown/binding-win32-x64-msvc":"1.2.13"}},
  "node_modules/scheduler": {"version":"0.28.0","resolved":"https://registry.npmjs.org/scheduler/-/scheduler-0.28.0.tgz","integrity":"sha512-juorfCmIkIw8tT+p5BXSm6PJjQF/ycEYmKyzURCIt/RaZIhL+PulbQ9Yu2z1HdOJDdqDTlxA1+xKBmHXJsczAw==","license":"MIT"},
  "node_modules/source-map-js": {"version":"1.2.2","resolved":"https://registry.npmjs.org/source-map-js/-/source-map-js-1.2.2.tgz","integrity":"sha512-KGj/8Y43x35aZVDtt+J4mK1hoLGHULMYfSkODJNQjNDC3oW1PqPoxMwo0pLUsWM/UEGzON/NxeHywEfNXNP3Vw==","dev":true,"license":"BSD-3-Clause","engines":{"node":">=0.10.0"}},
  "node_modules/tinyglobby": {"version":"0.2.17","resolved":"https://registry.npmjs.org/tinyglobby/-/tinyglobby-0.2.17.tgz","integrity":"sha512-wXR/dYpcqKmfWpEdZjiKJOwCNFndD0DMnrW/cYjVGttEkBfVgcLFHoNrlj47mjOVic9yyNu65alsgF4NQyTa2g==","dev":true,"license":"MIT","dependencies":{"fdir":"^6.5.0","picomatch":"^4.0.4"},"engines":{"node":">=12.0.0"},"funding":{"url":"https://github.com/sponsors/SuperchupuDev"}},
  "node_modules/typescript": {"version":"7.0.2","resolved":"https://registry.npmjs.org/typescript/-/typescript-7.0.2.tgz","integrity":"sha512-8FYau96o3NKOhbjKi/qNvG/W5jhzxkbdm5sj9AbZ/5T5sWqn3hJgLfGx27sRKZWTvyzCP8dLRBTf5tBTSRVUNA==","dev":true,"license":"Apache-2.0","bin":{"tsc":"bin/tsc"},"engines":{"node":">=16.20.0"},"optionalDependencies":{"@typescript/typescript-aix-ppc64":"7.0.2","@typescript/typescript-darwin-arm64":"7.0.2","@typescript/typescript-darwin-x64":"7.0.2","@typescript/typescript-freebsd-arm64":"7.0.2","@typescript/typescript-freebsd-x64":"7.0.2","@typescript/typescript-linux-arm":"7.0.2","@typescript/typescript-linux-arm64":"7.0.2","@typescript/typescript-linux-loong64":"7.0.2","@typescript/typescript-linux-mips64el":"7.0.2","@typescript/typescript-linux-ppc64":"7.0.2","@typescript/typescript-linux-riscv64":"7.0.2","@typescript/typescript-linux-s390x":"7.0.2","@typescript/typescript-linux-x64":"7.0.2","@typescript/typescript-netbsd-arm64":"7.0.2","@typescript/typescript-netbsd-x64":"7.0.2","@typescript/typescript-openbsd-arm64":"7.0.2","@typescript/typescript-openbsd-x64":"7.0.2","@typescript/typescript-sunos-x64":"7.0.2","@typescript/typescript-win32-arm64":"7.0.2","@typescript/typescript-win32-x64":"7.0.2"}},
  "node_modules/vite": {"version":"8.3.4","resolved":"https://registry.npmjs.org/vite/-/vite-8.3.4.tgz","integrity":"sha512-IftLE8phJhdNRIGNEV4JCCvfNScoZQVfcXaN8TQropWGJtOHcu+iAB9pHcuGvmEb/kddw0LBe/jS8ztdC6xdiQ==","dev":true,"license":"MIT","dependencies":{"lightningcss":"^1.33.0","picomatch":"^4.0.7","postcss":"^8.5.29","rolldown":"~1.2.12","tinyglobby":"^0.2.17"},"bin":{"vite":"bin/vite.js"},"engines":{"node":"^20.19.0 || >=22.12.0"},"funding":{"url":"https://github.com/vitejs/vite?sponsor=1"},"optionalDependencies":{"fsevents":"~2.3.3"},"peerDependencies":{"@types/node":"^20.19.0 || >=22.12.0","@vitejs/devtools":"^0.7.1","esbuild":"^0.27.0 || ^0.28.0","jiti":">=1.21.0","less":"^4.0.0","sass":"^1.70.0","sass-embedded":"^1.70.0","stylus":">=0.54.8","sugarss":"^5.0.0","terser":"^5.16.0","tsx":"^4.8.1","yaml":"^2.4.2"},"peerDependenciesMeta":{"@types/node":{"optional":true},"@vitejs/devtools":{"optional":true},"esbuild":{"optional":true},"jiti":{"optional":true},"less":{"optional":true},"sass":{"optional":true},"sass-embedded":{"optional":true},"stylus":{"optional":true},"sugarss":{"optional":true},"terser":{"optional":true},"tsx":{"optional":true},"yaml":{"optional":true}}}
  }
  """

  @lock_packages Jason.decode!(@lock_packages_json)

  @doc """
  Create a new component scaffold.

  ## Parameters

  - `ctx` - Sanctum context
  - `name` - Component name (lowercase alphanumeric + hyphens)
  - `type` - Component type: "reagent", "catalyst", "formula" or "tincture"
  - `version` - Semver version string (e.g. "0.1.0")
  - `opts` - `template:` names a tincture's template
    (`Compendium.tincture_templates/0`); the vanilla one when absent

  ## Returns

  - `{:ok, result}` with status, reference, and list of created files
  - `{:error, reason}` on validation failure or write error
  """
  @spec create(Context.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def create(%Context{} = ctx, name, type, version, opts \\ []) do
    with :ok <- validate_name(name),
         :ok <- validate_type(type),
         :ok <- validate_version(version),
         {:ok, template} <- validate_template(type, Keyword.get(opts, :template)),
         :ok <- check_not_exists(ctx, name, type, version) do
      type_atom = String.to_existing_atom(type)
      base_path = component_base_path(name, type, version)

      files =
        case {type, template} do
          {"tincture", %{name: "react"} = template} ->
            react_tincture_files(base_path, name, version, template)

          {"tincture", %{name: "vite"} = template} ->
            vite_tincture_files(base_path, name, version, template)

          {"tincture", template} ->
            [
              {base_path ++ [Compendium.ComponentPath.manifest_name()],
               tincture_manifest_for(name, version, template)},
              {base_path ++ ["index.html"], tincture_index_html(name)},
              {base_path ++ ["app.js"], tincture_app_js()},
              {base_path ++ ["style.css"], tincture_style_css()},
              {base_path ++ Compendium.Tincture.default_icon(), placeholder_icon_svg()},
              {base_path ++ Compendium.Tincture.default_preview(), placeholder_preview_svg()}
            ]

          _ ->
            [
              {base_path ++ [Compendium.ComponentPath.manifest_name()],
               manifest_for(name, type, version)},
              {base_path ++ ["src", "Cargo.toml"], Prima.CargoToml.template(type_atom)},
              {base_path ++ ["src", "src", "lib.rs"], lib_rs_for(type_atom)}
            ] ++ wit_files(base_path, type_atom)
        end

      rel_files =
        Enum.map(files, fn {path, content} -> {Enum.drop(path, length(base_path)), content} end)

      # Scaffolds are exempt from Sanctum.Tenancy.Caps.
      case Arca.Overlay.commit_unit(Sanctum.Context.actor(ctx), base_path, {:files, rel_files},
             cap: :exempt
           ) do
        {:ok, written} ->
          reference = local_ref(type, name, version)
          # In write order — the manifest (the unit's completion sentinel)
          # is last, and the list is the witness.
          file_list = Enum.map(written, &Path.join(base_path ++ &1))

          {:ok,
           %{
             status: "created",
             reference: reference,
             files: file_list,
             next_steps: next_steps(type, reference, template && template.name)
           }}

        # A commit's typed refusals are the vocabulary the surfaces
        # render — another writer holding the unit is not a broken store
        # — so they are answered as themselves; anything else is a
        # storage term, said in words.
        {:error, reason} = refusal ->
          if Prima.Refusal.reason?(reason),
            do: refusal,
            else: {:error, "Failed to write scaffold files: #{Refusals.render(reason)}"}
      end
    end
  end

  # ============================================================================
  # Validation
  # ============================================================================

  defp validate_name(name) when is_binary(name) do
    # The component name grammar lives in one place; a scaffold that accepted
    # a name registration refuses would strand the user one step later.
    case Prima.ComponentRef.validate_name(name) do
      :ok -> :ok
      {:error, reason} -> {:error, "Invalid component name: '#{name}'. #{reason}"}
    end
  end

  defp validate_name(_), do: {:error, "Missing required argument: name"}

  defp validate_type(nil), do: {:error, "Missing required argument: type"}

  defp validate_type(type) when is_binary(type) do
    if type in Prima.ComponentRef.valid_types() do
      :ok
    else
      {:error,
       "Invalid component type: '#{type}'. Must be: reagent, catalyst, formula, or tincture"}
    end
  end

  defp validate_type(type),
    do:
      {:error,
       "Invalid component type: '#{type}'. Must be: reagent, catalyst, formula, or tincture"}

  # Use the shared component version grammar.
  defp validate_version(version) when is_binary(version) do
    case Prima.ComponentRef.validate_version(version) do
      :ok -> :ok
      {:error, _} -> {:error, "Invalid version: '#{version}'. Must be valid semver (e.g. 0.1.0)"}
    end
  end

  defp validate_version(_), do: {:error, "Missing required argument: version"}

  # A tincture starts from one of the frame's templates
  # (`Compendium.tincture_templates/0`), vanilla when none is named; the
  # other component types take none.
  @default_template "vanilla"

  defp validate_template("tincture", name) do
    templates = Compendium.tincture_templates()

    case Enum.find(templates, &(&1.name == (name || @default_template))) do
      nil ->
        {:error,
         "Unknown template: '#{name}'. A tincture starts from one of: " <>
           Enum.map_join(templates, ", ", & &1.name)}

      template ->
        {:ok, template}
    end
  end

  defp validate_template(_type, _name), do: {:ok, nil}

  # A version the server ships is never scaffolded over, held by the
  # athanor or not: the seed is the default for that name and version. A
  # seed-catalog outage refuses loudly rather than falling through to the
  # generic "already exists" and sending someone deleting what a release
  # ships.
  defp check_not_exists(ctx, name, type, version) do
    path =
      component_base_path(name, type, version) ++ [Compendium.ComponentPath.manifest_name()]

    case Compendium.Provenance.shipped_versions(type, name) do
      {:ok, shipped} ->
        cond do
          version in shipped ->
            {:error,
             "#{local_ref(type, name, version)} is bundled with the server — edit your copy " <>
               "in place, or scaffold a new version or name"}

          Arca.exists?(Sanctum.Context.actor(ctx), path) ->
            {:error, "Component already exists: #{local_ref(type, name, version)}"}

          true ->
            :ok
        end

      {:error, reason} ->
        {:error, "Cannot scaffold right now — seed media unreadable: #{Refusals.render(reason)}"}
    end
  end

  # ============================================================================
  # Path Helpers
  # ============================================================================

  # The one spelling of a local reference — never hand-interpolated.
  defp local_ref(type, name, version) do
    Prima.ComponentRef.to_string(%Prima.ComponentRef{
      type: type,
      namespace: Compendium.ComponentPath.default_publisher(),
      name: name,
      version: version
    })
  end

  defp component_base_path(name, type, version) do
    Compendium.ComponentPath.version_dir(
      type,
      Compendium.ComponentPath.default_publisher(),
      name,
      version
    )
  end

  # ============================================================================
  # Templates
  # ============================================================================

  defp manifest_for(name, "catalyst", version) do
    safe_encode_pretty(%{
      name: name,
      type: "catalyst",
      version: version,
      publisher: Compendium.ComponentPath.default_publisher(),
      description: "TODO: Describe your catalyst",
      caps: %{
        egress: %{
          domains: [],
          methods: ["GET", "POST"]
        },
        limits: %{timeout: "30s"}
      },
      dependencies: %{
        static: []
      }
    })
  end

  defp manifest_for(name, "formula", version) do
    safe_encode_pretty(%{
      name: name,
      type: "formula",
      version: version,
      publisher: Compendium.ComponentPath.default_publisher(),
      description: "TODO: Describe your formula",
      caps: %{
        tools: [],
        limits: %{timeout: "5m"}
      },
      dependencies: %{
        static: []
      }
    })
  end

  defp manifest_for(name, "reagent", version) do
    safe_encode_pretty(%{
      name: name,
      type: "reagent",
      version: version,
      publisher: Compendium.ComponentPath.default_publisher(),
      description: "TODO: Describe your reagent",
      dependencies: %{
        static: []
      }
    })
  end

  # The template names the entry and, for a built tincture, the build tool.
  defp tincture_manifest_for(name, version, template) do
    tincture =
      %{entry: template.entry, icon: "palette"}
      |> then(&if template.build, do: Map.put(&1, :build, %{tool: template.build}), else: &1)

    safe_encode_pretty(%{
      name: name,
      type: "tincture",
      version: version,
      publisher: Compendium.ComponentPath.default_publisher(),
      description: "TODO: Describe your tincture",
      tincture: tincture,
      dependencies: %{
        static: []
      }
    })
  end

  defp safe_encode_pretty(data) do
    case Jason.encode(data, pretty: true) do
      {:ok, json} -> json
      {:error, _} -> "{}"
    end
  end

  defp lib_rs_for(:reagent) do
    """
    #[allow(warnings)]
    mod bindings;

    use bindings::exports::cyfr::reagent::compute::Guest;

    struct Component;
    bindings::export!(Component with_types_in bindings);

    impl Guest for Component {
        fn compute(input: String) -> String {
            let data: serde_json::Value = match serde_json::from_str(&input) {
                Ok(v) => v,
                Err(e) => return serde_json::json!({"error": e.to_string()}).to_string(),
            };
            // Pure computation here
            serde_json::to_string(&data).unwrap_or_else(|e|
                serde_json::json!({"error": e.to_string()}).to_string()
            )
        }
    }
    """
  end

  defp lib_rs_for(:catalyst) do
    """
    #[allow(warnings)]
    mod bindings;

    use bindings::exports::cyfr::catalyst::run::Guest;

    struct Component;
    bindings::export!(Component with_types_in bindings);

    impl Guest for Component {
        fn run(input: String) -> String {
            let request: serde_json::Value = match serde_json::from_str(&input) {
                Ok(v) => v,
                Err(e) => return serde_json::json!({"error": e.to_string()}).to_string(),
            };
            // For an authenticated API, declare a need with type api_key:<provider>,
            // fields, hosts and attach in cyfr-manifest.json, plus matching caps.egress.
            // Name the need as "connection" on cyfr:http/fetch requests.
            // CYFR attaches the credential in the control plane; never read or set it here.
            // TODO: Implement catalyst logic
            serde_json::json!({"error": "not implemented"}).to_string()
        }
    }
    """
  end

  defp lib_rs_for(:formula) do
    """
    #[allow(warnings)]
    mod bindings;

    use bindings::exports::cyfr::formula::run::Guest;
    use bindings::cyfr::formula::invoke;
    use serde_json::{json, Value};

    struct Component;
    bindings::export!(Component with_types_in bindings);

    impl Guest for Component {
        fn run(input: String) -> String {
            match handle_request(&input) {
                Ok(output) => output,
                Err(e) => json!({"error": e}).to_string(),
            }
        }
    }

    fn handle_request(input: &str) -> Result<String, String> {
        let parsed: Value = serde_json::from_str(input)
            .map_err(|e| format!("Invalid JSON: {e}"))?;
        // TODO: Implement formula logic using invoke::call
        Ok(json!({"error": "not implemented"}).to_string())
    }
    """
  end

  # ============================================================================
  # WIT Files
  # ============================================================================

  # The embedded WIT tree (`Prima.WIT` — the one source the
  # Locus build sandbox consumes too), mapped into the scaffold's layout.
  defp wit_files(base_path, type_atom) do
    type_atom
    |> Prima.WIT.files()
    |> Enum.map(fn {rel_segments, content} ->
      {base_path ++ ["src", "wit" | rel_segments], content}
    end)
  end

  # ============================================================================
  # Next Steps
  # ============================================================================

  defp next_steps("catalyst", reference, _template) do
    [
      "Declare the needs and caps blocks in #{Compendium.ComponentPath.manifest_name()} " <>
        "through Files — the console's Files page or the files tool; a chain's source tool " <>
        "reads the manifest but never changes it (storage grants default to none; 'data/' " <>
        "is the component-private scope — grant 'components/' only when the component " <>
        "genuinely manages component trees)",
      "For an authenticated API, declare a need with type api_key:<provider>, fields, " <>
        "hosts and attach, plus matching caps.egress; name that need as connection on " <>
        "cyfr:http/fetch requests. CYFR attaches the credential in the control plane " <>
        "without handing it to the component",
      "Edit src/src/lib.rs to implement your catalyst logic",
      "Compile: use build.compile with reference '#{reference}'",
      "Register: use component.register to index the compiled binary"
    ]
  end

  defp next_steps("formula", reference, _template) do
    [
      "Declare the needs and caps blocks in #{Compendium.ComponentPath.manifest_name()} " <>
        "through Files — the console's Files page or the files tool; a chain's source tool " <>
        "reads the manifest but never changes it (storage grants default to none; 'data/' " <>
        "is the component-private scope — grant 'components/' only when the component " <>
        "genuinely manages component trees)",
      "Edit src/src/lib.rs to implement your formula logic",
      "Compile: use build.compile with reference '#{reference}'",
      "Register: use component.register to index the compiled binary"
    ]
  end

  defp next_steps("reagent", reference, _template) do
    [
      "Edit src/src/lib.rs to implement your compute logic",
      "Compile: use build.compile with reference '#{reference}'",
      "Register: use component.register to index the compiled binary"
    ]
  end

  defp next_steps("tincture", reference, built) when built in ["react", "vite"] do
    [
      if(built == "react",
        do: "Edit src/App.tsx to build your UI",
        else: "Edit index.html, src/main.js and src/style.css to build your UI"
      ),
      "The build installs exactly what package-lock.json pins: change a dependency in " <>
        "package.json and regenerate package-lock.json beside it (npm install " <>
        "--package-lock-only), or the build is refused",
      "Add backend components to dependencies.static in #{Compendium.ComponentPath.manifest_name()}",
      "Replace #{Path.join(Compendium.Tincture.default_icon())} and " <>
        "#{Path.join(Compendium.Tincture.default_preview())} to brand the picker card " <>
        "(add up to #{Compendium.Tincture.preview_count()} previews)",
      "Compile: use build.compile with reference '#{reference}'",
      "Register: use component.register to index the built tincture"
    ]
  end

  defp next_steps("tincture", reference, _template) do
    [
      "Edit index.html, app.js, and style.css to build your UI",
      "The cyfr SDK (window.cyfr) is injected into the page — use " <>
        "cyfr.invoke(ref, operation, args) to call the components the manifest declares",
      "Add backend components to dependencies.static in #{Compendium.ComponentPath.manifest_name()}",
      "Replace #{Path.join(Compendium.Tincture.default_icon())} and " <>
        "#{Path.join(Compendium.Tincture.default_preview())} to brand the picker card " <>
        "(add up to #{Compendium.Tincture.preview_count()} previews)",
      "Register: use component.register with reference '#{reference}'"
    ]
  end

  # ============================================================================
  # Tincture Templates
  # ============================================================================

  defp tincture_index_html(name) do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>#{name}</title>
      <link rel="stylesheet" href="style.css">
    </head>
    <body>
      <div id="app">
        <h1>#{name}</h1>
        <p>Edit this tincture to build your UI.</p>
        <div id="data"></div>
      </div>
      <script src="app.js"></script>
    </body>
    </html>
    """
  end

  defp tincture_app_js do
    """
    // Tincture app entry point. window.cyfr is injected before this script
    // runs. Invoke a component the manifest declares in dependencies.static;
    // it runs with the input {"operation": "run", "params": {key: "value"}}:
    // cyfr.invoke("c:local.my-component", "run", { key: "value" })
    //   .then((result) => console.log(result.output))
    //   .catch((error) => console.error(error.code, error.message))
    //
    // A declared system action, and a declared stream (close() ends it):
    // cyfr.action("tool.action", {})
    // const feed = await cyfr.stream("tool.topic", null, ({ event, data }) => console.log(event, data))
    //
    // Shell verbs: cyfr.title("…"), cyfr.close(), cyfr.open("t:local.other").
    // A secret is typed into the shell, never the page: cyfr.credential("name")
    // resolves with {saved} once the shell's prompt closes.
    // At a public tincture's address the same calls run with no credential,
    // under its public profile.

    cyfr.ready()
    """
  end

  defp tincture_style_css do
    """
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: system-ui, sans-serif; padding: 1rem; color: #1a1a2e; }
    h1 { margin-bottom: 0.5rem; }
    #data { margin-top: 1rem; }
    """
  end

  # Placeholder media files written into `public/media/` so newly scaffolded
  # tinctures show *something* in the picker before the author replaces them.
  # The discovery helper finds them via the fixed convention paths.

  defp placeholder_icon_svg do
    ~S"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" width="256" height="256">
      <rect width="256" height="256" rx="48" fill="#6366f1"/>
      <text x="128" y="160" font-family="system-ui, sans-serif" font-size="120"
            font-weight="600" fill="#ffffff" text-anchor="middle">T</text>
    </svg>
    """
  end

  defp placeholder_preview_svg do
    ~S"""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 640 360" width="640" height="360">
      <rect width="640" height="360" fill="#1e1b4b"/>
      <text x="320" y="170" font-family="system-ui, sans-serif" font-size="36"
            font-weight="600" fill="#a5b4fc" text-anchor="middle">Preview 1</text>
      <text x="320" y="210" font-family="system-ui, sans-serif" font-size="14"
            fill="#818cf8" fill-opacity="0.7" text-anchor="middle">replace with a screenshot · add preview-2.svg, preview-3.svg, …</text>
    </svg>
    """
  end

  # ============================================================================
  # React Tincture Templates
  # ============================================================================

  defp react_tincture_files(base_path, name, version, template) do
    [
      {base_path ++ [Compendium.ComponentPath.manifest_name()],
       tincture_manifest_for(name, version, template)},
      {base_path ++ ["package.json"],
       package_json(name, "tsc -b && vite build", @react_packages)},
      {base_path ++ [@lockfile], lockfile(name, @react_packages)},
      {base_path ++ ["tsconfig.json"], react_tsconfig()},
      {base_path ++ ["vite.config.ts"], react_vite_config()},
      {base_path ++ ["index.html"], react_index_html(name)},
      {base_path ++ ["src", "main.tsx"], react_main_tsx()},
      {base_path ++ ["src", "App.tsx"], react_app_tsx(name)},
      {base_path ++ ["src", "index.css"], tincture_style_css()},
      {base_path ++ Compendium.Tincture.default_icon(), placeholder_icon_svg()},
      {base_path ++ Compendium.Tincture.default_preview(), placeholder_preview_svg()}
    ]
  end

  defp react_tsconfig do
    safe_encode_pretty(%{
      compilerOptions: %{
        target: "ES2020",
        module: "ESNext",
        lib: ["ES2020", "DOM", "DOM.Iterable"],
        jsx: "react-jsx",
        moduleResolution: "bundler",
        types: ["vite/client"],
        strict: true,
        noUnusedLocals: true,
        noUnusedParameters: true,
        noFallthroughCasesInSwitch: true,
        skipLibCheck: true
      },
      include: ["src"]
    })
  end

  defp react_vite_config do
    ~S"""
    import { defineConfig } from "vite";
    import react from "@vitejs/plugin-react";

    export default defineConfig({
      plugins: [react()],
      base: "./",
      build: {
        outDir: "dist",
        emptyOutDir: true,
        target: "esnext",
      },
    });
    """
  end

  defp react_index_html(name) do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>#{name}</title>
    </head>
    <body>
      <div id="root"></div>
      <script type="module" src="/src/main.tsx"></script>
    </body>
    </html>
    """
  end

  defp react_main_tsx do
    ~S"""
    import { StrictMode } from "react";
    import { createRoot } from "react-dom/client";
    import App from "./App";
    import "./index.css";

    createRoot(document.getElementById("root")!).render(
      <StrictMode>
        <App />
      </StrictMode>
    );
    """
  end

  defp react_app_tsx(name) do
    """
    import { useState, useEffect } from "react";

    // window.cyfr, injected before the page's scripts run.
    declare const cyfr: {
      readonly frame: string | null;
      readonly public: { athanor: string; publisher: string; name: string } | null;
      invoke(ref: string, operation: string, args?: Record<string, unknown>): Promise<{
        status: string;
        output: unknown;
        execution_id: string | null;
        duration_ms: number | null;
      }>;
      action(name: string, args?: Record<string, unknown>): Promise<unknown>;
      stream(
        name: string,
        subject: string | null,
        onEvent: (event: { id: number | null; event: string; data: unknown }) => void
      ): Promise<{ close(): void; closed: Promise<void> }>;
      open(ref: string): void;
      close(): void;
      title(title: string): void;
      ready(): void;
      credential(name: string): Promise<{ saved: boolean }>;
    };

    export default function App() {
      const [data, setData] = useState<Record<string, unknown> | null>(null);

      useEffect(() => {
        // Invoke a component the manifest declares in dependencies.static;
        // it runs with the input {"operation": "run", "params": {key: "value"}}:
        // cyfr.invoke("c:local.my-component", "run", { key: "value" })
        //   .then((result) => setData(result.output as Record<string, unknown>))
        //   .catch((error) => console.error(error.code, error.message));
        cyfr.ready();
        setData(null);
      }, []);

      return (
        <div>
          <h1>#{name}</h1>
          <p>Edit src/App.tsx to build your UI.</p>
          {data && <pre>{JSON.stringify(data, null, 2)}</pre>}
        </div>
      );
    }
    """
  end

  # ============================================================================
  # Vite Tincture Templates
  # ============================================================================

  defp vite_tincture_files(base_path, name, version, template) do
    [
      {base_path ++ [Compendium.ComponentPath.manifest_name()],
       tincture_manifest_for(name, version, template)},
      {base_path ++ ["package.json"], package_json(name, "vite build", @vite_packages)},
      {base_path ++ [@lockfile], lockfile(name, @vite_packages)},
      {base_path ++ ["vite.config.js"], vite_config()},
      {base_path ++ ["index.html"], vite_index_html(name)},
      {base_path ++ ["src", "main.js"], vite_main_js(name)},
      {base_path ++ ["src", "style.css"], tincture_style_css()},
      {base_path ++ Compendium.Tincture.default_icon(), placeholder_icon_svg()},
      {base_path ++ Compendium.Tincture.default_preview(), placeholder_preview_svg()}
    ]
  end

  defp vite_config do
    ~S"""
    import { defineConfig } from "vite";

    export default defineConfig({
      base: "./",
      build: {
        outDir: "dist",
        emptyOutDir: true,
        target: "esnext",
      },
    });
    """
  end

  defp vite_index_html(name) do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>#{name}</title>
    </head>
    <body>
      <div id="app"></div>
      <script type="module" src="/src/main.js"></script>
    </body>
    </html>
    """
  end

  defp vite_main_js(name) do
    """
    import "./style.css";

    const app = document.getElementById("app");
    app.innerHTML = "<h1>#{name}</h1><p>Edit src/main.js to build your UI.</p>";

    // window.cyfr is injected before this module runs. Invoke a component the
    // manifest declares in dependencies.static; it runs with the input
    // {"operation": "run", "params": {key: "value"}}:
    // cyfr.invoke("c:local.my-component", "run", { key: "value" })
    //   .then((result) => console.log(result.output))
    //   .catch((error) => console.error(error.code, error.message));
    //
    // A declared system action, and a declared stream (close() ends it):
    // cyfr.action("tool.action", {});
    // const feed = await cyfr.stream("tool.topic", null, ({ event, data }) => console.log(event, data));
    //
    // Shell verbs: cyfr.title("…"), cyfr.close(), cyfr.open("t:local.other").
    // A secret is typed into the shell, never the page: cyfr.credential("name")
    // resolves with {saved} once the shell's prompt closes.
    // At a public tincture's address the same calls run with no credential,
    // under its public profile.

    cyfr.ready();
    """
  end

  # ============================================================================
  # Package manifests and their lockfiles
  # ============================================================================

  defp package_json(name, build, packages) do
    safe_encode_pretty(
      Map.merge(
        %{
          "name" => name,
          "private" => true,
          "type" => "module",
          "scripts" => %{"dev" => "vite", "build" => build, "preview" => "vite preview"}
        },
        packages
      )
    )
  end

  # The lockfile for `packages`: its root names the same dependencies the
  # package manifest does, which is what `npm ci` holds the two to, and its
  # packages are the closure of those dependencies, in path order.
  defp lockfile(name, packages) do
    roots = packages |> Map.values() |> Enum.flat_map(&Map.keys/1)
    paths = @lock_packages |> closure(roots) |> Enum.sort()

    entries =
      [{"", Map.put(packages, "name", name)} | Enum.map(paths, &{&1, @lock_packages[&1]})]

    safe_encode_pretty(
      Jason.OrderedObject.new([
        {"name", name},
        {"lockfileVersion", 3},
        {"requires", true},
        {"packages", Jason.OrderedObject.new(entries)}
      ])
    )
  end

  # Node's resolution: a package's dependency is the nearest `node_modules`
  # entry of that name, looking outward from the package's own directory.
  defp closure(lock, roots) do
    Enum.reduce(roots, MapSet.new(), fn root, seen ->
      visit(lock, resolve(lock, "", root), seen)
    end)
  end

  defp visit(_lock, nil, seen), do: seen

  defp visit(lock, path, seen) do
    if MapSet.member?(seen, path) do
      seen
    else
      entry = Map.fetch!(lock, path)

      deps =
        Map.keys(Map.merge(entry["dependencies"] || %{}, entry["optionalDependencies"] || %{}))

      Enum.reduce(deps, MapSet.put(seen, path), &visit(lock, resolve(lock, path, &1), &2))
    end
  end

  defp resolve(lock, from, name) do
    candidate = if from == "", do: "node_modules/" <> name, else: from <> "/node_modules/" <> name

    cond do
      Map.has_key?(lock, candidate) -> candidate
      from == "" -> nil
      true -> resolve(lock, parent(from), name)
    end
  end

  defp parent(path) do
    case :binary.matches(path, "/node_modules/") do
      [] -> ""
      matches -> binary_part(path, 0, matches |> List.last() |> elem(0))
    end
  end
end
