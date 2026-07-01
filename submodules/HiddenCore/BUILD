# Bazel target for HiddenCore inside the Telegram-iOS fork.
# Path in the fork: submodules/HiddenCore/BUILD
#
# Only system frameworks are used (Foundation, CryptoKit, CommonCrypto, Combine,
# Security) — all part of the Apple SDK, so no extra deps are needed here.
# If the toolchain can't find the CommonCrypto module, add a modulemap shim the
# way other submodules do (see how the fork vendors system-module shims).

load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "HiddenCore",
    module_name = "HiddenCore",
    srcs = glob([
        "Sources/HiddenCore/**/*.swift",
    ]),
    visibility = [
        "//visibility:public",
    ],
)
