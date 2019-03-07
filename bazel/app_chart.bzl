load("@io_bazel_rules_docker//container:container.bzl", "container_bundle")
load("@io_bazel_rules_docker//container:providers.bzl", "ImageInfo", "ImportInfo")
load("@io_bazel_rules_docker//contrib:push-all.bzl", "container_push")
load("@cloud_robotics//bazel/build_rules:expand_vars.bzl", "expand_vars")
load("@cloud_robotics//bazel/build_rules:helm_chart.bzl", "helm_chart")
load("@cloud_robotics//bazel/build_rules:qualify_images.bzl", "qualify_images")
load("@cloud_robotics//bazel/build_rules/app_chart:cache_gcr_credentials.bzl", "cache_gcr_credentials")
load("@cloud_robotics//bazel/build_rules/app_chart:run_sequentially.bzl", "run_sequentially")

# Simplified version of _assemble_image_digest found in
# https://github.com/bazelbuild/rules_docker/blob/master/container/image.bzl
# This function executes digester to find the Docker image's digest.
def _assemble_image_digest(ctx, image, output_digest):
    blobsums = image.get("blobsum", [])
    digest_args = ["--digest=%s" % f.path for f in blobsums]
    blobs = image.get("zipped_layer", [])
    layer_args = ["--layer=%s" % f.path for f in blobs]
    config_arg = "--config=%s" % image["config"].path
    output_digest_arg = "--output-digest=%s" % output_digest.path

    arguments = [config_arg, output_digest_arg] + layer_args + digest_args
    if image.get("legacy"):
        arguments.append("--tarball=%s" % image["legacy"].path)

    ctx.actions.run(
        outputs = [output_digest],
        tools = [image["config"]] + blobsums + blobs +
                ([image["legacy"]] if image.get("legacy") else []),
        executable = ctx.executable._digester,
        arguments = arguments,
        mnemonic = "ImageDigest",
        progress_message = "Extracting image digest",
    )

def _impl(ctx):
    chart_yaml = ctx.actions.declare_file(ctx.label.name + "-chart.yaml")

    ctx.actions.expand_template(
        template = ctx.file._chart_yaml_template,
        output = chart_yaml,
        substitutions = {"${name}": ctx.label.name, "${version}": "0.0.1"},
    )

    values_yaml = ctx.actions.declare_file(ctx.label.name + "-values.yaml")
    source_digests = []
    cmds = [
        "cat {} - > {} <<EOF".format(ctx.file.values.path, values_yaml.path),
        "### Generated by app_chart ###",
        "images:",
    ]
    images = ctx.attr.images or {}
    for key, value in images.items():
        digest_file = None
        if ImageInfo in key:
            digest_file = key[ImageInfo].container_parts["digest"]
        else:
            # container_pull/container_image rules don't export ImageInfo.
            digest_file = ctx.actions.declare_file("{}-{}-digest".format(ctx.label.name, value))
            _assemble_image_digest(ctx, key[ImportInfo].container_parts, digest_file)

        cmds.append("  {nick}: {registry}/{image}@$(cat {digest})".format(
            nick = value.replace("-", "_"),
            registry = ctx.attr.registry,
            image = value,
            digest = digest_file.path,
        ))
        source_digests.append(digest_file)
    cmds.append("EOF")

    ctx.actions.run_shell(
        outputs = [values_yaml],
        inputs = ctx.files.values + source_digests,
        command = "\n".join(cmds),
    )

    helm_chart(
        ctx,
        name = ctx.label.name,
        chart = chart_yaml,
        values = values_yaml,
        # TODO(b/72936439): This is currently unused and fixed to 0.0.1.
        version = "0.0.1",
        templates = ctx.files.templates,
        files = ctx.files.files,
        helm = ctx.file._helm,
        out = ctx.outputs.chart,
    )

    return [DefaultInfo(
        runfiles = ctx.runfiles(files = [ctx.outputs.chart]),
        files = depset([ctx.outputs.chart]),
    )]

_app_chart_backend = rule(
    implementation = _impl,
    attrs = {
        "chart": attr.string(
            doc = "the chart name (robot/cloud/cloud-per-robot)",
            mandatory = True,
        ),
        "registry": attr.string(
            doc = "the docker registry that contains the images in this chart (gcr.io/my-project)",
            mandatory = True,
        ),
        "docker_tag": attr.string(
            doc = "the docker tag for image pushes, defaults to latest",
            default = "latest",
        ),
        "values": attr.label(
            allow_single_file = True,
            doc = "The values.yaml file.",
        ),
        "templates": attr.label_list(
            allow_empty = True,
            allow_files = True,
            default = [],
            doc = "Files for the chart's templates/ directory.",
        ),
        "extra_values": attr.string(
            default = "",
            doc = "This is a YAML string for the \"values\" field  of " +
                  "the app CR. This can be used to pass extra parameters to " +
                  "the app.",
        ),
        "files": attr.label_list(
            allow_empty = True,
            allow_files = True,
            default = [],
            doc = "Extra non-template files for the chart's files/ directory.",
        ),
        "images": attr.label_keyed_string_dict(
            allow_empty = True,
            doc = "Images referenced by the chart.",
        ),
        "_chart_yaml_template": attr.label(
            default = Label("@cloud_robotics//bazel/build_rules/app_chart:Chart.yaml.template"),
            allow_single_file = True,
        ),
        "_helm": attr.label(
            default = Label("@kubernetes_helm//:helm"),
            allow_single_file = True,
        ),
        "_digester": attr.label(
            default = "@containerregistry//:digester",
            cfg = "host",
            executable = True,
        ),
    },
    outputs = {
        "chart": "%{name}-0.0.1.tgz",
    },
)

def app_chart(
        name,
        registry,
        docker_tag = "latest",
        values = None,
        extra_templates = None,
        extra_values = None,
        files = None,
        images = None,
        visibility = None):
    """Macro for a standard Cloud Robotics helm chart.

    This macro establishes two subrules for chart name "foo-cloud":
    - :foo-cloud.push pushes the Docker images for the chart (if relevant).
    - :foo-cloud.snippet-yaml is a snippet of YAML defining the chart, which is
      used by app() to generate an App CR containing multiple inline
      charts.

    Args:
      name: string. Must be in the format {app}-{chart}, where chart is
        robot, cloud, or cloud-per-robot.
      registry: string. The docker registry for image pushes (gcr.io/my-project).
      docker_tag: string. Defaults to latest.
      values: file. The values.yaml file.
      extra_templates: list of files. Extra files for the chart's templates/ directory.
      extra_values: string. This is a YAML string for the "values" field  of
        the app CR. This can be used to pass extra parameters to the app.
      files: list of files. Extra non-template files for the chart's files/ directory.
      images: dict. Images referenced by the chart.
      visibility: Visibility.
    """

    _, chart = name.rsplit("-", 1)
    if name.endswith("cloud-per-robot"):
        chart = "cloud-per-robot"

    if not values:
        if chart == "cloud":
            values = "@cloud_robotics//bazel/build_rules/app_chart:values-cloud.yaml"
        else:
            values = "@cloud_robotics//bazel/build_rules/app_chart:values-robot.yaml"

    # We have a dict of string:target, but bazel rules only support target:string.
    reversed_images = {}
    if images:
        for k, v in images.items():
            reversed_images[v] = k

    _app_chart_backend(
        name = name,
        chart = chart,
        registry = registry,
        docker_tag = docker_tag,
        values = values,
        templates = native.glob([chart + "/*.yaml"]) + (extra_templates or []),
        extra_values = extra_values,
        files = files,
        images = reversed_images,
        visibility = visibility,
    )

    container_bundle(
        name = name + ".container-bundle",
        images = qualify_images(images or {}, registry, docker_tag),
    )
    container_push(
        name = name + ".push-all-containers",
        bundle = name + ".container-bundle",
        format = "Docker",
    )

    run_sequentially(
        name = name + ".push-cached-credentials",
        # The conditional works around container_push's inability to handle
        # an empty dict of containers:
        # https://github.com/bazelbuild/rules_docker/issues/511
        targets = [name + ".push-all-containers"] if images else [],
    )

    cache_gcr_credentials(
        name = name + ".push",
        target = name + ".push-cached-credentials",
        gcr_registry = registry,
        visibility = visibility,
    )

    extra_values_yaml = ""
    if extra_values:
        extra_values_yaml = "\n".join(["values: |-"] + ["      " + s for s in extra_values.split("\n")])

    native.genrule(
        name = name + ".snippet-yaml",
        srcs = [name],
        outs = [name + ".snippet.yaml"],
        cmd = """cat <<EOF > $@
  - installation_target: {target}
    name: {name}
    version: 0.0.1
    inline_chart: $$(base64 -w 0 $<)
    {extra_values_yaml}
EOF
""".format(
            name = name,
            target = chart.upper().replace("-", "_"),
            values_header = "values: |-\n" if extra_values else "",
            extra_values_yaml = extra_values_yaml,
        ),
    )

    if chart != "cloud-per-robot":
        native.genrule(
            name = name + ".snippet-v2-yaml",
            srcs = [name],
            outs = [name + ".snippet-v2.yaml"],
            cmd = """cat <<EOF > $@
    {target}:
      inline: $$(base64 -w 0 $<)
EOF
""".format(name = name, target = chart),
        )
