{{/* Derived from boutique-eks-argocd@446ed56 deploy/helm/boutique/templates/_helpers.tpl; modified for finops-spot-demo */}}
{{- define "boutique.name" -}}
{{- default .Chart.Name .Values.nameOverride -}}
{{- end -}}

{{- define "boutique.namespace" -}}
{{- default "boutique" .Values.namespace -}}
{{- end -}}

{{- define "boutique.imageRepo" -}}
{{- $root := .root -}}
{{- $svcName := .svcName -}}
{{- $registry := $root.Values.image.registry | trimSuffix "/" -}}
{{- $prefix := $root.Values.image.repositoryPrefix | trimSuffix "/" -}}
{{- if $registry -}}
{{- printf "%s/%s/%s" $registry $prefix $svcName -}}
{{- else -}}
{{- printf "%s/%s" $prefix $svcName -}}
{{- end -}}
{{- end -}}
{{- define "boutique.scaler" -}}
{{- required "scheduling.scaler is required (ca | karpenter | automode); pass -f values-<scaler>.yaml" .Values.scheduling.scaler -}}
{{- end -}}
