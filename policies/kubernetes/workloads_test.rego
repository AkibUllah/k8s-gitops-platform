package main

# A Deployment that satisfies every rule; tests mutate one field at a time.
good_container := {
	"name": "app",
	"image": "ghcr.io/akibullah/webhook-relay:1.1.2",
	"resources": {"requests": {"cpu": "100m", "memory": "128Mi"}, "limits": {"memory": "256Mi"}},
	"securityContext": {
		"allowPrivilegeEscalation": false,
		"readOnlyRootFilesystem": true,
		"capabilities": {"drop": ["ALL"]},
	},
	"readinessProbe": {"httpGet": {"path": "/health", "port": "http"}},
	"livenessProbe": {"httpGet": {"path": "/health", "port": "http"}},
}

pod_labels := {
	"app.kubernetes.io/name": "webhook-relay",
	"app.kubernetes.io/instance": "webhook-relay",
	"app.kubernetes.io/part-of": "commerce-platform",
}

deployment(container) := deployment_with(container, {}, {})

deployment_with(container, pod_overrides, meta_overrides) := {
	"apiVersion": "apps/v1",
	"kind": "Deployment",
	"metadata": object.union({"name": "webhook-relay", "labels": {"platform.akibullah.dev/environment": "dev"}}, meta_overrides),
	"spec": {
		"replicas": 2,
		"template": {
			"metadata": {"labels": pod_labels},
			"spec": shallow_merge(
				{
					"securityContext": {"runAsNonRoot": true, "runAsUser": 10001, "seccompProfile": {"type": "RuntimeDefault"}},
					"containers": [container],
				},
				pod_overrides,
			),
		},
	},
}

# object.union merges recursively; overrides here must replace whole keys.
shallow_merge(a, b) := object.union(object.remove(a, object.keys(b)), b)

with_field(obj, key, value) := shallow_merge(obj, {key: value})

with_security(key, value) := with_field(good_container, "securityContext", shallow_merge(good_container.securityContext, {key: value}))

test_compliant_deployment_passes if {
	count(deny) == 0 with input as deployment(good_container)
	count(warn) == 0 with input as deployment(good_container)
}

test_latest_tag_denied if {
	some msg in deny with input as deployment(with_field(good_container, "image", "ghcr.io/akibullah/webhook-relay:latest"))
	contains(msg, "unpinned image")
}

test_untagged_image_denied if {
	some msg in deny with input as deployment(with_field(good_container, "image", "redis"))
	contains(msg, "unpinned image")
}

test_registry_port_is_not_a_tag if {
	some msg in deny with input as deployment(with_field(good_container, "image", "registry.local:5000/team/app"))
	contains(msg, "unpinned image")
}

test_digest_and_registry_port_tag_allowed if {
	count(deny) == 0 with input as deployment(with_field(good_container, "image", "registry.local:5000/team/app@sha256:4b8c"))
	count(deny) == 0 with input as deployment(with_field(good_container, "image", "registry.local:5000/team/app:2.3.1"))
}

test_missing_requests_and_memory_limit_denied if {
	no_resources := object.remove(good_container, ["resources"])
	msgs := deny with input as deployment(no_resources)
	some a in msgs
	contains(a, "requests.cpu")
	some b in msgs
	contains(b, "requests.memory")
	some c in msgs
	contains(c, "limits.memory")
}

test_cpu_limit_not_required if {
	count(deny) == 0 with input as deployment(good_container)
}

test_root_user_denied if {
	d := deployment_with(good_container, {"securityContext": {"runAsNonRoot": true, "runAsUser": 0, "seccompProfile": {"type": "RuntimeDefault"}}}, {})
	some msg in deny with input as d
	contains(msg, "UID 0")
}

test_missing_run_as_non_root_denied if {
	d := deployment_with(good_container, {"securityContext": {"seccompProfile": {"type": "RuntimeDefault"}}}, {})
	some msg in deny with input as d
	contains(msg, "runAsNonRoot")
}

test_container_can_override_pod_non_root_to_false if {
	some msg in deny with input as deployment(with_security("runAsNonRoot", false))
	contains(msg, "runAsNonRoot")
}

test_privilege_escalation_denied if {
	some msg in deny with input as deployment(with_security("allowPrivilegeEscalation", true))
	contains(msg, "allowPrivilegeEscalation")
}

test_writable_root_filesystem_denied if {
	some msg in deny with input as deployment(with_security("readOnlyRootFilesystem", false))
	contains(msg, "readOnlyRootFilesystem")
}

test_privileged_and_capabilities_denied if {
	msgs := deny with input as deployment(with_security("privileged", true))
	some a in msgs
	contains(a, "privileged")
	some msg in deny with input as deployment(with_security("capabilities", {"drop": ["NET_RAW"]}))
	contains(msg, "drop ALL")
}

test_missing_seccomp_denied if {
	d := deployment_with(good_container, {"securityContext": {"runAsNonRoot": true}}, {})
	some msg in deny with input as d
	contains(msg, "seccomp")
}

test_host_namespaces_and_host_path_denied if {
	msgs := deny with input as deployment_with(good_container, {"hostNetwork": true, "volumes": [{"name": "docker", "hostPath": {"path": "/var/run/docker.sock"}}]}, {})
	some a in msgs
	contains(a, "hostNetwork")
	some b in msgs
	contains(b, "hostPath")
}

test_init_containers_are_checked if {
	init := with_field(good_container, "image", "busybox")
	d := deployment_with(good_container, {"initContainers": [init]}, {})
	some msg in deny with input as d
	contains(msg, "busybox")
}

test_missing_probes_denied if {
	no_probes := object.remove(good_container, ["readinessProbe", "livenessProbe"])
	msgs := deny with input as deployment(no_probes)
	some a in msgs
	contains(a, "readinessProbe")
	some b in msgs
	contains(b, "livenessProbe")
}

test_probe_exemption_needs_annotation_and_warns if {
	no_probes := object.remove(good_container, ["readinessProbe", "livenessProbe"])
	d := deployment_with(no_probes, {}, {"annotations": {"policy.akibullah.dev/probes-exempt": "queue worker"}})
	count(deny) == 0 with input as d
	some msg in warn with input as d
	contains(msg, "queue worker")
}

test_jobs_do_not_need_probes if {
	no_probes := object.remove(good_container, ["readinessProbe", "livenessProbe"])
	job := {
		"kind": "Job",
		"metadata": {"name": "migrate"},
		"spec": {"template": {
			"metadata": {"labels": pod_labels},
			"spec": {"securityContext": {"runAsNonRoot": true, "seccompProfile": {"type": "RuntimeDefault"}}, "containers": [no_probes]},
		}},
	}
	count(deny) == 0 with input as job
}

test_missing_pod_labels_denied if {
	d := deployment(good_container)
	unlabelled := json.patch(d, [{"op": "remove", "path": "/spec/template/metadata/labels/app.kubernetes.io~1part-of"}])
	some msg in deny with input as unlabelled
	contains(msg, "app.kubernetes.io/part-of")
}

test_single_replica_prod_denied if {
	d := json.patch(deployment(good_container), [
		{"op": "replace", "path": "/metadata/labels/platform.akibullah.dev~1environment", "value": "prod"},
		{"op": "replace", "path": "/spec/replicas", "value": 1},
	])
	some msg in deny with input as d
	contains(msg, "at least 2 replicas")
}

test_cronjob_pod_spec_is_found if {
	cj := {
		"kind": "CronJob",
		"metadata": {"name": "report"},
		"spec": {"jobTemplate": {"spec": {"template": {
			"metadata": {"labels": pod_labels},
			"spec": {"securityContext": {"runAsNonRoot": true, "seccompProfile": {"type": "RuntimeDefault"}}, "containers": [with_field(good_container, "image", "report:latest")]},
		}}}},
	}
	some msg in deny with input as cj
	contains(msg, "unpinned image")
}

test_missing_container_security_context_denied if {
	msgs := deny with input as deployment(object.remove(good_container, ["securityContext"]))
	some a in msgs
	contains(a, "allowPrivilegeEscalation")
	some b in msgs
	contains(b, "readOnlyRootFilesystem")
	some c in msgs
	contains(c, "drop ALL")
}
