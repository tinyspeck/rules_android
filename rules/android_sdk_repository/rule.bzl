# Copyright 2018 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""Bazel rule for Android sdk repository."""

load(
    "//rules:android_revision.bzl",
    "compare_android_revisions",
    "is_android_revision",
    "parse_android_revision",
)

_ANDROID_SDK_TOOLS = "10406996_latest"

_SDK_REPO_TEMPLATE = Label(":template.bzl")
_EMPTY_SDK_REPO_TEMPLATE = Label(":empty.template.bzl")

_BUILD_TOOLS_DIR = "build-tools"
_PLATFORMS_DIR = "platforms"
_SYSTEM_IMAGES_DIR = "system-images"
_LOCAL_MAVEN_REPOS = [
    "extras/android/m2repository",
    "extras/google/m2repository",
    "extras/m2repository",
]
_DIRS_TO_LINK = [
    _BUILD_TOOLS_DIR,
    "emulator",
    "platform-tools",
    _PLATFORMS_DIR,
    _SYSTEM_IMAGES_DIR,
] + _LOCAL_MAVEN_REPOS

_MIN_BUILD_TOOLS_VERSION = parse_android_revision("30.0.0")

def _read_api_levels(repo_ctx, android_sdk_path):
    platforms_dir = "%s/%s" % (android_sdk_path, _PLATFORMS_DIR)
    api_levels = []
    platforms_path = repo_ctx.path(platforms_dir)
    if not platforms_path.exists:
        return api_levels
    for entry in platforms_path.readdir():
        name = entry.basename
        if name.startswith("android-"):
            level = name[len("android-"):]
            if level.isdigit():
                api_levels.append(int(level))
    return api_levels

def _newest_build_tools(repo_ctx, android_sdk_path):
    build_tools_dir = "%s/%s" % (android_sdk_path, _BUILD_TOOLS_DIR)
    highest = None
    build_tools_path = repo_ctx.path(build_tools_dir)
    if not build_tools_path.exists:
        return None
    for entry in build_tools_path.readdir():
        name = entry.basename
        if is_android_revision(name):
            revision = parse_android_revision(name)
            highest = compare_android_revisions(highest, revision)
    return highest.realpath

def _find_system_images(repo_ctx, android_sdk_path):
    system_images_dir = "%s/%s" % (android_sdk_path, _SYSTEM_IMAGES_DIR)
    system_images = []

    system_images_path = repo_ctx.path(system_images_dir)
    if not system_images_path.exists:
        return system_images

    # The directory structure needed is "system-images/android-API/apis-enabled/arch"
    for api_entry in system_images_path.readdir():
        for enabled_entry in api_entry.readdir():
            for arch_entry in enabled_entry.readdir():
                image_path = "%s/%s/%s/%s" % (
                    _SYSTEM_IMAGES_DIR,
                    api_entry.basename,
                    enabled_entry.basename,
                    arch_entry.basename,
                )
                system_images.append(image_path)

    return system_images

def _android_sdk_repository_impl(repo_ctx):
    # Determine the SDK path to use, either from the attribute or the environment.
    if repo_ctx.attr._download_sdk:
        api_level = repo_ctx.attr.api_level
        build_tools_version = repo_ctx.attr.build_tools_version

        android_sdk_path = repo_ctx.path(".")

        # Platform is used to determine both sdkmanager and JDK platform variants
        if repo_ctx.os.name == "mac os x":
            platform = "mac"
            arch_for_zulu = repo_ctx.os.arch
        else:
            platform = "linux"
            # Zulu only has an x64 distribution for Linux
            arch_for_zulu = "x64"

        # 1. Download the Android command line tools (for sdkmanager)
        repo_ctx.report_progress("Downloading Android command line tools")
        cmdline_url = _cmdline_tools_url_for(platform)
        repo_ctx.download_and_extract(cmdline_url)

        # 2. Download a JDK that can run sdkmanager. The embedded Java does not include awd libraries. 
        zulu_version_string = "zulu22.32.21-ca-crac-jdk22.0.2-{platform}_{arch}".format(
            platform = platform, 
            arch = arch_for_zulu
        ).replace("mac", "macosx")
        repo_ctx.report_progress("Downloading JDK {} to use as sdkmanager runtime".format(zulu_version_string))
        java_home = repo_ctx.path("java_home")
        repo_ctx.download_and_extract(
            url = "https://cdn.azul.com/zulu/bin/{}.tar.gz".format(zulu_version_string), 
            output = java_home,
            type = "tar.gz",
            # Will be strip_prefix in a near version of Bazel: https://github.com/bazelbuild/bazel/issues/24034
            stripPrefix = zulu_version_string
        )

        # 3. Download the SDK, platform-tools, and build-tools with sdkmanager

        # Before running sdkmanager, insert the license file into the well-known location:
        # licenses/android-sdk-license
        license_path_file = repo_ctx.path("licenses/android-sdk-license")
        repo_ctx.file(license_path_file, content = repo_ctx.attr.license_hash)

        repo_ctx.report_progress("Downloading: API level {}, build tools {}".format(api_level, build_tools_version))
        # Download and install the Android SDK
        args = [
            "--sdk_root={path}".format(path = android_sdk_path),
            "platform-tools",
            "platforms;android-{api_level}".format(
                api_level = api_level,
            ),
            "build-tools;{build_tools_version}".format(build_tools_version = build_tools_version),
        ]
        
        result = repo_ctx.execute(["cmdline-tools/bin/sdkmanager"] + args, environment = {
            "JAVA_HOME": "{}".format(java_home),
        })

        if result.return_code != 0:
            print("sdkmanager call failed!")
            print(result.stderr)
            print(result.stdout)
    else:
        # Traditional env-based SDK
        android_sdk_path = repo_ctx.attr.path
        if not android_sdk_path:
            android_sdk_path = repo_ctx.os.environ.get("ANDROID_HOME")
        if not repo_ctx.attr._download and not android_sdk_path:
            # Create an empty repository that allows non-Android code to build.
            repo_ctx.template("BUILD.bazel", _EMPTY_SDK_REPO_TEMPLATE)
            return None

    # Read list of supported SDK levels
    api_levels = _read_api_levels(repo_ctx, android_sdk_path)
    if len(api_levels) == 0:
        fail("No Android SDK apis found in the Android SDK at %s. Please install APIs from the Android SDK Manager." % android_sdk_path)

    # Determine default SDK level.
    default_api_level = max(api_levels)
    if repo_ctx.attr.api_level:
        default_api_level = int(repo_ctx.attr.api_level)
    if default_api_level not in api_levels:
        fail("Android SDK api level %s was requested but it is not installed in the Android SDK at %s. The api levels found were %s. Please choose an available api level or install api level %s from the Android SDK Manager." % (
            default_api_level,
            android_sdk_path,
            api_levels,
            default_api_level,
        ))

    # Determine build_tools directory (and version)
    build_tools = None
    if repo_ctx.attr.build_tools_version:
        build_tools = parse_android_revision(repo_ctx.attr.build_tools_version)
    else:
        build_tools = _newest_build_tools(repo_ctx, android_sdk_path)

    # Check validity of build_tools
    if not build_tools:
        fail("Unable to determine build tools version")
    if compare_android_revisions(build_tools, _MIN_BUILD_TOOLS_VERSION) != build_tools:
        fail("Bazel requires Android build tools version %s or newer, %s was provided" % (
            _MIN_BUILD_TOOLS_VERSION.dir,
            build_tools.dir,
        ))

    # Determine system image dirs
    system_images = _find_system_images(repo_ctx, android_sdk_path)

    # Write the build file.
    repo_ctx.symlink(Label(":helper.bzl"), "helper.bzl")
    repo_ctx.template(
        "BUILD.bazel",
        _SDK_REPO_TEMPLATE,
        substitutions = {
            "__repository_name__": repo_ctx.name,
            "__build_tools_version__": build_tools.version,
            "__build_tools_directory__": build_tools.dir,
            "__api_levels__": ",".join([str(level) for level in api_levels]),
            "__default_api_level__": str(default_api_level),
            "__system_image_dirs__": "\n".join(["'%s'," % d for d in system_images]),
            # TODO(katre): implement these.
            #"__exported_files__": "",
        },
    )

    # repo is reproducible
    return None

_android_sdk_repository = repository_rule(
    implementation = _android_sdk_repository_impl,
    attrs = {
        "api_level": attr.int(default = 0),
        "build_tools_version": attr.string(),
        "path": attr.string(),
    },
    environ = ["ANDROID_HOME"],
    local = True,
)

_downloadable_android_sdk_repository = repository_rule(
    implementation = _android_sdk_repository_impl,
    attrs = {
        "api_level": attr.int(default = 0),
        "build_tools_version": attr.string(),
        "path": attr.string(),
        "license_hash": attr.string(),
        "_download_sdk": attr.bool(
            default=True,
        ),
    },
    local = False,
)


def android_sdk_repository(
        name,
        path = "",
        api_level = 0,
        build_tools_version = ""):
    """Create a repository with Android SDK toolchains.

    The SDK will be located at the given path, or via the ANDROID_HOME
    environment variable if the path attribute is unset.

    Args:
      name: The repository name.
      api_level: The SDK API level to use.
      build_tools_version: The build_tools in the SDK to use.
      path: The path to the Android SDK.
    """

    _android_sdk_repository(
        name = name,
        path = path,
        api_level = api_level,
        build_tools_version = build_tools_version,
    )

    native.register_toolchains("@%s//:sdk-toolchain" % name)
    native.register_toolchains("@%s//:all" % name)

def _android_sdk_repository_extension_impl(module_ctx):
    root_modules = [m for m in module_ctx.modules if m.is_root and m.tags.configure]
    if len(root_modules) > 1:
        fail("Expected at most one root module, found {}".format(", ".join([x.name for x in root_modules])))

    if root_modules:
        module = root_modules[0]
    else:
        module = module_ctx.modules[0]

    # ---------------
    # Configures both the hashed directory location, and cmdline_tools
    # versions to use per platform
    if module_ctx.os.name == "mac os x":
        md5_bin = "/sbin/md5"
    else:
        md5_bin = "/usr/bin/md5sum"

    output_base_hash_result = module_ctx.execute(
        ["bash", "-c", md5_bin, '-q -s "${PWD%/*/*/*/*}"'],
    )
    if output_base_hash_result.return_code != 0:
        fail("Failed to calculate output base hash: {}".format(
            output_base_hash_result.stderr,
        ))


    # Ensure that this repository is unique per output base
    output_base_hash = output_base_hash_result.stdout.split(" ")[0].strip()

    path = "/var/tmp/android_sdk/{}/sdk".format(output_base_hash)

    kwargs = {}
    if module.tags.configure:
        kwargs["api_level"] = module.tags.configure[0].api_level
        kwargs["build_tools_version"] = module.tags.configure[0].build_tools_version
        kwargs["license_hash"] = module.tags.configure[0].license_hash

    _downloadable_android_sdk_repository(
        name = "androidsdk",
        **kwargs
    )

android_sdk_repository_extension = module_extension(
    implementation = _android_sdk_repository_extension_impl,
    tag_classes = {
        "configure": tag_class(attrs = {
            "path": attr.string(),
            "api_level": attr.int(),
            "build_tools_version": attr.string(),
            "license_hash": attr.string(),
        }),
    },
)

### Auto android SDK imp

def _cmdline_tools_url_for(platform):
    if platform not in ["mac", "linux"]:
        fail("Expected mac or linux as platform URL types")

    return "https://dl.google.com/android/repository/commandlinetools-{platform}-{sdk_tools}.zip".format(platform = platform, sdk_tools = _ANDROID_SDK_TOOLS)

def _add_directory_repo_impl(repository_ctx):
    directory = repository_ctx.attr.directory

    repository_ctx.symlink(directory, "sdk")

    return directory

add_directory_repo = repository_rule(
    implementation = _add_directory_repo_impl,
    attrs = {
        "directory": attr.string(mandatory = True, doc = "Path to the directory to add"),
    },
)

