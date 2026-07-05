# pelegram hidden-area UI glue. Deliberately does NOT set -warnings-as-errors:
# it hosts SwiftUI + raw MTProto calls that are easier to iterate on without
# treating deprecations as hard errors.

load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "HiddenAreaUI",
    module_name = "HiddenAreaUI",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    deps = [
        "//submodules/HiddenCore:HiddenCore",
        "//submodules/Display:Display",
        "//submodules/Postbox:Postbox",
        "//submodules/AccountContext:AccountContext",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/TelegramApi:TelegramApi",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
    ],
    visibility = [
        "//visibility:public",
    ],
)
