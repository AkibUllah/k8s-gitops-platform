# Rules for how workloads are exposed and configured per environment.
package main

import data.lib.k8s

deny contains msg if {
	input.kind == "Service"
	input.spec.type in {"NodePort", "LoadBalancer"}
	not k8s.annotations["policy.akibullah.dev/allow-external-service"]
	msg := sprintf("%s: type %s bypasses the ingress controller; annotate policy.akibullah.dev/allow-external-service with a reason if intended", [k8s.name, input.spec.type])
}

deny contains msg if {
	input.kind == "Ingress"
	k8s.environment in {"staging", "prod"}
	some rule in input.spec.rules
	not host_has_tls(rule.host)
	msg := sprintf("%s: host %q has no TLS entry; %s ingresses must terminate TLS", [k8s.name, rule.host, k8s.environment])
}

host_has_tls(host) if {
	some t in input.spec.tls
	host in t.hosts
}

# Secret values for staging and prod come from External Secrets or Sealed
# Secrets, never from chart values committed to Git.
deny contains msg if {
	input.kind == "Secret"
	k8s.environment in {"staging", "prod"}
	msg := sprintf("%s: plain Secret rendered for %s; reference an existingSecret managed by External Secrets or Sealed Secrets", [k8s.name, k8s.environment])
}

deny contains msg if {
	input.kind == "Ingress"
	some rule in input.spec.rules
	endswith(rule.host, ".nip.io")
	k8s.environment in {"staging", "prod"}
	msg := sprintf("%s: wildcard DNS host %q is for local clusters only", [k8s.name, rule.host])
}
