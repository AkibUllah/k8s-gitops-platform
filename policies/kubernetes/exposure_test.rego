package main

svc(type, annotations) := {
	"kind": "Service",
	"metadata": {"name": "pay", "annotations": annotations},
	"spec": {"type": type, "selector": {"app": "pay"}},
}

ingress(env, hosts, tls) := {
	"kind": "Ingress",
	"metadata": {"name": "pay", "labels": {"platform.akibullah.dev/environment": env}},
	"spec": {
		"rules": [{"host": h} | some h in hosts],
		"tls": tls,
	},
}

test_cluster_ip_service_allowed if {
	count(deny) == 0 with input as svc("ClusterIP", {})
}

test_load_balancer_needs_annotation if {
	some msg in deny with input as svc("LoadBalancer", {})
	contains(msg, "bypasses the ingress controller")
	count(deny) == 0 with input as svc("LoadBalancer", {"policy.akibullah.dev/allow-external-service": "partner VPN endpoint"})
}

test_prod_ingress_requires_tls_for_every_host if {
	tls := [{"hosts": ["pay.dokan.com.bd"], "secretName": "pay-tls"}]
	count(deny) == 0 with input as ingress("prod", ["pay.dokan.com.bd"], tls)
	some msg in deny with input as ingress("prod", ["pay.dokan.com.bd", "api.dokan.com.bd"], tls)
	contains(msg, "api.dokan.com.bd")
}

test_dev_ingress_may_skip_tls if {
	count(deny) == 0 with input as ingress("dev", ["pay.dev.dokan.com.bd"], [])
}

test_nip_io_hosts_only_outside_staging_and_prod if {
	count(deny) == 0 with input as ingress("dev", ["pay.127.0.0.1.nip.io"], [])
	some msg in deny with input as ingress("staging", ["pay.127.0.0.1.nip.io"], [{"hosts": ["pay.127.0.0.1.nip.io"]}])
	contains(msg, "wildcard DNS")
}

secret(env) := {"kind": "Secret", "metadata": {"name": "keys", "labels": {"platform.akibullah.dev/environment": env}}}

test_plain_secrets_denied_in_staging_and_prod if {
	some msg in deny with input as secret("prod")
	contains(msg, "External Secrets")
	count(deny) > 0 with input as secret("staging")
	count(deny) == 0 with input as secret("dev")
}
