{{- define "minishop.image" -}}
{{- $image := index .root.Values.images .name -}}
{{ printf "%s@%s" $image.repository $image.digest }}
{{- end -}}
