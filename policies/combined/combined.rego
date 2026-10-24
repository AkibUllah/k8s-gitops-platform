# Cross-document rules, evaluated over a whole rendered release:
#   conftest test --combine --namespace combined --policy policies <manifests>
package combined

# conftest --combine passes [{path, contents}], where contents is one document
# or a list of documents for multi-document YAML.
documents contains d if {
	some f in input
	is_array(f.contents)
	some d in f.contents
	is_object(d)
}

documents contains d if {
	some f in input
	is_object(f.contents)
	d := f.contents
}

env(d) := object.get(d.metadata, ["labels", "platform.akibullah.dev/environment"], "")

pod_labels(d) := object.get(d.spec.template.metadata, "labels", {})

selects(selector, labels) if {
	every k, v in selector {
		labels[k] == v
	}
}

deployments contains d if {
	some d in documents
	d.kind == "Deployment"
}

# A staging/prod Deployment that can have more than one replica must be
# covered by a PodDisruptionBudget, or node drains can take it to zero.
deny contains msg if {
	some d in deployments
	env(d) in {"staging", "prod"}
	object.get(d.spec, "replicas", 2) > 1
	not has_pdb(d)
	msg := sprintf("Deployment/%s (%s) has no PodDisruptionBudget", [d.metadata.name, env(d)])
}

has_pdb(d) if {
	some p in documents
	p.kind == "PodDisruptionBudget"
	selects(p.spec.selector.matchLabels, pod_labels(d))
}

deny contains msg if {
	some h in documents
	h.kind == "HorizontalPodAutoscaler"
	ref := h.spec.scaleTargetRef
	not target_exists(ref)
	msg := sprintf("HorizontalPodAutoscaler/%s targets missing %s/%s", [h.metadata.name, ref.kind, ref.name])
}

target_exists(ref) if {
	some d in documents
	d.kind == ref.kind
	d.metadata.name == ref.name
}

# An HPA owns the replica count; a fixed spec.replicas would fight it on every sync.
deny contains msg if {
	some h in documents
	h.kind == "HorizontalPodAutoscaler"
	some d in deployments
	d.metadata.name == h.spec.scaleTargetRef.name
	d.spec.replicas
	msg := sprintf("Deployment/%s sets spec.replicas but is scaled by HorizontalPodAutoscaler/%s", [d.metadata.name, h.metadata.name])
}

deny contains msg if {
	some i in documents
	i.kind == "Ingress"
	some rule in i.spec.rules
	some p in rule.http.paths
	svc := p.backend.service.name
	not service_exists(svc)
	msg := sprintf("Ingress/%s routes %s%s to missing Service/%s", [i.metadata.name, rule.host, p.path, svc])
}

service_exists(name) if {
	some s in documents
	s.kind == "Service"
	s.metadata.name == name
}

deny contains msg if {
	some s in documents
	s.kind == "Service"
	sel := object.get(s.spec, "selector", {})
	count(sel) > 0
	not selects_some_pod(sel)
	msg := sprintf("Service/%s selects no pods in this release", [s.metadata.name])
}

selects_some_pod(sel) if {
	some d in documents
	d.kind in {"Deployment", "StatefulSet", "DaemonSet"}
	selects(sel, pod_labels(d))
}
