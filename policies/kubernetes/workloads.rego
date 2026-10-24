# Per-document rules for anything that runs containers.
# Run: conftest test --policy policies <manifests>
package main

import data.lib.k8s

deny contains msg if {
	some c in k8s.containers
	not k8s.image_pinned(c.image)
	msg := sprintf("%s: container %q uses unpinned image %q; use a version tag or digest, never latest", [k8s.name, c.name, c.image])
}

deny contains msg if {
	some c in k8s.containers
	not c.resources.requests.cpu
	msg := sprintf("%s: container %q must set resources.requests.cpu", [k8s.name, c.name])
}

deny contains msg if {
	some c in k8s.containers
	not c.resources.requests.memory
	msg := sprintf("%s: container %q must set resources.requests.memory", [k8s.name, c.name])
}

# CPU limits are deliberately not required (they cause throttling without
# protecting neighbours); a memory limit is, because memory is not compressible.
deny contains msg if {
	some c in k8s.containers
	not c.resources.limits.memory
	msg := sprintf("%s: container %q must set resources.limits.memory", [k8s.name, c.name])
}

deny contains msg if {
	some c in k8s.containers
	not k8s.run_as_non_root(c)
	msg := sprintf("%s: container %q must run with runAsNonRoot: true", [k8s.name, c.name])
}

deny contains msg if {
	some c in k8s.containers
	k8s.effective(c, "runAsUser") == 0
	msg := sprintf("%s: container %q must not run as UID 0", [k8s.name, c.name])
}

deny contains msg if {
	some c in k8s.containers
	not k8s.container_security(c).allowPrivilegeEscalation == false
	msg := sprintf("%s: container %q must set allowPrivilegeEscalation: false", [k8s.name, c.name])
}

deny contains msg if {
	some c in k8s.containers
	not k8s.container_security(c).readOnlyRootFilesystem == true
	msg := sprintf("%s: container %q must set readOnlyRootFilesystem: true (mount an emptyDir for scratch space)", [k8s.name, c.name])
}

deny contains msg if {
	some c in k8s.containers
	k8s.container_security(c).privileged == true
	msg := sprintf("%s: container %q must not be privileged", [k8s.name, c.name])
}

deny contains msg if {
	some c in k8s.containers
	drops := object.get(k8s.container_security(c), ["capabilities", "drop"], [])
	not "ALL" in drops
	msg := sprintf("%s: container %q must drop ALL capabilities", [k8s.name, c.name])
}

deny contains msg if {
	some c in k8s.containers
	not k8s.seccomp_restricted(c)
	msg := sprintf("%s: container %q needs a RuntimeDefault or Localhost seccomp profile", [k8s.name, c.name])
}

deny contains msg if {
	k8s.is_workload
	some field in ["hostNetwork", "hostPID", "hostIPC"]
	k8s.pod_spec[field] == true
	msg := sprintf("%s: %s is not allowed", [k8s.name, field])
}

deny contains msg if {
	k8s.is_workload
	some v in object.get(k8s.pod_spec, "volumes", [])
	v.hostPath
	msg := sprintf("%s: hostPath volume %q is not allowed", [k8s.name, v.name])
}

# Long-running workloads need both probes. A workload may opt out with an
# annotation that states why; the reason is surfaced as a warning.
probe_exempt if k8s.annotations["policy.akibullah.dev/probes-exempt"] != ""

deny contains msg if {
	k8s.is_long_running
	not probe_exempt
	some c in k8s.pod_spec.containers
	some probe in ["readinessProbe", "livenessProbe"]
	not c[probe]
	msg := sprintf("%s: container %q must define %s", [k8s.name, c.name, probe])
}

warn contains msg if {
	k8s.is_long_running
	probe_exempt
	msg := sprintf("%s: probes exempted (%s)", [k8s.name, k8s.annotations["policy.akibullah.dev/probes-exempt"]])
}

required_labels := ["app.kubernetes.io/name", "app.kubernetes.io/instance", "app.kubernetes.io/part-of"]

deny contains msg if {
	k8s.is_workload
	not k8s.is_hook
	some l in required_labels
	not k8s.pod_labels[l]
	msg := sprintf("%s: pod template is missing label %q", [k8s.name, l])
}

deny contains msg if {
	k8s.environment == "prod"
	input.kind == "Deployment"
	input.spec.replicas < 2
	msg := sprintf("%s: prod Deployments need at least 2 replicas (or an HPA)", [k8s.name])
}
