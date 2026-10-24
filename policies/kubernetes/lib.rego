# Helpers shared by the per-document policies.
package lib.k8s

workload_kinds := {"Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job", "CronJob", "Pod"}

long_running_kinds := {"Deployment", "StatefulSet", "DaemonSet"}

is_workload if workload_kinds[input.kind]

is_long_running if long_running_kinds[input.kind]

name := sprintf("%s/%s", [input.kind, input.metadata.name])

labels := object.get(input.metadata, "labels", {})

annotations := object.get(input.metadata, "annotations", {})

environment := object.get(labels, "platform.akibullah.dev/environment", "")

is_hook if annotations["helm.sh/hook"]

pod_spec := input.spec if input.kind == "Pod"

pod_spec := input.spec.jobTemplate.spec.template.spec if input.kind == "CronJob"

pod_spec := input.spec.template.spec if {
	is_workload
	not input.kind in {"Pod", "CronJob"}
}

pod_labels := object.get(input.metadata, "labels", {}) if input.kind == "Pod"

pod_labels := object.get(input.spec.template.metadata, "labels", {}) if {
	is_workload
	not input.kind in {"Pod", "CronJob"}
}

containers contains c if {
	some c in pod_spec.containers
}

containers contains c if {
	some c in object.get(pod_spec, "initContainers", [])
}

pod_security := object.get(pod_spec, "securityContext", {})

container_security(c) := object.get(c, "securityContext", {})

# Effective value of a security setting: container level wins over pod level.
effective(c, key) := container_security(c)[key]

effective(c, key) := pod_security[key] if not has_key(container_security(c), key)

has_key(obj, key) if _ = obj[key]

run_as_non_root(c) if effective(c, "runAsNonRoot") == true

seccomp_restricted(c) if effective(c, "seccompProfile").type in {"RuntimeDefault", "Localhost"}

# An image is pinned when it carries a digest, or a tag other than "latest".
image_pinned(img) if contains(img, "@sha256:")

image_pinned(img) if {
	not contains(img, "@")
	parts := split(img, "/")
	last := parts[count(parts) - 1]
	contains(last, ":")
	tag := split(last, ":")[1]
	tag != ""
	tag != "latest"
}
