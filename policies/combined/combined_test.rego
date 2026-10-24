package combined

labels := {"app.kubernetes.io/name": "pay", "app.kubernetes.io/instance": "pay"}

deploy(env, replicas) := d if {
	base := {
		"kind": "Deployment",
		"metadata": {"name": "pay", "labels": {"platform.akibullah.dev/environment": env}},
		"spec": {"template": {"metadata": {"labels": object.union(labels, {"app.kubernetes.io/version": "1.0.4"})}}},
	}
	d := json.patch(base, [{"op": "add", "path": "/spec/replicas", "value": replicas}])
}

deploy_hpa(env) := {
	"kind": "Deployment",
	"metadata": {"name": "pay", "labels": {"platform.akibullah.dev/environment": env}},
	"spec": {"template": {"metadata": {"labels": labels}}},
}

pdb := {"kind": "PodDisruptionBudget", "metadata": {"name": "pay"}, "spec": {"selector": {"matchLabels": labels}}}

hpa(target) := {"kind": "HorizontalPodAutoscaler", "metadata": {"name": "pay"}, "spec": {"scaleTargetRef": {"kind": "Deployment", "name": target}}}

service(name, selector) := {"kind": "Service", "metadata": {"name": name}, "spec": {"selector": selector}}

ingress(backend) := {"kind": "Ingress", "metadata": {"name": "pay"}, "spec": {"rules": [{
	"host": "pay.dokan.com.bd",
	"http": {"paths": [{"path": "/", "backend": {"service": {"name": backend}}}]},
}]}}

# Mirrors conftest --combine: one entry per file, multi-document files as lists.
files(docs) := [{"path": "release.yaml", "contents": docs}]

test_complete_release_passes if {
	docs := [deploy_hpa("prod"), pdb, hpa("pay"), service("pay", labels), ingress("pay")]
	count(deny) == 0 with input as files(docs)
}

test_single_document_files_are_read if {
	inp := [
		{"path": "deploy.yaml", "contents": deploy("prod", 3)},
		{"path": "pdb.yaml", "contents": pdb},
	]
	count(deny) == 0 with input as inp
}

test_prod_deployment_without_pdb_denied if {
	some msg in deny with input as files([deploy("prod", 3)])
	contains(msg, "no PodDisruptionBudget")
}

test_hpa_scaled_deployment_counts_as_multi_replica if {
	some msg in deny with input as files([deploy_hpa("staging"), hpa("pay")])
	contains(msg, "no PodDisruptionBudget")
}

test_dev_and_single_replica_need_no_pdb if {
	count(deny) == 0 with input as files([deploy("dev", 3)])
	count(deny) == 0 with input as files([deploy("prod", 1)])
}

test_hpa_with_missing_target_denied if {
	some msg in deny with input as files([hpa("payments")])
	contains(msg, "targets missing Deployment/payments")
}

test_fixed_replicas_with_hpa_denied if {
	some msg in deny with input as files([deploy("dev", 2), hpa("pay")])
	contains(msg, "sets spec.replicas")
}

test_ingress_to_missing_service_denied if {
	some msg in deny with input as files([ingress("pay-api")])
	contains(msg, "missing Service/pay-api")
}

test_service_selecting_nothing_denied if {
	some msg in deny with input as files([deploy("dev", 1), service("pay", {"app.kubernetes.io/name": "relay"})])
	contains(msg, "selects no pods")
	count(deny) == 0 with input as files([deploy("dev", 1), service("pay", labels)])
}

test_null_documents_are_ignored if {
	count(deny) == 0 with input as files([null, deploy("dev", 1)])
}
